import Darwin
import Foundation

/// 通过 usbmuxd 连接到 iOS 真机上 `port` 的 transport。
///
/// 流程：连接 `/var/run/usbmuxd` → 发送 Connect（DeviceID + 网络字节序端口）→ Result Number == 0 后，
/// 该 socket 变为与设备端口之间的原始字节隧道。读取用 DispatchSourceRead，写入走独立串行队列。
nonisolated final class ViewScopeUSBMuxTunnelTransport: ViewScopeByteTransport, @unchecked Sendable {
    /// 单次读取上限。
    private static let maximumReadLength = 1 << 20
    /// 单次读取下限（DispatchSource 估算值可能为 0）。
    private static let minimumReadLength = 64 * 1024

    let deviceID: Int
    let port: UInt16
    private let socketPath: String
    private let connectTimeout: TimeInterval
    private let writeTimeout: TimeInterval
    /// 事件与读取所在的串行队列。
    private let queue: DispatchQueue
    /// 写入与关闭 fd 所在的串行队列，保证 fd 关闭发生在所有已排队写入之后。
    private let writeQueue: DispatchQueue

    /// 以下两项由 lock 保护，可在任意线程访问。
    private let lock = NSLock()
    private var isCancelled = false
    private var writableDescriptor: Int32 = -1

    /// 以下状态只在 queue 上访问。
    private var eventHandler: (@Sendable (ViewScopeTransportEvent) -> Void)?
    private var readSource: (any DispatchSourceRead)?
    private var tunnelDescriptor: Int32 = -1
    private var hasStarted = false
    private var isFinished = false

    init(
        deviceID: Int,
        port: UInt16,
        socketPath: String = ViewScopeUSBMuxPacket.defaultSocketPath,
        connectTimeout: TimeInterval = 5,
        writeTimeout: TimeInterval = 30
    ) {
        self.deviceID = deviceID
        self.port = port
        self.socketPath = socketPath
        self.connectTimeout = connectTimeout
        self.writeTimeout = writeTimeout
        self.queue = DispatchQueue(label: "cn.vanjay.ViewScope.usbmux-tunnel.\(deviceID).\(port)", qos: .userInitiated)
        self.writeQueue = DispatchQueue(label: "cn.vanjay.ViewScope.usbmux-tunnel-write.\(deviceID).\(port)", qos: .userInitiated)
    }

    private var cancelled: Bool {
        lock.withLock {
            isCancelled
        }
    }

    func start(eventHandler: @escaping @Sendable (ViewScopeTransportEvent) -> Void) {
        queue.async { [self] in
            guard hasStarted == false, isFinished == false else {
                return
            }
            hasStarted = true
            self.eventHandler = eventHandler

            // usbmuxd 是本地 socket，阻塞式握手耗时很短，且受 connectTimeout 限制
            let descriptor: Int32
            do {
                descriptor = try ViewScopeUSBMuxSocket.connectTunnel(
                    path: socketPath,
                    deviceID: deviceID,
                    port: port,
                    timeout: connectTimeout
                )
            } catch {
                finish(with: error)
                return
            }
            if cancelled || isFinished {
                Darwin.close(descriptor)
                return
            }

            tunnelDescriptor = descriptor
            lock.withLock {
                writableDescriptor = descriptor
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in
                self?.readAvailableBytes()
            }
            // cancel handler 持有 self，source 取消后释放，fd 只在这里关闭一次
            source.setCancelHandler { [self] in
                closeDescriptor(descriptor)
            }
            readSource = source
            source.resume()
            emit(.ready)
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let timeout = writeTimeout
        writeQueue.async { [self] in
            let descriptor = lock.withLock {
                writableDescriptor
            }
            guard descriptor >= 0 else {
                completion(ViewScopeTransportError.notConnected)
                return
            }
            do {
                try ViewScopeUSBMuxSocket.writeAllNonBlocking(fd: descriptor, data: data, timeout: timeout)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
        }
        queue.async { [self] in
            // 主动取消：不再回调事件
            isFinished = true
            eventHandler = nil
            tearDown()
        }
    }

    // MARK: - 私有

    private func emit(_ event: ViewScopeTransportEvent) {
        guard isFinished == false, cancelled == false else {
            return
        }
        eventHandler?(event)
    }

    private func readAvailableBytes() {
        guard isFinished == false, tunnelDescriptor >= 0 else {
            return
        }
        let estimated = Int(readSource?.data ?? 0)
        let length = min(max(estimated, Self.minimumReadLength), Self.maximumReadLength)
        var buffer = Data(count: length)
        let descriptor = tunnelDescriptor
        let result = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else {
                return 0
            }
            return Darwin.read(descriptor, base, length)
        }
        if result > 0 {
            buffer.count = result
            emit(.data(buffer))
            return
        }
        if result == 0 {
            // EOF：对端关闭
            finish(with: nil)
            return
        }
        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK || code == EINTR {
            return
        }
        finish(with: ViewScopeTransportError.posix(code))
    }

    /// 连接结束：回调一次 `.closed` 并释放资源。
    private func finish(with error: (any Error)?) {
        guard isFinished == false else {
            return
        }
        isFinished = true
        let handler = eventHandler
        eventHandler = nil
        tearDown()
        if cancelled == false {
            handler?(.closed(error))
        }
    }

    private func tearDown() {
        if tunnelDescriptor >= 0 {
            // 先 shutdown，让写队列中阻塞/等待的写入尽快失败，随后由 cancel handler 关闭 fd
            Darwin.shutdown(tunnelDescriptor, SHUT_RDWR)
            tunnelDescriptor = -1
        }
        if let source = readSource {
            readSource = nil
            source.cancel()
        }
    }

    private func closeDescriptor(_ descriptor: Int32) {
        writeQueue.async { [self] in
            lock.withLock {
                if writableDescriptor == descriptor {
                    writableDescriptor = -1
                }
            }
            Darwin.close(descriptor)
        }
    }
}
