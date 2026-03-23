import AppKit
import Combine
import SnapKit
import ViewScopeServer

@MainActor
final class ConsolePanelController: NSViewController {
    private enum Layout {
        static let documentInset: CGFloat = 12
    }

    private let store: WorkspaceStore
    private let panelView = WorkspacePanelContainerView()
    private let syncToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let targetPopupButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let documentView = ConsoleDocumentView()
    private let inputField = NSTextField()
    private let submitButton = NSButton()
    private let clearButton = NSButton()
    private var cancellables = Set<AnyCancellable>()
    private var currentModel: ConsolePanelModel?

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
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutRowsDocumentView()
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

        submitButton.bezelStyle = .rounded
        submitButton.title = L10n.consoleSubmit
        submitButton.target = self
        submitButton.action = #selector(handleSubmit(_:))

        inputRow.addArrangedSubview(inputField)
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
        Publishers.CombineLatest4(
            store.$capture,
            store.$selectedNodeDetail,
            store.$consoleCurrentTarget,
            store.$consoleRows
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
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

        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.renderCurrentState()
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
        clearButton.isEnabled = model.rows.isEmpty == false

        rebuildTargetPopup(with: model)
        rebuildRows(with: model.rows, showsPlaceholder: store.capture != nil)
    }

    private func rebuildTargetPopup(with model: ConsolePanelModel) {
        targetPopupButton.removeAllItems()
        targetPopupButton.autoenablesItems = false

        if model.targetOptions.isEmpty {
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
        } else {
            targetPopupButton.selectItem(at: 0)
        }
    }

    private func rebuildRows(with rows: [ConsoleRowModel], showsPlaceholder: Bool) {
        documentView.subviews.forEach {
            $0.removeFromSuperview()
        }

        let visibleRows = rows.isEmpty
            ? (showsPlaceholder ? [ConsoleRowModel(kind: .response, title: L10n.consoleEmptyState)] : [])
            : rows
        for row in visibleRows {
            let rowView = ConsoleRowView(row: row)
            documentView.addSubview(rowView)
        }

        layoutRowsDocumentView(scrollsToBottom: rows.isEmpty == false)
    }

    private func layoutRowsDocumentView(scrollsToBottom: Bool = false) {
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

        var currentY = Layout.documentInset
        for subview in documentView.subviews {
            subview.frame = NSRect(
                x: Layout.documentInset,
                y: currentY,
                width: availableWidth,
                height: 1
            )
            subview.layoutSubtreeIfNeeded()
            let fittingHeight = max(subview.fittingSize.height, 24)
            subview.frame.size.height = fittingHeight
            currentY += fittingHeight + 8
        }

        if documentView.subviews.isEmpty == false {
            currentY -= 8
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

    @objc private func handleAutoSyncToggle(_ sender: Any?) {
        store.setConsoleAutoSyncEnabled(syncToggle.state == .on)
    }

    @objc private func handleTargetSelection(_ sender: Any?) {
        guard let objectID = targetPopupButton.selectedItem?.representedObject as? String else { return }
        store.selectConsoleTarget(objectID: objectID)
    }

    @objc private func handleClear(_ sender: Any?) {
        store.clearConsoleHistory()
    }

    @objc private func handleSubmit(_ sender: Any?) {
        let expression = inputField.stringValue
        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputField.stringValue = ""
        Task { await store.submitConsole(expression: expression) }
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
