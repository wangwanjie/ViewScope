import Foundation

/// 字节传输层事件。实现方保证同一个 transport 的事件在其内部串行队列上按顺序回调。
nonisolated enum ViewScopeTransportEvent: Sendable {
    /// 底层连接已建立，可以收发数据。
    case ready
    /// 收到一段原始字节（未分帧）。
    case data(Data)
    /// 连接被对端关闭（error 为 nil，表示 EOF）或出错。之后不会再有任何事件。
    case closed((any Error)?)
}

/// 客户端与宿主之间的原始字节通道：loopback TCP 或 usbmuxd 隧道。
///
/// 约定：
/// - `start` 只调用一次；事件处理闭包在 transport 内部串行队列上调用；
/// - `cancel()` 之后不再回调任何事件（包括 `.closed`），可重复调用；
/// - `send` 的 completion 在任意后台队列回调，失败时带 error。
nonisolated protocol ViewScopeByteTransport: AnyObject, Sendable {
    func start(eventHandler: @escaping @Sendable (ViewScopeTransportEvent) -> Void)
    func send(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void)
    func cancel()
}

/// 传输层错误。
nonisolated enum ViewScopeTransportError: LocalizedError, Equatable {
    /// 端口非法。
    case invalidPort
    /// 连接尚未建立或已经关闭。
    case notConnected
    /// usb 宿主缺少 DeviceID，无法建立隧道。
    case missingDevice
    /// 无法连接 usbmuxd 本地 socket。
    case usbmuxUnavailable(String)
    /// usbmuxd 拒绝了请求（Result Number 非 0）。
    case usbmuxRefused(Int)
    /// usbmuxd 返回了无法识别的数据。
    case usbmuxProtocol
    /// 底层读写超时。
    case timedOut
    /// 其他 POSIX 错误。
    case posix(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return L10n.connectionErrorInvalidPort
        case .notConnected:
            return L10n.connectionErrorNotConnected
        case .missingDevice:
            return L10n.connectionErrorMissingDevice
        case .usbmuxUnavailable(let reason):
            return L10n.connectionErrorUSBMuxUnavailable(reason)
        case .usbmuxRefused(let code):
            return L10n.connectionErrorUSBMuxRefused(code)
        case .usbmuxProtocol:
            return L10n.connectionErrorUSBMuxProtocol
        case .timedOut:
            return L10n.connectionErrorTransportTimeout
        case .posix(let code):
            return String(cString: strerror(code))
        }
    }
}

/// 无法建立连接时使用的占位 transport：启动后立即以给定错误关闭。
nonisolated final class ViewScopeUnavailableTransport: ViewScopeByteTransport, @unchecked Sendable {
    private let error: any Error
    private let lock = NSLock()
    private var isCancelled = false

    init(error: any Error) {
        self.error = error
    }

    func start(eventHandler: @escaping @Sendable (ViewScopeTransportEvent) -> Void) {
        let error = self.error
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            // 已取消则不再回调
            let cancelled = self.lock.withLock {
                self.isCancelled
            }
            if cancelled {
                return
            }
            eventHandler(.closed(error))
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        _ = data
        completion(ViewScopeTransportError.notConnected)
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
        }
    }
}
