import AppKit
import Combine
import SnapKit

@MainActor
final class PreferencesWindowController: NSWindowController {
    private static let autosaveName = NSWindow.FrameAutosaveName("ViewScopePreferencesWindowFrame")

    init(store: WorkspaceStore) {
        let contentViewController = PreferencesViewController(store: store)
        let window = NSWindow(contentViewController: contentViewController)
        window.title = "Preferences"
        window.appearance = NSAppearance(named: .aqua)
        window.styleMask = [.titled, .closable, .miniaturizable]
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 600, height: 360))
        window.minSize = NSSize(width: 600, height: 360)
        super.init(window: window)
        shouldCascadeWindows = false

        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPreferencesWindow() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class PreferencesViewController: NSViewController {
    private let store: WorkspaceStore
    private let settings: AppSettings
    private let updateManager: UpdateManager
    private var cancellables = Set<AnyCancellable>()

    private let updateStrategyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoRefreshCheckbox = NSButton(checkboxWithTitle: "Enable automatic refresh every 2.5 seconds", target: nil, action: nil)
    private let autoHighlightCheckbox = NSButton(checkboxWithTitle: "Highlight the selected node in the host app", target: nil, action: nil)
    private let statusBarCountCheckbox = NSButton(checkboxWithTitle: "Show connected count in the status bar item", target: nil, action: nil)
    private let automaticDownloadsCheckbox = NSButton(checkboxWithTitle: "Automatically download updates", target: nil, action: nil)
    private let automaticDownloadsHint = NSTextField(wrappingLabelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")

    init(store: WorkspaceStore) {
        self.store = store
        self.settings = store.settings
        self.updateManager = store.updateManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindSettings()
        syncControlsFromSettings()
    }

    private func buildUI() {
        let titleLabel = NSTextField(labelWithString: "Preferences")
        titleLabel.font = NSFont(name: "Avenir Next Demi Bold", size: 28) ?? .systemFont(ofSize: 28, weight: .semibold)

        let descriptionLabel = NSTextField(wrappingLabelWithString: "Tune how ViewScope refreshes captures, mirrors selection back to the host app, and checks for updates.")
        descriptionLabel.textColor = .secondaryLabelColor

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.backgroundColor = NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.92, alpha: 1).cgColor

        updateStrategyPopup.addItems(withTitles: AppSettings.UpdateCheckStrategy.allCases.map(\.title))
        updateStrategyPopup.target = self
        updateStrategyPopup.action = #selector(updateStrategyChanged(_:))

        autoRefreshCheckbox.target = self
        autoRefreshCheckbox.action = #selector(toggleAutoRefresh(_:))
        autoHighlightCheckbox.target = self
        autoHighlightCheckbox.action = #selector(toggleAutoHighlight(_:))
        statusBarCountCheckbox.target = self
        statusBarCountCheckbox.action = #selector(toggleStatusBarCount(_:))
        automaticDownloadsCheckbox.target = self
        automaticDownloadsCheckbox.action = #selector(toggleAutomaticDownloads(_:))

        automaticDownloadsHint.textColor = .secondaryLabelColor
        automaticDownloadsHint.maximumNumberOfLines = 2

        let strategyRow = labeledRow(title: "Update checks", control: updateStrategyPopup)
        let contentStack = NSStackView(views: [
            strategyRow,
            autoRefreshCheckbox,
            autoHighlightCheckbox,
            statusBarCountCheckbox,
            automaticDownloadsCheckbox,
            automaticDownloadsHint,
            actionsRow()
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14

        card.addSubview(contentStack)
        contentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(22)
        }

        versionLabel.textColor = .secondaryLabelColor

        let rootStack = NSStackView(views: [titleLabel, descriptionLabel, card, versionLabel])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 18

        view.addSubview(rootStack)
        rootStack.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(24)
            make.bottom.lessThanOrEqualToSuperview().inset(24)
        }
        card.snp.makeConstraints { make in
            make.width.equalTo(rootStack)
        }
    }

    private func bindSettings() {
        settings.$autoRefreshEnabled
            .combineLatest(settings.$autoHighlightSelection, settings.$showConnectedCountInStatusBar, settings.$updateCheckStrategy)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.syncControlsFromSettings()
            }
            .store(in: &cancellables)
    }

    private func syncControlsFromSettings() {
        if let index = AppSettings.UpdateCheckStrategy.allCases.firstIndex(of: settings.updateCheckStrategy) {
            updateStrategyPopup.selectItem(at: index)
        }
        autoRefreshCheckbox.state = settings.autoRefreshEnabled ? .on : .off
        autoHighlightCheckbox.state = settings.autoHighlightSelection ? .on : .off
        statusBarCountCheckbox.state = settings.showConnectedCountInStatusBar ? .on : .off
        automaticDownloadsCheckbox.state = updateManager.automaticallyDownloadsUpdates ? .on : .off
        automaticDownloadsCheckbox.isEnabled = updateManager.supportsAutomaticUpdateDownloads
        automaticDownloadsHint.stringValue = updateManager.supportsAutomaticUpdateDownloads
            ? "Sparkle can fetch the next release in the background and install it after restart."
            : "Sparkle automatic downloads are unavailable until a signed appcast feed is configured."

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        versionLabel.stringValue = "Current version \(shortVersion) (\(buildVersion))"
    }

    private func labeledRow(title: String, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.alignment = .right
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.snp.makeConstraints { make in
            make.width.equalTo(112)
        }

        let row = NSStackView(views: [titleLabel, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func actionsRow() -> NSView {
        let checkNowButton = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates(_:)))
        let openGitHubButton = NSButton(title: "Open GitHub", target: self, action: #selector(openGitHubHomepage(_:)))
        let buttons = NSStackView(views: [checkNowButton, openGitHubButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let spacer = NSView()
        spacer.snp.makeConstraints { make in
            make.width.equalTo(112)
        }

        let row = NSStackView(views: [spacer, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    @objc private func updateStrategyChanged(_ sender: NSPopUpButton) {
        let index = max(0, sender.indexOfSelectedItem)
        settings.updateCheckStrategy = AppSettings.UpdateCheckStrategy.allCases[index]
    }

    @objc private func toggleAutoRefresh(_ sender: NSButton) {
        settings.autoRefreshEnabled = sender.state == .on
    }

    @objc private func toggleAutoHighlight(_ sender: NSButton) {
        settings.autoHighlightSelection = sender.state == .on
    }

    @objc private func toggleStatusBarCount(_ sender: NSButton) {
        settings.showConnectedCountInStatusBar = sender.state == .on
    }

    @objc private func toggleAutomaticDownloads(_ sender: NSButton) {
        updateManager.automaticallyDownloadsUpdates = sender.state == .on
        syncControlsFromSettings()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updateManager.checkForUpdates()
    }

    @objc private func openGitHubHomepage(_ sender: Any?) {
        updateManager.openGitHubHomepage()
    }
}
