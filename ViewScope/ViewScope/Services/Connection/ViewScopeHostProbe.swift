import Foundation
import ViewScopeServer

/// 发现探测：在一个 transport 上发送 `discoveryRequest`，等待 `discoveryResponse` 中的 announcement。
nonisolated enum ViewScopeHostProbe {
    /// 探测 loopback 端口。
    static func probeLoopback(port: UInt16, timeout: TimeInterval) async -> ViewScopeHostAnnouncement? {
        // 端口段里绝大多数端口没有监听者。先用 POSIX 非阻塞 connect 做一次廉价预检，
        // 只对真正在监听的端口创建 NWConnection，避免每轮扫描都让 Network.framework
        // 在控制台刷出几十条 `nw_endpoint_flow_failed_with_error` 日志。
        guard isLoopbackPortListening(port, timeout: min(timeout, 0.2)) else {
            return nil
        }
        return await probe(transport: ViewScopeLoopbackTransport(port: port), timeout: timeout)
    }

    /// 判断 `127.0.0.1:port` 是否有进程在监听。loopback 上被拒绝的连接会立即失败。
    static func isLoopbackPortListening(_ port: UInt16, timeout: TimeInterval) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            // 无法创建 socket 时退回完整探测，不误判为无宿主
            return true
        }
        defer {
            Darwin.close(descriptor)
        }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            return true
        }
        guard errno == EINPROGRESS else {
            return false
        }
        // 连接进行中：等待可写后读取 SO_ERROR 得到最终结果
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(max(timeout, 0.01) * 1000)
        guard poll(&pollDescriptor, 1, milliseconds) > 0 else {
            return false
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return false
        }
        return socketError == 0
    }

    /// 通过 usbmuxd 探测设备端口。
    static func probeUSB(device: ViewScopeUSBDevice, port: UInt16, timeout: TimeInterval) async -> ViewScopeHostAnnouncement? {
        let transport = ViewScopeUSBMuxTunnelTransport(
            deviceID: device.deviceID,
            port: port,
            connectTimeout: timeout,
            writeTimeout: timeout
        )
        return await probe(transport: transport, timeout: timeout)
    }

    /// 在给定 transport 上执行一次探测；超时、出错或对端不是 ViewScope 宿主时返回 nil。
    static func probe(transport: any ViewScopeByteTransport, timeout: TimeInterval) async -> ViewScopeHostAnnouncement? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ViewScopeHostAnnouncement?, Never>) in
            let operation = ProbeOperation(transport: transport, continuation: continuation)
            operation.begin(timeout: timeout)
        }
    }
}

/// 单次探测的状态机；continuation 只恢复一次。
nonisolated private final class ProbeOperation: @unchecked Sendable {
    private let transport: any ViewScopeByteTransport
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ViewScopeHostAnnouncement?, Never>?
    /// 只在 transport 的事件队列上使用。
    private let decoder = ViewScopeMessageStreamDecoder(maximumBufferSize: 4 * 1024 * 1024)
    private let requestID = UUID().uuidString

    init(transport: any ViewScopeByteTransport, continuation: CheckedContinuation<ViewScopeHostAnnouncement?, Never>) {
        self.transport = transport
        self.continuation = continuation
    }

    func begin(timeout: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
            finish(nil)
        }
        transport.start { [self] event in
            handle(event)
        }
    }

    private func handle(_ event: ViewScopeTransportEvent) {
        switch event {
        case .ready:
            sendDiscoveryRequest()
        case .data(let data):
            for output in decoder.consume(data) {
                switch output {
                case .message(let message):
                    if message.kind == .discoveryResponse, let announcement = message.announcement {
                        finish(announcement)
                        return
                    }
                    if message.kind == .error {
                        finish(nil)
                        return
                    }
                case .undecodable, .overflow:
                    finish(nil)
                    return
                }
            }
        case .closed:
            finish(nil)
        }
    }

    private func sendDiscoveryRequest() {
        let message = ViewScopeMessage(kind: .discoveryRequest, requestID: requestID)
        guard let data = try? ViewScopeConnectionCoding.encodeLine(message, encoder: ViewScopeConnectionCoding.makeEncoder()) else {
            finish(nil)
            return
        }
        transport.send(data) { [self] error in
            if error != nil {
                finish(nil)
            }
        }
    }

    private func finish(_ announcement: ViewScopeHostAnnouncement?) {
        let pending: CheckedContinuation<ViewScopeHostAnnouncement?, Never>? = lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
        guard let pending else {
            return
        }
        // 取消 transport 会释放其持有的事件闭包，从而打破 operation ↔ transport 的循环引用
        transport.cancel()
        pending.resume(returning: announcement)
    }
}
