import AppKit
import Combine
import SnapKit
import UniformTypeIdentifiers
import ViewScopeServer

@MainActor
/// “修改记录”面板：列出所有实时修改，支持逐条还原、撤销/重做、清空与导出为代码。
final class ModificationLogViewController: NSViewController {
    private enum Column {
        static let time = NSUserInterfaceItemIdentifier("modification.time")
        static let object = NSUserInterfaceItemIdentifier("modification.object")
        static let property = NSUserInterfaceItemIdentifier("modification.property")
        static let change = NSUserInterfaceItemIdentifier("modification.change")
        static let action = NSUserInterfaceItemIdentifier("modification.action")
    }

    private let store: WorkspaceStore
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let clearButton = NSButton()
    private let exportButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var records: [WorkspaceModificationRecord] = []
    private var cancellables = Set<AnyCancellable>()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bindStore()
        applyLocalization()
        reload()
    }

    private func buildUI() {
        [undoButton, redoButton, clearButton, exportButton].forEach {
            $0.bezelStyle = .rounded
            $0.target = self
        }
        undoButton.action = #selector(handleUndo(_:))
        redoButton.action = #selector(handleRedo(_:))
        clearButton.action = #selector(handleClear(_:))
        exportButton.action = #selector(handleExport(_:))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        let toolbar = NSStackView(views: [undoButton, redoButton, clearButton, statusLabel, exportButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let columns: [(NSUserInterfaceItemIdentifier, CGFloat)] = [
            (Column.time, 70),
            (Column.object, 200),
            (Column.property, 140),
            (Column.change, 240),
            (Column.action, 70)
        ]
        for (identifier, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.width = width
            column.minWidth = 50
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick(_:))
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor

        view.addSubview(toolbar)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        toolbar.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(toolbar.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview().inset(12)
        }
        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
            make.width.lessThanOrEqualTo(scrollView).offset(-40)
        }
    }

    private func bindStore() {
        store.modificationLog.$records
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)

        // 撤销栈、连接状态、抓取变化都会影响按钮与“还原”是否可用
        Publishers.CombineLatest4(
            store.modificationLog.$canUndo,
            store.modificationLog.$canRedo,
            store.$connectionState,
            store.$isApplyingModificationHistory
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            self?.updateControls()
            self?.tableView.reloadData()
        }
        .store(in: &cancellables)

        store.$capture
            .map { $0?.captureID }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateControls()
                self?.tableView.reloadData()
            }
            .store(in: &cancellables)

        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyLocalization()
            }
            .store(in: &cancellables)
    }

    private func applyLocalization() {
        undoButton.title = L10n.menuUndo
        redoButton.title = L10n.menuRedo
        clearButton.title = L10n.changesClear
        exportButton.title = L10n.changesExportCode
        emptyLabel.stringValue = L10n.changesEmpty
        tableView.tableColumn(withIdentifier: Column.time)?.title = L10n.changesColumnTime
        tableView.tableColumn(withIdentifier: Column.object)?.title = L10n.changesColumnObject
        tableView.tableColumn(withIdentifier: Column.property)?.title = L10n.changesColumnProperty
        tableView.tableColumn(withIdentifier: Column.change)?.title = L10n.changesColumnChange
        tableView.tableColumn(withIdentifier: Column.action)?.title = ""
        tableView.reloadData()
    }

    private func reload() {
        // 最新的修改显示在最上面
        records = store.modificationLog.records.reversed()
        tableView.reloadData()
        emptyLabel.isHidden = records.isEmpty == false
        updateControls()
    }

    private func updateControls() {
        undoButton.isEnabled = store.canUndoModification
        redoButton.isEnabled = store.canRedoModification
        clearButton.isEnabled = records.isEmpty == false
        exportButton.isEnabled = records.contains(where: { $0.state == .applied })
        statusLabel.stringValue = store.connectionState.activeHost == nil && records.isEmpty == false
            ? L10n.changesReadOnlyHint
            : ""
    }

    // MARK: - 事件

    @objc private func handleUndo(_ sender: Any?) {
        Task {
            await store.undoLastModification()
        }
    }

    @objc private func handleRedo(_ sender: Any?) {
        Task {
            await store.redoLastModification()
        }
    }

    @objc private func handleClear(_ sender: Any?) {
        store.clearModificationLog()
    }

    @objc private func handleExport(_ sender: NSButton) {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: L10n.changesCopyCode, action: #selector(copyCode(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        let saveItem = NSMenuItem(title: L10n.changesSaveCode, action: #selector(saveCode(_:)), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func copyCode(_ sender: Any?) {
        let code = store.makeModificationCode()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        statusLabel.stringValue = L10n.changesCodeCopied
    }

    @objc private func saveCode(_ sender: Any?) {
        let code = store.makeModificationCode()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ViewScopeChanges.swift"
        panel.allowedContentTypes = [.swiftSource]
        panel.canCreateDirectories = true
        guard let window = view.window else {
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                try code.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func handleRevert(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < records.count else {
            return
        }
        let recordID = records[row].id
        Task {
            await store.revertModification(id: recordID)
        }
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < records.count else {
            return
        }
        let record = records[row]
        guard store.connectionState.activeHost?.identifier == record.hostIdentifier else {
            return
        }
        Task {
            await store.revealNode(record.nodeID)
        }
    }
}

extension ModificationLogViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, row < records.count else {
            return nil
        }
        let record = records[row]

        if identifier == Column.action {
            let button = NSButton(title: L10n.changesRevert, target: self, action: #selector(handleRevert(_:)))
            button.bezelStyle = .inline
            button.controlSize = .small
            button.tag = row
            button.isEnabled = store.canRevertModification(record)
            return button
        }

        let text: String
        switch identifier {
        case Column.time:
            text = Self.timeFormatter.string(from: record.date)
        case Column.object:
            let className = ViewScopeClassNameFormatter.displayName(for: record.displayClassName)
            text = [className, record.nodeAddress].compactMap { $0 }.joined(separator: " ")
        case Column.property:
            text = record.title
        case Column.change:
            let oldValue = WorkspaceModificationValueFormatter.displayString(for: record.oldValue)
            let newValue = WorkspaceModificationValueFormatter.displayString(for: record.newValue)
            let suffix = record.state == .undone ? " \(L10n.changesUndoneSuffix)" : ""
            text = "\(oldValue) → \(newValue)\(suffix)"
        default:
            text = ""
        }

        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.font = identifier == Column.change
            ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            : NSFont.systemFont(ofSize: 12)
        label.textColor = record.state == .undone ? .secondaryLabelColor : .labelColor
        label.toolTip = "\(record.hostDisplayName) · \(record.key)"
        return label
    }
}
