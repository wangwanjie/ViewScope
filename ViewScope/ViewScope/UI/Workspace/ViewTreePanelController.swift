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
    private let wrapperToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let emptyStateView = WorkspaceEmptyStateView()
    private var cancellables = Set<AnyCancellable>()
    private var rootItems: [ViewTreeNodeItem] = []
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
        wrapperToggle.title = L10n.hierarchyShowSystemWrappers
        wrapperToggle.state = store.showsSystemWrapperViews ? .on : .off
        wrapperToggle.target = self
        wrapperToggle.action = #selector(handleWrapperToggle(_:))
        wrapperToggle.font = NSFont.systemFont(ofSize: 11)

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
        panelView.contentView.addSubview(wrapperToggle)
        panelView.contentView.addSubview(scrollView)
        panelView.contentView.addSubview(emptyStateView)
        searchField.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }
        wrapperToggle.snp.makeConstraints { make in
            make.top.equalTo(searchField.snp.bottom).offset(6)
            make.leading.equalToSuperview().inset(12)
            make.trailing.lessThanOrEqualToSuperview().inset(12)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(wrapperToggle.snp.bottom).offset(8)
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
        wrapperToggle.state = store.showsSystemWrapperViews ? .on : .off
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
        wrapperToggle.isHidden = isDisconnected
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
        let presentationRootNodeIDs = ViewHierarchyPresentation.presentedRootNodeIDs(
            from: rootNodeIDs,
            nodes: capture.nodes,
            showsSystemWrappers: store.showsSystemWrapperViews
        )
        let presentationRoots = presentationRootNodeIDs.compactMap {
            ViewTreeNodeItem.make(
                nodeID: $0,
                nodes: capture.nodes,
                showsSystemWrappers: store.showsSystemWrapperViews
            )
        }
        let query = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return presentationRoots }
        return presentationRoots.compactMap { $0.filtered(matching: query) }
    }

    private func restoreExpansionState(items: [ViewTreeNodeItem]) {
        items.forEach { item in
            if store.isNodeExpanded(item.node.id) || item.parent == nil {
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
            store.setNodeExpanded(current.node.id, isExpanded: true)
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

    @objc private func handleWrapperToggle(_ sender: Any?) {
        store.setShowsSystemWrapperViews(wrapperToggle.state == .on)
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
        store.setNodeExpanded(item.node.id, isExpanded: true)
        item.children.forEach { expandRecursively($0) }
    }

    private func collapseDescendants(of item: ViewTreeNodeItem) {
        item.children.forEach {
            collapseDescendants(of: $0)
            outlineView.collapseItem($0)
            store.setNodeExpanded($0.node.id, isExpanded: false)
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
        store.setNodeExpanded(item.node.id, isExpanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? ViewTreeNodeItem else { return }
        store.setNodeExpanded(item.node.id, isExpanded: false)
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
    enum IconKind: Equatable {
        case window
        case viewController
        case button
        case label
        case image
        case scrollView
        case tableView
        case outlineView
        case stackView
        case textField
        case slider
        case segmentedControl
        case control
        case view

        var symbolCandidates: [String] {
            switch self {
            case .window:
                return ["macwindow", "rectangle"]
            case .viewController:
                return ["rectangle.stack.person.crop", "person.crop.rectangle.stack", "square.stack.3d.up"]
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
            case .view:
                return ["square.on.square", "square"]
            }
        }
    }

    static func classText(for node: ViewScopeHierarchyNode) -> String {
        let classText = ViewScopeClassNameFormatter.displayName(for: node.className)
        guard let controllerText = controllerText(for: node) else {
            return classText
        }
        return "\(classText) \(controllerText).view"
    }

    static func secondaryText(for node: ViewScopeHierarchyNode) -> String? {
        [ivarText(for: node)]
            .compactMap { sanitized($0) }
            .joined(separator: " • ")
            .nonEmpty
    }

    static func controllerText(for node: ViewScopeHierarchyNode) -> String? {
        guard let className = sanitized(node.rootViewControllerClassName) else { return nil }
        return ViewScopeClassNameFormatter.displayName(for: className)
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

    static func iconKind(for node: ViewScopeHierarchyNode) -> IconKind {
        if node.kind == .window {
            return .window
        }
        if sanitized(node.rootViewControllerClassName) != nil {
            return .viewController
        }

        let className = classText(for: node)
        if className.contains("NSOutlineView") {
            return .outlineView
        }
        if className.contains("NSTableView") {
            return .tableView
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
            node.className,
            classText(for: node),
            node.rootViewControllerClassName ?? "",
            controllerText(for: node) ?? "",
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
}

enum ViewTreeLayoutMetrics {
    static let rowHeight: CGFloat = 36
    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 4
    static let trailingSpacing: CGFloat = 8
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
    weak var delegate: ViewTreeNodeCellViewDelegate?
    private let handlersButton = ViewTreeHandlersButton()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let labelsStackView = NSStackView()
    private let visibilityButton = NSButton()
    private var handlersButtonWidthConstraint: Constraint?
    private var handlersButtonHeightConstraint: Constraint?
    private var nodeID: String?
    private var eventHandlers: [ViewScopeEventHandler] = []
    private var handlersPopover: NSPopover?
    private var isEffectivelyHidden = false

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

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        secondaryLabel.font = NSFont.systemFont(ofSize: 10.5)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        visibilityButton.bezelStyle = .inline
        visibilityButton.imagePosition = .imageOnly
        visibilityButton.target = self
        visibilityButton.action = #selector(handleVisibilityButton(_:))

        labelsStackView.orientation = .vertical
        labelsStackView.alignment = .leading
        labelsStackView.spacing = 1
        labelsStackView.addArrangedSubview(titleLabel)
        labelsStackView.addArrangedSubview(secondaryLabel)

        addSubview(handlersButton)
        addSubview(iconView)
        addSubview(labelsStackView)
        addSubview(visibilityButton)

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
        labelsStackView.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(6)
            make.top.greaterThanOrEqualToSuperview().inset(ViewTreeLayoutMetrics.verticalInset)
            make.bottom.lessThanOrEqualToSuperview().inset(ViewTreeLayoutMetrics.verticalInset)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(visibilityButton.snp.leading).offset(-ViewTreeLayoutMetrics.trailingSpacing)
        }
        visibilityButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(4)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(18)
        }

        updateHandlersButtonAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(node: ViewScopeHierarchyNode, isEffectivelyHidden: Bool) {
        nodeID = node.id
        self.isEffectivelyHidden = isEffectivelyHidden
        eventHandlers = ViewTreeNodePresentation.eventHandlers(for: node)
        titleLabel.stringValue = ViewTreeNodePresentation.classText(for: node)
        iconView.image = ViewTreeNodePresentation.iconImage(for: node)
        let secondaryText = ViewTreeNodePresentation.secondaryText(for: node)
        secondaryLabel.isHidden = secondaryText == nil
        secondaryLabel.stringValue = secondaryText ?? ""
        visibilityButton.image = NSImage(systemSymbolName: node.isHidden ? "eye.slash" : "eye", accessibilityDescription: nil)
        visibilityButton.toolTip = node.isHidden ? L10n.hierarchyMenuShowView : L10n.hierarchyMenuHideView
        visibilityButton.isEnabled = node.kind == .view
        updateHandlersButtonMetrics(animated: false)
        updateContentAppearance()
        if eventHandlers.isEmpty {
            handlersPopover?.close()
            handlersPopover = nil
        }
    }

    @objc private func handleVisibilityButton(_ sender: Any?) {
        guard let nodeID else { return }
        delegate?.viewTreeNodeCellViewDidToggleVisibility(self, nodeID: nodeID)
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
        let hasHandlers = eventHandlers.isEmpty == false
        let targetWidth: CGFloat = hasHandlers ? (handlersButton.isHovering ? 14 : 10) : 0
        let targetHeight: CGFloat = hasHandlers ? (handlersButton.isHovering ? 20 : 16) : 0

        handlersButton.isHidden = hasHandlers == false
        let updates = {
            self.handlersButtonWidthConstraint?.update(offset: targetWidth)
            self.handlersButtonHeightConstraint?.update(offset: targetHeight)
            self.layoutSubtreeIfNeeded()
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
        secondaryLabel.textColor = secondaryColor
        iconView.contentTintColor = accessoryColor
        visibilityButton.contentTintColor = accessoryColor
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

    static func make(
        nodeID: String,
        nodes: [String: ViewScopeHierarchyNode],
        showsSystemWrappers: Bool = false
    ) -> ViewTreeNodeItem? {
        guard let node = nodes[nodeID] else { return nil }
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
