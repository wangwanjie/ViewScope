import AppKit
import Combine
import Foundation
import SnapKit
import ViewScopeServer

@MainActor
final class ViewTreePanelController: NSViewController {
    /// 搜索输入防抖时长（秒）。
    private static let searchDebounceInterval: TimeInterval = 0.15
    /// 方向键切换选中时，节点详情请求的防抖时长（秒）。
    private static let keyboardSelectionDebounceInterval: TimeInterval = 0.12

    private let store: WorkspaceStore
    private let presentationBuilder = ViewTreePresentationBuilder()
    private let selectionSynchronizer = ViewTreeSelectionSynchronizer()
    private let panelView = WorkspacePanelContainerView()
    private let searchField = NSSearchField(frame: .zero)
    private let searchMatchLabel = NSTextField(labelWithString: "")
    private let previousMatchButton = NSButton()
    private let nextMatchButton = NSButton()
    private let wrapperToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let issuesOnlyToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let outlineView = ViewTreeOutlineView()
    private let emptyStateView = WorkspaceEmptyStateView()
    private var cancellables = Set<AnyCancellable>()
    private var rootItems: [ViewTreeNodeItem] = []
    private var itemsByNodeID: [String: ViewTreeNodeItem] = [:]
    private var currentQuery = ""
    /// 当前搜索命中的节点（先序顺序），用于“上一个 / 下一个”。
    private var searchMatchNodeIDs: [String] = []
    private var currentMatchIndex: Int?
    private var searchDebounceTimer: Timer?
    private var keyboardSelectionTimer: Timer?
    private var isExpansionSyncScheduled = false
    private var lastFocusedNodeID: String?
    private var diagnosticsReport = LayoutDiagnosticsReport.empty
    /// rebuild 期间置 true，忽略 NSOutlineView 回调避免级联循环。
    private var isBatchUpdating = false

    /// 是否处于过滤模式（搜索或只看问题节点）：此时展开状态由过滤结果决定，不与 store 同步。
    private var isFiltering: Bool {
        normalizedQuery.isEmpty == false || store.inspectionTools.showsOnlyIssueNodes
    }

    private var normalizedQuery: String {
        currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

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
        searchField.sendsSearchStringImmediately = true

        searchMatchLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        searchMatchLabel.textColor = .secondaryLabelColor
        searchMatchLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        configureMatchButton(previousMatchButton, symbolName: "chevron.up", toolTip: L10n.previewToolsSearchPrevious, action: #selector(selectPreviousMatch(_:)))
        configureMatchButton(nextMatchButton, symbolName: "chevron.down", toolTip: L10n.previewToolsSearchNext, action: #selector(selectNextMatch(_:)))

        wrapperToggle.title = L10n.hierarchyShowSystemWrappers
        wrapperToggle.state = store.showsSystemWrapperViews ? .on : .off
        wrapperToggle.target = self
        wrapperToggle.action = #selector(handleWrapperToggle(_:))
        wrapperToggle.font = NSFont.systemFont(ofSize: 11)

        issuesOnlyToggle.title = L10n.previewToolsTreeOnlyIssues
        issuesOnlyToggle.state = store.inspectionTools.showsOnlyIssueNodes ? .on : .off
        issuesOnlyToggle.target = self
        issuesOnlyToggle.action = #selector(handleIssuesOnlyToggle(_:))
        issuesOnlyToggle.font = NSFont.systemFont(ofSize: 11)

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
        outlineView.onHoverRowChanged = { [weak self] row in
            self?.handleHoverRowChanged(row)
        }
        outlineView.onFindRequested = { [weak self] in
            self?.focusSearchField()
        }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = outlineView

        let togglesStack = NSStackView(views: [wrapperToggle, issuesOnlyToggle])
        togglesStack.orientation = .horizontal
        togglesStack.spacing = 12
        togglesStack.alignment = .centerY

        panelView.contentView.addSubview(searchField)
        panelView.contentView.addSubview(searchMatchLabel)
        panelView.contentView.addSubview(previousMatchButton)
        panelView.contentView.addSubview(nextMatchButton)
        panelView.contentView.addSubview(togglesStack)
        panelView.contentView.addSubview(scrollView)
        panelView.contentView.addSubview(emptyStateView)
        searchField.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(12)
        }
        searchMatchLabel.snp.makeConstraints { make in
            make.centerY.equalTo(searchField)
            make.leading.equalTo(searchField.snp.trailing).offset(6)
        }
        previousMatchButton.snp.makeConstraints { make in
            make.centerY.equalTo(searchField)
            make.leading.equalTo(searchMatchLabel.snp.trailing).offset(4)
            make.width.height.equalTo(20)
        }
        nextMatchButton.snp.makeConstraints { make in
            make.centerY.equalTo(searchField)
            make.leading.equalTo(previousMatchButton.snp.trailing).offset(2)
            make.trailing.equalToSuperview().inset(12)
            make.width.height.equalTo(20)
        }
        togglesStack.snp.makeConstraints { make in
            make.top.equalTo(searchField.snp.bottom).offset(6)
            make.leading.equalToSuperview().inset(12)
            make.trailing.lessThanOrEqualToSuperview().inset(12)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(togglesStack.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview()
        }
        emptyStateView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        updateSearchMatchControls()
    }

    private func configureMatchButton(_ button: NSButton, symbolName: String, toolTip: String, action: Selector) {
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.target = self
        button.action = action
    }

    private func bindStore() {
        // 树结构变化（capture / focusedNodeID / language）→ 完整重建
        Publishers.CombineLatest3(store.$capture, store.$focusedNodeID, AppLocalization.shared.$language)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.rebuildTree()
            }
            .store(in: &cancellables)

        // 选中变化 → 只同步选中行，不重建树
        store.$selectedNodeID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isBatchUpdating else {
                    return
                }
                self.syncSelectionFromStore()
            }
            .store(in: &cancellables)

        // 展开状态由 store 统一维护（包括折叠时清除的后代展开态），树只负责跟随。
        store.$expandedNodeIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleExpansionSync()
            }
            .store(in: &cancellables)

        let tools = store.inspectionTools
        tools.$hoveredNodeID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] nodeID in
                self?.applyHoverHighlight(nodeID)
            }
            .store(in: &cancellables)

        tools.$showsOnlyIssueNodes
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] showsOnlyIssueNodes in
                self?.issuesOnlyToggle.state = showsOnlyIssueNodes ? .on : .off
                self?.rebuildTree()
            }
            .store(in: &cancellables)

        tools.$showsDiagnostics
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadVisibleCells()
            }
            .store(in: &cancellables)

        tools.searchFocusRequests
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.focusSearchField()
            }
            .store(in: &cancellables)
    }

    // MARK: - 重建

    private func rebuildTree() {
        isBatchUpdating = true
        defer {
            isBatchUpdating = false
        }

        panelView.setTitle(L10n.hierarchy, subtitle: store.focusedNode?.title)
        wrapperToggle.state = store.showsSystemWrapperViews ? .on : .off
        diagnosticsReport = store.inspectionTools.diagnosticsReport(for: store.capture)
        ensureFocusedRootExpandedInStore()

        let query = normalizedQuery
        let showsOnlyIssues = store.inspectionTools.showsOnlyIssueNodes
        let report = diagnosticsReport
        let nodeFilter: ((ViewScopeHierarchyNode) -> Bool)?
        if showsOnlyIssues {
            nodeFilter = { node in
                report.issuesByNodeID[node.id]?.isEmpty == false
            }
        } else {
            nodeFilter = nil
        }
        rootItems = presentationBuilder.buildRoots(
            capture: store.capture,
            focusedNodeID: store.focusedNodeID,
            showsSystemWrappers: store.showsSystemWrapperViews,
            query: query,
            nodeFilter: nodeFilter
        )
        rebuildItemIndex()
        updateEmptyState()

        // 保留滚动位置：刷新 capture（稳定节点 ID）后用户不会被跳回顶部。
        let savedScrollOrigin = scrollView.contentView.bounds.origin
        outlineView.resetHoverTracking()
        selectionSynchronizer.withProgrammaticSelection {
            outlineView.reloadData()
            if isFiltering {
                expandFilterPaths(items: rootItems)
            } else {
                restoreExpansionState(items: rootItems)
            }
        }
        scrollView.contentView.scroll(to: savedScrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        searchMatchNodeIDs = query.isEmpty ? [] : collectMatchNodeIDs(items: rootItems)
        if let currentMatchIndex, currentMatchIndex >= searchMatchNodeIDs.count {
            self.currentMatchIndex = nil
        }
        updateSearchMatchControls()
        syncSelectionFromStore()
        applyHoverHighlight(store.inspectionTools.hoveredNodeID)
    }

    private func rebuildItemIndex() {
        var index: [String: ViewTreeNodeItem] = [:]
        var stack = rootItems
        while let item = stack.popLast() {
            index[item.node.id] = item
            stack.append(contentsOf: item.children)
        }
        itemsByNodeID = index
    }

    /// 聚焦子树时树根被强制展开；同步告诉 store，让预览里的子节点也分层显示。
    private func ensureFocusedRootExpandedInStore() {
        let focusedNodeID = store.focusedNodeID
        defer {
            lastFocusedNodeID = focusedNodeID
        }
        guard let focusedNodeID,
              focusedNodeID != lastFocusedNodeID,
              store.isNodeExpanded(focusedNodeID) == false,
              store.node(withID: focusedNodeID)?.childIDs.isEmpty == false else {
            return
        }
        store.setNodeExpanded(focusedNodeID, isExpanded: true)
    }

    private func updateEmptyState() {
        let isDisconnected = store.capture == nil
        emptyStateView.isHidden = !isDisconnected
        searchField.isHidden = isDisconnected
        searchMatchLabel.isHidden = isDisconnected
        previousMatchButton.isHidden = isDisconnected
        nextMatchButton.isHidden = isDisconnected
        wrapperToggle.isHidden = isDisconnected
        issuesOnlyToggle.isHidden = isDisconnected
        scrollView.isHidden = isDisconnected
        guard isDisconnected else {
            return
        }

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

    private func restoreExpansionState(items: [ViewTreeNodeItem]) {
        items.forEach { item in
            if store.isNodeExpanded(item.node.id) || item.parent == nil {
                outlineView.expandItem(item)
            }
            restoreExpansionState(items: item.children)
        }
    }

    /// 过滤模式下展开所有“通往命中节点”的路径，命中节点本身保持折叠（其完整子树仍可手动展开）。
    private func expandFilterPaths(items: [ViewTreeNodeItem]) {
        for item in items where item.isOnFilterPath {
            outlineView.expandItem(item)
            expandFilterPaths(items: item.children)
        }
    }

    private func collectMatchNodeIDs(items: [ViewTreeNodeItem]) -> [String] {
        var result: [String] = []
        var stack = Array(items.reversed())
        while let item = stack.popLast() {
            if item.isFilterMatch {
                result.append(item.node.id)
            }
            stack.append(contentsOf: item.children.reversed())
        }
        return result
    }

    // MARK: - 展开状态同步

    private func scheduleExpansionSync() {
        guard isExpansionSyncScheduled == false else {
            return
        }
        isExpansionSyncScheduled = true
        MainRunLoopScheduler.perform { [weak self] in
            guard let self else {
                return
            }
            self.isExpansionSyncScheduled = false
            self.syncExpansionFromStore()
        }
    }

    /// 让 NSOutlineView 的展开态与 store 完全一致：折叠时连同后代一起折叠，避免再次展开时孙节点“自动复原”。
    private func syncExpansionFromStore() {
        guard isFiltering == false, rootItems.isEmpty == false else {
            return
        }
        isBatchUpdating = true
        defer {
            isBatchUpdating = false
        }
        selectionSynchronizer.withProgrammaticSelection {
            var stack = rootItems
            while let item = stack.popLast() {
                let shouldExpand = item.parent == nil || store.isNodeExpanded(item.node.id)
                let isExpanded = outlineView.isItemExpanded(item)
                if shouldExpand {
                    if isExpanded == false {
                        outlineView.expandItem(item)
                    }
                    stack.append(contentsOf: item.children)
                } else if isExpanded {
                    outlineView.collapseItem(item, collapseChildren: true)
                }
            }
        }
        syncSelectionFromStore()
    }

    // MARK: - 选中同步

    private func syncSelectionFromStore() {
        selectionSynchronizer.syncSelection(
            selectedNodeID: store.selectedNodeID,
            item: store.selectedNodeID.flatMap { itemsByNodeID[$0] },
            outlineView: outlineView
        ) { [weak self] item in
            self?.revealItem(item)
        }
    }

    /// 让某个节点在树中可见：store 原子地展开全部祖先，界面上逐级展开（不再回写 store）。
    private func revealItem(_ item: ViewTreeNodeItem) {
        var ancestors: [ViewTreeNodeItem] = []
        var currentItem = item.parent
        while let current = currentItem {
            ancestors.append(current)
            currentItem = current.parent
        }
        // 只有确实存在未展开的祖先时才写 store，避免无意义地重复发布 expandedNodeIDs。
        let hasCollapsedAncestor = ancestors.contains { $0.parent != nil && store.isNodeExpanded($0.node.id) == false }
        if isFiltering == false, hasCollapsedAncestor {
            store.expandAncestors(of: item.node.id)
        }
        let wasBatchUpdating = isBatchUpdating
        isBatchUpdating = true
        for ancestor in ancestors.reversed() where outlineView.isItemExpanded(ancestor) == false {
            outlineView.expandItem(ancestor)
        }
        isBatchUpdating = wasBatchUpdating
    }

    // MARK: - 悬停

    private func handleHoverRowChanged(_ row: Int) {
        guard row >= 0, let item = outlineView.item(atRow: row) as? ViewTreeNodeItem else {
            store.inspectionTools.clearHover()
            return
        }
        store.inspectionTools.setHoveredNodeIDCoalesced(item.node.id)
    }

    private func applyHoverHighlight(_ hoveredNodeID: String?) {
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? ViewTreeRowView else {
                return
            }
            let item = self.outlineView.item(atRow: row) as? ViewTreeNodeItem
            rowView.isHovered = hoveredNodeID != nil && item?.node.id == hoveredNodeID
        }
    }

    private func reloadVisibleCells() {
        let visibleRows = outlineView.rows(in: outlineView.visibleRect)
        guard visibleRows.length > 0 else {
            return
        }
        outlineView.reloadData(
            forRowIndexes: IndexSet(integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length)),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    // MARK: - 搜索

    private func focusSearchField() {
        guard searchField.isHidden == false else {
            return
        }
        view.window?.makeFirstResponder(searchField)
    }

    private func scheduleSearch(_ query: String) {
        searchDebounceTimer?.invalidate()
        searchDebounceTimer = MainRunLoopScheduler.schedule(after: Self.searchDebounceInterval) { [weak self] in
            self?.applySearch(query)
        }
    }

    private func applySearch(_ query: String) {
        guard query != currentQuery else {
            return
        }
        currentQuery = query
        currentMatchIndex = nil
        rebuildTree()
        // 搜索结果第一条自动滚动到可见区域，但不改变选中。
        if let firstMatch = searchMatchNodeIDs.first,
           let item = itemsByNodeID[firstMatch] {
            let row = outlineView.row(forItem: item)
            if row >= 0 {
                outlineView.scrollRowToVisible(row)
            }
        }
    }

    private func updateSearchMatchControls() {
        let hasQuery = normalizedQuery.isEmpty == false
        searchMatchLabel.isHidden = hasQuery == false || store.capture == nil
        previousMatchButton.isEnabled = searchMatchNodeIDs.isEmpty == false
        nextMatchButton.isEnabled = searchMatchNodeIDs.isEmpty == false
        guard hasQuery else {
            searchMatchLabel.stringValue = ""
            return
        }
        if searchMatchNodeIDs.isEmpty {
            searchMatchLabel.stringValue = L10n.previewToolsSearchNoMatch
        } else {
            searchMatchLabel.stringValue = L10n.previewToolsSearchMatchCount(
                current: (currentMatchIndex ?? -1) + 1,
                total: searchMatchNodeIDs.count
            )
        }
    }

    @objc private func selectNextMatch(_ sender: Any?) {
        moveToMatch(offset: 1)
    }

    @objc private func selectPreviousMatch(_ sender: Any?) {
        moveToMatch(offset: -1)
    }

    private func moveToMatch(offset: Int) {
        guard searchMatchNodeIDs.isEmpty == false else {
            return
        }
        let count = searchMatchNodeIDs.count
        let nextIndex: Int
        if let currentMatchIndex {
            nextIndex = ((currentMatchIndex + offset) % count + count) % count
        } else {
            nextIndex = offset >= 0 ? 0 : count - 1
        }
        currentMatchIndex = nextIndex
        updateSearchMatchControls()
        let nodeID = searchMatchNodeIDs[nextIndex]
        Task { @MainActor [weak self] in
            await self?.store.selectNode(withID: nodeID)
        }
    }

    // MARK: - 右键菜单

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// 菜单作用的节点：右键点中的行优先，否则为当前选中行。所有菜单项都作用于同一个节点。
    private var menuTargetItem: ViewTreeNodeItem? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else {
            return nil
        }
        return outlineView.item(atRow: row) as? ViewTreeNodeItem
    }

    @objc private func focusMenuTargetNode(_ sender: Any?) {
        guard let nodeID = menuTargetItem?.node.id else {
            return
        }
        store.setFocusedNode(nodeID)
    }

    @objc private func clearFocus(_ sender: Any?) {
        store.clearFocus()
    }

    @objc private func toggleMenuTargetVisibility(_ sender: Any?) {
        guard let nodeID = menuTargetItem?.node.id else {
            return
        }
        Task {
            await store.toggleVisibility(for: nodeID)
        }
    }

    /// 高亮右键点中的节点：先选中它（不重复闪烁），再在宿主中高亮。
    @objc private func highlightMenuTargetNode(_ sender: Any?) {
        guard let nodeID = menuTargetItem?.node.id else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if self.store.selectedNodeID != nodeID {
                await self.store.selectNode(withID: nodeID, highlightInHost: false)
            }
            await self.store.highlightCurrentSelection()
        }
    }

    /// 手动刷新保留展开状态与滚动位置（节点 ID 跨抓取稳定）。
    @objc private func refreshCapture(_ sender: Any?) {
        Task {
            await store.refreshCapture(forceReloadSelectionDetail: true, clearingVisibleState: false)
        }
    }

    @objc private func handleWrapperToggle(_ sender: Any?) {
        store.setShowsSystemWrapperViews(wrapperToggle.state == .on)
    }

    @objc private func handleIssuesOnlyToggle(_ sender: Any?) {
        store.inspectionTools.showsOnlyIssueNodes = issuesOnlyToggle.state == .on
    }

    @objc private func copySelectedNodeTitle(_ sender: Any?) {
        copyToPasteboard(menuTargetItem?.node.title)
    }

    @objc private func copySelectedNodeClassName(_ sender: Any?) {
        copyToPasteboard(menuTargetItem.map { ViewScopeClassNameFormatter.displayName(for: $0.node.className) })
    }

    @objc private func copySelectedNodeControllerClassName(_ sender: Any?) {
        copyToPasteboard(menuTargetItem.flatMap { ViewTreeNodePresentation.controllerClassNameText(for: $0.node) })
    }

    @objc private func copySelectedNodeIvarNames(_ sender: Any?) {
        copyToPasteboard(menuTargetItem.flatMap { ViewTreeNodePresentation.ivarText(for: $0.node) })
    }

    @objc private func copySelectedNodeIdentifier(_ sender: Any?) {
        copyToPasteboard(menuTargetItem?.node.identifier)
    }

    @objc private func copySelectedNodeAddress(_ sender: Any?) {
        copyToPasteboard(menuTargetItem?.node.address)
    }

    @objc private func copySelectedNodeID(_ sender: Any?) {
        copyToPasteboard(menuTargetItem?.node.id)
    }

    @objc private func expandMenuTargetChildren(_ sender: Any?) {
        guard let item = menuTargetItem else {
            return
        }
        expandRecursively(item)
    }

    @objc private func collapseMenuTargetChildren(_ sender: Any?) {
        guard let item = menuTargetItem else {
            return
        }
        collapseDescendants(of: item)
    }

    private func copyToPasteboard(_ value: String?) {
        guard let value, !value.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// 递归展开：界面上一次性展开整棵子树；store 只对子树的叶子调用原子的 `expandAncestors`，
    /// 叶子的祖先链覆盖了子树里所有需要展开的节点，总代价 O(叶子数 × 深度)。
    private func expandRecursively(_ item: ViewTreeNodeItem) {
        isBatchUpdating = true
        selectionSynchronizer.withProgrammaticSelection {
            outlineView.expandItem(item, expandChildren: true)
        }
        isBatchUpdating = false

        guard isFiltering == false else {
            return
        }
        var stack = [item]
        var leafNodeIDs: [String] = []
        while let current = stack.popLast() {
            if current.children.isEmpty {
                leafNodeIDs.append(current.node.id)
            } else {
                stack.append(contentsOf: current.children)
            }
        }
        if leafNodeIDs.isEmpty {
            store.setNodeExpanded(item.node.id, isExpanded: true)
            return
        }
        // 一次性批量展开所有叶子的祖先，只发布一次展开状态
        store.expandNodes(leafNodeIDs.compactMap { leafNodeID in
            store.capture?.nodes[leafNodeID]?.parentID
        })
    }

    /// 折叠所有直接子节点（store 会连同它们的后代展开态一起清除）。
    private func collapseDescendants(of item: ViewTreeNodeItem) {
        isBatchUpdating = true
        selectionSynchronizer.withProgrammaticSelection {
            for child in item.children where child.children.isEmpty == false {
                outlineView.collapseItem(child, collapseChildren: true)
            }
        }
        isBatchUpdating = false

        guard isFiltering == false else {
            return
        }
        for child in item.children where child.children.isEmpty == false {
            store.setNodeExpanded(child.node.id, isExpanded: false)
        }
    }
}

extension ViewTreePanelController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch(searchField.stringValue)
    }

    /// 回车跳到下一个匹配（Shift+回车跳到上一个）。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        // 先立即应用尚在防抖中的查询，保证跳转基于最新结果。
        searchDebounceTimer?.invalidate()
        applySearch(searchField.stringValue)
        let isShiftPressed = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        moveToMatch(offset: isShiftPressed ? -1 : 1)
        return true
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

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = ViewTreeRowView()
        if let item = item as? ViewTreeNodeItem {
            rowView.isHovered = item.node.id == store.inspectionTools.hoveredNodeID
        }
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? ViewTreeNodeItem else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("ViewTreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? ViewTreeNodeCellView ?? ViewTreeNodeCellView(frame: .zero)
        cell.identifier = identifier
        let showsDiagnostics = store.inspectionTools.showsDiagnostics
        cell.configure(
            node: item.node,
            isEffectivelyHidden: item.isEffectivelyHidden,
            issueSeverity: showsDiagnostics ? diagnosticsReport.maximumSeverity(for: item.node.id) : nil,
            issueToolTip: showsDiagnostics ? diagnosticsReport.tooltip(for: item.node.id) : nil,
            isSearchMatch: item.isFilterMatch && normalizedQuery.isEmpty == false
        )
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isBatchUpdating else {
            return
        }
        switch selectionSynchronizer.userSelectionChange(
            selectedRow: outlineView.selectedRow,
            itemAtRow: { row in
                outlineView.item(atRow: row)
            }
        ) {
        case .ignored:
            return
        case .update(let nodeID):
            keyboardSelectionTimer?.invalidate()
            // 方向键连续切换时防抖，只为最终停留的节点请求详情并在宿主中高亮。
            if NSApp.currentEvent?.type == .keyDown {
                keyboardSelectionTimer = MainRunLoopScheduler.schedule(after: Self.keyboardSelectionDebounceInterval) { [weak self] in
                    guard let self else {
                        return
                    }
                    Task {
                        await self.store.selectNode(withID: nodeID)
                    }
                }
            } else {
                Task {
                    await store.selectNode(withID: nodeID)
                }
            }
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isBatchUpdating, isFiltering == false else {
            return
        }
        guard let item = notification.userInfo?["NSObject"] as? ViewTreeNodeItem else {
            return
        }
        store.setNodeExpanded(item.node.id, isExpanded: true)
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        // NSOutlineView 收起节点时，如果被选中的行是其后代，
        // 会在 didCollapse 之前触发 outlineViewSelectionDidChange。
        // 提前标记，防止该回调被当成用户操作写回 store。
        selectionSynchronizer.beginProgrammaticSelection()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        selectionSynchronizer.endProgrammaticSelection()
        guard !isBatchUpdating, isFiltering == false else {
            return
        }
        guard let item = notification.userInfo?["NSObject"] as? ViewTreeNodeItem else {
            return
        }
        store.setNodeExpanded(item.node.id, isExpanded: false)
    }
}

extension ViewTreePanelController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let targetItem = menuTargetItem else {
            return
        }
        let node = targetItem.node

        let toggleTitle = node.isHidden ? L10n.hierarchyMenuShowView : L10n.hierarchyMenuHideView
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleMenuTargetVisibility(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = node.kind != .window
        menu.addItem(toggleItem)

        let focusItem = NSMenuItem(title: L10n.hierarchyMenuFocusSubtree, action: #selector(focusMenuTargetNode(_:)), keyEquivalent: "")
        focusItem.target = self
        focusItem.isEnabled = true
        menu.addItem(focusItem)

        let clearFocusItem = NSMenuItem(title: L10n.hierarchyMenuClearFocus, action: #selector(clearFocus(_:)), keyEquivalent: "")
        clearFocusItem.target = self
        clearFocusItem.isEnabled = store.focusedNodeID != nil
        menu.addItem(clearFocusItem)

        let highlightItem = NSMenuItem(title: L10n.hierarchyMenuHighlight, action: #selector(highlightMenuTargetNode(_:)), keyEquivalent: "")
        highlightItem.target = self
        highlightItem.isEnabled = true
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

        if let controllerClassName = ViewTreeNodePresentation.controllerClassNameText(for: node) {
            let copyControllerClassNameItem = NSMenuItem(
                title: "\(L10n.menuCopy) \(controllerClassName)",
                action: #selector(copySelectedNodeControllerClassName(_:)),
                keyEquivalent: ""
            )
            copyControllerClassNameItem.target = self
            copyItems.append(copyControllerClassNameItem)
        }

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

        // 是否有子项以“展示层级”为准（wrapper 被折叠后原始 childIDs 可能不为空但界面上没有子项）。
        if targetItem.children.isEmpty == false {
            menu.addItem(.separator())

            let expandChildrenItem = NSMenuItem(title: L10n.hierarchyMenuExpandChildren, action: #selector(expandMenuTargetChildren(_:)), keyEquivalent: "")
            expandChildrenItem.target = self
            menu.addItem(expandChildrenItem)

            let collapseChildrenItem = NSMenuItem(title: L10n.hierarchyMenuCollapseChildren, action: #selector(collapseMenuTargetChildren(_:)), keyEquivalent: "")
            collapseChildrenItem.target = self
            menu.addItem(collapseChildrenItem)
        }
    }
}

enum ViewTreeNodePresentation {
    enum IconKind: Equatable {
        case window
        case layer
        case viewController
        case tabView
        case button
        case label
        case image
        case scrollView
        case tableView
        case collectionView
        case outlineView
        case stackView
        case textField
        case slider
        case segmentedControl
        case control
        case effectView
        case view

        var symbolCandidates: [String] {
            switch self {
            case .window:
                return ["macwindow", "rectangle"]
            case .layer:
                return ["square.stack.3d.forward.dottedline", "square.3.layers.3d", "square.stack.3d.up"]
            case .viewController:
                return ["rectangle.stack.person.crop", "person.crop.rectangle.stack", "square.stack.3d.up"]
            case .tabView:
                return ["rectangle.split.3x1", "square.split.2x1"]
            case .button:
                return ["button.programmable", "capsule", "rectangle.and.hand.point.up.left"]
            case .label:
                return ["text.alignleft", "captions.bubble", "character"]
            case .image:
                return ["photo", "photo.on.rectangle"]
            case .scrollView:
                return ["scroll", "rectangle.3.group"]
            case .tableView:
                return ["tablecells", "list.bullet.rectangle"]
            case .collectionView:
                return ["square.grid.2x2", "square.grid.3x3"]
            case .outlineView:
                return ["list.bullet.indent", "list.bullet"]
            case .stackView:
                return ["square.stack.3d.down.right", "square.stack.3d.up"]
            case .textField:
                return ["text.cursor", "character.textbox", "textbox"]
            case .slider:
                return ["slider.horizontal.3", "line.3.horizontal.decrease.circle"]
            case .segmentedControl:
                return ["rectangle.split.3x1", "square.split.2x1"]
            case .control:
                return ["switch.2", "slider.horizontal.3"]
            case .effectView:
                return ["sparkles.rectangle.stack", "sparkles"]
            case .view:
                return ["square.on.square", "square"]
            }
        }
    }

    static func classText(for node: ViewScopeHierarchyNode) -> String {
        preferredDisplayClassName(for: node)
    }

    static func controllerAnnotationText(for node: ViewScopeHierarchyNode) -> String? {
        guard let controllerClassNameText = controllerClassNameText(for: node) else {
            return nil
        }
        return "\(controllerClassNameText).view"
    }

    static func controllerClassNameText(for node: ViewScopeHierarchyNode) -> String? {
        controllerText(for: node)
    }

    static func trailingText(for node: ViewScopeHierarchyNode) -> String? {
        ivarText(for: node)
    }

    static func rowText(for node: ViewScopeHierarchyNode) -> String {
        var parts = [classText(for: node)]
        if let controllerAnnotationText = controllerAnnotationText(for: node) {
            parts.append(controllerAnnotationText)
        }
        if let trailingText = trailingText(for: node) {
            parts.append(trailingText)
        }
        return parts.joined(separator: " ")
    }

    /// 副标题：优先显示 specialTrace（如 "VCName.view"），其次显示 ivar 名称。
    /// 与 Lookin 的 subtitle 逻辑一致：specialTrace > ivarName。
    static func secondaryText(for node: ViewScopeHierarchyNode) -> String? {
        // specialTrace 来自 ViewScopeSnapshotBuilder 的 subtitle 字段
        if let subtitle = sanitized(node.subtitle), !subtitle.isEmpty {
            return subtitle
        }
        return ivarText(for: node)
    }

    static func controllerText(for node: ViewScopeHierarchyNode) -> String? {
        guard let className = sanitized(node.rootViewControllerClassName) else { return nil }
        return ViewScopeClassNameFormatter.displayName(for: className)
    }

    static func ivarText(for node: ViewScopeHierarchyNode) -> String? {
        let traces = preferredIvarTraces(for: node)
        if !traces.isEmpty {
            let names = orderedUniqueIvarNames(from: traces.map(\.ivarName))
            let joined = names.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }

        guard let ivarName = sanitizedIvarName(node.ivarName) else { return nil }
        return ivarName
    }

    static func matches(node: ViewScopeHierarchyNode, query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return true }
        return searchableText(for: node).contains(normalizedQuery)
    }

    static func iconKind(for node: ViewScopeHierarchyNode) -> IconKind {
        if node.kind == .window {
            return .window
        }
        // layer 节点：若有宿主视图，按宿主视图类名决定图标（和 Lookin 一致）；
        // 否则用通用的 layer 图标。
        if node.kind == .layer {
            if node.hostViewClassName == nil {
                return .layer
            }
            // Fall through to class-name-based icon resolution below.
        }
        if sanitized(node.rootViewControllerClassName) != nil {
            return .viewController
        }

        // classText 现在返回纯类名（对 layer 节点返回宿主视图类名）
        let className = classText(for: node)
        if className.contains("NSTabView") {
            return .tabView
        }
        if className.contains("NSOutlineView") {
            return .outlineView
        }
        if className.contains("NSTableView") {
            return .tableView
        }
        if className.contains("NSCollectionView") {
            return .collectionView
        }
        if className.contains("NSScrollView") || className.contains("NSClipView") {
            return .scrollView
        }
        if className.contains("NSStackView") {
            return .stackView
        }
        if className.contains("NSButton") {
            return .button
        }
        if className.contains("NSSlider") {
            return .slider
        }
        if className.contains("NSSegmentedControl") {
            return .segmentedControl
        }
        if className.contains("NSTextField") {
            return .textField
        }
        if className.contains("NSSearchField") || className.contains("NSTextView") || className.contains("NSSecureTextField") {
            return .textField
        }
        if className.contains("NSImageView") {
            return .image
        }
        if className.contains("NSVisualEffectView") || className.contains("NSGlassEffectView") {
            return .effectView
        }
        if className.contains("NSControl") {
            return .control
        }
        return .view
    }

    static func iconImage(for node: ViewScopeHierarchyNode) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        for symbolName in iconKind(for: node).symbolCandidates {
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                return image.withSymbolConfiguration(configuration)
            }
        }
        return nil
    }

    static func eventHandlers(for node: ViewScopeHierarchyNode) -> [ViewScopeEventHandler] {
        if let handlers = node.eventHandlers, handlers.isEmpty == false {
            return handlers
        }
        guard let synthesizedControlHandler = synthesizedControlHandler(for: node) else {
            return []
        }
        return [synthesizedControlHandler]
    }

    static func isSystemWrapper(node: ViewScopeHierarchyNode) -> Bool {
        ViewHierarchyPresentation.isSystemWrapper(node)
    }

    private static func searchableText(for node: ViewScopeHierarchyNode) -> String {
        let handlers = eventHandlers(for: node)
        let ivarNames = node.ivarTraces.map { $0.ivarName }.joined(separator: " ")
        let handlerTitles = handlers.map { $0.title }.joined(separator: " ")
        let handlerSubtitles = handlers.compactMap { $0.subtitle }.joined(separator: " ")
        let handlerDelegates = handlers.compactMap { $0.delegateClassName }.joined(separator: " ")

        var targetClassNames: [String] = []
        var actionNames: [String] = []
        for handler in handlers {
            for targetAction in handler.targetActions {
                if let targetClassName = targetAction.targetClassName {
                    targetClassNames.append(targetClassName)
                }
                if let actionName = targetAction.actionName {
                    actionNames.append(actionName)
                }
            }
        }

        var searchText = ""
        let parts = [
            node.title,
            node.subtitle ?? "",
            node.className,
            classText(for: node),
            node.rootViewControllerClassName ?? "",
            controllerText(for: node) ?? "",
            // 树上显示的是 “XxxViewController.view”，按显示文本搜索也要能命中。
            controllerAnnotationText(for: node) ?? "",
            ivarNames,
            node.ivarName ?? "",
            node.controlActionName ?? "",
            node.controlTargetClassName ?? "",
            handlerTitles,
            handlerSubtitles,
            handlerDelegates,
            targetClassNames.joined(separator: " "),
            actionNames.joined(separator: " "),
            node.identifier ?? "",
            node.address ?? ""
        ]

        for part in parts where part.isEmpty == false {
            if searchText.isEmpty == false {
                searchText.append(" ")
            }
            searchText.append(part)
        }

        return searchText.lowercased()
    }

    private static func synthesizedControlHandler(for node: ViewScopeHierarchyNode) -> ViewScopeEventHandler? {
        let targetAction = ViewScopeEventTargetAction(
            targetClassName: sanitized(node.controlTargetClassName),
            actionName: sanitized(node.controlActionName)
        )
        guard targetAction.targetClassName != nil || targetAction.actionName != nil else {
            return nil
        }

        return ViewScopeEventHandler(
            kind: .controlAction,
            title: targetAction.actionName ?? L10n.serverItemTitle("action"),
            targetActions: [targetAction]
        )
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func preferredDisplayClassName(for node: ViewScopeHierarchyNode) -> String {
        if node.kind == .layer, let hostViewClassName = sanitized(node.hostViewClassName) {
            return ViewScopeClassNameFormatter.displayName(for: hostViewClassName)
        }
        return ViewScopeClassNameFormatter.displayName(for: node.className)
    }

    private static func preferredTraceHostClassName(for node: ViewScopeHierarchyNode) -> String? {
        let grouped = Dictionary(grouping: node.ivarTraces) { trace in
            canonicalTraceHostClassName(from: trace.hostClassName) ?? ""
        }
        let groupedCandidates: [(candidate: String, traces: [ViewScopeIvarTrace])] = grouped.compactMap { candidate, traces in
            guard candidate.isEmpty == false else {
                return nil
            }
            return (candidate: candidate, traces: traces)
        }

        return groupedCandidates
            .sorted { lhs, rhs in
                let lhsPriority = traceHostClassPriority(lhs.candidate)
                let rhsPriority = traceHostClassPriority(rhs.candidate)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                if lhs.traces.count != rhs.traces.count {
                    return lhs.traces.count > rhs.traces.count
                }
                return ViewScopeClassNameFormatter.displayName(for: lhs.candidate) <
                    ViewScopeClassNameFormatter.displayName(for: rhs.candidate)
            }
            .first?
            .candidate
    }

    private static func preferredIvarTraces(for node: ViewScopeHierarchyNode) -> [ViewScopeIvarTrace] {
        guard node.kind == .layer, node.ivarTraces.isEmpty == false else {
            return node.ivarTraces
        }

        let preferredHostClassName = sanitized(node.hostViewClassName) ?? preferredTraceHostClassName(for: node)
        guard let preferredHostClassName else {
            return node.ivarTraces
        }

        let preferredDisplayName = ViewScopeClassNameFormatter.displayName(for: preferredHostClassName)
        let filtered = node.ivarTraces.filter { trace in
            guard let traceHostClassName = canonicalTraceHostClassName(from: trace.hostClassName) else {
                return false
            }
            return ViewScopeClassNameFormatter.displayName(for: traceHostClassName) == preferredDisplayName
        }
        return filtered.isEmpty ? node.ivarTraces : filtered
    }

    private static func orderedUniqueIvarNames(from names: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for name in names {
            guard let sanitizedName = sanitizedIvarName(name) else { continue }
            guard isUUIDLikeIvarName(sanitizedName) == false else { continue }
            guard seen.insert(sanitizedName).inserted else { continue }
            result.append(sanitizedName)
        }
        return result
    }

    private static func isUUIDLikeIvarName(_ name: String) -> Bool {
        let stripped = String(name.drop(while: { $0 == "_" }))
        guard stripped.count >= 16 else { return false }
        return stripped.allSatisfy { $0.isHexDigit }
    }

    private static func sanitizedIvarName(_ value: String?) -> String? {
        sanitized(value)
    }

    private static func canonicalTraceHostClassName(from value: String?) -> String? {
        sanitized(value)?
            .components(separatedBy: " : ")
            .first
    }

    private static func traceHostClassPriority(_ className: String) -> Int {
        let displayName = ViewScopeClassNameFormatter.displayName(for: className)
        if displayName.localizedCaseInsensitiveContains("layer") {
            return 2
        }
        if systemWrapperClassNames.contains(displayName) {
            return 1
        }
        return 0
    }

    private static let systemWrapperClassNames: Set<String> = [
        "_NSSplitViewItemViewWrapper",
        "_NSSplitViewCollapsedInteractionsView",
        "NSBlurryAlleywayView",
        "NSThemeFrame",
        "NSTitlebarContainerBlockingView",
        "NSTitlebarView",
        "_NSTitlebarDecorationView",
        "_NSTitlebarContainerView",
        "_NSToolbarFullScreenWindowContentView"
    ]
}

enum ViewTreeLayoutMetrics {
    static let rowHeight: CGFloat = 28
    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 3
    static let trailingSpacing: CGFloat = 8
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let trailingFont = NSFont.systemFont(ofSize: 10.5)
}

private struct ViewTreeHandlersButtonMetrics {
    let width: CGFloat
    let height: CGFloat
    let isHidden: Bool

    static func resolve(hasHandlers: Bool, isHovering: Bool) -> Self {
        guard hasHandlers else {
            return .init(width: 0, height: 0, isHidden: true)
        }
        return .init(
            width: isHovering ? 14 : 10,
            height: isHovering ? 20 : 16,
            isHidden: false
        )
    }
}

private final class ViewTreeHandlersButton: NSButton {
    var hoverStateDidChange: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private(set) var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            hoverStateDidChange?(isHovering)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }
}

private final class ViewTreeNodeCellView: NSTableCellView {
    private let handlersButton = ViewTreeHandlersButton()
    private let iconView = NSImageView()
    private let leadingLabelsStackView = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let controllerLabel = NSTextField(labelWithString: "")
    private let ivarLabel = NSTextField(labelWithString: "")
    /// 布局问题徽标：颜色表示最高严重程度，tooltip 列出全部问题。
    private let diagnosticsBadgeView = NSImageView()
    private var handlersButtonWidthConstraint: Constraint?
    private var handlersButtonHeightConstraint: Constraint?
    private var nodeID: String?
    private var node: ViewScopeHierarchyNode?
    private var eventHandlers: [ViewScopeEventHandler] = []
    private var handlersPopover: NSPopover?
    private var isEffectivelyHidden = false
    private var issueSeverity: LayoutDiagnosticIssue.Severity?
    private var isSearchMatch = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard oldValue != backgroundStyle else { return }
            updateContentAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        handlersButton.isBordered = false
        handlersButton.title = ""
        handlersButton.toolTip = L10n.hierarchyShowHandlers
        handlersButton.target = self
        handlersButton.action = #selector(handleHandlersButton(_:))
        handlersButton.wantsLayer = true
        handlersButton.hoverStateDidChange = { [weak self] _ in
            self?.updateHandlersButtonMetrics(animated: true)
            self?.updateHandlersButtonAppearance()
        }

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        titleLabel.font = ViewTreeLayoutMetrics.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel.cell?.usesSingleLineMode = true

        controllerLabel.font = ViewTreeLayoutMetrics.trailingFont
        controllerLabel.lineBreakMode = .byTruncatingTail
        controllerLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        controllerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controllerLabel.cell?.usesSingleLineMode = true

        ivarLabel.font = ViewTreeLayoutMetrics.trailingFont
        ivarLabel.lineBreakMode = .byTruncatingHead
        ivarLabel.alignment = .right
        ivarLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ivarLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ivarLabel.cell?.usesSingleLineMode = true

        leadingLabelsStackView.orientation = .horizontal
        leadingLabelsStackView.alignment = .centerY
        leadingLabelsStackView.spacing = 4
        leadingLabelsStackView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leadingLabelsStackView.addArrangedSubview(titleLabel)
        leadingLabelsStackView.addArrangedSubview(controllerLabel)

        diagnosticsBadgeView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        diagnosticsBadgeView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        diagnosticsBadgeView.isHidden = true
        diagnosticsBadgeView.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 搜索命中时给标题加淡黄色底，便于在长列表中定位。
        leadingLabelsStackView.wantsLayer = true
        leadingLabelsStackView.layer?.cornerRadius = 3

        addSubview(handlersButton)
        addSubview(iconView)
        addSubview(leadingLabelsStackView)
        addSubview(ivarLabel)
        addSubview(diagnosticsBadgeView)

        handlersButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(2)
            make.centerY.equalToSuperview()
            handlersButtonWidthConstraint = make.width.equalTo(0).constraint
            handlersButtonHeightConstraint = make.height.equalTo(0).constraint
        }
        iconView.snp.makeConstraints { make in
            make.leading.equalTo(handlersButton.snp.trailing).offset(6)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(14)
        }
        leadingLabelsStackView.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(6)
            make.top.greaterThanOrEqualToSuperview().inset(ViewTreeLayoutMetrics.verticalInset).priority(.low)
            make.bottom.lessThanOrEqualToSuperview().inset(ViewTreeLayoutMetrics.verticalInset).priority(.low)
            make.centerY.equalToSuperview()
        }
        ivarLabel.snp.makeConstraints { make in
            make.leading.greaterThanOrEqualTo(leadingLabelsStackView.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(diagnosticsBadgeView.snp.leading).offset(-4)
        }
        diagnosticsBadgeView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview().inset(ViewTreeLayoutMetrics.trailingSpacing)
            make.width.height.equalTo(12)
        }

        updateHandlersButtonAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        node: ViewScopeHierarchyNode,
        isEffectivelyHidden: Bool,
        issueSeverity: LayoutDiagnosticIssue.Severity? = nil,
        issueToolTip: String? = nil,
        isSearchMatch: Bool = false
    ) {
        self.node = node
        nodeID = node.id
        self.isEffectivelyHidden = isEffectivelyHidden
        self.issueSeverity = issueSeverity
        self.isSearchMatch = isSearchMatch
        diagnosticsBadgeView.isHidden = issueSeverity == nil
        diagnosticsBadgeView.toolTip = issueToolTip
        eventHandlers = ViewTreeNodePresentation.eventHandlers(for: node)
        iconView.image = ViewTreeNodePresentation.iconImage(for: node)
        titleLabel.stringValue = ViewTreeNodePresentation.classText(for: node)
        let controllerAnnotationText = ViewTreeNodePresentation.controllerAnnotationText(for: node)
        controllerLabel.stringValue = controllerAnnotationText ?? ""
        controllerLabel.isHidden = controllerAnnotationText == nil
        let trailingText = ViewTreeNodePresentation.trailingText(for: node)
        ivarLabel.stringValue = trailingText ?? ""
        ivarLabel.isHidden = trailingText == nil
        updateHandlersButtonMetrics(animated: false)
        updateContentAppearance()
        if eventHandlers.isEmpty {
            handlersPopover?.close()
            handlersPopover = nil
        }
    }

    @objc private func handleHandlersButton(_ sender: Any?) {
        guard eventHandlers.isEmpty == false else { return }
        handlersPopover?.close()

        let controller = ViewTreeEventHandlersPopoverController(handlers: eventHandlers)
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        popover.show(relativeTo: handlersButton.bounds, of: handlersButton, preferredEdge: .maxY)
        handlersPopover = popover
    }

    private func updateHandlersButtonMetrics(animated: Bool) {
        let metrics = ViewTreeHandlersButtonMetrics.resolve(
            hasHandlers: eventHandlers.isEmpty == false,
            isHovering: handlersButton.isHovering
        )
        handlersButton.isHidden = metrics.isHidden
        let updates = {
            self.handlersButtonWidthConstraint?.update(offset: metrics.width)
            self.handlersButtonHeightConstraint?.update(offset: metrics.height)

            // 这里不能在 cell 配置阶段同步触发 layoutSubtreeIfNeeded()。
            // 展开树节点时 NSOutlineView 正在批量创建行视图，同步布局会反向触发行构建，
            // 进而把 configure -> 布局 -> 行创建 串成递归链路，导致主线程持续高 CPU。
            self.needsUpdateConstraints = true
            self.needsLayout = true
        }

        guard animated else {
            updates()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            updates()
        }
    }

    private func updateHandlersButtonAppearance() {
        let isSelected = backgroundStyle == .emphasized
        let fillColor: NSColor
        let borderColor: NSColor
        if isSelected {
            fillColor = NSColor.white.withAlphaComponent(handlersButton.isHovering ? 1 : 0.88)
            borderColor = NSColor.white.withAlphaComponent(0.92)
        } else {
            fillColor = NSColor.systemBlue.withAlphaComponent(handlersButton.isHovering ? 0.96 : 0.6)
            borderColor = NSColor.systemBlue.withAlphaComponent(0.82)
        }
        handlersButton.layer?.backgroundColor = fillColor.cgColor
        handlersButton.layer?.borderColor = borderColor.cgColor
        handlersButton.layer?.borderWidth = 1
        handlersButton.layer?.cornerRadius = 5
    }

    private func updateContentAppearance() {
        let isSelected = backgroundStyle == .emphasized
        let alphaComponent: CGFloat = isEffectivelyHidden ? 0.45 : 1

        let titleColor: NSColor
        let secondaryColor: NSColor
        let accessoryColor: NSColor
        if isSelected {
            titleColor = NSColor.white.withAlphaComponent(alphaComponent)
            secondaryColor = NSColor.white.withAlphaComponent(isEffectivelyHidden ? 0.72 : 0.88)
            accessoryColor = NSColor.white.withAlphaComponent(alphaComponent)
        } else {
            titleColor = NSColor.labelColor.withAlphaComponent(alphaComponent)
            secondaryColor = NSColor.secondaryLabelColor.withAlphaComponent(alphaComponent)
            accessoryColor = NSColor.secondaryLabelColor.withAlphaComponent(alphaComponent)
        }

        titleLabel.textColor = titleColor
        controllerLabel.textColor = secondaryColor
        ivarLabel.textColor = secondaryColor
        iconView.contentTintColor = accessoryColor
        diagnosticsBadgeView.contentTintColor = isSelected ? NSColor.white : issueSeverity?.color
        leadingLabelsStackView.layer?.backgroundColor = isSearchMatch && isSelected == false
            ? NSColor.systemYellow.withAlphaComponent(0.35).cgColor
            : NSColor.clear.cgColor
        updateHandlersButtonAppearance()
    }
}

private final class ViewTreeEventHandlersPopoverController: NSViewController {
    private let handlers: [ViewScopeEventHandler]
    private let scrollView = NSScrollView()
    private let documentView = ViewTreeFlippedContentView()
    private var itemViews: [ViewTreeEventHandlerItemView] = []
    private let contentInset: CGFloat = 10

    init(handlers: [ViewScopeEventHandler]) {
        self.handlers = handlers
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = documentView

        container.addSubview(scrollView)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        for (index, handler) in handlers.enumerated() {
            let itemView = ViewTreeEventHandlerItemView(
                handler: handler,
                showsTopSeparator: index > 0
            )
            itemViews.append(itemView)
            documentView.addSubview(itemView)
        }

        view.layoutSubtreeIfNeeded()
        updatePreferredContentSize()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePreferredContentSize()
    }

    private func updatePreferredContentSize() {
        var fitting = CGSize.zero
        var currentY = contentInset
        for itemView in itemViews {
            let size = itemView.fittingSize
            itemView.frame = NSRect(
                x: contentInset,
                y: currentY,
                width: max(size.width, 1),
                height: size.height
            )
            currentY += size.height
            fitting.width = max(fitting.width, size.width)
            fitting.height += size.height
        }

        let preferredWidth = min(max(fitting.width + contentInset * 2, 360), 560)
        for itemView in itemViews {
            var frame = itemView.frame
            frame.size.width = preferredWidth - contentInset * 2
            itemView.frame = frame
        }
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: preferredWidth,
            height: fitting.height + contentInset * 2
        )
        preferredContentSize = NSSize(
            width: preferredWidth,
            height: min(max(fitting.height + 20, 80), 360)
        )
    }
}

private final class ViewTreeFlippedContentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private final class ViewTreeEventHandlerItemView: NSView {
    private let handler: ViewScopeEventHandler
    private let separatorView = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    init(handler: ViewScopeEventHandler, showsTopSeparator: Bool) {
        self.handler = handler
        super.init(frame: .zero)
        wantsLayer = true

        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        separatorView.isHidden = showsTopSeparator == false

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0

        addSubview(separatorView)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(detailLabel)

        separatorView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(1)
        }
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.top.equalToSuperview().offset(showsTopSeparator ? 12 : 2)
            make.width.height.equalTo(16)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(10)
            make.top.equalToSuperview().offset(showsTopSeparator ? 10 : 0)
            make.trailing.equalToSuperview()
        }
        detailLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel)
            make.top.equalTo(titleLabel.snp.bottom).offset(4)
            make.trailing.bottom.equalToSuperview()
        }

        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        titleLabel.stringValue = handler.title
        detailLabel.stringValue = detailLines().joined(separator: "\n")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.image = image(for: handler)
        iconView.contentTintColor = .secondaryLabelColor
    }

    private func detailLines() -> [String] {
        var lines: [String] = []

        if let subtitle = handler.subtitle, subtitle.isEmpty == false {
            lines.append(subtitle)
        }
        if handler.kind == .gesture, let isEnabled = handler.isEnabled {
            lines.append("\(L10n.serverItemTitle("enabled")): \(isEnabled ? L10n.serverYes : L10n.serverNo)")
        }
        if let delegateClassName = handler.delegateClassName, delegateClassName.isEmpty == false {
            lines.append("\(L10n.serverItemTitle("delegate")): \(ViewScopeClassNameFormatter.displayName(for: delegateClassName))")
        }

        if handler.targetActions.isEmpty {
            lines.append("\(L10n.serverItemTitle("target")): nil")
            lines.append("\(L10n.serverItemTitle("action")): nil")
        } else if handler.targetActions.count == 1, let targetAction = handler.targetActions.first {
            lines.append("\(L10n.serverItemTitle("target")): \(formattedTargetValue(for: targetAction))")
            lines.append("\(L10n.serverItemTitle("action")): \(targetAction.actionName ?? "nil")")
        } else {
            for (index, targetAction) in handler.targetActions.enumerated() {
                lines.append("\(L10n.serverItemTitle("target")) \(index + 1): \(formattedTargetValue(for: targetAction))")
                lines.append("\(L10n.serverItemTitle("action")) \(index + 1): \(targetAction.actionName ?? "nil")")
            }
        }

        return lines
    }

    private func formattedTargetValue(for targetAction: ViewScopeEventTargetAction) -> String {
        if let targetClassName = targetAction.targetClassName, targetClassName.isEmpty == false {
            return ViewScopeClassNameFormatter.displayName(for: targetClassName)
        }
        if targetAction.actionName != nil {
            return L10n.serverFirstResponder
        }
        return "nil"
    }

    private func image(for handler: ViewScopeEventHandler) -> NSImage? {
        let symbolCandidates: [String]
        switch handler.kind {
        case .controlAction:
            symbolCandidates = ["cursorarrow.click", "bolt.horizontal.circle", "command.circle"]
        case .gesture:
            symbolCandidates = ["hand.tap", "hand.point.up.left", "wave.3.forward.circle"]
        }
        for symbolName in symbolCandidates {
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                return image
            }
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

final class ViewTreeNodeItem: NSObject {
    let node: ViewScopeHierarchyNode
    weak var parent: ViewTreeNodeItem?
    let children: [ViewTreeNodeItem]
    /// 过滤（搜索 / 只看问题节点）时，节点自身满足条件。
    private(set) var isFilterMatch = false
    /// 过滤时，节点的后代中存在命中节点，需要展开以显示命中结果。
    private(set) var isOnFilterPath = false

    var isEffectivelyHidden: Bool {
        node.isHidden || parent?.isEffectivelyHidden == true
    }

    init(node: ViewScopeHierarchyNode, children: [ViewTreeNodeItem]) {
        self.node = node
        self.children = children
        super.init()
        self.children.forEach { $0.parent = self }
    }

    static func make(
        nodeID: String,
        nodes: [String: ViewScopeHierarchyNode],
        showsSystemWrappers: Bool = false
    ) -> ViewTreeNodeItem? {
        guard let node = nodes[nodeID] else {
            return nil
        }
        let childNodeIDs = ViewHierarchyPresentation.presentedChildNodeIDs(
            of: nodeID,
            nodes: nodes,
            showsSystemWrappers: showsSystemWrappers
        )
        let children = childNodeIDs.compactMap {
            make(nodeID: $0, nodes: nodes, showsSystemWrappers: showsSystemWrappers)
        }
        return ViewTreeNodeItem(node: node, children: children)
    }

    /// 按搜索关键字过滤。
    func filtered(matching query: String) -> ViewTreeNodeItem? {
        filtered { ViewTreeNodePresentation.matches(node: $0, query: query) }
    }

    /// 按条件过滤：
    /// - 命中节点保留完整子树（便于继续查看它的子节点），默认折叠；
    /// - 未命中但后代有命中的节点只保留通往命中节点的路径，并标记为需要展开。
    func filtered(where predicate: (ViewScopeHierarchyNode) -> Bool) -> ViewTreeNodeItem? {
        if predicate(node) {
            let copiedChildren = children.map { $0.copySubtree() }
            let item = ViewTreeNodeItem(node: node, children: copiedChildren)
            item.isFilterMatch = true
            // 命中节点的后代中如果还有命中项，也要能展开看到它们。
            let filteredDescendants = children.compactMap { $0.filtered(where: predicate) }
            if filteredDescendants.isEmpty == false {
                let pathItem = ViewTreeNodeItem(node: node, children: mergedChildren(original: copiedChildren, filtered: filteredDescendants))
                pathItem.isFilterMatch = true
                pathItem.isOnFilterPath = true
                return pathItem
            }
            return item
        }
        let filteredChildren = children.compactMap { $0.filtered(where: predicate) }
        guard filteredChildren.isEmpty == false else {
            return nil
        }
        let item = ViewTreeNodeItem(node: node, children: filteredChildren)
        item.isOnFilterPath = true
        return item
    }

    /// 复制整棵子树（item 的 parent 是弱引用且只能有一个，因此不能在两棵树之间共享子节点）。
    private func copySubtree() -> ViewTreeNodeItem {
        ViewTreeNodeItem(node: node, children: children.map { $0.copySubtree() })
    }

    /// 命中节点同时也是路径节点时：保留全部子节点，但用过滤结果替换其中包含命中项的子树。
    private func mergedChildren(original: [ViewTreeNodeItem], filtered: [ViewTreeNodeItem]) -> [ViewTreeNodeItem] {
        let filteredByNodeID = Dictionary(filtered.map { ($0.node.id, $0) }, uniquingKeysWith: { first, _ in first })
        return original.map { filteredByNodeID[$0.node.id] ?? $0 }
    }
}
