import Darwin
import Foundation

/// usbmuxd 本地 socket 的阻塞式 POSIX 工具。只能在后台队列调用。
nonisolated enum ViewScopeUSBMuxSocket {
    /// 打开并连接 usbmuxd 的 AF_UNIX socket，设置收发超时与 SO_NOSIGPIPE。
    static func open(path: String, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ViewScopeTransportError.usbmuxUnavailable(String(cString: strerror(errno)))
        }
        // 对端关闭后写入不触发 SIGPIPE，改为返回 EPIPE
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd: fd, timeout: timeout)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw ViewScopeTransportError.usbmuxUnavailable(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
            buffer[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ViewScopeTransportError.usbmuxUnavailable(reason)
        }
        return fd
    }

    /// 设置收发超时；timeout <= 0 时清除超时（隧道建立后需要清除）。
    static func setTimeout(fd: Int32, timeout: TimeInterval) {
        var value = timeval()
        if timeout > 0 {
            value.tv_sec = Int(timeout)
            value.tv_usec = Int32((timeout - Double(Int(timeout))) * 1_000_000)
        }
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// 设置为非阻塞，供 DispatchSourceRead 使用。
    static func setNonBlocking(fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// 阻塞写入全部数据（受 SO_SNDTIMEO 限制）。
    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else {
                return
            }
            var written = 0
            while written < raw.count {
                let result = Darwin.write(fd, base + written, raw.count - written)
                if result > 0 {
                    written += result
                    continue
                }
                if result < 0 && errno == EINTR {
                    continue
                }
                if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw ViewScopeTransportError.timedOut
                }
                throw ViewScopeTransportError.posix(result < 0 ? errno : EPIPE)
            }
        }
    }

    /// 向非阻塞 fd 写入全部数据：缓冲区满时 poll 等待可写，直到 deadline。
    static func writeAllNonBlocking(fd: Int32, data: Data, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else {
                return
            }
            var written = 0
            while written < raw.count {
                let result = Darwin.write(fd, base + written, raw.count - written)
                if result > 0 {
                    written += result
                    continue
                }
                if result < 0 && errno == EINTR {
                    continue
                }
                if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else {
                        throw ViewScopeTransportError.timedOut
                    }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
                    continue
                }
                throw ViewScopeTransportError.posix(result < 0 ? errno : EPIPE)
            }
        }
    }

    /// 阻塞读取恰好 count 字节（受 SO_RCVTIMEO 限制）。
    static func readExactly(fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var received = 0
        try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else {
                return
            }
            while received < count {
                let result = Darwin.read(fd, base + received, count - received)
                if result > 0 {
                    received += result
                    continue
                }
                if result == 0 {
                    throw ViewScopeTransportError.notConnected
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ViewScopeTransportError.timedOut
                }
                throw ViewScopeTransportError.posix(errno)
            }
        }
        return data
    }

    /// 阻塞读取一个完整报文；只读取该报文的字节，不会多读隧道数据。
    static func readPacket(fd: Int32) throws -> ViewScopeUSBMuxPacket.Packet {
        let headerData = try readExactly(fd: fd, count: ViewScopeUSBMuxPacket.headerLength)
        guard let header = ViewScopeUSBMuxPacket.decodeHeader(headerData) else {
            throw ViewScopeTransportError.usbmuxProtocol
        }
        let length = Int(header.length)
        guard length >= ViewScopeUSBMuxPacket.headerLength,
              length <= ViewScopeUSBMuxPacket.maximumPacketLength else {
            throw ViewScopeTransportError.usbmuxProtocol
        }
        let body = try readExactly(fd: fd, count: length - ViewScopeUSBMuxPacket.headerLength)
        return ViewScopeUSBMuxPacket.Packet(header: header, payload: try ViewScopeUSBMuxPacket.decodePayload(body))
    }

    /// 发送请求并读取一个 Result 报文，检查 Number == 0。
    static func performResultRequest(fd: Int32, payload: [String: Any], tag: UInt32) throws {
        try writeAll(fd: fd, data: try ViewScopeUSBMuxPacket.encode(payload: payload, tag: tag))
        let response = try readPacket(fd: fd)
        guard let number = ViewScopeUSBMuxPacket.resultNumber(in: response.payload) else {
            throw ViewScopeTransportError.usbmuxProtocol
        }
        guard number == 0 else {
            throw ViewScopeTransportError.usbmuxRefused(number)
        }
    }

    /// 一次性 ListDevices 请求。
    static func listDevices(path: String, timeout: TimeInterval) throws -> [ViewScopeUSBDevice] {
        let fd = try open(path: path, timeout: timeout)
        defer {
            Darwin.close(fd)
        }
        try writeAll(fd: fd, data: try ViewScopeUSBMuxPacket.encode(payload: ViewScopeUSBMuxPacket.listDevicesPayload(), tag: 1))
        let response = try readPacket(fd: fd)
        return ViewScopeUSBMuxPacket.devices(fromDeviceList: response.payload)
    }

    /// 通过 usbmuxd Connect 到设备端口，成功后返回已切换为原始隧道的非阻塞 fd（调用方负责关闭）。
    static func connectTunnel(path: String, deviceID: Int, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        let fd = try open(path: path, timeout: timeout)
        do {
            try performResultRequest(
                fd: fd,
                payload: ViewScopeUSBMuxPacket.connectPayload(deviceID: deviceID, port: port),
                tag: 1
            )
        } catch {
            Darwin.close(fd)
            throw error
        }
        // 隧道建立后清除超时，之后读写由调用方用 DispatchSource / poll 控制
        setTimeout(fd: fd, timeout: 0)
        setNonBlocking(fd: fd)
        return fd
    }
}
