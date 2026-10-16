import Foundation
import Network

/// 通过 NWConnection 连接 `127.0.0.1:port` 的 transport（macOS 宿主、iOS 模拟器）。
nonisolated final class ViewScopeLoopbackTransport: ViewScopeByteTransport, @unchecked Sendable {
    /// 单次 receive 的最大长度。
    private static let maximumReceiveLength = 1 << 20

    private let port: UInt16
    private let queue: DispatchQueue
    /// 以下状态只在 `queue` 上读写。
    private var connection: NWConnection?
    private var eventHandler: (@Sendable (ViewScopeTransportEvent) -> Void)?
    private var isFinished = false

    init(port: UInt16) {
        self.port = port
        self.queue = DispatchQueue(label: "cn.vanjay.ViewScope.loopback-transport.\(port)", qos: .userInitiated)
    }

    func start(eventHandler: @escaping @Sendable (ViewScopeTransportEvent) -> Void) {
        queue.async { [self] in
            guard isFinished == false, connection == nil else {
                return
            }
            self.eventHandler = eventHandler
            guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
                close(with: ViewScopeTransportError.invalidPort)
                return
            }
            let connection = NWConnection(
                host: NWEndpoint.Host.ipv4(IPv4Address.loopback),
                port: endpointPort,
                using: .tcp
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                // stateUpdateHandler 在 queue 上回调
                self?.handle(state: state)
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        queue.async { [self] in
            guard isFinished == false, let connection else {
                completion(ViewScopeTransportError.notConnected)
                return
            }
            connection.send(content: data, completion: .contentProcessed { error in
                completion(error)
            })
        }
    }

    func cancel() {
        queue.async { [self] in
            // 主动取消：不再回调任何事件
            eventHandler = nil
            isFinished = true
            connection?.stateUpdateHandler = nil
            connection?.cancel()
        }
    }

    private func handle(state: NWConnection.State) {
        guard isFinished == false else {
            return
        }
        switch state {
        case .ready:
            eventHandler?(.ready)
            receiveNextChunk()
        case .waiting(let error):
            // loopback 上 waiting 通常意味着端口未监听（连接被拒绝），NWConnection 会一直重试，这里直接失败
            close(with: error)
        case .failed(let error):
            close(with: error)
        case .cancelled:
            close(with: nil)
        default:
            break
        }
    }

    private func receiveNextChunk() {
        guard isFinished == false, let connection else {
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumReceiveLength) { [weak self] data, _, isComplete, error in
            // receive 回调同样在 queue 上
            guard let self else {
                return
            }
            self.handleReceive(data: data, isComplete: isComplete, error: error)
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard isFinished == false else {
            return
        }
        if let data, data.isEmpty == false {
            eventHandler?(.data(data))
        }
        if let error {
            close(with: error)
            return
        }
        if isComplete {
            close(with: nil)
            return
        }
        receiveNextChunk()
    }

    /// 结束连接并回调一次 `.closed`。
    private func close(with error: (any Error)?) {
        guard isFinished == false else {
            return
        }
        isFinished = true
        let handler = eventHandler
        eventHandler = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        handler?(.closed(error))
    }
}
