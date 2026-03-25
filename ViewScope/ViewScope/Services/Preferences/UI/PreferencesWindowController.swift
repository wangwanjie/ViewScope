import AppKit
import Combine
import SnapKit

@MainActor
final class PreferencesWindowController: NSWindowController {
    private static let autosaveName = NSWindow.FrameAutosaveName("ViewScopePreferencesWindowFrame")
    private var cancellables = Set<AnyCancellable>()

    init(store: WorkspaceStore) {
        let contentViewController = PreferencesViewController(store: store)
        let window = NSWindow(contentViewController: contentViewController)
        window.title = L10n.preferencesWindowTitle
        window.styleMask = [.titled, .closable, .miniaturizable]
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 640, height: 420))
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        shouldCascadeWindows = false

        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        bindLocalization()
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

    private func bindLocalization() {
        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.window?.title = L10n.preferencesWindowTitle
            }
            .store(in: &cancellables)
    }
}

@MainActor
private final class PreferencesViewController: NSViewController {
    private enum PreferencesPane: Int, CaseIterable {
        case general
        case updates
    }

    private let store: WorkspaceStore
    private let settings: AppSettings
    private let updateManager: UpdateManager
    private var cancellables = Set<AnyCancellable>()
    private var selectedPane: PreferencesPane = .general

    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let sectionControl = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let card = PreferencesCardView()
    private let paneHostView = NSView()
    private let generalPaneView = NSView()
    private let updatesPaneView = NSView()
    private let languageTitleLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageHintLabel = NSTextField(wrappingLabelWithString: "")
    private let updateChecksTitleLabel = NSTextField(labelWithString: "")
    private let updateStrategyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoRefreshCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let autoHighlightCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let statusBarCountCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let automaticDownloadsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let automaticDownloadsHint = NSTextField(wrappingLabelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let checkNowButton = NSButton(title: "", target: nil, action: nil)
    private let openGitHubButton = NSButton(title: "", target: nil, action: nil)

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
        view = PreferencesBackgroundView()
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindSettings()
        applyLocalization()
        syncControlsFromSettings()
    }

    private func buildUI() {
        titleLabel.font = NSFont(name: "Avenir Next Demi Bold", size: 28) ?? .systemFont(ofSize: 28, weight: .semibold)

        descriptionLabel.textColor = .secondaryLabelColor

        sectionControl.segmentStyle = .rounded
        sectionControl.selectedSegment = selectedPane.rawValue
        sectionControl.target = self
        sectionControl.action = #selector(changePane(_:))

        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))

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
        checkNowButton.target = self
        checkNowButton.action = #selector(checkForUpdates(_:))
        openGitHubButton.target = self
        openGitHubButton.action = #selector(openGitHubHomepage(_:))

        automaticDownloadsHint.textColor = .secondaryLabelColor
        automaticDownloadsHint.maximumNumberOfLines = 2
        languageHintLabel.textColor = .secondaryLabelColor
        languageHintLabel.maximumNumberOfLines = 2

        let generalContentStack = NSStackView(views: [
            labeledRow(titleLabel: languageTitleLabel, control: languagePopup),
            indentedRow(content: languageHintLabel),
            autoRefreshCheckbox,
            autoHighlightCheckbox,
            statusBarCountCheckbox
        ])
        generalContentStack.orientation = .vertical
        generalContentStack.alignment = .leading
        generalContentStack.spacing = 14

        generalPaneView.addSubview(generalContentStack)
        generalContentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let updatesContentStack = NSStackView(views: [
            labeledRow(titleLabel: updateChecksTitleLabel, control: updateStrategyPopup),
            automaticDownloadsCheckbox,
            automaticDownloadsHint,
            actionsRow()
        ])
        updatesContentStack.orientation = .vertical
        updatesContentStack.alignment = .leading
        updatesContentStack.spacing = 14

        updatesPaneView.addSubview(updatesContentStack)
        updatesContentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        card.addSubview(paneHostView)
        paneHostView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(22)
        }

        versionLabel.textColor = .secondaryLabelColor

        let rootStack = NSStackView(views: [titleLabel, descriptionLabel, sectionControl, card, versionLabel])
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
        sectionControl.snp.makeConstraints { make in
            make.width.equalTo(280)
        }

        presentSelectedPane()
    }

    private func bindSettings() {
        settings.$autoRefreshEnabled
            .combineLatest(
                settings.$autoHighlightSelection,
                settings.$showConnectedCountInStatusBar,
                settings.$updateCheckStrategy
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.applyLocalization()
                self?.syncControlsFromSettings()
            }
            .store(in: &cancellables)

        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyLocalization()
                self?.syncControlsFromSettings()
            }
            .store(in: &cancellables)
    }

    private func applyLocalization() {
        titleLabel.stringValue = L10n.preferencesTitle
        descriptionLabel.stringValue = L10n.preferencesDescription
        sectionControl.setLabel(L10n.preferencesSegmentGeneral, forSegment: PreferencesPane.general.rawValue)
        sectionControl.setLabel(L10n.preferencesSegmentUpdates, forSegment: PreferencesPane.updates.rawValue)
        sectionControl.selectedSegment = selectedPane.rawValue
        languageTitleLabel.stringValue = L10n.preferencesLanguage
        languageHintLabel.stringValue = L10n.preferencesLanguageHint
        updateChecksTitleLabel.stringValue = L10n.preferencesUpdateChecks
        autoRefreshCheckbox.title = L10n.preferencesAutoRefresh
        autoHighlightCheckbox.title = L10n.preferencesAutoHighlight
        statusBarCountCheckbox.title = L10n.preferencesStatusCount
        automaticDownloadsCheckbox.title = L10n.preferencesAutoDownloads
        checkNowButton.title = L10n.preferencesCheckForUpdates
        openGitHubButton.title = L10n.preferencesOpenGitHub
        rebuildLanguagePopup()
        rebuildUpdateStrategyPopup()
    }

    private func syncControlsFromSettings() {
        if let languageIndex = AppLanguage.allCases.firstIndex(of: settings.appLanguage) {
            languagePopup.selectItem(at: languageIndex)
        }
        if let strategyIndex = AppSettings.UpdateCheckStrategy.allCases.firstIndex(of: settings.updateCheckStrategy) {
            updateStrategyPopup.selectItem(at: strategyIndex)
        }
        autoRefreshCheckbox.state = settings.autoRefreshEnabled ? .on : .off
        autoHighlightCheckbox.state = settings.autoHighlightSelection ? .on : .off
        statusBarCountCheckbox.state = settings.showConnectedCountInStatusBar ? .on : .off
        automaticDownloadsCheckbox.state = updateManager.automaticallyDownloadsUpdates ? .on : .off
        automaticDownloadsCheckbox.isEnabled = updateManager.supportsAutomaticUpdateDownloads
        automaticDownloadsHint.stringValue = updateManager.supportsAutomaticUpdateDownloads
            ? L10n.preferencesAutoDownloadsAvailable
            : L10n.preferencesAutoDownloadsUnavailable

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        versionLabel.stringValue = L10n.currentVersion(shortVersion, buildVersion)
    }

    private func rebuildLanguagePopup() {
        let selectedLanguage = settings.appLanguage
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: AppLanguage.allCases.map(L10n.languageName))
        if let index = AppLanguage.allCases.firstIndex(of: selectedLanguage) {
            languagePopup.selectItem(at: index)
        }
    }

    private func rebuildUpdateStrategyPopup() {
        let selectedStrategy = settings.updateCheckStrategy
        updateStrategyPopup.removeAllItems()
        updateStrategyPopup.addItems(withTitles: AppSettings.UpdateCheckStrategy.allCases.map(\.title))
        if let index = AppSettings.UpdateCheckStrategy.allCases.firstIndex(of: selectedStrategy) {
            updateStrategyPopup.selectItem(at: index)
        }
    }

    private func presentSelectedPane() {
        let paneView: NSView
        switch selectedPane {
        case .general:
            paneView = generalPaneView
        case .updates:
            paneView = updatesPaneView
        }

        guard paneHostView.subviews.first !== paneView else { return }
        paneHostView.subviews.forEach { $0.removeFromSuperview() }
        paneHostView.addSubview(paneView)
        paneView.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }
        view.layoutSubtreeIfNeeded()
    }

    private func labeledRow(titleLabel: NSTextField, control: NSView) -> NSView {
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

    private func indentedRow(content: NSView) -> NSView {
        let spacer = NSView()
        spacer.snp.makeConstraints { make in
            make.width.equalTo(112)
        }

        let row = NSStackView(views: [spacer, content])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func actionsRow() -> NSView {
        let buttons = NSStackView(views: [checkNowButton, openGitHubButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        return indentedRow(content: buttons)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let index = max(0, sender.indexOfSelectedItem)
        settings.appLanguage = AppLanguage.allCases[index]
    }

    @objc private func changePane(_ sender: NSSegmentedControl) {
        let selectedIndex = max(0, sender.selectedSegment)
        selectedPane = PreferencesPane(rawValue: selectedIndex) ?? .general
        presentSelectedPane()
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

private final class PreferencesBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

private final class PreferencesCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.borderWidth = 1
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
    }
}
