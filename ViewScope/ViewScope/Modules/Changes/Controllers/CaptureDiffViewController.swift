import AppKit
import Combine
import SnapKit
import UniformTypeIdentifiers
import ViewScopeServer

@MainActor
/// “抓取对比”面板：把当前抓取与基线比较，按类别筛选，点击条目在工作区中选中节点。
final class CaptureDiffViewController: NSViewController {
    private enum Column {
        static let category = NSUserInterfaceItemIdentifier("diff.category")
        static let object = NSUserInterfaceItemIdentifier("diff.object")
        static let detail = NSUserInterfaceItemIdentifier("diff.detail")
    }

    /// 筛选项：nil 表示全部。
    private static let filterCategories: [CaptureDiffEntry.Category?] = [nil] + CaptureDiffEntry.Category.allCases.map { $0 }

    private let store: WorkspaceStore
    private let baselineLabel = NSTextField(labelWithString: "")
    private let setBaselineButton = NSButton()
    private let importBaselineButton = NSButton()
    private let clearBaselineButton = NSButton()
    private let filterControl = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var result: CaptureDiffResult = .empty
    private var visibleEntries: [CaptureDiffEntry] = []
    private var selectedFilterIndex = 0
    private var cancellables = Set<AnyCancellable>()

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bindStore()
        applyLocalization()
        recompute()
    }

    private func buildUI() {
        [setBaselineButton, importBaselineButton, clearBaselineButton].forEach {
            $0.bezelStyle = .rounded
            $0.target = self
        }
        setBaselineButton.action = #selector(handleSetBaseline(_:))
        importBaselineButton.action = #selector(handleImportBaseline(_:))
        clearBaselineButton.action = #selector(handleClearBaseline(_:))

        baselineLabel.textColor = .secondaryLabelColor
        baselineLabel.lineBreakMode = .byTruncatingTail
        baselineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toolbar = NSStackView(views: [setBaselineButton, importBaselineButton, clearBaselineButton, baselineLabel])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8

        filterControl.segmentCount = Self.filterCategories.count
        filterControl.trackingMode = .selectOne
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(handleFilterChange(_:))
        filterControl.segmentStyle = .rounded

        let columns: [(NSUserInterfaceItemIdentifier, CGFloat)] = [
            (Column.category, 120),
            (Column.object, 260),
            (Column.detail, 320)
        ]
        for (identifier, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.width = width
            column.minWidth = 60
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleRowClick(_:))
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor

        view.addSubview(toolbar)
        view.addSubview(filterControl)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        toolbar.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }
        filterControl.snp.makeConstraints { make in
            make.top.equalTo(toolbar.snp.bottom).offset(10)
            make.leading.equalToSuperview().inset(12)
            make.trailing.lessThanOrEqualToSuperview().inset(12)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(filterControl.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview().inset(12)
        }
        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
            make.width.lessThanOrEqualTo(scrollView).offset(-40)
        }
    }

    private func bindStore() {
        Publishers.CombineLatest(
            store.$capture.map { $0?.captureID }.removeDuplicates(),
            store.$diffBaseline.map { $0?.createdAt }.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _ in
            self?.recompute()
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
        setBaselineButton.title = L10n.diffSetBaseline
        importBaselineButton.title = L10n.diffImportBaseline
        clearBaselineButton.title = L10n.diffClearBaseline
        tableView.tableColumn(withIdentifier: Column.category)?.title = L10n.diffColumnCategory
        tableView.tableColumn(withIdentifier: Column.object)?.title = L10n.changesColumnObject
        tableView.tableColumn(withIdentifier: Column.detail)?.title = L10n.diffColumnDetail
        updateHeader()
        tableView.reloadData()
    }

    private func recompute() {
        result = store.makeCaptureDiff() ?? .empty
        applyFilter()
        updateHeader()
    }

    private func applyFilter() {
        let category = Self.filterCategories[selectedFilterIndex]
        visibleEntries = result.entries(in: category)
        tableView.reloadData()
    }

    private func updateHeader() {
        for (index, category) in Self.filterCategories.enumerated() {
            let count = category.map { result.count(of: $0) } ?? result.entries.count
            let title = category.map { L10n.diffCategoryTitle($0) } ?? L10n.diffFilterAll
            filterControl.setLabel("\(title) \(count)", forSegment: index)
            filterControl.setWidth(0, forSegment: index)
        }
        filterControl.selectedSegment = selectedFilterIndex

        if let baseline = store.diffBaseline {
            let dateText = DateFormatter.localizedString(from: baseline.createdAt, dateStyle: .none, timeStyle: .medium)
            baselineLabel.stringValue = L10n.diffBaselineInfo(baseline.name, dateText)
        } else {
            baselineLabel.stringValue = ""
        }
        setBaselineButton.isEnabled = store.capture != nil
        clearBaselineButton.isEnabled = store.diffBaseline != nil

        if store.diffBaseline == nil {
            emptyLabel.stringValue = L10n.diffNoBaseline
        } else if store.capture == nil {
            emptyLabel.stringValue = L10n.diffNoCapture
        } else {
            emptyLabel.stringValue = L10n.diffNoChanges
        }
        emptyLabel.isHidden = visibleEntries.isEmpty == false || (result.entries.isEmpty == false)
    }

    // MARK: - 事件

    @objc private func handleSetBaseline(_ sender: Any?) {
        store.setCurrentCaptureAsDiffBaseline()
    }

    @objc private func handleImportBaseline(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(exportedAs: WorkspaceArchiveCodec.typeIdentifier, conformingTo: .data)]
        guard let window = view.window else {
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                try self?.store.loadDiffBaseline(from: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = L10n.importFailedTitle
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func handleClearBaseline(_ sender: Any?) {
        store.clearDiffBaseline()
    }

    @objc private func handleFilterChange(_ sender: NSSegmentedControl) {
        selectedFilterIndex = max(0, sender.selectedSegment)
        applyFilter()
        updateHeader()
    }

    @objc private func handleRowClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < visibleEntries.count else {
            return
        }
        guard let nodeID = visibleEntries[row].currentNodeID, store.capture?.nodes[nodeID] != nil else {
            NSSound.beep()
            return
        }
        Task {
            await store.revealNode(nodeID)
        }
    }
}

extension CaptureDiffViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, row < visibleEntries.count else {
            return nil
        }
        let entry = visibleEntries[row]
        let text: String
        switch identifier {
        case Column.category:
            text = L10n.diffCategoryTitle(entry.category)
        case Column.object:
            let className = ViewScopeClassNameFormatter.displayName(for: entry.className)
            text = [className, entry.address].compactMap { $0 }.joined(separator: " ")
        case Column.detail:
            text = entry.detail
        default:
            text = ""
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = color(for: entry.category, column: identifier)
        if entry.currentNodeID == nil {
            label.toolTip = L10n.diffNodeMissing
        } else {
            label.toolTip = entry.title
        }
        return label
    }

    private func color(for category: CaptureDiffEntry.Category, column: NSUserInterfaceItemIdentifier) -> NSColor {
        guard column == Column.category else {
            return .labelColor
        }
        switch category {
        case .added:
            return .systemGreen
        case .removed:
            return .systemRed
        case .frameChanged:
            return .systemBlue
        case .visibilityChanged:
            return .systemOrange
        case .classChanged:
            return .systemPurple
        case .reparented:
            return .systemTeal
        }
    }
}
