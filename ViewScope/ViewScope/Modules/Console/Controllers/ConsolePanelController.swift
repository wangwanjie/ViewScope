import AppKit
import Combine
import SnapKit
import ViewScopeServer

@MainActor
final class ConsolePanelController: NSViewController {
    private enum Layout {
        static let documentInset: CGFloat = 12
        static let rowSpacing: CGFloat = 8
        /// 距离底部小于该值时视为“停在底部”，新行到达后自动滚动。
        static let bottomStickThreshold: CGFloat = 24
        /// 补全菜单最多显示的条目数。
        static let maximumCompletionMenuItems = 60
    }

    /// 输入停止后多久预取补全（秒）。
    static let completionDebounceInterval: TimeInterval = 0.25

    private let store: WorkspaceStore
    private let panelView = WorkspacePanelContainerView()
    private let syncToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let targetPopupButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let documentView = ConsoleDocumentView()
    private let inputField = NSTextField()
    private let referenceButton = NSButton()
    private let submitButton = NSButton()
    private let clearButton = NSButton()
    private var cancellables = Set<AnyCancellable>()
    private var currentModel: ConsolePanelModel?

    /// 已渲染的行（按顺序），用于增量追加，避免每次都重建全部行。
    private var renderedRowIDs: [String] = []
    private var rowViewsByID: [String: ConsoleRowView] = [:]
    private var rowHeightsByID: [String: CGFloat] = [:]
    private var lastLayoutWidth: CGFloat = 0
    private var isShowingPlaceholderRow = false
    /// 目标下拉框上次渲染时的签名，未变化时不重建（避免下拉菜单打开时被关闭）。
    private var lastTargetPopupSignature: [String] = []

    /// 补全缓存：仅对同一前缀有效。
    private var cachedCompletionPrefix: String?
    private var cachedCompletions: [ViewScopeConsoleCompletion] = []
    private var completionTask: Task<Void, Never>?

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = panelView
        panelView.setAccessibilityElement(true)
        panelView.setAccessibilityRole(.group)
        panelView.setAccessibilityIdentifier("workspace.consolePanel")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bindStore()
        renderCurrentState()
        renderRows()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutRowsDocumentView(scrollsToBottom: false)
    }

    private func buildUI() {
        panelView.setTitle(L10n.consoleTitle)

        configureToolbarButton(clearButton, symbolName: "trash", toolTip: L10n.consoleClearHistory, action: #selector(handleClear(_:)))
        panelView.accessoryStackView.addArrangedSubview(clearButton)

        syncToggle.title = L10n.consoleAutoSync
        syncToggle.font = NSFont.systemFont(ofSize: 11)
        syncToggle.target = self
        syncToggle.action = #selector(handleAutoSyncToggle(_:))

        targetPopupButton.bezelStyle = .rounded
        targetPopupButton.target = self
        targetPopupButton.action = #selector(handleTargetSelection(_:))
        targetPopupButton.autoenablesItems = false

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = documentView

        let targetRow = NSStackView(views: [syncToggle, targetPopupButton])
        targetRow.orientation = .horizontal
        targetRow.alignment = .centerY
        targetRow.spacing = 8
        targetPopupButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let inputRow = NSStackView()
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8

        inputField.placeholderString = L10n.consoleInputPlaceholder
        inputField.target = self
        inputField.action = #selector(handleSubmit(_:))
        inputField.delegate = self
        inputField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        referenceButton.bezelStyle = .rounded
        referenceButton.title = "@"
        referenceButton.toolTip = L10n.consoleInsertObjectReference
        referenceButton.target = self
        referenceButton.action = #selector(showReferenceMenu(_:))

        submitButton.bezelStyle = .rounded
        submitButton.title = L10n.consoleSubmit
        submitButton.target = self
        submitButton.action = #selector(handleSubmit(_:))

        inputRow.addArrangedSubview(inputField)
        inputRow.addArrangedSubview(referenceButton)
        inputRow.addArrangedSubview(submitButton)

        panelView.contentView.addSubview(targetRow)
        panelView.contentView.addSubview(statusLabel)
        panelView.contentView.addSubview(scrollView)
        panelView.contentView.addSubview(inputRow)

        targetRow.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }
        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(targetRow.snp.bottom).offset(6)
            make.leading.trailing.equalToSuperview().inset(12)
        }
        inputRow.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview().inset(12)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(statusLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(inputRow.snp.top).offset(-10)
        }
    }

    private func bindStore() {
        // 头部状态（目标、可用性）与行列表分开刷新：抓取变化不再重建全部行
        Publishers.CombineLatest3(
            store.$capture.map { $0?.captureID }.removeDuplicates(),
            store.$consoleCurrentTarget,
            store.$connectionState
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.renderCurrentState()
        }
        .store(in: &cancellables)

        Publishers.CombineLatest4(
            store.$consoleCandidateTargets,
            store.$consoleRecentTargets,
            store.$consoleAutoSyncEnabled,
            store.$consoleIsLoadingTarget
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            self?.renderCurrentState()
        }
        .store(in: &cancellables)

        store.$consoleRows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.renderCurrentState()
                self?.renderRows()
            }
            .store(in: &cancellables)

        store.$capture
            .map { $0 == nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.renderRows()
            }
            .store(in: &cancellables)

        // 当前目标变化后补全缓存失效
        store.$consoleCurrentTarget
            .map { $0?.reference.objectID }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.invalidateCompletionCache()
            }
            .store(in: &cancellables)

        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lastTargetPopupSignature = []
                self?.renderCurrentState()
                self?.renderRows(forceRebuild: true)
            }
            .store(in: &cancellables)
    }

    private func renderCurrentState() {
        let model = ConsoleModelBuilder.make(
            currentTarget: store.consoleCurrentTarget,
            candidateTargets: store.consoleCandidateTargets,
            recentTargets: store.consoleRecentTargets,
            rows: store.consoleRows,
            autoSyncEnabled: store.consoleAutoSyncEnabled,
            isLoading: store.consoleIsLoadingTarget,
            captureID: store.capture?.captureID
        )
        currentModel = model
        panelView.setTitle(L10n.consoleTitle, subtitle: model.currentTarget?.subtitle)

        syncToggle.title = L10n.consoleAutoSync
        syncToggle.state = model.autoSyncEnabled ? .on : .off
        statusLabel.stringValue = model.statusText ?? ""
        statusLabel.isHidden = model.statusText == nil
        inputField.isEnabled = model.isSubmitEnabled
        submitButton.isEnabled = model.isSubmitEnabled
        referenceButton.isEnabled = model.isSubmitEnabled && store.supportsExtendedConsoleSyntax
        referenceButton.toolTip = L10n.consoleInsertObjectReference
        submitButton.title = L10n.consoleSubmit
        clearButton.isEnabled = model.rows.isEmpty == false
        inputField.placeholderString = store.supportsExtendedConsoleSyntax
            ? L10n.consoleInputPlaceholderExtended
            : L10n.consoleInputPlaceholder

        rebuildTargetPopupIfNeeded(with: model)
    }

    private func rebuildTargetPopupIfNeeded(with model: ConsolePanelModel) {
        let signature = model.targetOptions.map { "\($0.id)|\($0.descriptor.title)|\($0.source == .recent)" }
            + ["current:\(model.currentTarget?.reference.objectID ?? "")|\(model.currentTarget?.reference.captureID ?? "")"]
        guard signature != lastTargetPopupSignature else {
            return
        }
        lastTargetPopupSignature = signature

        targetPopupButton.removeAllItems()

        if model.targetOptions.isEmpty, model.currentTarget == nil {
            targetPopupButton.addItem(withTitle: L10n.consoleNoTargets)
            targetPopupButton.lastItem?.isEnabled = false
            return
        }

        for option in model.targetOptions {
            let sourceSuffix = option.source == .recent ? L10n.consoleRecentSuffix : L10n.consoleSelectionSuffix
            let item = NSMenuItem(title: "\(option.descriptor.title) \(sourceSuffix)", action: nil, keyEquivalent: "")
            item.representedObject = option.id
            targetPopupButton.menu?.addItem(item)
        }

        if let currentTarget = model.currentTarget,
           let index = model.targetOptions.firstIndex(where: { $0.id == currentTarget.reference.objectID }) {
            targetPopupButton.selectItem(at: index)
        } else if let currentTarget = model.currentTarget {
            // 当前目标不在候选列表中（例如已失效）：单独显示一个不可选的条目，而不是误选第 0 项
            let item = NSMenuItem(title: currentTarget.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            targetPopupButton.menu?.insertItem(item, at: 0)
            targetPopupButton.selectItem(at: 0)
        } else {
            let item = NSMenuItem(title: L10n.consoleStatusNoTarget, action: nil, keyEquivalent: "")
            item.isEnabled = false
            targetPopupButton.menu?.insertItem(item, at: 0)
            targetPopupButton.selectItem(at: 0)
        }
    }

    // MARK: - 行渲染

    private func renderRows(forceRebuild: Bool = false) {
        let rows = store.consoleRows
        let showsPlaceholder = rows.isEmpty && store.capture != nil
        let wasAtBottom = isScrolledToBottom

        if rows.isEmpty {
            removeAllRowViews()
            if showsPlaceholder {
                let placeholder = ConsoleRowModel(id: "console.placeholder", kind: .response, title: L10n.consoleEmptyState)
                addRowView(for: placeholder)
                isShowingPlaceholderRow = true
            }
            layoutRowsDocumentView(scrollsToBottom: false)
            return
        }

        if isShowingPlaceholderRow || forceRebuild {
            removeAllRowViews()
        }

        // 行只会在尾部追加、在头部被截断（上限 500）或整体清空：先移除头部已不存在的行
        let newIDs = rows.map(\.id)
        let newIDSet = Set(newIDs)
        let staleIDs = renderedRowIDs.filter { newIDSet.contains($0) == false }
        for staleID in staleIDs {
            rowViewsByID[staleID]?.removeFromSuperview()
            rowViewsByID.removeValue(forKey: staleID)
            rowHeightsByID.removeValue(forKey: staleID)
        }
        renderedRowIDs.removeAll { newIDSet.contains($0) == false }

        guard Array(newIDs.prefix(renderedRowIDs.count)) == renderedRowIDs else {
            // 不是简单追加：整体重建
            removeAllRowViews()
            rows.forEach { addRowView(for: $0) }
            layoutRowsDocumentView(scrollsToBottom: true)
            return
        }

        let appendedRows = rows.dropFirst(renderedRowIDs.count)
        appendedRows.forEach { addRowView(for: $0) }
        // 用户停在底部（或刚提交命令）时跟随滚动；向上翻看历史时保持位置
        layoutRowsDocumentView(scrollsToBottom: wasAtBottom && appendedRows.isEmpty == false)
    }

    private func addRowView(for row: ConsoleRowModel) {
        let rowView = ConsoleRowView(row: row)
        documentView.addSubview(rowView)
        rowViewsByID[row.id] = rowView
        renderedRowIDs.append(row.id)
    }

    private func removeAllRowViews() {
        documentView.subviews.forEach {
            $0.removeFromSuperview()
        }
        rowViewsByID.removeAll()
        rowHeightsByID.removeAll()
        renderedRowIDs.removeAll()
        isShowingPlaceholderRow = false
    }

    private var isScrolledToBottom: Bool {
        let visibleRect = scrollView.contentView.documentVisibleRect
        return visibleRect.maxY >= documentView.bounds.height - Layout.bottomStickThreshold
    }

    private func layoutRowsDocumentView(scrollsToBottom: Bool) {
        let contentSize = scrollView.contentSize
        let availableWidth = max(0, contentSize.width - (Layout.documentInset * 2))

        guard availableWidth > 0 else {
            documentView.frame = NSRect(
                x: 0,
                y: 0,
                width: max(contentSize.width, 1),
                height: max(contentSize.height, 1)
            )
            return
        }

        // 宽度变化时行高缓存失效
        if availableWidth != lastLayoutWidth {
            rowHeightsByID.removeAll()
            lastLayoutWidth = availableWidth
        }

        var currentY = Layout.documentInset
        for rowID in renderedRowIDs {
            guard let subview = rowViewsByID[rowID] else {
                continue
            }
            let height: CGFloat
            if let cachedHeight = rowHeightsByID[rowID] {
                height = cachedHeight
            } else {
                subview.frame = NSRect(x: Layout.documentInset, y: currentY, width: availableWidth, height: 1)
                subview.layoutSubtreeIfNeeded()
                height = max(subview.fittingSize.height, 24)
                rowHeightsByID[rowID] = height
            }
            subview.frame = NSRect(x: Layout.documentInset, y: currentY, width: availableWidth, height: height)
            currentY += height + Layout.rowSpacing
        }

        if renderedRowIDs.isEmpty == false {
            currentY -= Layout.rowSpacing
        }

        let documentWidth = max(contentSize.width, availableWidth + (Layout.documentInset * 2))
        let documentHeight = max(contentSize.height, currentY + Layout.documentInset)
        documentView.frame = NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight)

        if scrollsToBottom {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: max(0, documentView.bounds.height - scrollView.contentView.bounds.height)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func configureToolbarButton(_ button: NSButton, symbolName: String, toolTip: String, action: Selector) {
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.target = self
        button.action = action
    }

    // MARK: - 输入辅助

    /// 当前光标位置（UTF-16）。
    private var inputCursorLocation: Int {
        if let editor = inputField.currentEditor() {
            return editor.selectedRange.location
        }
        return (inputField.stringValue as NSString).length
    }

    private func replaceInput(with text: String, cursorLocation: Int) {
        inputField.stringValue = text
        if let editor = inputField.currentEditor() {
            editor.selectedRange = NSRange(location: cursorLocation, length: 0)
        }
    }

    /// 在光标处插入文本。
    private func insertIntoInput(_ text: String) {
        view.window?.makeFirstResponder(inputField)
        let current = inputField.stringValue as NSString
        let location = min(inputCursorLocation, current.length)
        var insertion = text
        // 引用参数前补一个空格，避免与前面的关键字粘连
        if location > 0 {
            let previous = current.character(at: location - 1)
            if let scalar = Unicode.Scalar(previous), CharacterSet.whitespaces.contains(scalar) == false, scalar != ":" {
                insertion = " " + insertion
            }
        }
        let next = current.replacingCharacters(in: NSRange(location: location, length: 0), with: insertion)
        replaceInput(with: next, cursorLocation: location + (insertion as NSString).length)
    }

    private func invalidateCompletionCache() {
        completionTask?.cancel()
        completionTask = nil
        cachedCompletionPrefix = nil
        cachedCompletions = []
    }

    /// 输入变化后防抖预取补全。
    private func scheduleCompletionPrefetch() {
        guard store.supportsExtendedConsoleSyntax else {
            return
        }
        let token = ConsoleCompletionToken.token(in: inputField.stringValue, cursorLocation: inputCursorLocation)
        guard token.prefix.isEmpty == false, token.prefix != cachedCompletionPrefix else {
            return
        }
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.completionDebounceInterval * 1_000_000_000))
            guard Task.isCancelled == false, let self else {
                return
            }
            let completions = await self.store.requestConsoleCompletions(prefix: token.prefix)
            guard Task.isCancelled == false else {
                return
            }
            self.cachedCompletionPrefix = token.prefix
            self.cachedCompletions = completions
        }
    }

    /// Tab：唯一结果直接补全，多个结果弹出菜单。
    private func presentCompletions() {
        guard store.supportsExtendedConsoleSyntax, currentModel?.isSubmitEnabled == true else {
            NSSound.beep()
            return
        }
        let token = ConsoleCompletionToken.token(in: inputField.stringValue, cursorLocation: inputCursorLocation)
        if token.prefix == cachedCompletionPrefix, cachedCompletions.isEmpty == false {
            showCompletionMenu(cachedCompletions, token: token)
            return
        }
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard let self else {
                return
            }
            let completions = await self.store.requestConsoleCompletions(prefix: token.prefix.isEmpty ? nil : token.prefix)
            guard Task.isCancelled == false else {
                return
            }
            self.cachedCompletionPrefix = token.prefix
            self.cachedCompletions = completions
            // 等待期间用户继续输入：只有单词没变才弹出
            let latestToken = ConsoleCompletionToken.token(in: self.inputField.stringValue, cursorLocation: self.inputCursorLocation)
            guard latestToken == token else {
                return
            }
            self.showCompletionMenu(completions, token: token)
        }
    }

    private func showCompletionMenu(_ completions: [ViewScopeConsoleCompletion], token: ConsoleCompletionToken) {
        guard completions.isEmpty == false else {
            NSSound.beep()
            return
        }
        if completions.count == 1, let completion = completions.first {
            applyCompletion(completion.name, token: token)
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for completion in completions.prefix(Layout.maximumCompletionMenuItems) {
            let item = NSMenuItem(title: completion.name, action: #selector(handleCompletionItem(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = "\(completion.signature)  —  \(completion.declaringClassName)"
            item.representedObject = ConsoleCompletionSelection(name: completion.name, token: token)
            if completion.isProperty {
                item.image = NSImage(systemSymbolName: "p.square", accessibilityDescription: nil)
            } else {
                item.image = NSImage(systemSymbolName: "m.square", accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: inputField.bounds.height + 4), in: inputField)
    }

    private func applyCompletion(_ name: String, token: ConsoleCompletionToken) {
        let result = token.applying(name, to: inputField.stringValue)
        view.window?.makeFirstResponder(inputField)
        replaceInput(with: result.text, cursorLocation: result.cursorLocation)
    }

    // MARK: - 事件

    @objc private func handleCompletionItem(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ConsoleCompletionSelection else {
            return
        }
        applyCompletion(selection.name, token: selection.token)
    }

    @objc private func showReferenceMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let returnedObjects = store.consoleRecentTargets
        let selectionTargets = store.consoleCandidateTargets
        if returnedObjects.isEmpty, selectionTargets.isEmpty {
            let item = NSMenuItem(title: L10n.consoleNoRecentObjects, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for descriptor in returnedObjects {
            menu.addItem(makeReferenceItem(descriptor, suffix: L10n.consoleRecentSuffix))
        }
        if returnedObjects.isEmpty == false, selectionTargets.isEmpty == false {
            menu.addItem(.separator())
        }
        for descriptor in selectionTargets {
            menu.addItem(makeReferenceItem(descriptor, suffix: L10n.consoleSelectionSuffix))
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func makeReferenceItem(_ descriptor: ViewScopeConsoleTargetDescriptor, suffix: String) -> NSMenuItem {
        let reference = "@\(descriptor.reference.objectID)"
        let item = NSMenuItem(title: "\(reference)  \(descriptor.title) \(suffix)", action: #selector(handleReferenceItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = reference
        return item
    }

    @objc private func handleReferenceItem(_ sender: NSMenuItem) {
        guard let reference = sender.representedObject as? String else {
            return
        }
        insertIntoInput(reference)
    }

    @objc private func handleAutoSyncToggle(_ sender: Any?) {
        store.setConsoleAutoSyncEnabled(syncToggle.state == .on)
    }

    @objc private func handleTargetSelection(_ sender: Any?) {
        guard let objectID = targetPopupButton.selectedItem?.representedObject as? String else {
            return
        }
        store.selectConsoleTarget(objectID: objectID)
    }

    @objc private func handleClear(_ sender: Any?) {
        store.clearConsoleHistory()
    }

    @objc private func handleSubmit(_ sender: Any?) {
        let expression = inputField.stringValue
        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        inputField.stringValue = ""
        invalidateCompletionCache()
        Task {
            await store.submitConsole(expression: expression)
            // 自己提交的命令总是滚动到底部
            layoutRowsDocumentView(scrollsToBottom: true)
        }
    }
}

extension ConsolePanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleCompletionPrefetch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            if let entry = store.previousConsoleHistoryEntry(currentInput: inputField.stringValue) {
                replaceInput(with: entry, cursorLocation: (entry as NSString).length)
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if let entry = store.nextConsoleHistoryEntry() {
                replaceInput(with: entry, cursorLocation: (entry as NSString).length)
            }
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.complete(_:)):
            presentCompletions()
            return true
        default:
            return false
        }
    }
}

/// 补全菜单项携带的数据。
private final class ConsoleCompletionSelection: NSObject {
    let name: String
    let token: ConsoleCompletionToken

    init(name: String, token: ConsoleCompletionToken) {
        self.name = name
        self.token = token
    }
}

private final class ConsoleDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ConsoleRowView: NSView {
    init(row: ConsoleRowModel) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        let titleLabel = NSTextField(wrappingLabelWithString: row.title)
        titleLabel.maximumNumberOfLines = 0
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        titleLabel.isSelectable = true

        let subtitleLabel = NSTextField(wrappingLabelWithString: row.subtitle ?? "")
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.font = NSFont.systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isHidden = row.subtitle == nil

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3

        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(10)
        }

        switch row.kind {
        case .submit:
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        case .response:
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.2).cgColor
        case .error:
            titleLabel.textColor = .systemRed
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.07).cgColor
            layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
