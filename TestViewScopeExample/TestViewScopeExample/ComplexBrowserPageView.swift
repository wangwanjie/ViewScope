import Cocoa

private final class BrowserTreeNode: NSObject {
    let title: String
    let subtitle: String
    let badge: String
    let children: [BrowserTreeNode]

    init(title: String, subtitle: String, badge: String, children: [BrowserTreeNode]) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.children = children
    }
}

private struct BrowserRequestRow {
    let title: String
    let owner: String
    let status: String
    let duration: String
}

@MainActor
final class ComplexBrowserPageView: NSView {
    private let splitView = NSSplitView()
    private let outlineView = NSOutlineView()
    private let requestTableView = NSTableView()

    private let treeNodes: [BrowserTreeNode] = [
        BrowserTreeNode(
            title: "Application Shell",
            subtitle: "2 windows",
            badge: "ROOT",
            children: [
                BrowserTreeNode(
                    title: "Main Window",
                    subtitle: "Active",
                    badge: "WINDOW",
                    children: [
                        BrowserTreeNode(title: "Sidebar", subtitle: "cards + toggles", badge: "STACK", children: [
                            BrowserTreeNode(title: "Inspector Hooks", subtitle: "checkboxes", badge: "CARD", children: []),
                            BrowserTreeNode(title: "Preview Theme", subtitle: "popup + slider", badge: "CARD", children: []),
                            BrowserTreeNode(title: "Launch Summary", subtitle: "capsule badge", badge: "CARD", children: [])
                        ]),
                        BrowserTreeNode(title: "Playground Tab", subtitle: "forms + charts", badge: "TAB", children: [
                            BrowserTreeNode(title: "Control Matrix", subtitle: "grid controls", badge: "FORM", children: []),
                            BrowserTreeNode(title: "Nested Preview Canvas", subtitle: "custom drawing", badge: "CANVAS", children: []),
                            BrowserTreeNode(title: "Build Sessions", subtitle: "table card", badge: "TABLE", children: [])
                        ]),
                        BrowserTreeNode(title: "Data Browser Tab", subtitle: "outline + request list", badge: "TAB", children: [
                            BrowserTreeNode(title: "Source Outline", subtitle: "expanded rows", badge: "OUTLINE", children: [
                                BrowserTreeNode(title: "Application Shell", subtitle: "root row", badge: "ROW", children: []),
                                BrowserTreeNode(title: "Main Window", subtitle: "child row", badge: "ROW", children: []),
                                BrowserTreeNode(title: "Data Browser Tab", subtitle: "selected row", badge: "ROW", children: [])
                            ]),
                            BrowserTreeNode(title: "Request Table", subtitle: "4 columns", badge: "TABLE", children: [
                                BrowserTreeNode(title: "Sync Snapshot", subtitle: "Connected", badge: "ROW", children: []),
                                BrowserTreeNode(title: "Resolve Selection", subtitle: "Idle", badge: "ROW", children: []),
                                BrowserTreeNode(title: "Push Overlay", subtitle: "Queued", badge: "ROW", children: [])
                            ]),
                            BrowserTreeNode(title: "Selection Inspector", subtitle: "tokens + controls", badge: "FORM", children: [])
                        ])
                    ]
                )
            ]
        )
    ]

    private let requestRows: [BrowserRequestRow] = [
        .init(title: "Sync Snapshot", owner: "Main Window", status: "Connected", duration: "14 ms"),
        .init(title: "Resolve Selection", owner: "Outline Panel", status: "Idle", duration: "31 ms"),
        .init(title: "Push Overlay", owner: "Inspector", status: "Queued", duration: "45 ms"),
        .init(title: "Refresh Preview", owner: "Canvas", status: "Running", duration: "62 ms"),
        .init(title: "Replay Diff", owner: "Recent Sessions", status: "Succeeded", duration: "24 ms"),
        .init(title: "Persist Capture", owner: "History Store", status: "Stored", duration: "19 ms")
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildInterface() {
        identify(self, "complex-browser-root")

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        identify(splitView, "complex-browser-split")
        addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let outlineCard = makeOutlineCard()
        let requestsCard = makeRequestsCard()
        let inspectorCard = makeInspectorCard()

        splitView.addArrangedSubview(outlineCard)
        splitView.addArrangedSubview(requestsCard)
        splitView.addArrangedSubview(inspectorCard)

        outlineCard.widthAnchor.constraint(equalToConstant: 280).isActive = true
        inspectorCard.widthAnchor.constraint(equalToConstant: 300).isActive = true
    }

    private func makeOutlineCard() -> NSView {
        let card = PanelView(
            title: "Source Outline",
            subtitle: "A nested NSOutlineView with expandable items and custom row badges."
        )
        identify(card, "browser-outline-card")

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        identify(toolbar, "browser-outline-toolbar")

        let modeControl = identify(
            NSSegmentedControl(labels: ["Views", "Layers", "Events"], trackingMode: .selectOne, target: nil, action: nil),
            "browser-outline-mode"
        )
        modeControl.selectedSegment = 0

        let searchField = identify(NSSearchField(), "browser-outline-search")
        searchField.placeholderString = "Filter rows"
        searchField.controlSize = .small

        toolbar.addArrangedSubview(modeControl)
        toolbar.addArrangedSubview(searchField)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        card.contentStack.addArrangedSubview(toolbar)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("browser-outline-column"))
        column.title = "Source"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 40
        outlineView.indentationPerLevel = 18
        outlineView.intercellSpacing = NSSize(width: 0, height: 4)
        outlineView.floatsGroupRows = false
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.delegate = self
        outlineView.dataSource = self
        identify(outlineView, "browser-outline-view")

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView
        identify(scrollView, "browser-outline-scroll")
        scrollView.heightAnchor.constraint(equalToConstant: 560).isActive = true
        card.contentStack.addArrangedSubview(scrollView)

        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        outlineView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        return card
    }

    private func makeRequestsCard() -> NSView {
        let card = PanelView(
            title: "Request Table",
            subtitle: "A denser NSTableView layout with custom cells, headers, and a footer status row."
        )
        identify(card, "browser-requests-card")

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        identify(toolbar, "browser-requests-toolbar")

        let filterField = identify(NSSearchField(), "browser-request-search")
        filterField.placeholderString = "Search requests"

        let stateFilter = identify(
            NSSegmentedControl(labels: ["All", "Active", "Done"], trackingMode: .selectOne, target: nil, action: nil),
            "browser-request-filter"
        )
        stateFilter.selectedSegment = 0

        let actionButton = identify(NSButton(title: "Replay Queue", target: nil, action: nil), "browser-request-action")

        toolbar.addArrangedSubview(filterField)
        toolbar.addArrangedSubview(stateFilter)
        toolbar.addArrangedSubview(actionButton)
        filterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        card.contentStack.addArrangedSubview(toolbar)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("request-name"))
        nameColumn.title = "Request"
        nameColumn.width = 220

        let ownerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("request-owner"))
        ownerColumn.title = "Owner"
        ownerColumn.width = 150

        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("request-status"))
        statusColumn.title = "Status"
        statusColumn.width = 120

        let durationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("request-duration"))
        durationColumn.title = "Duration"
        durationColumn.width = 90

        requestTableView.addTableColumn(nameColumn)
        requestTableView.addTableColumn(ownerColumn)
        requestTableView.addTableColumn(statusColumn)
        requestTableView.addTableColumn(durationColumn)
        requestTableView.headerView = NSTableHeaderView()
        requestTableView.rowHeight = 42
        requestTableView.intercellSpacing = NSSize(width: 0, height: 4)
        requestTableView.usesAlternatingRowBackgroundColors = true
        requestTableView.selectionHighlightStyle = .regular
        requestTableView.delegate = self
        requestTableView.dataSource = self
        identify(requestTableView, "browser-request-table")

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = requestTableView
        identify(scrollView, "browser-request-scroll")
        scrollView.heightAnchor.constraint(equalToConstant: 420).isActive = true
        card.contentStack.addArrangedSubview(scrollView)

        requestTableView.reloadData()
        requestTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        identify(footer, "browser-request-footer")

        let footerLabel = NSTextField(labelWithString: "Queue depth")
        footerLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let progress = identify(NSProgressIndicator(), "browser-request-progress")
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = 68
        progress.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let badge = BrowserBadgeView()
        badge.configure(text: "3 ACTIVE", tintColor: NSColor(calibratedRed: 0.11, green: 0.45, blue: 0.76, alpha: 1))

        footer.addArrangedSubview(footerLabel)
        footer.addArrangedSubview(progress)
        footer.addArrangedSubview(badge)
        card.contentStack.addArrangedSubview(footer)

        return card
    }

    private func makeInspectorCard() -> NSView {
        let card = PanelView(
            title: "Selection Inspector",
            subtitle: "A compact side panel with nested stacks, tokens, grid rows, and action groups."
        )
        identify(card, "browser-inspector-card")

        let metrics = NSStackView()
        metrics.orientation = .horizontal
        metrics.alignment = .top
        metrics.spacing = 10
        metrics.distribution = .fillEqually
        identify(metrics, "browser-inspector-metrics")
        metrics.addArrangedSubview(MetricCardView(title: "Rows", value: "24", accentColor: NSColor(calibratedRed: 0.15, green: 0.64, blue: 0.5, alpha: 1)))
        metrics.addArrangedSubview(MetricCardView(title: "Diffs", value: "07", accentColor: NSColor(calibratedRed: 0.89, green: 0.53, blue: 0.22, alpha: 1)))
        card.contentStack.addArrangedSubview(metrics)

        let grid = NSGridView(views: [
            [inspectorLabel("Selection"), inspectorValue("Data Browser Tab")],
            [inspectorLabel("Class"), inspectorValue("NSTabView")],
            [inspectorLabel("Frame"), inspectorValue("x 0 y 0 w 780 h 660")],
            [inspectorLabel("Rows"), inspectorValue("Outline 9 • Table 6")]
        ])
        identify(grid, "browser-inspector-grid")
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 72
        card.contentStack.addArrangedSubview(grid)

        let tokenField = identify(NSTokenField(), "browser-inspector-token-field")
        tokenField.objectValue = ["outline", "table", "forms", "filters"]
        card.contentStack.addArrangedSubview(tokenField)

        let toggleRow = NSStackView()
        toggleRow.orientation = .vertical
        toggleRow.alignment = .leading
        toggleRow.spacing = 8
        identify(toggleRow, "browser-inspector-toggle-row")
        let stickyHeaders = identify(NSButton(checkboxWithTitle: "Keep headers pinned", target: nil, action: nil), "browser-sticky-headers")
        stickyHeaders.state = .on
        let recordDiffs = identify(NSButton(checkboxWithTitle: "Record incremental diffs", target: nil, action: nil), "browser-record-diffs")
        recordDiffs.state = .on
        let selectionStepper = identify(NSStepper(), "browser-selection-stepper")
        selectionStepper.minValue = 1
        selectionStepper.maxValue = 9
        selectionStepper.doubleValue = 3
        toggleRow.addArrangedSubview(stickyHeaders)
        toggleRow.addArrangedSubview(recordDiffs)
        toggleRow.addArrangedSubview(selectionStepper)
        card.contentStack.addArrangedSubview(toggleRow)

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        identify(actionRow, "browser-inspector-action-row")
        actionRow.addArrangedSubview(identify(NSButton(title: "Highlight Row", target: nil, action: nil), "browser-highlight-row-button"))
        actionRow.addArrangedSubview(identify(NSButton(title: "Jump to Owner", target: nil, action: nil), "browser-jump-owner-button"))
        card.contentStack.addArrangedSubview(actionRow)

        return card
    }

    @discardableResult
    private func identify<T: NSView>(_ view: T, _ rawIdentifier: String) -> T {
        view.identifier = NSUserInterfaceItemIdentifier(rawIdentifier)
        view.setAccessibilityIdentifier(rawIdentifier)
        return view
    }

    private func inspectorLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func inspectorValue(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        return label
    }
}

extension ComplexBrowserPageView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = item as? BrowserTreeNode
        return node?.children.count ?? treeNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? BrowserTreeNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = item as? BrowserTreeNode
        return node?.children[index] ?? treeNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? BrowserTreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("browser-outline-cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? BrowserOutlineCellView ?? {
            let view = BrowserOutlineCellView()
            view.identifier = identifier
            return view
        }()
        cell.configure(title: node.title, subtitle: node.subtitle, badge: node.badge)
        return cell
    }
}

extension ComplexBrowserPageView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        requestRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = requestRows[row]
        let columnID = tableColumn?.identifier.rawValue ?? "request-name"

        if columnID == "request-name" {
            let identifier = NSUserInterfaceItemIdentifier("browser-request-name-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserRequestNameCellView ?? {
                let view = BrowserRequestNameCellView()
                view.identifier = identifier
                return view
            }()
            cell.configure(title: item.title, subtitle: item.owner)
            return cell
        }

        let value: String
        switch columnID {
        case "request-owner":
            value = item.owner
        case "request-status":
            value = item.status
        case "request-duration":
            value = item.duration
        default:
            value = item.title
        }

        let identifier = NSUserInterfaceItemIdentifier("browser-request-text-\(columnID)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            view.textField = label
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
            ])
            return view
        }()

        cell.textField?.stringValue = value
        cell.textField?.font = columnID == "request-duration"
            ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            : NSFont.systemFont(ofSize: 12, weight: .medium)
        cell.textField?.textColor = columnID == "request-status" && (value == "Connected" || value == "Succeeded")
            ? NSColor(calibratedRed: 0.11, green: 0.53, blue: 0.34, alpha: 1)
            : .labelColor
        return cell
    }
}

private final class BrowserOutlineCellView: NSTableCellView {
    private let dotView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeView = BrowserBadgeView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4
        dotView.layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.88, alpha: 1).cgColor
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.identifier = NSUserInterfaceItemIdentifier("browser-outline-dot")
        dotView.setAccessibilityIdentifier("browser-outline-dot")

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        let labelStack = NSStackView(views: [titleLabel, subtitleLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.identifier = NSUserInterfaceItemIdentifier("browser-outline-label-stack")
        labelStack.setAccessibilityIdentifier("browser-outline-label-stack")

        addSubview(dotView)
        addSubview(labelStack)
        addSubview(badgeView)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),
            labelStack.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 10),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: badgeView.leadingAnchor, constant: -8),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView.widthAnchor.constraint(greaterThanOrEqualToConstant: 54)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, subtitle: String, badge: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        badgeView.configure(text: badge, tintColor: NSColor(calibratedRed: 0.10, green: 0.43, blue: 0.63, alpha: 1))
    }
}

private final class BrowserRequestNameCellView: NSTableCellView {
    private let iconView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 9
        iconView.layer?.backgroundColor = NSColor(calibratedRed: 0.84, green: 0.92, blue: 0.99, alpha: 1).cgColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.identifier = NSUserInterfaceItemIdentifier("browser-request-icon")
        iconView.setAccessibilityIdentifier("browser-request-icon")

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        let labelStack = NSStackView(views: [titleLabel, subtitleLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.identifier = NSUserInterfaceItemIdentifier("browser-request-label-stack")
        labelStack.setAccessibilityIdentifier("browser-request-label-stack")

        addSubview(iconView)
        addSubview(labelStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            labelStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
    }
}

private final class BrowserBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("browser-badge-view")
        setAccessibilityIdentifier("browser-badge-view")

        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.identifier = NSUserInterfaceItemIdentifier("browser-badge-label")
        label.setAccessibilityIdentifier("browser-badge-label")
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, tintColor: NSColor) {
        label.stringValue = text
        label.textColor = tintColor
        layer?.backgroundColor = tintColor.withAlphaComponent(0.14).cgColor
    }
}
