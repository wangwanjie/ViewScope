import Foundation
import ViewScopeServer

/// 会话超时配置（秒）。
nonisolated struct ViewScopeSessionTimeouts: Sendable, Equatable {
    /// 建立底层连接。
    var connect: TimeInterval
    /// 普通请求。
    var request: TimeInterval
    /// capture 请求（payload 大，宿主生成也慢）。
    var capture: TimeInterval

    static let standard = ViewScopeSessionTimeouts(connect: 5, request: 15, capture: 30)
}

@MainActor
/// 客户端与一个被调试宿主之间的单个会话。底层字节通道由 `ViewScopeByteTransport` 提供（loopback 或 usbmuxd）。
final class ViewScopeClientSession: WorkspaceSessionProtocol {
    typealias TransportFactory = @MainActor (ViewScopeHostAnnouncement) -> any ViewScopeByteTransport

    nonisolated enum SessionError: LocalizedError, Equatable {
        case connectionFailed(String)
        case disconnected
        case invalidResponse
        case server(String)
        /// 建连超时。
        case connectTimedOut
        /// 请求超时（连接保持）。
        case timedOut
        /// 宿主协议版本过低，不支持该请求。
        case unsupportedByHost
        /// 请求编码失败。
        case encodingFailed
        /// 宿主发送的单条消息超过缓冲上限。
        case messageTooLarge

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let message):
                return message
            case .disconnected:
                return AppLocalization.backgroundString("session.error.disconnected")
            case .invalidResponse:
                return AppLocalization.backgroundString("session.error.invalid_response")
            case .server(let message):
                return message
            case .connectTimedOut:
                return L10n.connectionErrorConnectTimeout
            case .timedOut:
                return L10n.connectionErrorRequestTimeout
            case .unsupportedByHost:
                return L10n.connectionErrorUnsupportedByHost
            case .encodingFailed:
                return L10n.connectionErrorEncodingFailed
            case .messageTooLarge:
                return L10n.connectionErrorMessageTooLarge
            }
        }
    }

    /// 等待响应中的请求。
    private struct PendingRequest {
        let continuation: CheckedContinuation<ViewScopeMessage, Error>
        let timeoutTask: Task<Void, Never>?
    }

    let announcement: ViewScopeHostAnnouncement
    /// 握手后协商出的协议版本；握手前为最低支持版本。
    private(set) var negotiatedProtocolVersion: Int = viewScopeMinimumSupportedProtocolVersion

    private let transport: any ViewScopeByteTransport
    private let timeouts: ViewScopeSessionTimeouts
    private let maximumBufferSize: Int
    private let encoder = ViewScopeConnectionCoding.makeEncoder()
    private var pendingRequests: [String: PendingRequest] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var unexpectedDisconnectHandler: (@MainActor (Error) -> Void)?
    private var isStarted = false
    private var isReady = false
    /// open() 握手成功后为 true；只有此后的断开才算“意外断开”并通知 handler。
    private var isOpened = false
    private var isDisconnected = false

    init(
        announcement: ViewScopeHostAnnouncement,
        timeouts: ViewScopeSessionTimeouts = .standard,
        maximumBufferSize: Int = ViewScopeLineFramer.defaultMaximumBufferSize,
        transportFactory: TransportFactory = ViewScopeClientSession.makeDefaultTransport
    ) {
        self.announcement = announcement
        self.timeouts = timeouts
        self.maximumBufferSize = maximumBufferSize
        self.transport = transportFactory(announcement)
    }

    deinit {
        transport.cancel()
    }

    /// 依据 announcement 的到达方式创建 transport。
    static func makeDefaultTransport(for announcement: ViewScopeHostAnnouncement) -> any ViewScopeByteTransport {
        let route = announcement.resolvedTransport
        switch route.kind {
        case .loopback:
            return ViewScopeLoopbackTransport(port: announcement.port)
        case .usbmux:
            guard let deviceID = route.deviceID else {
                return ViewScopeUnavailableTransport(error: ViewScopeTransportError.missingDevice)
            }
            return ViewScopeUSBMuxTunnelTransport(deviceID: deviceID, port: announcement.port)
        }
    }

    // MARK: - WorkspaceSessionProtocol

    func open() async throws -> ViewScopeServerHelloPayload {
        try await startIfNeeded()
        // 宿主声明的版本更低时按宿主版本握手
        let requestedVersion = min(viewScopeCurrentProtocolVersion, announcement.protocolVersion)
        let response = try await sendRequest(
            ViewScopeMessage(
                kind: .clientHello,
                clientHello: ViewScopeClientHelloPayload(
                    authToken: announcement.authToken,
                    clientName: "ViewScope",
                    clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? viewScopeServerRuntimeVersion,
                    protocolVersion: requestedVersion,
                    preferredLanguage: AppLocalization.shared.language.rawValue
                )
            ),
            timeout: timeouts.request
        )
        guard response.kind == .serverHello, let serverHello = response.serverHello else {
            throw SessionError.invalidResponse
        }
        // v3 宿主在 host.protocolVersion 与 serverHello.protocolVersion 中都回填协商结果；旧宿主只有后者
        let reportedVersion = serverHello.host.protocolVersion ?? serverHello.protocolVersion
        negotiatedProtocolVersion = min(requestedVersion, reportedVersion)
        isOpened = true
        return serverHello
    }

    func requestCapture() async throws -> ViewScopeCapturePayload {
        let response = try await sendRequest(ViewScopeMessage(kind: .captureRequest), timeout: timeouts.capture)
        guard response.kind == .captureResponse, let capture = response.capture else {
            throw SessionError.invalidResponse
        }
        return capture
    }

    func requestNodeDetail(nodeID: String) async throws -> ViewScopeNodeDetailPayload {
        let response = try await sendRequest(
            ViewScopeMessage(kind: .nodeDetailRequest, nodeRequest: ViewScopeNodeRequestPayload(nodeID: nodeID)),
            timeout: timeouts.request
        )
        guard response.kind == .nodeDetailResponse, let detail = response.nodeDetail else {
            throw SessionError.invalidResponse
        }
        return detail
    }

    func highlight(nodeID: String, duration: TimeInterval) async throws {
        _ = try await sendRequest(
            ViewScopeMessage(
                kind: .highlightRequest,
                highlightRequest: ViewScopeHighlightRequestPayload(nodeID: nodeID, duration: duration)
            ),
            timeout: timeouts.request
        )
    }

    func applyMutation(nodeID: String, property: ViewScopeEditableProperty) async throws {
        let response = try await sendRequest(
            ViewScopeMessage(
                kind: .mutationRequest,
                mutationRequest: ViewScopeMutationRequestPayload(nodeID: nodeID, property: property)
            ),
            timeout: timeouts.request
        )
        guard response.kind == .ack else {
            throw SessionError.invalidResponse
        }
    }

    func invokeConsole(
        target: ViewScopeRemoteObjectReference,
        expression: String
    ) async throws -> ViewScopeConsoleInvokeResponsePayload {
        let response = try await sendRequest(
            ViewScopeMessage(
                kind: .consoleInvokeRequest,
                consoleInvokeRequest: ViewScopeConsoleInvokeRequestPayload(
                    target: target,
                    expression: expression
                )
            ),
            timeout: timeouts.request
        )
        guard response.kind == .consoleInvokeResponse,
              let payload = response.consoleInvokeResponse else {
            throw SessionError.invalidResponse
        }
        return payload
    }

    func requestConsoleCompletions(
        target: ViewScopeRemoteObjectReference,
        prefix: String?
    ) async throws -> [ViewScopeConsoleCompletion] {
        guard negotiatedProtocolVersion >= 3 else {
            throw SessionError.unsupportedByHost
        }
        let response = try await sendRequest(
            ViewScopeMessage(
                kind: .consoleCompletionRequest,
                consoleCompletionRequest: ViewScopeConsoleCompletionRequestPayload(target: target, prefix: prefix)
            ),
            timeout: timeouts.request
        )
        guard response.kind == .consoleCompletionResponse,
              let payload = response.consoleCompletionResponse else {
            throw SessionError.invalidResponse
        }
        return payload.completions
    }

    func ping() async throws {
        guard negotiatedProtocolVersion >= 3 else {
            throw SessionError.unsupportedByHost
        }
        let response = try await sendRequest(ViewScopeMessage(kind: .ping), timeout: timeouts.request)
        guard response.kind == .ack else {
            throw SessionError.invalidResponse
        }
    }

    func setUnexpectedDisconnectHandler(_ handler: (@MainActor (Error) -> Void)?) {
        unexpectedDisconnectHandler = handler
    }

    func disconnect() {
        guard isDisconnected == false else {
            return
        }
        // 主动断开：不通知 unexpectedDisconnectHandler
        tearDown(with: SessionError.disconnected)
    }

    // MARK: - 建连

    private func startIfNeeded() async throws {
        if isDisconnected {
            throw SessionError.disconnected
        }
        guard isStarted == false else {
            return
        }
        isStarted = true

        let streamDecoder = ViewScopeMessageStreamDecoder(maximumBufferSize: maximumBufferSize)
        transport.start { [weak self] event in
            // 该闭包在 transport 的后台串行队列上执行：数据在这里完成分帧与 JSON 解码，再按顺序切回主线程
            switch event {
            case .data(let data):
                let outputs = streamDecoder.consume(data)
                guard outputs.isEmpty == false else {
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handle(outputs: outputs)
                    }
                }
            case .ready, .closed:
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handle(event: event)
                    }
                }
            }
        }

        let connectTimeout = timeouts.connect
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyContinuation = continuation
            readyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.nanoseconds(connectTimeout))
                if Task.isCancelled {
                    return
                }
                self?.handleConnectTimeout()
            }
        }
    }

    private func handleConnectTimeout() {
        guard readyContinuation != nil else {
            return
        }
        tearDown(with: SessionError.connectTimedOut)
    }

    // MARK: - 请求

    private func sendRequest(_ message: ViewScopeMessage, timeout: TimeInterval) async throws -> ViewScopeMessage {
        if isDisconnected {
            throw SessionError.disconnected
        }

        let requestID = UUID().uuidString
        var request = message
        request.requestID = requestID
        let data: Data
        do {
            data = try ViewScopeConnectionCoding.encodeLine(request, encoder: encoder)
        } catch {
            throw SessionError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ViewScopeMessage, Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
                if Task.isCancelled {
                    return
                }
                // 超时只让该请求失败，连接保持；迟到的响应会因找不到 pending 而被丢弃
                self?.failRequest(requestID, with: SessionError.timedOut)
            }
            pendingRequests[requestID] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
            transport.send(data) { [weak self] error in
                guard let error else {
                    return
                }
                let sessionError = SessionError.connectionFailed(error.localizedDescription)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.failRequest(requestID, with: sessionError)
                    }
                }
            }
        }
    }

    private func failRequest(_ requestID: String, with error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        pending.timeoutTask?.cancel()
        pending.continuation.resume(throwing: error)
    }

    // MARK: - 事件处理

    private func handle(event: ViewScopeTransportEvent) {
        guard isDisconnected == false else {
            return
        }
        switch event {
        case .ready:
            isReady = true
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            readyContinuation?.resume()
            readyContinuation = nil
        case .closed(let error):
            let sessionError: SessionError
            if isReady == false, let error {
                sessionError = .connectionFailed(error.localizedDescription)
            } else {
                sessionError = .disconnected
            }
            handleUnexpectedClose(with: sessionError)
        case .data:
            break
        }
    }

    private func handle(outputs: [ViewScopeMessageStreamDecoder.Output]) {
        for output in outputs {
            guard isDisconnected == false else {
                return
            }
            switch output {
            case .message(let message):
                resolve(message)
            case .undecodable(let requestID):
                if let requestID {
                    failRequest(requestID, with: SessionError.invalidResponse)
                }
            case .overflow:
                handleUnexpectedClose(with: SessionError.messageTooLarge)
            }
        }
    }

    private func resolve(_ message: ViewScopeMessage) {
        guard let requestID = message.requestID,
              let pending = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        pending.timeoutTask?.cancel()
        if message.kind == .error {
            if let errorMessage = message.error?.message, errorMessage.isEmpty == false {
                pending.continuation.resume(throwing: SessionError.server(errorMessage))
            } else {
                pending.continuation.resume(throwing: SessionError.invalidResponse)
            }
        } else {
            pending.continuation.resume(returning: message)
        }
    }

    /// 非主动断开：释放资源，握手完成后通知 handler。
    private func handleUnexpectedClose(with error: SessionError) {
        guard isDisconnected == false else {
            return
        }
        let shouldNotify = isOpened
        tearDown(with: error)
        if shouldNotify {
            unexpectedDisconnectHandler?(error)
        }
    }

    /// 统一的收尾：取消 transport，让建连与所有等待中的请求失败。
    private func tearDown(with error: SessionError) {
        isDisconnected = true
        transport.cancel()
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        if let readyContinuation {
            self.readyContinuation = nil
            readyContinuation.resume(throwing: error)
        }
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private nonisolated static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(interval, 0) * 1_000_000_000)
    }
}
