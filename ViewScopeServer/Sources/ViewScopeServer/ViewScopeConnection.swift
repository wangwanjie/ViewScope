import Foundation
import Network

@MainActor
final class ViewScopeServerConnection {
    private let connection: NWConnection
    private let onMessage: @MainActor (ViewScopeMessage) -> Void
    private let onDisconnect: @MainActor () -> Void
    private var incomingBuffer = Data()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        connection: NWConnection,
        onMessage: @escaping @MainActor (ViewScopeMessage) -> Void,
        onDisconnect: @escaping @MainActor () -> Void
    ) {
        self.connection = connection
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
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
        guard let data = try? encoder.encode(message) else { return }
        var framed = data
        framed.append(0x0A)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                self.handleReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            onDisconnect()
        default:
            break
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            incomingBuffer.append(data)
            while let newline = incomingBuffer.firstIndex(of: 0x0A) {
                let line = incomingBuffer.prefix(upTo: newline)
                incomingBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                if let message = try? decoder.decode(ViewScopeMessage.self, from: line) {
                    onMessage(message)
                }
            }
        }

        if isComplete || error != nil {
            onDisconnect()
            return
        }

        receiveNextChunk()
    }
}
