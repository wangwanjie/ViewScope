import AppKit
import Combine
import SnapKit
import ViewScopeServer

@MainActor
final class WorkspaceToolbarViewController: NSViewController {
    private enum Layout {
        static let leadingInset: CGFloat = 12
        static let trailingInset: CGFloat = 14
    }

    private let store: WorkspaceStore
    private var cancellables = Set<AnyCancellable>()
    private var liveHosts: [ViewScopeHostAnnouncement] = []
    private var isRebuildingHostMenu = false

    private let hostPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "", target: nil, action: nil)
    private let connectionBadge = CapsuleBadgeView(fontSize: 10, horizontalInset: 8, verticalInset: 3, minimumHeight: 20)
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
        view = NSVisualEffectView()
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
        guard let toolbarView = view as? NSVisualEffectView else { return }
        toolbarView.material = .titlebar
        toolbarView.blendingMode = .withinWindow
        toolbarView.state = .active
        toolbarView.wantsLayer = true
        toolbarView.layer?.borderWidth = 1
        toolbarView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        hostPopUpButton.controlSize = .regular
        hostPopUpButton.bezelStyle = .rounded
        hostPopUpButton.target = self
        hostPopUpButton.action = #selector(handleHostSelection(_:))

        refreshButton.bezelStyle = .texturedRounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshCapture(_:))
        disconnectButton.bezelStyle = .texturedRounded
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectHost(_:))

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor

        let controls = NSStackView(views: [hostPopUpButton, refreshButton, disconnectButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        view.addSubview(controls)
        view.addSubview(connectionBadge)
        view.addSubview(statusLabel)

        controls.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Layout.leadingInset)
            make.centerY.equalToSuperview()
        }
        hostPopUpButton.snp.makeConstraints { make in
            make.width.equalTo(340)
        }
        connectionBadge.snp.makeConstraints { make in
            make.leading.equalTo(controls.snp.trailing).offset(12)
            make.centerY.equalToSuperview()
        }
        statusLabel.snp.makeConstraints { make in
            make.leading.equalTo(connectionBadge.snp.trailing).offset(10)
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

        Publishers.CombineLatest3(store.$connectionState, store.$errorMessage, AppLocalization.shared.$language)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.applyLocalization()
                self?.rebuildHostMenu()
                self?.updateConnectionState()
            }
            .store(in: &cancellables)
    }

    private func applyLocalization() {
        refreshButton.title = L10n.refresh
        disconnectButton.title = L10n.disconnect
        hostPopUpButton.toolTip = L10n.liveHosts
    }

    private func rebuildHostMenu() {
        isRebuildingHostMenu = true
        defer { isRebuildingHostMenu = false }

        hostPopUpButton.removeAllItems()
        let activeHost = store.connectionState.activeHost

        if liveHosts.isEmpty {
            let placeholder = activeHost?.displayName ?? store.connectionState.importedCaptureName ?? L10n.noHostsOnlineTitle
            hostPopUpButton.addItem(withTitle: placeholder)
            hostPopUpButton.lastItem?.isEnabled = false
            hostPopUpButton.isEnabled = false
            return
        }

        hostPopUpButton.isEnabled = true
        if activeHost == nil {
            hostPopUpButton.addItem(withTitle: L10n.hostPickerPlaceholder)
            hostPopUpButton.lastItem?.isEnabled = false
        }

        for host in liveHosts {
            let title = "\(host.displayName)  ·  \(host.bundleIdentifier)"
            hostPopUpButton.addItem(withTitle: title)
            hostPopUpButton.lastItem?.representedObject = host.identifier
        }

        if let activeHost,
           let index = liveHosts.firstIndex(where: { $0.identifier == activeHost.identifier }) {
            hostPopUpButton.selectItem(at: index)
        } else {
            hostPopUpButton.selectItem(at: 0)
        }
    }

    private func updateConnectionState() {
        let state = store.connectionState
        statusLabel.stringValue = store.errorMessage ?? state.statusText
        refreshButton.isEnabled = state.activeHost != nil
        disconnectButton.isEnabled = state.activeHost != nil

        let badgeText: String
        let textColor: NSColor
        let backgroundColor: NSColor
        switch state {
        case .idle:
            badgeText = L10n.idleBadge
            textColor = NSColor(calibratedRed: 0.11, green: 0.43, blue: 0.63, alpha: 1)
            backgroundColor = NSColor(calibratedRed: 0.86, green: 0.94, blue: 0.98, alpha: 1)
        case .connecting:
            badgeText = L10n.linkingBadge
            textColor = NSColor(calibratedRed: 0.61, green: 0.38, blue: 0.06, alpha: 1)
            backgroundColor = NSColor(calibratedRed: 0.99, green: 0.94, blue: 0.84, alpha: 1)
        case .connected:
            badgeText = L10n.liveBadge
            textColor = NSColor(calibratedRed: 0.06, green: 0.48, blue: 0.32, alpha: 1)
            backgroundColor = NSColor(calibratedRed: 0.88, green: 0.96, blue: 0.91, alpha: 1)
        case .imported:
            badgeText = L10n.loadedBadge
            textColor = NSColor(calibratedRed: 0.27, green: 0.25, blue: 0.53, alpha: 1)
            backgroundColor = NSColor(calibratedRed: 0.92, green: 0.91, blue: 0.98, alpha: 1)
        case .failed:
            badgeText = L10n.errorBadge
            textColor = NSColor(calibratedRed: 0.66, green: 0.19, blue: 0.19, alpha: 1)
            backgroundColor = NSColor(calibratedRed: 0.99, green: 0.90, blue: 0.90, alpha: 1)
        }

        connectionBadge.text = badgeText
        connectionBadge.applyStyle(textColor: textColor, backgroundColor: backgroundColor)
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

        Task { await store.connect(to: host) }
    }

    @objc private func refreshCapture(_ sender: Any?) {
        Task { await store.refreshCapture(forceReloadSelectionDetail: true, clearingVisibleState: true) }
    }

    @objc private func disconnectHost(_ sender: Any?) {
        store.disconnect()
    }
}
