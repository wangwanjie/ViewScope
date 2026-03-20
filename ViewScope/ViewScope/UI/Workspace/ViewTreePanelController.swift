import AppKit
import Combine
import Foundation
import SnapKit
import ViewScopeServer

@MainActor
final class ViewTreePanelController: NSViewController {
    private let store: WorkspaceStore
    private let panelView = WorkspacePanelContainerView()
    private let searchField = NSSearchField(frame: .zero)
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let emptyStateView = WorkspaceEmptyStateView()
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
        panelView.setAccessibilityElement(true)
        panelView.setAccessibilityRole(.group)
        panelView.setAccessibilityIdentifier("workspace.treePanel")
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
        outlineView.rowHeight = ViewTreeLayoutMetrics.rowHeight
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
        panelView.contentView.addSubview(emptyStateView)
        searchField.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(searchField.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview()
        }
        emptyStateView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
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
        updateEmptyState()
        outlineView.reloadData()
        restoreExpansionState(items: rootItems)
        syncSelectionFromStore()
    }

    private func updateEmptyState() {
        let isDisconnected = store.capture == nil
        emptyStateView.isHidden = !isDisconnected
        searchField.isHidden = isDisconnected
        scrollView.isHidden = isDisconnected
        guard isDisconnected else { return }

        emptyStateView.configure(
            .init(
                symbolName: "square.stack.3d.up.slash",
                title: L10n.hierarchyEmptyTitle,
                message: L10n.previewDisconnectedPlaceholder,
                actionTitle: nil,
                action: nil
            )
        )
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

    @objc private func refreshCapture(_ sender: Any?) {
        Task { await store.refreshCapture(forceReloadSelectionDetail: true, clearingVisibleState: true) }
    }

    @objc private func copySelectedNodeTitle(_ sender: Any?) {
        copyToPasteboard(selectedMenuItem?.node.title)
    }

    @objc private func copySelectedNodeClassName(_ sender: Any?) {
        copyToPasteboard(selectedMenuItem.map { ViewScopeClassNameFormatter.displayName(for: $0.node.className) })
    }

    @objc private func copySelectedNodeIvarNames(_ sender: Any?) {
        copyToPasteboard(selectedMenuItem.flatMap { ViewTreeNodePresentation.ivarText(for: $0.node) })
    }

    @objc private func copySelectedNodeIdentifier(_ sender: Any?) {
        copyToPasteboard(selectedMenuItem?.node.identifier)
    }

    @objc private func copySelectedNodeAddress(_ sender: Any?) {
        copyToPasteboard(selectedMenuItem?.node.address)
    }

    @objc private func copySelectedNodeID(_ sender: Any?) {
        copyToPasteboard(selectedMenuItem?.node.id)
    }

    @objc private func expandSelectedNodeChildren(_ sender: Any?) {
        guard let item = selectedMenuItem else { return }
        expandRecursively(item)
    }

    @objc private func collapseSelectedNodeChildren(_ sender: Any?) {
        guard let item = selectedMenuItem else { return }
        collapseDescendants(of: item)
    }

    private var selectedMenuItemNodeID: String? {
        selectedMenuItem?.node.id
    }

    private var selectedMenuItem: ViewTreeNodeItem? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? ViewTreeNodeItem
    }

    private func copyToPasteboard(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func expandRecursively(_ item: ViewTreeNodeItem) {
        outlineView.expandItem(item)
        expandedNodeIDs.insert(item.node.id)
        item.children.forEach { expandRecursively($0) }
    }

    private func collapseDescendants(of item: ViewTreeNodeItem) {
        item.children.forEach {
            collapseDescendants(of: $0)
            outlineView.collapseItem($0)
            expandedNodeIDs.remove($0.node.id)
        }
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
        cell.configure(node: item.node, isEffectivelyHidden: item.isEffectivelyHidden)
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

        let refreshItem = NSMenuItem(title: L10n.hierarchyMenuRefresh, action: #selector(refreshCapture(_:)), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = store.capture != nil
        menu.addItem(refreshItem)

        var copyItems: [NSMenuItem] = []

        if !node.title.isEmpty {
            let copyTitleItem = NSMenuItem(title: L10n.hierarchyMenuCopyTitle, action: #selector(copySelectedNodeTitle(_:)), keyEquivalent: "")
            copyTitleItem.target = self
            copyItems.append(copyTitleItem)
        }

        let copyClassNameItem = NSMenuItem(title: L10n.hierarchyMenuCopyClassName, action: #selector(copySelectedNodeClassName(_:)), keyEquivalent: "")
        copyClassNameItem.target = self
        copyItems.append(copyClassNameItem)

        if ViewTreeNodePresentation.ivarText(for: node) != nil {
            let copyIvarNameItem = NSMenuItem(title: L10n.hierarchyMenuCopyIvarName, action: #selector(copySelectedNodeIvarNames(_:)), keyEquivalent: "")
            copyIvarNameItem.target = self
            copyItems.append(copyIvarNameItem)
        }

        let copyNodeIDItem = NSMenuItem(title: L10n.hierarchyMenuCopyNodeID, action: #selector(copySelectedNodeID(_:)), keyEquivalent: "")
        copyNodeIDItem.target = self
        copyItems.append(copyNodeIDItem)

        if let identifier = node.identifier, !identifier.isEmpty {
            let copyIdentifierItem = NSMenuItem(title: L10n.hierarchyMenuCopyIdentifier, action: #selector(copySelectedNodeIdentifier(_:)), keyEquivalent: "")
            copyIdentifierItem.target = self
            copyItems.append(copyIdentifierItem)
        }

        if let address = node.address, !address.isEmpty {
            let copyAddressItem = NSMenuItem(title: L10n.hierarchyMenuCopyAddress, action: #selector(copySelectedNodeAddress(_:)), keyEquivalent: "")
            copyAddressItem.target = self
            copyItems.append(copyAddressItem)
        }

        if !copyItems.isEmpty {
            menu.addItem(.separator())
            copyItems.forEach(menu.addItem)
        }

        if !node.childIDs.isEmpty {
            menu.addItem(.separator())

            let expandChildrenItem = NSMenuItem(title: L10n.hierarchyMenuExpandChildren, action: #selector(expandSelectedNodeChildren(_:)), keyEquivalent: "")
            expandChildrenItem.target = self
            menu.addItem(expandChildrenItem)

            let collapseChildrenItem = NSMenuItem(title: L10n.hierarchyMenuCollapseChildren, action: #selector(collapseSelectedNodeChildren(_:)), keyEquivalent: "")
            collapseChildrenItem.target = self
            menu.addItem(collapseChildrenItem)
        }
    }
}

private protocol ViewTreeNodeCellViewDelegate: AnyObject {
    func viewTreeNodeCellViewDidToggleVisibility(_ cell: ViewTreeNodeCellView, nodeID: String)
}

enum ViewTreeNodePresentation {
    static func classText(for node: ViewScopeHierarchyNode) -> String {
        ViewScopeClassNameFormatter.displayName(for: node.className)
    }

    static func ivarText(for node: ViewScopeHierarchyNode) -> String? {
        let traces = node.ivarTraces
        if !traces.isEmpty {
            let names = traces.map(\.ivarName)
            let joined = names.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }

        guard let ivarName = sanitized(node.ivarName) else { return nil }
        return ivarName
    }

    static func matches(node: ViewScopeHierarchyNode, query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return true }
        return searchableText(for: node).contains(normalizedQuery)
    }

    private static func searchableText(for node: ViewScopeHierarchyNode) -> String {
        [
            node.title,
            node.className,
            classText(for: node),
            node.ivarTraces.map(\.ivarName).joined(separator: " "),
            node.ivarName ?? "",
            node.identifier ?? "",
            node.address ?? ""
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ViewTreeLayoutMetrics {
    static let rowHeight: CGFloat = 30
    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 4
    static let trailingSpacing: CGFloat = 8
}

private final class ViewTreeNodeCellView: NSTableCellView {
    weak var delegate: ViewTreeNodeCellViewDelegate?
    private let classLabel = NSTextField(labelWithString: "")
    private let ivarLabel = NSTextField(labelWithString: "")
    private let visibilityButton = NSButton()
    private var nodeID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        classLabel.font = NSFont.systemFont(ofSize: 12)
        classLabel.lineBreakMode = .byTruncatingTail
        classLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        ivarLabel.font = NSFont.systemFont(ofSize: 11)
        ivarLabel.textColor = .secondaryLabelColor
        ivarLabel.alignment = .right
        ivarLabel.lineBreakMode = .byTruncatingHead
        ivarLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        visibilityButton.bezelStyle = .inline
        visibilityButton.imagePosition = .imageOnly
        visibilityButton.target = self
        visibilityButton.action = #selector(handleVisibilityButton(_:))

        addSubview(classLabel)
        addSubview(ivarLabel)
        addSubview(visibilityButton)

        classLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(ViewTreeLayoutMetrics.horizontalInset)
            make.centerY.equalToSuperview()
            make.top.greaterThanOrEqualToSuperview().inset(ViewTreeLayoutMetrics.verticalInset)
            make.bottom.lessThanOrEqualToSuperview().inset(ViewTreeLayoutMetrics.verticalInset)
            make.trailing.lessThanOrEqualTo(ivarLabel.snp.leading).offset(-ViewTreeLayoutMetrics.trailingSpacing)
        }
        ivarLabel.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.greaterThanOrEqualTo(classLabel.snp.trailing).offset(ViewTreeLayoutMetrics.trailingSpacing)
            make.trailing.equalTo(visibilityButton.snp.leading).offset(-ViewTreeLayoutMetrics.trailingSpacing)
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

    func configure(node: ViewScopeHierarchyNode, isEffectivelyHidden: Bool) {
        nodeID = node.id
        classLabel.stringValue = ViewTreeNodePresentation.classText(for: node)
        let ivarText = ViewTreeNodePresentation.ivarText(for: node)
        ivarLabel.isHidden = ivarText == nil
        ivarLabel.stringValue = ivarText ?? ""
        let alphaComponent: CGFloat = isEffectivelyHidden ? 0.45 : 1
        classLabel.textColor = .labelColor.withAlphaComponent(alphaComponent)
        ivarLabel.textColor = .secondaryLabelColor.withAlphaComponent(alphaComponent)
        visibilityButton.image = NSImage(systemSymbolName: node.isHidden ? "eye.slash" : "eye", accessibilityDescription: nil)
        visibilityButton.toolTip = node.isHidden ? L10n.hierarchyMenuShowView : L10n.hierarchyMenuHideView
        visibilityButton.isEnabled = node.kind == .view
        visibilityButton.contentTintColor = .secondaryLabelColor.withAlphaComponent(alphaComponent)
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

final class ViewTreeNodeItem: NSObject {
    let node: ViewScopeHierarchyNode
    weak var parent: ViewTreeNodeItem?
    let children: [ViewTreeNodeItem]
    var isEffectivelyHidden: Bool {
        node.isHidden || parent?.isEffectivelyHidden == true
    }

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
        ViewTreeNodePresentation.matches(node: node, query: query)
    }
}
