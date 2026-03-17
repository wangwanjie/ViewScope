import Foundation
import Network
import ViewScopeServer

@MainActor
final class ViewScopeClientSession {
    enum SessionError: LocalizedError {
        case connectionFailed(String)
        case disconnected
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let message):
                return message
            case .disconnected:
                return "The connection closed unexpectedly."
            case .invalidResponse:
                return "The host returned an unexpected response."
            case .server(let message):
                return message
            }
        }
    }

    let announcement: ViewScopeHostAnnouncement

    private let connection: NWConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var incomingBuffer = Data()
    private var pendingRequests: [String: CheckedContinuation<ViewScopeMessage, Error>] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var isStarted = false
    private var isDisconnected = false

    init(announcement: ViewScopeHostAnnouncement) {
        self.announcement = announcement
        self.connection = NWConnection(
            host: NWEndpoint.Host.ipv4(IPv4Address("127.0.0.1")!),
            port: NWEndpoint.Port(rawValue: announcement.port) ?? .any,
            using: .tcp
        )
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func open() async throws -> ViewScopeServerHelloPayload {
        try await startIfNeeded()
        let response = try await sendRequest(
            ViewScopeMessage(
                kind: .clientHello,
                clientHello: ViewScopeClientHelloPayload(
                    authToken: announcement.authToken,
                    clientName: "ViewScope",
                    clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
                    protocolVersion: viewScopeCurrentProtocolVersion
                )
            )
        )
        guard response.kind == .serverHello, let serverHello = response.serverHello else {
            throw SessionError.invalidResponse
        }
        return serverHello
    }

    func requestCapture() async throws -> ViewScopeCapturePayload {
        let response = try await sendRequest(ViewScopeMessage(kind: .captureRequest))
        guard response.kind == .captureResponse, let capture = response.capture else {
            throw SessionError.invalidResponse
        }
        return capture
    }

    func requestNodeDetail(nodeID: String) async throws -> ViewScopeNodeDetailPayload {
        let response = try await sendRequest(
            ViewScopeMessage(kind: .nodeDetailRequest, nodeRequest: ViewScopeNodeRequestPayload(nodeID: nodeID))
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
            )
        )
    }

    func disconnect() {
        guard !isDisconnected else { return }
        isDisconnected = true
        connection.cancel()
        failPendingRequests(with: SessionError.disconnected)
    }

    private func startIfNeeded() async throws {
        guard !isStarted else { return }
        isStarted = true

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handle(state: state)
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveNextChunk()

        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
        }
    }

    private func sendRequest(_ message: ViewScopeMessage) async throws -> ViewScopeMessage {
        if isDisconnected {
            throw SessionError.disconnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            let requestID = UUID().uuidString
            pendingRequests[requestID] = continuation
            var request = message
            request.requestID = requestID
            send(request)
        }
    }

    private func send(_ message: ViewScopeMessage) {
        guard let data = try? encoder.encode(message) else { return }
        var framed = data
        framed.append(0x0A)
        connection.send(content: framed, completion: .contentProcessed { _ in })
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
        case .ready:
            readyContinuation?.resume()
            readyContinuation = nil
        case .failed(let error):
            let sessionError = SessionError.connectionFailed(error.localizedDescription)
            readyContinuation?.resume(throwing: sessionError)
            readyContinuation = nil
            disconnect()
        case .cancelled:
            readyContinuation?.resume(throwing: SessionError.disconnected)
            readyContinuation = nil
            disconnect()
        default:
            break
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            incomingBuffer.append(data)
            while let newlineIndex = incomingBuffer.firstIndex(of: 0x0A) {
                let line = incomingBuffer.prefix(upTo: newlineIndex)
                incomingBuffer.removeSubrange(...newlineIndex)
                guard !line.isEmpty else { continue }
                guard let message = try? decoder.decode(ViewScopeMessage.self, from: line) else { continue }
                resolve(message)
            }
        }

        if isComplete || error != nil {
            disconnect()
            return
        }

        receiveNextChunk()
    }

    private func resolve(_ message: ViewScopeMessage) {
        guard let requestID = message.requestID,
              let continuation = pendingRequests.removeValue(forKey: requestID) else {
            return
        }

        if message.kind == .error, let error = message.error?.message {
            continuation.resume(throwing: SessionError.server(error))
        } else {
            continuation.resume(returning: message)
        }
    }

    private func failPendingRequests(with error: Error) {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
