import AppKit
import Combine
import SnapKit
import ViewScopeServer

@MainActor
final class ViewTreePanelController: NSViewController {
    private let store: WorkspaceStore
    private let panelView = WorkspacePanelContainerView()
    private let searchField = NSSearchField(frame: .zero)
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private var cancellables = Set<AnyCancellable>()
    private var rootItems: [ViewTreeNodeItem] = []
    private var expandedNodeIDs = Set<String>()
    private var currentQuery = ""
    private var isApplyingProgrammaticSelection = false

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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bindStore()
        rebuildTree()
    }

    private func buildUI() {
        panelView.setTitle(L10n.hierarchy)

        searchField.placeholderString = L10n.searchPlaceholder
        searchField.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ViewTreeColumn"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 34
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.focusRingType = .none
        outlineView.indentationPerLevel = 16
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.menu = makeContextMenu()

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = outlineView

        panelView.contentView.addSubview(searchField)
        panelView.contentView.addSubview(scrollView)
        searchField.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(searchField.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    private func bindStore() {
        Publishers.CombineLatest4(store.$capture, store.$selectedNodeID, store.$focusedNodeID, AppLocalization.shared.$language)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.rebuildTree()
            }
            .store(in: &cancellables)
    }

    private func rebuildTree() {
        panelView.setTitle(L10n.hierarchy, subtitle: store.focusedNode?.title)
        rootItems = buildFilteredRoots()
        outlineView.reloadData()
        restoreExpansionState(items: rootItems)
        syncSelectionFromStore()
    }

    private func buildFilteredRoots() -> [ViewTreeNodeItem] {
        guard let capture = store.capture else { return [] }
        let rootNodeIDs = store.focusedNodeID.map { [$0] } ?? capture.rootNodeIDs
        let roots = rootNodeIDs.compactMap { ViewTreeNodeItem.make(nodeID: $0, nodes: capture.nodes) }
        let query = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return roots }
        return roots.compactMap { $0.filtered(matching: query) }
    }

    private func restoreExpansionState(items: [ViewTreeNodeItem]) {
        items.forEach { item in
            if expandedNodeIDs.contains(item.node.id) || item.parent == nil {
                outlineView.expandItem(item)
            }
            restoreExpansionState(items: item.children)
        }
    }

    private func syncSelectionFromStore() {
        guard let selectedNodeID = store.selectedNodeID,
              let item = findItem(nodeID: selectedNodeID, items: rootItems) else {
            outlineView.deselectAll(nil)
            return
        }

        expandAncestors(of: item)
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        isApplyingProgrammaticSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        isApplyingProgrammaticSelection = false
    }

    private func findItem(nodeID: String, items: [ViewTreeNodeItem]) -> ViewTreeNodeItem? {
        for item in items {
            if item.node.id == nodeID {
                return item
            }
            if let child = findItem(nodeID: nodeID, items: item.children) {
                return child
            }
        }
        return nil
    }

    private func expandAncestors(of item: ViewTreeNodeItem) {
        var currentItem = item.parent
        while let current = currentItem {
            outlineView.expandItem(current)
            currentItem = current.parent
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    @objc private func focusSelectedNode(_ sender: Any?) {
        store.focusSelectedNode()
    }

    @objc private func clearFocus(_ sender: Any?) {
        store.clearFocus()
    }

    @objc private func toggleSelectedNodeVisibility(_ sender: Any?) {
        guard let nodeID = selectedMenuItemNodeID else { return }
        Task { await store.toggleVisibility(for: nodeID) }
    }

    @objc private func highlightSelectedNode(_ sender: Any?) {
        Task { await store.highlightCurrentSelection() }
    }

    private var selectedMenuItemNodeID: String? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? ViewTreeNodeItem else {
            return nil
        }
        return item.node.id
    }
}

extension ViewTreePanelController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        currentQuery = searchField.stringValue
        rebuildTree()
    }
}

extension ViewTreePanelController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ViewTreeNodeItem)?.children.count ?? rootItems.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? ViewTreeNodeItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ViewTreeNodeItem)?.children[index] ?? rootItems[index]
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? ViewTreeNodeItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ViewTreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? ViewTreeNodeCellView ?? ViewTreeNodeCellView(frame: .zero)
        cell.identifier = identifier
        cell.delegate = self
        cell.configure(node: item.node)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingProgrammaticSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? ViewTreeNodeItem else {
            Task { await store.selectNode(withID: nil) }
            return
        }
        Task { await store.selectNode(withID: item.node.id) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? ViewTreeNodeItem else { return }
        expandedNodeIDs.insert(item.node.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? ViewTreeNodeItem else { return }
        expandedNodeIDs.remove(item.node.id)
    }
}

extension ViewTreePanelController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let nodeID = selectedMenuItemNodeID,
              let node = store.node(withID: nodeID) else {
            return
        }

        let toggleTitle = node.isHidden ? L10n.hierarchyMenuShowView : L10n.hierarchyMenuHideView
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleSelectedNodeVisibility(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = node.kind == .view
        menu.addItem(toggleItem)

        let focusItem = NSMenuItem(title: L10n.hierarchyMenuFocusSubtree, action: #selector(focusSelectedNode(_:)), keyEquivalent: "")
        focusItem.target = self
        focusItem.isEnabled = true
        menu.addItem(focusItem)

        let clearFocusItem = NSMenuItem(title: L10n.hierarchyMenuClearFocus, action: #selector(clearFocus(_:)), keyEquivalent: "")
        clearFocusItem.target = self
        clearFocusItem.isEnabled = store.focusedNodeID != nil
        menu.addItem(clearFocusItem)

        let highlightItem = NSMenuItem(title: L10n.hierarchyMenuHighlight, action: #selector(highlightSelectedNode(_:)), keyEquivalent: "")
        highlightItem.target = self
        highlightItem.isEnabled = store.selectedNodeID != nil
        menu.addItem(highlightItem)
    }
}

private protocol ViewTreeNodeCellViewDelegate: AnyObject {
    func viewTreeNodeCellViewDidToggleVisibility(_ cell: ViewTreeNodeCellView, nodeID: String)
}

private final class ViewTreeNodeCellView: NSTableCellView {
    weak var delegate: ViewTreeNodeCellViewDelegate?
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let visibilityButton = NSButton()
    private var nodeID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        visibilityButton.bezelStyle = .inline
        visibilityButton.imagePosition = .imageOnly
        visibilityButton.target = self
        visibilityButton.action = #selector(handleVisibilityButton(_:))

        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        addSubview(labels)
        addSubview(visibilityButton)
        labels.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(6)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(visibilityButton.snp.leading).offset(-8)
        }
        visibilityButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(4)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(18)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(node: ViewScopeHierarchyNode) {
        nodeID = node.id
        titleLabel.stringValue = node.title.replacingOccurrences(of: "\n", with: " ")
        subtitleLabel.stringValue = node.className.components(separatedBy: ".").last ?? node.className
        visibilityButton.image = NSImage(systemSymbolName: node.isHidden ? "eye.slash" : "eye", accessibilityDescription: nil)
        visibilityButton.toolTip = node.isHidden ? L10n.hierarchyMenuShowView : L10n.hierarchyMenuHideView
        visibilityButton.isEnabled = node.kind == .view
    }

    @objc private func handleVisibilityButton(_ sender: Any?) {
        guard let nodeID else { return }
        delegate?.viewTreeNodeCellViewDidToggleVisibility(self, nodeID: nodeID)
    }
}

extension ViewTreePanelController: ViewTreeNodeCellViewDelegate {
    fileprivate func viewTreeNodeCellViewDidToggleVisibility(_ cell: ViewTreeNodeCellView, nodeID: String) {
        Task { await store.toggleVisibility(for: nodeID) }
    }
}

private final class ViewTreeNodeItem: NSObject {
    let node: ViewScopeHierarchyNode
    weak var parent: ViewTreeNodeItem?
    let children: [ViewTreeNodeItem]

    init(node: ViewScopeHierarchyNode, children: [ViewTreeNodeItem]) {
        self.node = node
        self.children = children
        super.init()
        self.children.forEach { $0.parent = self }
    }

    static func make(nodeID: String, nodes: [String: ViewScopeHierarchyNode]) -> ViewTreeNodeItem? {
        guard let node = nodes[nodeID] else { return nil }
        let children = node.childIDs.compactMap { make(nodeID: $0, nodes: nodes) }
        return ViewTreeNodeItem(node: node, children: children)
    }

    func filtered(matching query: String) -> ViewTreeNodeItem? {
        let filteredChildren = children.compactMap { $0.filtered(matching: query) }
        if matches(query) || !filteredChildren.isEmpty {
            return ViewTreeNodeItem(node: node, children: filteredChildren)
        }
        return nil
    }

    private func matches(_ query: String) -> Bool {
        [node.title, node.className, node.identifier ?? "", node.address ?? ""]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
    }
}
