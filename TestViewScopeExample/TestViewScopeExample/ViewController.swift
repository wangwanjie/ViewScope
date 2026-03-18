import Cocoa

private struct DeviceRow {
    let name: String
    let status: String
    let build: String
    let latency: String
}

@MainActor
final class ViewController: NSViewController {
    private let splitView = NSSplitView()
    private let sidebarStack = NSStackView()
    private let detailStack = NSStackView()
    private let tableView = NSTableView()
    private let pageSelector = NSSegmentedControl(labels: ["Playground", "Data Browser"], trackingMode: .selectOne, target: nil, action: nil)
    private let pageTabs = NSTabView()
    private let statusField = NSTextField(labelWithString: "Ready for ViewScope inspection")
    private let syncProgress = NSProgressIndicator()
    private var hasConfiguredWindow = false

    private let sampleRows: [DeviceRow] = [
        .init(name: "Dashboard Shell", status: "Connected", build: "1.0.0 (18)", latency: "14 ms"),
        .init(name: "Preferences Sheet", status: "Idle", build: "1.0.0 (18)", latency: "22 ms"),
        .init(name: "Diff Preview", status: "Refreshing", build: "1.0.0 (18)", latency: "31 ms"),
        .init(name: "Highlight Overlay", status: "Queued", build: "1.0.0 (18)", latency: "45 ms")
    ]

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowIfNeeded()
    }

    private func buildInterface() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.99, alpha: 1).cgColor
        identify(view, "root-view")

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        identify(splitView, "root-split-view")
        view.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            splitView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        let sidebar = makeSidebar()
        let detail = makeDetailArea()
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(detail)
        sidebar.widthAnchor.constraint(equalToConstant: 280).isActive = true
    }

    private func makeSidebar() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.26, alpha: 1).cgColor
        container.layer?.cornerRadius = 28
        identify(container, "sidebar-container")

        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 14
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        identify(sidebarStack, "sidebar-stack")
        container.addSubview(sidebarStack)

        NSLayoutConstraint.activate([
            sidebarStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            sidebarStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            sidebarStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            sidebarStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18)
        ])

        let title = NSTextField(labelWithString: "Host Controls")
        title.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        title.textColor = .white
        identify(title, "sidebar-title")
        addSidebarView(title)

        let subtitle = NSTextField(labelWithString: "Everything here is intentionally inspectable from ViewScope.")
        subtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = NSColor(calibratedWhite: 1, alpha: 0.74)
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0
        identify(subtitle, "sidebar-subtitle")
        addSidebarView(subtitle)

        let hooksCard = makeSidebarCard(title: "Inspector Hooks", subtitle: "Debug-only switches and visual toggles.")
        let autoRefresh = identify(NSButton(checkboxWithTitle: "Auto refresh snapshots", target: nil, action: nil), "auto-refresh-toggle")
        autoRefresh.state = .on
        let highlights = identify(NSButton(checkboxWithTitle: "Keep overlay highlights enabled", target: nil, action: nil), "highlight-toggle")
        highlights.state = .on
        let modeControl = identify(
            NSSegmentedControl(labels: ["Live", "Snapshot", "Diff"], trackingMode: .selectOne, target: nil, action: nil),
            "capture-mode-control"
        )
        modeControl.selectedSegment = 0
        hooksCard.contentStack.addArrangedSubview(autoRefresh)
        hooksCard.contentStack.addArrangedSubview(highlights)
        hooksCard.contentStack.addArrangedSubview(modeControl)
        addSidebarView(hooksCard)

        let themeCard = makeSidebarCard(title: "Preview Theme", subtitle: "Useful for verifying colors, sliders, and nested cards.")
        let paletteRow = NSStackView()
        paletteRow.orientation = .horizontal
        paletteRow.alignment = .centerY
        paletteRow.spacing = 10
        let colorLabel = sidebarCaption("Accent")
        let accentWell = identify(NSColorWell(), "accent-color-well")
        accentWell.color = NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.88, alpha: 1)
        let layoutLabel = sidebarCaption("Density")
        let densitySlider = identify(NSSlider(value: 0.62, minValue: 0, maxValue: 1, target: nil, action: nil), "density-slider")
        paletteRow.addArrangedSubview(colorLabel)
        paletteRow.addArrangedSubview(accentWell)
        paletteRow.addArrangedSubview(layoutLabel)
        paletteRow.addArrangedSubview(densitySlider)
        themeCard.contentStack.addArrangedSubview(paletteRow)

        let sourcePopUp = identify(NSPopUpButton(), "data-source-popup")
        sourcePopUp.addItems(withTitles: ["Primary Window", "Settings Sheet", "Overlay Preview"])
        sourcePopUp.selectItem(at: 0)
        themeCard.contentStack.addArrangedSubview(sourcePopUp)

        let spinner = identify(NSProgressIndicator(), "sidebar-spinner")
        spinner.style = .spinning
        spinner.startAnimation(nil)
        themeCard.contentStack.addArrangedSubview(spinner)
        addSidebarView(themeCard)

        let badgeCard = makeSidebarCard(title: "Launch Summary", subtitle: "The host should appear in ViewScope as TestViewScopeExample.")
        let statusBadge = NSTextField(labelWithString: "DEBUG HOST")
        statusBadge.alignment = .center
        statusBadge.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        statusBadge.textColor = NSColor(calibratedRed: 0.1, green: 0.34, blue: 0.6, alpha: 1)
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 11
        statusBadge.layer?.backgroundColor = NSColor(calibratedRed: 0.84, green: 0.92, blue: 0.99, alpha: 1).cgColor
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)
        statusBadge.heightAnchor.constraint(equalToConstant: 22).isActive = true
        identify(statusBadge, "debug-host-badge")
        badgeCard.contentStack.addArrangedSubview(statusBadge)
        addSidebarView(badgeCard)

        return container
    }

    private func makeDetailArea() -> NSView {
        let container = NSView()
        identify(container, "detail-container")

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 16
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        identify(detailStack, "detail-stack")
        container.addSubview(detailStack)

        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            detailStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            detailStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            detailStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24)
        ])

        let heroCard = PanelView(
            title: "Inspector Playground",
            subtitle: "A purposely busy AppKit window for validating discovery, view capture, and identifiers."
        )
        identify(heroCard, "hero-card")
        let heroControls = NSStackView()
        heroControls.orientation = .horizontal
        heroControls.alignment = .centerY
        heroControls.spacing = 12
        let searchField = identify(NSSearchField(), "hero-search-field")
        searchField.placeholderString = "Search view ids, titles, or classes"
        pageSelector.target = self
        pageSelector.action = #selector(changePage(_:))
        pageSelector.selectedSegment = 0
        identify(pageSelector, "hero-page-selector")
        let refreshButton = identify(NSButton(title: "Refresh Snapshot", target: self, action: #selector(refreshSnapshot(_:))), "refresh-snapshot-button")
        let highlightButton = identify(NSButton(title: "Ping Overlay", target: self, action: #selector(pingOverlay(_:))), "ping-overlay-button")
        heroControls.addArrangedSubview(searchField)
        heroControls.addArrangedSubview(pageSelector)
        heroControls.addArrangedSubview(refreshButton)
        heroControls.addArrangedSubview(highlightButton)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        heroCard.contentStack.addArrangedSubview(heroControls)
        addDetailView(heroCard)

        let metricsRow = NSStackView()
        metricsRow.orientation = .horizontal
        metricsRow.alignment = .top
        metricsRow.spacing = 14
        identify(metricsRow, "metrics-row")
        metricsRow.distribution = .fillEqually
        metricsRow.addArrangedSubview(MetricCardView(title: "View Tree", value: "148", accentColor: NSColor(calibratedRed: 0.17, green: 0.45, blue: 0.78, alpha: 1)))
        metricsRow.addArrangedSubview(MetricCardView(title: "Connected Sessions", value: "3", accentColor: NSColor(calibratedRed: 0.14, green: 0.62, blue: 0.49, alpha: 1)))
        metricsRow.addArrangedSubview(MetricCardView(title: "Last Capture", value: "42 ms", accentColor: NSColor(calibratedRed: 0.89, green: 0.53, blue: 0.22, alpha: 1)))
        addDetailView(metricsRow)

        pageTabs.tabViewType = .noTabsNoBorder
        identify(pageTabs, "detail-page-tabs")
        let overviewItem = NSTabViewItem(identifier: "playground-page")
        overviewItem.label = "Playground"
        overviewItem.view = makeOverviewPage()
        let browserItem = NSTabViewItem(identifier: "browser-page")
        browserItem.label = "Data Browser"
        browserItem.view = makeBrowserPage()
        pageTabs.addTabViewItem(overviewItem)
        pageTabs.addTabViewItem(browserItem)
        pageTabs.selectTabViewItem(at: 0)
        pageTabs.heightAnchor.constraint(equalToConstant: 660).isActive = true
        addDetailView(pageTabs)

        let footerCard = PanelView(
            title: "Sync Status",
            subtitle: "Interactive controls below are useful when checking incremental updates."
        )
        identify(footerCard, "footer-card")
        let footerRow = NSStackView()
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 14
        identify(statusField, "footer-status-label")
        statusField.textColor = .secondaryLabelColor
        syncProgress.isIndeterminate = false
        syncProgress.minValue = 0
        syncProgress.maxValue = 100
        syncProgress.doubleValue = 72
        syncProgress.controlSize = .regular
        identify(syncProgress, "footer-progress-indicator")
        let reconnectButton = identify(NSButton(title: "Reconnect Host", target: self, action: #selector(refreshSnapshot(_:))), "reconnect-host-button")
        footerRow.addArrangedSubview(statusField)
        footerRow.addArrangedSubview(syncProgress)
        footerRow.addArrangedSubview(reconnectButton)
        syncProgress.widthAnchor.constraint(equalToConstant: 220).isActive = true
        footerCard.contentStack.addArrangedSubview(footerRow)
        addDetailView(footerCard)

        return container
    }

    private func makeOverviewPage() -> NSView {
        let container = NSView()
        identify(container, "playground-page")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        identify(stack, "playground-page-stack")
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])

        let mainRow = NSStackView()
        mainRow.orientation = .horizontal
        mainRow.alignment = .top
        mainRow.spacing = 16
        identify(mainRow, "main-row")

        let controlsCard = makeControlsCard()
        controlsCard.widthAnchor.constraint(equalToConstant: 390).isActive = true
        let previewCard = makePreviewCard()
        mainRow.addArrangedSubview(controlsCard)
        mainRow.addArrangedSubview(previewCard)
        addArranged(mainRow, to: stack)

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .top
        bottomRow.spacing = 16
        identify(bottomRow, "bottom-row")

        let tableCard = makeTableCard()
        let activityCard = makeActivityCard()
        activityCard.widthAnchor.constraint(equalToConstant: 320).isActive = true
        bottomRow.addArrangedSubview(tableCard)
        bottomRow.addArrangedSubview(activityCard)
        addArranged(bottomRow, to: stack)

        return container
    }

    private func makeBrowserPage() -> NSView {
        let browserPage = ComplexBrowserPageView()
        identify(browserPage, "browser-page-view")
        return browserPage
    }

    private func makeControlsCard() -> PanelView {
        let card = PanelView(
            title: "Control Matrix",
            subtitle: "Common AppKit inputs with stable identifiers for testing selection and property capture."
        )
        identify(card, "controls-card")

        let titleField = identify(NSTextField(string: "ViewScope Example"), "title-text-field")
        let secretField = identify(NSSecureTextField(string: "debug-token"), "secret-text-field")
        let refreshSlider = identify(NSSlider(value: 0.45, minValue: 0, maxValue: 1, target: nil, action: nil), "refresh-slider")
        let refreshValue = NSTextField(labelWithString: "45%")
        refreshValue.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let refreshRow = NSStackView(views: [refreshSlider, refreshValue])
        refreshRow.orientation = .horizontal
        refreshRow.alignment = .centerY
        refreshRow.spacing = 10

        let sizeControl = identify(
            NSSegmentedControl(labels: ["Compact", "Balanced", "Expanded"], trackingMode: .selectOne, target: nil, action: nil),
            "density-segmented-control"
        )
        sizeControl.selectedSegment = 1

        let surfacePopUp = identify(NSPopUpButton(), "surface-popup")
        surfacePopUp.addItems(withTitles: ["Desktop Shell", "Inspector Pane", "Floating Overlay"])
        surfacePopUp.selectItem(at: 1)

        let comboBox = identify(NSComboBox(), "runtime-combo-box")
        comboBox.addItems(withObjectValues: ["Debug", "Release", "Nightly"])
        comboBox.stringValue = "Debug"

        let checkbox = identify(NSButton(checkboxWithTitle: "Mirror highlight state to all windows", target: nil, action: nil), "mirror-checkbox")
        checkbox.state = .on

        let datePicker = identify(NSDatePicker(), "build-date-picker")
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.dateValue = Date(timeIntervalSinceNow: -3600)

        let colorWell = identify(NSColorWell(), "surface-color-well")
        colorWell.color = NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.75, alpha: 1)

        let grid = NSGridView(views: [
            [formLabel("Title"), titleField],
            [formLabel("Auth Token"), secretField],
            [formLabel("Refresh Rate"), refreshRow],
            [formLabel("Density"), sizeControl],
            [formLabel("Surface"), surfacePopUp],
            [formLabel("Runtime"), comboBox],
            [formLabel("Options"), checkbox],
            [formLabel("Build Time"), datePicker],
            [formLabel("Accent"), colorWell]
        ])
        identify(grid, "controls-grid")
        grid.rowSpacing = 10
        grid.columnSpacing = 16
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 92
        card.contentStack.addArrangedSubview(grid)

        return card
    }

    private func makePreviewCard() -> PanelView {
        let card = PanelView(
            title: "Nested Preview Canvas",
            subtitle: "Custom views with badges, cards, and charts to inspect hierarchy depth."
        )
        identify(card, "preview-card")

        let canvas = PreviewCanvasView()
        identify(canvas, "preview-canvas")
        canvas.heightAnchor.constraint(equalToConstant: 270).isActive = true
        card.contentStack.addArrangedSubview(canvas)

        let footerRow = NSStackView()
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 12
        identify(footerRow, "preview-footer-row")

        let levelIndicator = identify(NSLevelIndicator(), "preview-level-indicator")
        levelIndicator.levelIndicatorStyle = .continuousCapacity
        levelIndicator.maxValue = 10
        levelIndicator.doubleValue = 7
        levelIndicator.warningValue = 8
        levelIndicator.criticalValue = 9
        levelIndicator.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let stepper = identify(NSStepper(), "preview-stepper")
        stepper.minValue = 1
        stepper.maxValue = 12
        stepper.increment = 1
        stepper.doubleValue = 4

        let tokens = identify(NSTokenField(), "preview-token-field")
        tokens.objectValue = ["appkit", "debug", "hierarchy", "overlay"]

        footerRow.addArrangedSubview(levelIndicator)
        footerRow.addArrangedSubview(stepper)
        footerRow.addArrangedSubview(tokens)
        card.contentStack.addArrangedSubview(footerRow)

        return card
    }

    private func makeTableCard() -> PanelView {
        let card = PanelView(
            title: "Build Sessions",
            subtitle: "A small table view for checking cell hierarchies and row selection."
        )
        identify(card, "table-card")

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Surface"
        nameColumn.width = 180

        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.title = "Status"
        statusColumn.width = 120

        let buildColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("build"))
        buildColumn.title = "Build"
        buildColumn.width = 110

        let latencyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("latency"))
        latencyColumn.title = "Latency"
        latencyColumn.width = 90

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(statusColumn)
        tableView.addTableColumn(buildColumn)
        tableView.addTableColumn(latencyColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 34
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self
        identify(tableView, "sessions-table-view")

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        identify(scrollView, "sessions-table-scroll")
        scrollView.heightAnchor.constraint(equalToConstant: 205).isActive = true

        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        card.contentStack.addArrangedSubview(scrollView)
        return card
    }

    private func makeActivityCard() -> PanelView {
        let card = PanelView(
            title: "Activity Feed",
            subtitle: "Mixed labels, pills, and buttons for selection testing."
        )
        identify(card, "activity-card")

        let tagRow = NSStackView()
        tagRow.orientation = .horizontal
        tagRow.alignment = .centerY
        tagRow.spacing = 8
        identify(tagRow, "activity-tag-row")
        tagRow.addArrangedSubview(TagView(title: "Discovery", tintColor: NSColor(calibratedRed: 0.17, green: 0.46, blue: 0.8, alpha: 1)))
        tagRow.addArrangedSubview(TagView(title: "Capture", tintColor: NSColor(calibratedRed: 0.15, green: 0.64, blue: 0.5, alpha: 1)))
        tagRow.addArrangedSubview(TagView(title: "Overlay", tintColor: NSColor(calibratedRed: 0.88, green: 0.54, blue: 0.18, alpha: 1)))
        card.contentStack.addArrangedSubview(tagRow)

        let noteStack = NSStackView()
        noteStack.orientation = .vertical
        noteStack.spacing = 10
        identify(noteStack, "activity-note-stack")
        noteStack.addArrangedSubview(feedRow(title: "Discovery beacon published", detail: "Broadcasting local host metadata over DistributedNotificationCenter."))
        noteStack.addArrangedSubview(feedRow(title: "Inspector selection updated", detail: "Highlight overlay can now follow the selected node automatically."))
        noteStack.addArrangedSubview(feedRow(title: "Snapshot cached", detail: "Latest hierarchy diff stored for manual comparison."))
        card.contentStack.addArrangedSubview(noteStack)

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10
        identify(actionRow, "activity-action-row")
        let secondaryButton = identify(NSButton(title: "Open Drawer", target: self, action: #selector(pingOverlay(_:))), "open-drawer-button")
        let badge = NSTextField(labelWithString: "3 pending")
        badge.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        badge.textColor = .secondaryLabelColor
        identify(badge, "pending-badge")
        actionRow.addArrangedSubview(secondaryButton)
        actionRow.addArrangedSubview(badge)
        card.contentStack.addArrangedSubview(actionRow)

        return card
    }

    private func feedRow(title: String, detail: String) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
        container.layer?.cornerRadius = 14
        identify(container, "feed-row-\(title.replacingOccurrences(of: " ", with: "-").lowercased())")

        let marker = NSView()
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.88, alpha: 1).cgColor
        marker.layer?.cornerRadius = 4
        identify(marker, "feed-row-marker")

        let titleField = NSTextField(labelWithString: title)
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let detailField = NSTextField(labelWithString: detail)
        detailField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        detailField.textColor = .secondaryLabelColor
        detailField.maximumNumberOfLines = 0
        identify(titleField, "feed-row-title")
        identify(detailField, "feed-row-detail")

        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.translatesAutoresizingMaskIntoConstraints = false

        marker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(marker)
        container.addSubview(labels)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true

        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            marker.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            marker.widthAnchor.constraint(equalToConstant: 8),
            marker.heightAnchor.constraint(equalToConstant: 44),
            labels.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 12),
            labels.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            labels.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        return container
    }

    @objc private func refreshSnapshot(_ sender: Any?) {
        statusField.stringValue = "Snapshot refreshed at \(Self.timeFormatter.string(from: Date()))"
        syncProgress.doubleValue = min(syncProgress.doubleValue + 9, syncProgress.maxValue)
    }

    @objc private func changePage(_ sender: Any?) {
        let selectedIndex = max(pageSelector.selectedSegment, 0)
        pageTabs.selectTabViewItem(at: selectedIndex)
        statusField.stringValue = selectedIndex == 0
            ? "Switched to the Playground page"
            : "Switched to the Data Browser page"
    }

    @objc private func pingOverlay(_ sender: Any?) {
        statusField.stringValue = "Overlay ping sent at \(Self.timeFormatter.string(from: Date()))"
    }

    private func configureWindowIfNeeded() {
        guard !hasConfiguredWindow, let window = view.window else { return }
        hasConfiguredWindow = true
        window.title = "TestViewScopeExample"
        window.setContentSize(NSSize(width: 1420, height: 940))
        window.minSize = NSSize(width: 1280, height: 820)
    }

    private func addSidebarView(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        sidebarStack.addArrangedSubview(child)
    }

    private func addDetailView(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        detailStack.addArrangedSubview(child)
    }

    private func addArranged(_ child: NSView, to stackView: NSStackView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        stackView.addArrangedSubview(child)
    }

    private func makeSidebarCard(title: String, subtitle: String) -> PanelView {
        let card = PanelView(title: title, subtitle: subtitle)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.1).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor
        card.titleLabel.textColor = .white
        card.subtitleLabel?.textColor = NSColor(calibratedWhite: 1, alpha: 0.66)
        return card
    }

    private func sidebarCaption(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.72)
        return label
    }

    private func formLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    @discardableResult
    private func identify<T: NSView>(_ view: T, _ rawIdentifier: String) -> T {
        let identifier = NSUserInterfaceItemIdentifier(rawIdentifier)
        view.identifier = identifier
        view.setAccessibilityIdentifier(rawIdentifier)
        return view
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

extension ViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        sampleRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = sampleRows[row]
        let value: String

        switch tableColumn?.identifier.rawValue {
        case "status":
            value = item.status
        case "build":
            value = item.build
        case "latency":
            value = item.latency
        default:
            value = item.name
        }

        let identifier = NSUserInterfaceItemIdentifier("cell-\(tableColumn?.identifier.rawValue ?? "name")")
        let cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8)
            ])
            return cell
        }()

        cellView.textField?.stringValue = value
        cellView.textField?.font = tableColumn?.identifier.rawValue == "name"
            ? NSFont.systemFont(ofSize: 12, weight: .semibold)
            : NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        cellView.textField?.textColor = tableColumn?.identifier.rawValue == "status" && value == "Connected"
            ? NSColor(calibratedRed: 0.12, green: 0.53, blue: 0.33, alpha: 1)
            : .labelColor
        return cellView
    }
}
