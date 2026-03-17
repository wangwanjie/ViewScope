import Cocoa
import Combine
import ViewScopeServer

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: WorkspaceStore
    private let openMainWindowHandler: () -> Void
    private let openPreferencesHandler: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(store: WorkspaceStore, openMainWindowHandler: @escaping () -> Void, openPreferencesHandler: @escaping () -> Void) {
        self.store = store
        self.openMainWindowHandler = openMainWindowHandler
        self.openPreferencesHandler = openPreferencesHandler
        super.init()
        configureStatusItem()
        bindStore()
    }

    private func configureStatusItem() {
        statusItem.button?.title = "VS"
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        rebuildMenu()
    }

    private func bindStore() {
        Publishers.CombineLatest4(store.$discoveredHosts, store.$connectionState, store.settings.$showConnectedCountInStatusBar, store.settings.$autoRefreshEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func rebuildMenu() {
        statusItem.button?.title = statusTitle

        let menu = NSMenu()
        let summary = NSMenuItem(title: statusSummary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open ViewScope", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: "Refresh Capture", action: #selector(refreshCapture), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = store.capture != nil
        menu.addItem(refreshItem)

        let autoRefreshItem = NSMenuItem(title: "Auto Refresh", action: #selector(toggleAutoRefresh), keyEquivalent: "")
        autoRefreshItem.target = self
        autoRefreshItem.state = store.settings.autoRefreshEnabled ? .on : .off
        menu.addItem(autoRefreshItem)

        let autoHighlightItem = NSMenuItem(title: "Auto Highlight Selection", action: #selector(toggleAutoHighlight), keyEquivalent: "")
        autoHighlightItem.target = self
        autoHighlightItem.state = store.settings.autoHighlightSelection ? .on : .off
        menu.addItem(autoHighlightItem)

        if !store.discoveredHosts.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "Live Hosts", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for host in store.discoveredHosts.prefix(5) {
                let item = NSMenuItem(title: host.displayName, action: #selector(connectToHost(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = host.identifier
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let preferencesItem = NSMenuItem(title: "Preferences", action: #selector(openPreferences), keyEquivalent: "")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        let updatesItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private var statusTitle: String {
        guard store.settings.showConnectedCountInStatusBar else { return "VS" }
        let connectedCount = store.connectionState.activeHost == nil ? 0 : 1
        return connectedCount == 0 ? "VS" : "VS \(connectedCount)"
    }

    private var statusSummary: String {
        switch store.connectionState {
        case .idle:
            return store.discoveredHosts.isEmpty ? "Waiting for local debug hosts" : "\(store.discoveredHosts.count) host(s) available"
        case .connecting(let name):
            return "Connecting to \(name)..."
        case .connected(let host):
            return "Connected to \(host.displayName)"
        case .failed(let message):
            return message
        }
    }

    @objc private func openMainWindow() {
        openMainWindowHandler()
    }

    @objc private func refreshCapture() {
        Task { await store.refreshCapture() }
    }

    @objc private func toggleAutoRefresh() {
        store.settings.autoRefreshEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleAutoHighlight() {
        store.settings.autoHighlightSelection.toggle()
        rebuildMenu()
    }

    @objc private func connectToHost(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let host = store.discoveredHosts.first(where: { $0.identifier == identifier }) else {
            return
        }
        Task { await store.connect(to: host) }
        openMainWindowHandler()
    }

    @objc private func openPreferences() {
        openPreferencesHandler()
    }

    @objc private func checkForUpdates() {
        store.updateManager.checkForUpdates()
    }
}
