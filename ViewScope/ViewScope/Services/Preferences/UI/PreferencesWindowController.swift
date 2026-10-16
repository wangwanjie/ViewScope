import AppKit
import Combine
import SnapKit

@MainActor
final class PreferencesWindowController: NSWindowController {
    private static let autosaveName = NSWindow.FrameAutosaveName("ViewScopePreferencesWindowFrame")
    private static let toolbarIdentifier = NSToolbar.Identifier("ViewScopePreferencesToolbar")
    private let preferencesController: PreferencesViewController
    private var cancellables = Set<AnyCancellable>()

    init(store: WorkspaceStore) {
        let contentViewController = PreferencesViewController(store: store)
        preferencesController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        window.title = L10n.preferencesWindowTitle
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        shouldCascadeWindows = false

        // 系统设置风格：工具栏图标页签切换“通用 / 更新”
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        toolbar.selectedItemIdentifier = PreferencesPane.general.toolbarItemIdentifier

        contentViewController.onPreferredContentSizeChange = { [weak self] size in
            self?.resizeWindow(toFitContentSize: size, animated: true)
        }
        // 先恢复上次的位置，再按当前页签内容决定尺寸（保持左上角不动）
        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        resizeWindow(toFitContentSize: contentViewController.fittingContentSize, animated: false)
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
                self?.refreshToolbarLabels()
            }
            .store(in: &cancellables)
    }

    private func refreshToolbarLabels() {
        window?.toolbar?.items.forEach { item in
            guard let pane = PreferencesPane(toolbarItemIdentifier: item.itemIdentifier) else {
                return
            }
            item.label = pane.title
        }
    }

    /// 保持窗口左上角不动，按内容高度调整窗口大小。
    private func resizeWindow(toFitContentSize contentSize: NSSize, animated: Bool) {
        guard let window else {
            return
        }
        let contentRect = NSRect(origin: .zero, size: contentSize)
        var frame = window.frameRect(forContentRect: contentRect)
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = PreferencesPane(toolbarItemIdentifier: sender.itemIdentifier) else {
            return
        }
        // 显式同步选中态，保证任何触发方式下页签高亮都与内容一致
        window?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
        preferencesController.select(pane)
    }
}

extension PreferencesWindowController: NSToolbarDelegate {
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = PreferencesPane(toolbarItemIdentifier: itemIdentifier) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PreferencesPane.allCases.map(\.toolbarItemIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}

private enum PreferencesPane: Int, CaseIterable {
    case general
    case updates

    var title: String {
        switch self {
        case .general:
            return L10n.preferencesSegmentGeneral
        case .updates:
            return L10n.preferencesSegmentUpdates
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            return "gearshape"
        case .updates:
            return "arrow.triangle.2.circlepath"
        }
    }

    var toolbarItemIdentifier: NSToolbarItem.Identifier {
        switch self {
        case .general:
            return NSToolbarItem.Identifier("preferences.general")
        case .updates:
            return NSToolbarItem.Identifier("preferences.updates")
        }
    }

    init?(toolbarItemIdentifier: NSToolbarItem.Identifier) {
        guard let pane = Self.allCases.first(where: { $0.toolbarItemIdentifier == toolbarItemIdentifier }) else {
            return nil
        }
        self = pane
    }
}

@MainActor
private final class PreferencesViewController: NSViewController {
    private enum Layout {
        static let contentWidth: CGFloat = 560
        static let contentInset: CGFloat = 20
        static let groupSpacing: CGFloat = 16
    }

    private let store: WorkspaceStore
    private let settings: AppSettings
    private let updateManager: UpdateManager
    private var cancellables = Set<AnyCancellable>()
    private var selectedPane: PreferencesPane = .general

    /// 切换页签后内容高度变化，通知窗口调整尺寸。
    var onPreferredContentSizeChange: ((NSSize) -> Void)?

    private let paneHostView = NSView()
    private let generalPaneView = NSStackView()
    private let updatesPaneView = NSStackView()
    private let languageTitleLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageHintLabel = NSTextField(wrappingLabelWithString: "")
    private let updateChecksTitleLabel = NSTextField(labelWithString: "")
    private let updateStrategyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoRefreshTitleLabel = NSTextField(labelWithString: "")
    private let autoRefreshSwitch = NSSwitch()
    private let autoHighlightTitleLabel = NSTextField(labelWithString: "")
    private let autoHighlightSwitch = NSSwitch()
    private let statusBarCountTitleLabel = NSTextField(labelWithString: "")
    private let statusBarCountSwitch = NSSwitch()
    private let autoReconnectTitleLabel = NSTextField(labelWithString: "")
    private let autoReconnectSwitch = NSSwitch()
    private let automaticDownloadsTitleLabel = NSTextField(labelWithString: "")
    private let automaticDownloadsSwitch = NSSwitch()
    private let automaticDownloadsHint = NSTextField(wrappingLabelWithString: "")
    private let appIconView = NSImageView()
    private let appNameLabel = NSTextField(labelWithString: "")
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

    /// 当前页签内容需要的窗口内容尺寸。
    var fittingContentSize: NSSize {
        _ = view
        view.layoutSubtreeIfNeeded()
        return NSSize(width: Layout.contentWidth, height: ceil(view.fittingSize.height))
    }

    func select(_ pane: PreferencesPane) {
        guard selectedPane != pane else {
            return
        }
        selectedPane = pane
        presentSelectedPane()
        onPreferredContentSizeChange?(fittingContentSize)
    }

    private func buildUI() {
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        updateStrategyPopup.target = self
        updateStrategyPopup.action = #selector(updateStrategyChanged(_:))

        configureSwitch(autoRefreshSwitch, action: #selector(toggleAutoRefresh(_:)))
        configureSwitch(autoHighlightSwitch, action: #selector(toggleAutoHighlight(_:)))
        configureSwitch(statusBarCountSwitch, action: #selector(toggleStatusBarCount(_:)))
        configureSwitch(autoReconnectSwitch, action: #selector(toggleAutoReconnect(_:)))
        configureSwitch(automaticDownloadsSwitch, action: #selector(toggleAutomaticDownloads(_:)))

        checkNowButton.bezelStyle = .rounded
        checkNowButton.target = self
        checkNowButton.action = #selector(checkForUpdates(_:))
        openGitHubButton.bezelStyle = .rounded
        openGitHubButton.target = self
        openGitHubButton.action = #selector(openGitHubHomepage(_:))

        appIconView.image = NSApp.applicationIconImage
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.snp.makeConstraints { make in
            make.width.height.equalTo(44)
        }
        appNameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor

        // 通用：语言 + 行为开关
        configurePaneStack(generalPaneView)
        generalPaneView.addArrangedSubview(PreferencesGroupView(rows: [
            PreferencesRowView(titleLabel: languageTitleLabel, hintLabel: languageHintLabel, control: languagePopup)
        ]))
        generalPaneView.addArrangedSubview(PreferencesGroupView(rows: [
            PreferencesRowView(titleLabel: autoRefreshTitleLabel, control: autoRefreshSwitch),
            PreferencesRowView(titleLabel: autoHighlightTitleLabel, control: autoHighlightSwitch),
            PreferencesRowView(titleLabel: autoReconnectTitleLabel, control: autoReconnectSwitch),
            PreferencesRowView(titleLabel: statusBarCountTitleLabel, control: statusBarCountSwitch)
        ]))

        // 更新：版本信息 + 检查策略
        configurePaneStack(updatesPaneView)
        let appInfoStack = NSStackView(views: [appNameLabel, versionLabel])
        appInfoStack.orientation = .vertical
        appInfoStack.alignment = .leading
        appInfoStack.spacing = 2
        let buttonsStack = NSStackView(views: [openGitHubButton, checkNowButton])
        buttonsStack.orientation = .horizontal
        buttonsStack.spacing = 8
        updatesPaneView.addArrangedSubview(PreferencesGroupView(rows: [
            PreferencesRowView(leadingViews: [appIconView, appInfoStack], control: buttonsStack)
        ]))
        updatesPaneView.addArrangedSubview(PreferencesGroupView(rows: [
            PreferencesRowView(titleLabel: updateChecksTitleLabel, control: updateStrategyPopup),
            PreferencesRowView(titleLabel: automaticDownloadsTitleLabel, hintLabel: automaticDownloadsHint, control: automaticDownloadsSwitch)
        ]))

        view.addSubview(paneHostView)
        paneHostView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(Layout.contentInset)
            make.width.equalTo(Layout.contentWidth - Layout.contentInset * 2)
        }

        presentSelectedPane()
    }

    private func configurePaneStack(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = Layout.groupSpacing
    }

    private func configureSwitch(_ control: NSSwitch, action: Selector) {
        control.controlSize = .small
        control.target = self
        control.action = action
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

        settings.$autoReconnectEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncControlsFromSettings()
            }
            .store(in: &cancellables)

        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                self.applyLocalization()
                self.syncControlsFromSettings()
                // 不同语言文案长度不同，重新适配窗口高度
                self.onPreferredContentSizeChange?(self.fittingContentSize)
            }
            .store(in: &cancellables)
    }

    private func applyLocalization() {
        languageTitleLabel.stringValue = L10n.preferencesLanguage
        languageHintLabel.stringValue = L10n.preferencesLanguageHint
        updateChecksTitleLabel.stringValue = L10n.preferencesUpdateChecks
        autoRefreshTitleLabel.stringValue = L10n.preferencesAutoRefresh
        autoHighlightTitleLabel.stringValue = L10n.preferencesAutoHighlight
        statusBarCountTitleLabel.stringValue = L10n.preferencesStatusCount
        autoReconnectTitleLabel.stringValue = L10n.preferencesAutoReconnect
        automaticDownloadsTitleLabel.stringValue = L10n.preferencesAutoDownloads
        appNameLabel.stringValue = L10n.appName
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
        autoRefreshSwitch.state = settings.autoRefreshEnabled ? .on : .off
        autoHighlightSwitch.state = settings.autoHighlightSelection ? .on : .off
        statusBarCountSwitch.state = settings.showConnectedCountInStatusBar ? .on : .off
        autoReconnectSwitch.state = settings.autoReconnectEnabled ? .on : .off
        automaticDownloadsSwitch.state = updateManager.automaticallyDownloadsUpdates ? .on : .off
        automaticDownloadsSwitch.isEnabled = updateManager.supportsAutomaticUpdateDownloads
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

        guard paneHostView.subviews.first !== paneView else {
            return
        }
        paneHostView.subviews.forEach { $0.removeFromSuperview() }
        paneHostView.addSubview(paneView)
        paneView.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }
        view.layoutSubtreeIfNeeded()
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let index = max(0, sender.indexOfSelectedItem)
        settings.appLanguage = AppLanguage.allCases[index]
    }

    @objc private func updateStrategyChanged(_ sender: NSPopUpButton) {
        let index = max(0, sender.indexOfSelectedItem)
        settings.updateCheckStrategy = AppSettings.UpdateCheckStrategy.allCases[index]
    }

    @objc private func toggleAutoRefresh(_ sender: NSSwitch) {
        settings.autoRefreshEnabled = sender.state == .on
    }

    @objc private func toggleAutoHighlight(_ sender: NSSwitch) {
        settings.autoHighlightSelection = sender.state == .on
    }

    @objc private func toggleAutoReconnect(_ sender: NSSwitch) {
        settings.autoReconnectEnabled = sender.state == .on
    }

    @objc private func toggleStatusBarCount(_ sender: NSSwitch) {
        settings.showConnectedCountInStatusBar = sender.state == .on
    }

    @objc private func toggleAutomaticDownloads(_ sender: NSSwitch) {
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
        layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor)
    }
}

/// 系统设置风格的分组：圆角浅色底，组内各行之间用细线分隔。
private final class PreferencesGroupView: NSView {
    private var dividers: [NSView] = []

    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = WorkspaceTheme.Metrics.panelCornerRadius
        layer?.borderWidth = 1

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.snp.makeConstraints { make in
                    make.height.equalTo(1)
                }
                dividers.append(divider)
                // 分隔线左侧与文字对齐，右侧通栏
                let dividerContainer = NSView()
                dividerContainer.addSubview(divider)
                divider.snp.makeConstraints { make in
                    make.top.bottom.trailing.equalToSuperview()
                    make.leading.equalToSuperview().inset(PreferencesRowView.horizontalInset)
                }
                stack.addArrangedSubview(dividerContainer)
            }
            stack.addArrangedSubview(row)
        }

        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
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
        layer?.backgroundColor = resolvedCGColor(WorkspaceTheme.groupedFill)
        layer?.borderColor = resolvedCGColor(WorkspaceTheme.panelBorder)
        dividers.forEach {
            $0.layer?.backgroundColor = resolvedCGColor(WorkspaceTheme.hairline)
        }
    }
}

/// 分组内的一行：左侧标题（可带说明文字），右侧控件。
private final class PreferencesRowView: NSView {
    static let horizontalInset: CGFloat = 14
    static let textMaxWidth: CGFloat = 320

    convenience init(titleLabel: NSTextField, hintLabel: NSTextField? = nil, control: NSView) {
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0
        // 明确换行宽度，fittingSize 才能算出多行文字的正确高度
        titleLabel.preferredMaxLayoutWidth = Self.textMaxWidth
        var views: [NSView] = [titleLabel]
        if let hintLabel {
            hintLabel.font = .systemFont(ofSize: 11)
            hintLabel.textColor = .secondaryLabelColor
            hintLabel.maximumNumberOfLines = 0
            hintLabel.preferredMaxLayoutWidth = Self.textMaxWidth
            views.append(hintLabel)
        }
        let textStack = NSStackView(views: views)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        self.init(leadingViews: [textStack], control: control)
    }

    init(leadingViews: [NSView], control: NSView) {
        super.init(frame: .zero)

        let leadingStack = NSStackView(views: leadingViews)
        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = 12
        leadingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leadingViews.forEach {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(leadingStack)
        addSubview(control)
        leadingStack.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(Self.horizontalInset)
            make.top.greaterThanOrEqualToSuperview().inset(10)
            make.bottom.lessThanOrEqualToSuperview().inset(10)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(control.snp.leading).offset(-16)
        }
        control.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(Self.horizontalInset)
            make.centerY.equalToSuperview()
            make.top.greaterThanOrEqualToSuperview().inset(8)
            make.bottom.lessThanOrEqualToSuperview().inset(8)
        }
        snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(40)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
