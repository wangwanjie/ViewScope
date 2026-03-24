import Foundation

@MainActor
final class WorkspaceConnectionCoordinator {
    private(set) var session: (any WorkspaceSessionProtocol)?
    private(set) var generation: UInt64 = 0

    private var autoRefreshTimer: Timer?

    func beginNewGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    func activate(session: any WorkspaceSessionProtocol) {
        self.session = session
    }

    func disconnectCurrentSession() {
        session?.disconnect()
        session = nil
        stopAutoRefreshTimer()
    }

    func isActiveConnection(generation: UInt64, session: any WorkspaceSessionProtocol) -> Bool {
        generation == self.generation && self.session === session
    }

    func configureAutoRefreshTimer(
        isEnabled: Bool,
        isConnected: Bool,
        handler: @escaping @MainActor () async -> Void
    ) {
        stopAutoRefreshTimer()
        guard isEnabled, isConnected else { return }

        let timer = Timer(timeInterval: 2.5, repeats: true) { _ in
            Task { @MainActor in
                await handler()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoRefreshTimer = timer
    }

    func stopAutoRefreshTimer() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }
}
