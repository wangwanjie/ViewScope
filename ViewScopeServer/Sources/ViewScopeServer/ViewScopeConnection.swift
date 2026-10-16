import Foundation
import Network

/// Inspector 与单个客户端连接之间的抽象，便于在测试中用假连接驱动消息处理。
@MainActor
protocol ViewScopeMessageChannel: AnyObject {
    /// 是否已经通过 clientHello 认证。
    var isAuthenticated: Bool { get set }
    /// 协商后的协议版本。
    var negotiatedProtocolVersion: Int { get set }
    /// 客户端界面语言，用于本地化错误信息。
    var interfaceLanguage: ViewScopeInterfaceLanguage { get set }
    func send(_ message: ViewScopeMessage)
    func cancel()
}

/// 消息编码：编码失败（通常是 NaN/Inf）时把非有限数清洗为 0 后重试，保证 capture 不会整个发不出去（A3）。
enum ViewScopeMessageCoding {
    private static let nonFiniteSentinel = "__VIEWSCOPE_NON_FINITE__"

    static func encode(_ message: ViewScopeMessage) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(message) {
            return data
        }
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: nonFiniteSentinel,
            negativeInfinity: nonFiniteSentinel,
            nan: nonFiniteSentinel
        )
        guard let data = try? encoder.encode(message),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json.replacingOccurrences(of: "\"\(nonFiniteSentinel)\"", with: "0").data(using: .utf8)
    }

    static func decode(_ data: Data) throws -> ViewScopeMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ViewScopeMessage.self, from: data)
    }

    /// 无法解码的行：尽量取出 requestID，以便仍然回一条 error。
    static func extractRequestID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["requestID"] as? String
    }
}

/// 一个 TCP 连接：按换行分帧收发 JSON 消息。
@MainActor
final class ViewScopeServerConnection: ViewScopeMessageChannel {
    /// 单个未分帧缓冲区的上限，超过即判定为异常客户端并断开。
    static let maximumBufferedBytes = 32 << 20

    var isAuthenticated = false
    var negotiatedProtocolVersion = viewScopeCurrentProtocolVersion
    var interfaceLanguage = ViewScopeInterfaceLanguage.english

    private let connection: NWConnection
    private let onMessage: @MainActor (ViewScopeMessage, ViewScopeServerConnection) -> Void
    private let onDisconnect: @MainActor (ViewScopeServerConnection) -> Void
    private var incomingBuffer = Data()
    private var didDisconnect = false
    /// 编码与发送放在串行队列：不阻塞主线程（B12），同时保持响应顺序。
    private let sendQueue = DispatchQueue(label: "cn.vanjay.ViewScopeServer.send", qos: .userInitiated)

    init(
        connection: NWConnection,
        onMessage: @escaping @MainActor (ViewScopeMessage, ViewScopeServerConnection) -> Void,
        onDisconnect: @escaping @MainActor (ViewScopeServerConnection) -> Void
    ) {
        self.connection = connection
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handle(state: state)
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveNextChunk()
    }

    func send(_ message: ViewScopeMessage) {
        let connection = connection
        sendQueue.async {
            var data = ViewScopeMessageCoding.encode(message)
            if data == nil, message.requestID != nil {
                // 实在编码不了也要回一条 error，保证请求恰好得到一条响应。
                data = ViewScopeMessageCoding.encode(
                    ViewScopeMessage(
                        kind: .error,
                        requestID: message.requestID,
                        error: ViewScopeErrorPayload(message: "Failed to encode response.")
                    )
                )
            }
            guard var framed = data else {
                return
            }
            framed.append(0x0A)
            connection.send(content: framed, completion: .contentProcessed { _ in })
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                self?.handleReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            notifyDisconnect()
        default:
            break
        }
    }

    private func notifyDisconnect() {
        guard didDisconnect == false else {
            return
        }
        didDisconnect = true
        onDisconnect(self)
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard didDisconnect == false else {
            return
        }
        if let data, !data.isEmpty {
            incomingBuffer.append(data)
            while let newline = incomingBuffer.firstIndex(of: 0x0A) {
                let line = Data(incomingBuffer[incomingBuffer.startIndex ..< newline])
                incomingBuffer.removeSubrange(incomingBuffer.startIndex ... newline)
                guard !line.isEmpty else {
                    continue
                }
                do {
                    let message = try ViewScopeMessageCoding.decode(line)
                    onMessage(message, self)
                } catch {
                    send(
                        ViewScopeMessage(
                            kind: .error,
                            requestID: ViewScopeMessageCoding.extractRequestID(from: line),
                            error: ViewScopeErrorPayload(message: interfaceLanguage.text("server.error.malformed_message"))
                        )
                    )
                }
            }
            // 没有换行却持续堆积：判定为异常连接，回 error 后断开。
            if incomingBuffer.count > Self.maximumBufferedBytes {
                incomingBuffer.removeAll()
                send(
                    ViewScopeMessage(
                        kind: .error,
                        error: ViewScopeErrorPayload(message: interfaceLanguage.text("server.error.message_too_large"))
                    )
                )
                cancel()
                return
            }
        }

        if isComplete || error != nil {
            cancel()
            notifyDisconnect()
            return
        }

        receiveNextChunk()
    }
}

/// 在端口段内依次尝试监听，第一个可用端口胜出（§4.2）。
@MainActor
final class ViewScopePortRangeListener {
    enum Fallback {
        /// 端口段全部占用时放弃（iOS）。
        case none
        /// 端口段全部占用时退回 loopback 上的任意端口（macOS，保持向后兼容）。
        case anyLoopbackPort
    }

    private let ports: [UInt16]
    private let fallback: Fallback
    private let newConnectionHandler: @MainActor (NWConnection) -> Void
    private let onReady: @MainActor (UInt16) -> Void
    private let onFailure: @MainActor () -> Void
    private var listener: NWListener?
    private var attemptIndex = 0
    /// 每次尝试的代号，用来丢弃已取消 listener 的迟到回调。
    private var generation = 0
    private var attemptTimeout: DispatchWorkItem?
    private(set) var boundPort: UInt16?

    init(
        ports: ClosedRange<UInt16>,
        fallback: Fallback,
        newConnectionHandler: @escaping @MainActor (NWConnection) -> Void,
        onReady: @escaping @MainActor (UInt16) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        self.ports = Array(ports)
        self.fallback = fallback
        self.newConnectionHandler = newConnectionHandler
        self.onReady = onReady
        self.onFailure = onFailure
    }

    func start() {
        attemptIndex = 0
        attemptNext()
    }

    func cancel() {
        generation += 1
        attemptTimeout?.cancel()
        attemptTimeout = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func attemptNext() {
        if attemptIndex < ports.count {
            let port = ports[attemptIndex]
            attemptIndex += 1
            attempt(port: NWEndpoint.Port(rawValue: port), isFallback: false)
            return
        }
        if fallback == .anyLoopbackPort, attemptIndex == ports.count {
            attemptIndex += 1
            attempt(port: .any, isFallback: true)
            return
        }
        NSLog("ViewScopeServer: no free port in \(ports.first ?? 0)...\(ports.last ?? 0); the inspection server is not listening.")
        onFailure()
    }

    private func attempt(port: NWEndpoint.Port?, isFallback: Bool) {
        listener?.cancel()
        listener = nil
        generation += 1
        let currentGeneration = generation

        guard let port else {
            attemptNext()
            return
        }

        let parameters = NWParameters.tcp
        // 端口段扫描依赖“被占用就失败”的语义，不能开启端口复用。
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            attemptNext()
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else {
                    connection.cancel()
                    return
                }
                self.newConnectionHandler(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handle(state: state, generation: currentGeneration)
            }
        }
        self.listener = listener
        listener.start(queue: .global(qos: .userInitiated))

        // 个别系统版本上占用端口会停在 waiting 而不是 failed，这里加一个超时兜底。
        attemptTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration, self.boundPort == nil else {
                return
            }
            self.attemptNext()
        }
        attemptTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
    }

    private func handle(state: NWListener.State, generation stateGeneration: Int) {
        guard stateGeneration == generation else {
            return
        }
        switch state {
        case .ready:
            attemptTimeout?.cancel()
            attemptTimeout = nil
            guard let port = listener?.port?.rawValue else {
                attemptNext()
                return
            }
            boundPort = port
            onReady(port)
        case .failed, .waiting:
            attemptTimeout?.cancel()
            attemptTimeout = nil
            if boundPort != nil {
                // 已就绪的 listener 之后失败：整体视为失败。
                NSLog("ViewScopeServer listener stopped unexpectedly.")
                cancel()
                onFailure()
                return
            }
            attemptNext()
        default:
            break
        }
    }
}
