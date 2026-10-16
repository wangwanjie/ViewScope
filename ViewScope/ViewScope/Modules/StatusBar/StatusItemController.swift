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
            .map { _ in () }
            .merge(with: store.settings.$autoHighlightSelection.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func rebuildMenu() {
        statusItem.button?.title = statusTitle

        let menu = NSMenu()
        // 手动控制可用状态：NSMenu 默认会根据 target/action 自动启用，导致 isEnabled 被忽略
        menu.autoenablesItems = false
        let summary = NSMenuItem(title: statusSummary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: L10n.statusOpen, action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: L10n.statusRefresh, action: #selector(refreshCapture), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = store.canRefreshCapture
        menu.addItem(refreshItem)

        let autoRefreshItem = NSMenuItem(title: L10n.statusAutoRefresh, action: #selector(toggleAutoRefresh), keyEquivalent: "")
        autoRefreshItem.target = self
        autoRefreshItem.state = store.settings.autoRefreshEnabled ? .on : .off
        menu.addItem(autoRefreshItem)

        let autoHighlightItem = NSMenuItem(title: L10n.statusAutoHighlight, action: #selector(toggleAutoHighlight), keyEquivalent: "")
        autoHighlightItem.target = self
        autoHighlightItem.state = store.settings.autoHighlightSelection ? .on : .off
        menu.addItem(autoHighlightItem)

        if !store.discoveredHosts.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: L10n.liveHosts, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            // 按设备分组显示，最多 8 个宿主
            var remaining = 8
            for group in WorkspaceHostPresentation.groupedByDevice(store.discoveredHosts) where remaining > 0 {
                let groupHeader = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                groupHeader.isEnabled = false
                menu.addItem(groupHeader)
                for host in group.hosts.prefix(remaining) {
                    let item = NSMenuItem(title: WorkspaceHostPresentation.hostTitle(of: host), action: #selector(connectToHost(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = host.identifier
                    item.indentationLevel = 1
                    item.state = store.connectionState.activeHost?.identifier == host.identifier ? .on : .off
                    menu.addItem(item)
                    remaining -= 1
                }
            }
        }

        menu.addItem(NSMenuItem.separator())
        let preferencesItem = NSMenuItem(title: L10n.statusPreferences, action: #selector(openPreferences), keyEquivalent: "")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        let updatesItem = NSMenuItem(title: L10n.statusCheckForUpdates, action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: L10n.statusQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
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
            return store.discoveredHosts.isEmpty ? L10n.statusWaitingForLocalHosts : L10n.hostsAvailable(store.discoveredHosts.count)
        case .connecting(let name):
            return L10n.connecting(name)
        case .connected(let host):
            return L10n.connected(host.displayName)
        case .imported(let name):
            return L10n.loadedCaptureFile(name)
        case .failed(let message):
            return message
        case .lost:
            return L10n.connectedHostDisappeared
        }
    }

    @objc private func openMainWindow() {
        openMainWindowHandler()
    }

    @objc private func refreshCapture() {
        Task {
            await store.refreshCapture(forceReloadSelectionDetail: true, clearingVisibleState: true)
        }
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
        Task {
            await self.store.connect(to: host)
        }
        openMainWindowHandler()
    }

    @objc private func openPreferences() {
        openPreferencesHandler()
    }

    @objc private func checkForUpdates() {
        store.updateManager.checkForUpdates()
    }
}
