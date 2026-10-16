import AppKit
import Combine
import SnapKit
import ViewScopeServer

@MainActor
final class WorkspaceToolbarViewController: NSViewController {
    private enum Layout {
        static let trailingInset: CGFloat = 12
        static let hostPopUpWidth: CGFloat = 300
    }

    private let store: WorkspaceStore
    private var cancellables = Set<AnyCancellable>()
    private var liveHosts: [ViewScopeHostAnnouncement] = []
    private var isRebuildingHostMenu = false
    private var pendingHostIdentifier: String?

    private let hostPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = WorkspaceIconButton()
    private let disconnectButton = WorkspaceIconButton()
    private let modificationLogButton = WorkspaceIconButton()
    private let captureDiffButton = WorkspaceIconButton()
    private let inspectorToggleButton = WorkspaceIconButton()
    private let connectionBadge = CapsuleBadgeView(fontSize: 10, horizontalInset: 8, verticalInset: 2, minimumHeight: 18)
    private let statusLabel = NSTextField(labelWithString: "")

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // 工具栏位于透明标题栏这一行，直接透出窗口底色
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        applyLocalization()
        bindStore()
        rebuildHostMenu()
        updateConnectionState()
    }

    private func buildUI() {
        hostPopUpButton.controlSize = .regular
        hostPopUpButton.bezelStyle = .rounded
        hostPopUpButton.target = self
        hostPopUpButton.action = #selector(handleHostSelection(_:))

        configureIconButton(refreshButton, symbolName: "arrow.clockwise", action: #selector(refreshCapture(_:)))
        configureIconButton(disconnectButton, symbolName: "eject", action: #selector(disconnectHost(_:)))
        configureIconButton(modificationLogButton, symbolName: "list.bullet.rectangle", action: #selector(showModificationLog(_:)))
        configureIconButton(captureDiffButton, symbolName: "arrow.left.arrow.right.square", action: #selector(showCaptureDiff(_:)))
        configureIconButton(inspectorToggleButton, symbolName: "sidebar.right", action: #selector(toggleInspector(_:)))
        inspectorToggleButton.setButtonType(.pushOnPushOff)

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor

        // 左侧：宿主选择 + 刷新/断开；中间：连接状态；右侧：面板工具
        let controls = NSStackView(views: [hostPopUpButton, refreshButton, disconnectButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        controls.setCustomSpacing(8, after: hostPopUpButton)

        let statusStack = NSStackView(views: [connectionBadge, statusLabel])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 8
        statusStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toolControls = NSStackView(views: [modificationLogButton, captureDiffButton, WorkspaceToolbarDivider(), inspectorToggleButton])
        toolControls.orientation = .horizontal
        toolControls.alignment = .centerY
        toolControls.spacing = 4
        toolControls.setContentCompressionResistancePriority(.required, for: .horizontal)

        view.addSubview(controls)
        view.addSubview(statusStack)
        view.addSubview(toolControls)

        controls.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
        }
        hostPopUpButton.snp.makeConstraints { make in
            make.width.equalTo(Layout.hostPopUpWidth)
        }
        statusStack.snp.makeConstraints { make in
            make.leading.equalTo(controls.snp.trailing).offset(16)
            make.trailing.lessThanOrEqualTo(toolControls.snp.leading).offset(-12)
            make.centerY.equalToSuperview()
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolControls.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(Layout.trailingInset)
            make.centerY.equalToSuperview()
        }
    }

    private func bindStore() {
        store.$discoveredHosts
            .receive(on: RunLoop.main)
            .sink { [weak self] hosts in
                self?.liveHosts = hosts
                self?.rebuildHostMenu()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(store.$recentHosts, store.$connectedDevices)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.rebuildHostMenu()
            }
            .store(in: &cancellables)

        store.settings.$showsInspector
            .receive(on: RunLoop.main)
            .sink { [weak self] showsInspector in
                self?.inspectorToggleButton.state = showsInspector ? .on : .off
                self?.inspectorToggleButton.toolTip = showsInspector ? L10n.hideInspector : L10n.showInspector
            }
            .store(in: &cancellables)

        store.$captureInsight
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateConnectionState()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(store.$connectionState, store.$errorMessage, AppLocalization.shared.$language)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.pendingHostIdentifier = WorkspaceToolbarHostSelectionState.syncedPendingHostIdentifier(
                    existingPendingHostIdentifier: self?.pendingHostIdentifier,
                    connectionState: self?.store.connectionState ?? .idle
                )
                self?.applyLocalization()
                self?.rebuildHostMenu()
                self?.updateConnectionState()
            }
            .store(in: &cancellables)
    }

    private func applyLocalization() {
        refreshButton.toolTip = L10n.refresh
        disconnectButton.toolTip = store.connectionState.importedCaptureName == nil ? L10n.disconnect : L10n.menuCloseImportedCapture
        hostPopUpButton.toolTip = L10n.liveHosts
        modificationLogButton.toolTip = L10n.menuModificationLog
        captureDiffButton.toolTip = L10n.menuCaptureDiff
        inspectorToggleButton.toolTip = store.settings.showsInspector ? L10n.hideInspector : L10n.showInspector
    }

    private func rebuildHostMenu() {
        isRebuildingHostMenu = true
        defer {
            isRebuildingHostMenu = false
        }

        hostPopUpButton.removeAllItems()
        hostPopUpButton.autoenablesItems = false
        let activeHost = store.connectionState.activeHost
        let selectedHostIdentifier = WorkspaceToolbarHostSelectionState.menuSelectedHostIdentifier(
            connectionState: store.connectionState,
            pendingHostIdentifier: pendingHostIdentifier
        )
        let devicesWithoutHosts = WorkspaceHostPresentation.devicesWithoutHosts(
            devices: store.connectedDevices,
            hosts: liveHosts
        )
        let liveBundleIdentifiers = Set(liveHosts.map(\.bundleIdentifier))
        let offlineRecentHosts = store.recentHosts.filter { liveBundleIdentifiers.contains($0.bundleIdentifier) == false }.prefix(5)

        if liveHosts.isEmpty {
            let placeholder = activeHost?.displayName
                ?? store.connectionState.lostHost?.displayName
                ?? store.connectionState.importedCaptureName
                ?? L10n.noHostsOnlineTitle
            hostPopUpButton.addItem(withTitle: placeholder)
            hostPopUpButton.lastItem?.isEnabled = false
            appendDeviceHints(devicesWithoutHosts)
            appendRecentHosts(Array(offlineRecentHosts))
            hostPopUpButton.isEnabled = devicesWithoutHosts.isEmpty == false || offlineRecentHosts.isEmpty == false
            hostPopUpButton.selectItem(at: 0)
            return
        }

        hostPopUpButton.isEnabled = true
        if activeHost == nil {
            hostPopUpButton.addItem(withTitle: L10n.hostPickerPlaceholder)
            hostPopUpButton.lastItem?.isEnabled = false
        }

        // 按设备分组：分组标题不可选，宿主条目缩进显示
        let groups = WorkspaceHostPresentation.groupedByDevice(liveHosts)
        for group in groups {
            if let menu = hostPopUpButton.menu, menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            hostPopUpButton.menu?.addItem(header)
            for host in group.hosts {
                let item = NSMenuItem(title: WorkspaceHostPresentation.hostTitle(of: host), action: nil, keyEquivalent: "")
                item.representedObject = host.identifier
                item.indentationLevel = 1
                item.toolTip = "\(host.bundleIdentifier) · pid \(host.processIdentifier)"
                hostPopUpButton.menu?.addItem(item)
            }
        }
        appendDeviceHints(devicesWithoutHosts)
        appendRecentHosts(Array(offlineRecentHosts))

        if let selectedHostIdentifier,
           let index = hostPopUpButton.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedHostIdentifier }) {
            hostPopUpButton.selectItem(at: index)
        } else {
            hostPopUpButton.selectItem(at: 0)
        }
    }

    /// “设备已连接但未发现宿主”提示。
    private func appendDeviceHints(_ devices: [WorkspaceConnectedDevice]) {
        guard devices.isEmpty == false else {
            return
        }
        hostPopUpButton.menu?.addItem(.separator())
        for device in devices {
            let title = L10n.hostDeviceWithoutHosts(
                "\(device.name) (\(WorkspaceHostPresentation.connectionTypeTitle(device.connectionType)))"
            )
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            hostPopUpButton.menu?.addItem(item)
        }
    }

    /// 最近连接过但当前不在线的宿主，选中时尝试按 bundle id 重连。
    private func appendRecentHosts(_ records: [RecentHostRecord]) {
        guard records.isEmpty == false else {
            return
        }
        hostPopUpButton.menu?.addItem(.separator())
        let header = NSMenuItem(title: L10n.hostRecentSection, action: nil, keyEquivalent: "")
        header.isEnabled = false
        hostPopUpButton.menu?.addItem(header)
        for record in records {
            let item = NSMenuItem(
                title: "\(record.displayName) · \(record.bundleIdentifier) \(L10n.hostRecentNotRunningSuffix)",
                action: nil,
                keyEquivalent: ""
            )
            item.indentationLevel = 1
            item.isEnabled = false
            hostPopUpButton.menu?.addItem(item)
        }
    }

    private func updateConnectionState() {
        let state = store.connectionState
        statusLabel.stringValue = store.errorMessage ?? state.statusText
        statusLabel.toolTip = captureInsightToolTip
        refreshButton.isEnabled = store.canRefreshCapture
        disconnectButton.isEnabled = store.canDisconnect
        disconnectButton.toolTip = state.importedCaptureName == nil ? L10n.disconnect : L10n.menuCloseImportedCapture

        let badgeText: String
        let tint: NSColor
        switch state {
        case .idle:
            badgeText = L10n.idleBadge
            tint = .systemGray
        case .connecting:
            badgeText = L10n.linkingBadge
            tint = .systemOrange
        case .connected:
            badgeText = L10n.liveBadge
            tint = .systemGreen
        case .imported:
            badgeText = L10n.loadedBadge
            tint = .systemPurple
        case .failed:
            badgeText = L10n.errorBadge
            tint = .systemRed
        case .lost:
            badgeText = L10n.lostBadge
            tint = .systemYellow
        }
        let colors = WorkspaceTheme.badgeColors(tint: tint)

        connectionBadge.text = badgeText
        connectionBadge.applyStyle(textColor: colors.text, backgroundColor: colors.background)
    }

    @objc private func handleHostSelection(_ sender: NSPopUpButton) {
        guard !isRebuildingHostMenu,
              let identifier = sender.selectedItem?.representedObject as? String,
              let host = liveHosts.first(where: { $0.identifier == identifier }) else {
            return
        }

        if store.connectionState.activeHost?.identifier == identifier {
            return
        }

        pendingHostIdentifier = identifier
        Task {
            await store.connect(to: host)
        }
    }

    /// 抓取历史统计（captureInsight）作为状态文字的提示信息。
    private var captureInsightToolTip: String? {
        let insight = store.captureInsight
        guard insight.totalCaptures > 0 else {
            return nil
        }
        return L10n.historySummary(count: insight.totalCaptures, averageMilliseconds: insight.averageDurationMilliseconds)
    }

    private func configureIconButton(_ button: NSButton, symbolName: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.target = self
        button.action = action
    }

    @objc private func refreshCapture(_ sender: Any?) {
        Task {
            await store.refreshCapture(forceReloadSelectionDetail: true, clearingVisibleState: true)
        }
    }

    @objc private func disconnectHost(_ sender: Any?) {
        store.disconnect()
    }

    @objc private func showModificationLog(_ sender: Any?) {
        store.requestPanel(.modificationLog)
    }

    @objc private func showCaptureDiff(_ sender: Any?) {
        store.requestPanel(.captureDiff)
    }

    @objc private func toggleInspector(_ sender: Any?) {
        store.settings.showsInspector.toggle()
    }
}

enum WorkspaceToolbarHostSelectionState {
    static func menuSelectedHostIdentifier(
        connectionState: WorkspaceConnectionState,
        pendingHostIdentifier: String?
    ) -> String? {
        connectionState.activeHost?.identifier ?? pendingHostIdentifier
    }

    static func syncedPendingHostIdentifier(
        existingPendingHostIdentifier: String?,
        connectionState: WorkspaceConnectionState
    ) -> String? {
        if let activeHost = connectionState.activeHost {
            return activeHost.identifier
        }

        switch connectionState {
        case .idle, .imported, .failed, .lost:
            return nil
        case .connecting:
            return existingPendingHostIdentifier
        case .connected:
            return existingPendingHostIdentifier
        }
    }
}
