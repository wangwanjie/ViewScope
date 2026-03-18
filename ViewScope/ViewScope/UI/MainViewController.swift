import AppKit
import Combine
import SnapKit
import ViewScopeServer

@MainActor
final class MainViewController: NSViewController {
    private let store: WorkspaceStore
    private var cancellables = Set<AnyCancellable>()

    private let headerView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let connectionBadge = CapsuleBadgeView()
    private let searchField = NSSearchField(frame: .zero)
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let highlightButton = NSButton(title: "", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let liveHostsLabel = NSTextField(labelWithString: "")
    private let recentHostsLabel = NSTextField(labelWithString: "")
    private let hierarchyTitleLabel = NSTextField(labelWithString: "")
    private let inspectorTitleLabel = NSTextField(labelWithString: "")

    private let contentContainer = NSView()
    private let workspaceSplitView = NSSplitView()
    private let sidebarView = NSView()
    private let captureSplitView = NSSplitView()
    private let hierarchyView = NSView()
    private let detailView = NSView()
    private let emptyStateView = IntegrationGuideView()

    private let liveHostsTableView = NSTableView()
    private let recentHostsTableView = NSTableView()
    private let liveHostsScrollView = NSScrollView()
    private let recentHostsScrollView = NSScrollView()

    private let hierarchyOutlineView = NSOutlineView()
    private let hierarchyScrollView = NSScrollView()
    private let previewView = ScreenshotPreviewView()
    private let detailScrollView = NSScrollView()
    private let detailStackView = NSStackView()
    private let previewHitTester = PreviewHitTester()

    private var outlineRoots: [OutlineItem] = []
    private var visibleOutlineRoots: [OutlineItem] = []
    private var liveHosts: [ViewScopeHostAnnouncement] = []
    private var recentHosts: [RecentHostRecord] = []
    private var searchQuery: String = ""

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        applyLocalization()
        bindStore()
        store.start()
        applyCurrentStoreState()
    }

    private func buildUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.97, alpha: 1).cgColor

        headerView.material = .headerView
        headerView.blendingMode = .withinWindow
        headerView.state = .active
        headerView.wantsLayer = true
        headerView.layer?.borderWidth = 1
        headerView.layer?.borderColor = NSColor(calibratedRed: 0.84, green: 0.88, blue: 0.91, alpha: 1).cgColor

        titleLabel.font = NSFont(name: "Avenir Next Demi Bold", size: 28) ?? .systemFont(ofSize: 28, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping

        connectionBadge.text = L10n.idleBadge
        connectionBadge.applyStyle(
            textColor: NSColor(calibratedRed: 0.11, green: 0.43, blue: 0.63, alpha: 1),
            backgroundColor: NSColor(calibratedRed: 0.86, green: 0.94, blue: 0.98, alpha: 1)
        )

        searchField.delegate = self
        previewView.onCanvasClick = { [weak self] canvasPoint in
            self?.selectNodeFromPreview(at: canvasPoint)
        }

        refreshButton.target = self
        refreshButton.action = #selector(refreshCapture(_:))
        highlightButton.target = self
        highlightButton.action = #selector(highlightSelection(_:))
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectHost(_:))

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4

        let buttonsStack = NSStackView(views: [refreshButton, highlightButton, disconnectButton])
        buttonsStack.orientation = .horizontal
        buttonsStack.alignment = .centerY
        buttonsStack.spacing = 10

        headerView.addSubview(titleStack)
        headerView.addSubview(connectionBadge)
        headerView.addSubview(searchField)
        headerView.addSubview(buttonsStack)

        contentContainer.addSubview(sidebarView)
        contentContainer.addSubview(captureSplitView)
        contentContainer.addSubview(emptyStateView)

        workspaceSplitView.isVertical = true
        workspaceSplitView.dividerStyle = .thin
        captureSplitView.isVertical = true
        captureSplitView.dividerStyle = .thin

        buildSidebar()
        buildHierarchyPanel()
        buildDetailPanel()

        captureSplitView.addArrangedSubview(hierarchyView)
        captureSplitView.addArrangedSubview(detailView)

        contentContainer.addSubview(sidebarView)
        contentContainer.addSubview(captureSplitView)
        contentContainer.addSubview(emptyStateView)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        view.addSubview(headerView)
        view.addSubview(contentContainer)
        view.addSubview(statusLabel)

        headerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }
        titleStack.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(24)
            make.top.equalToSuperview().offset(18)
            make.bottom.equalToSuperview().inset(18)
            make.trailing.lessThanOrEqualTo(connectionBadge.snp.leading).offset(-12)
        }
        connectionBadge.snp.makeConstraints { make in
            make.centerY.equalTo(titleLabel)
            make.leading.greaterThanOrEqualTo(titleStack.snp.trailing).offset(12)
            make.width.greaterThanOrEqualTo(84)
            make.height.equalTo(24)
        }
        searchField.snp.makeConstraints { make in
            make.leading.equalTo(connectionBadge.snp.trailing).offset(16)
            make.centerY.equalTo(titleLabel)
            make.width.equalTo(360)
        }
        buttonsStack.snp.makeConstraints { make in
            make.leading.equalTo(searchField.snp.trailing).offset(14)
            make.trailing.equalToSuperview().inset(24)
            make.centerY.equalTo(titleLabel)
        }

        contentContainer.snp.makeConstraints { make in
            make.top.equalTo(headerView.snp.bottom)
            make.leading.trailing.equalToSuperview().inset(18)
        }
        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(contentContainer.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview().inset(18)
            make.height.equalTo(18)
        }

        sidebarView.snp.makeConstraints { make in
            make.top.bottom.leading.equalToSuperview()
            make.width.equalTo(284)
        }
        captureSplitView.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview()
            make.leading.equalTo(sidebarView.snp.trailing).offset(18)
        }
        emptyStateView.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview()
            make.leading.equalTo(sidebarView.snp.trailing).offset(18)
        }

        emptyStateView.isHidden = false
        captureSplitView.isHidden = true
    }

    private func buildSidebar() {
        sidebarView.wantsLayer = true
        sidebarView.layer?.cornerRadius = 24
        sidebarView.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.24, alpha: 1).cgColor

        configureSidebarSectionLabel(liveHostsLabel)
        configureSidebarSectionLabel(recentHostsLabel)

        configure(tableView: liveHostsTableView, action: #selector(handleLiveHostSelection(_:)))
        configure(tableView: recentHostsTableView, action: #selector(handleRecentHostSelection(_:)))

        liveHostsScrollView.drawsBackground = false
        liveHostsScrollView.borderType = .noBorder
        liveHostsScrollView.hasVerticalScroller = true
        liveHostsScrollView.documentView = liveHostsTableView

        recentHostsScrollView.drawsBackground = false
        recentHostsScrollView.borderType = .noBorder
        recentHostsScrollView.hasVerticalScroller = true
        recentHostsScrollView.documentView = recentHostsTableView

        let liveCard = sidebarCardView(containing: liveHostsScrollView)
        let recentCard = sidebarCardView(containing: recentHostsScrollView)

        sidebarView.addSubview(liveHostsLabel)
        sidebarView.addSubview(liveCard)
        sidebarView.addSubview(recentHostsLabel)
        sidebarView.addSubview(recentCard)

        liveHostsLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(18)
        }
        liveCard.snp.makeConstraints { make in
            make.top.equalTo(liveHostsLabel.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(228)
        }
        recentHostsLabel.snp.makeConstraints { make in
            make.top.equalTo(liveCard.snp.bottom).offset(18)
            make.leading.trailing.equalToSuperview().inset(18)
        }
        recentCard.snp.makeConstraints { make in
            make.top.equalTo(recentHostsLabel.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview().inset(16)
            make.height.greaterThanOrEqualTo(320)
        }
    }

    private func buildHierarchyPanel() {
        hierarchyView.wantsLayer = true
        hierarchyView.layer?.cornerRadius = 24
        hierarchyView.layer?.backgroundColor = NSColor.white.cgColor

        configureSectionTitleLabel(hierarchyTitleLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HierarchyColumn"))
        column.title = L10n.hierarchy
        hierarchyOutlineView.addTableColumn(column)
        hierarchyOutlineView.outlineTableColumn = column
        hierarchyOutlineView.headerView = nil
        hierarchyOutlineView.rowHeight = 52
        hierarchyOutlineView.focusRingType = .none
        hierarchyOutlineView.selectionHighlightStyle = .sourceList
        hierarchyOutlineView.delegate = self
        hierarchyOutlineView.dataSource = self

        hierarchyScrollView.drawsBackground = false
        hierarchyScrollView.borderType = .noBorder
        hierarchyScrollView.hasVerticalScroller = true
        hierarchyScrollView.documentView = hierarchyOutlineView

        hierarchyView.addSubview(hierarchyTitleLabel)
        hierarchyView.addSubview(hierarchyScrollView)

        hierarchyTitleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(18)
        }
        hierarchyScrollView.snp.makeConstraints { make in
            make.top.equalTo(hierarchyTitleLabel.snp.bottom).offset(12)
            make.leading.trailing.bottom.equalToSuperview().inset(12)
        }
        hierarchyView.snp.makeConstraints { make in
            make.width.equalTo(420)
        }
    }

    private func buildDetailPanel() {
        detailView.wantsLayer = true
        detailView.layer?.cornerRadius = 24
        detailView.layer?.backgroundColor = NSColor.white.cgColor

        configureSectionTitleLabel(inspectorTitleLabel)
        detailStackView.orientation = .vertical
        detailStackView.alignment = .leading
        detailStackView.spacing = 14

        detailScrollView.drawsBackground = false
        detailScrollView.borderType = .noBorder
        detailScrollView.hasVerticalScroller = true
        detailScrollView.documentView = detailStackView

        detailView.addSubview(inspectorTitleLabel)
        detailView.addSubview(detailScrollView)

        inspectorTitleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(18)
        }
        detailScrollView.snp.makeConstraints { make in
            make.top.equalTo(inspectorTitleLabel.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview().inset(12)
        }
        detailStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.width.equalTo(detailScrollView.contentView)
        }
    }

    private func configure(tableView: NSTableView, action: Selector) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Cell"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.focusRingType = .none
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = action
    }

    private func bindStore() {
        store.$discoveredHosts
            .receive(on: RunLoop.main)
            .sink { [weak self] hosts in
                self?.liveHosts = hosts
                self?.liveHostsTableView.reloadData()
            }
            .store(in: &cancellables)

        store.$recentHosts
            .receive(on: RunLoop.main)
            .sink { [weak self] records in
                self?.recentHosts = records
                self?.recentHostsTableView.reloadData()
            }
            .store(in: &cancellables)

        store.$capture
            .receive(on: RunLoop.main)
            .sink { [weak self] capture in
                self?.updateCapture(capture)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(store.$connectionState, store.$selectedNodeDetail, store.$captureInsight, store.$errorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] connectionState, detail, insight, errorMessage in
                self?.renderDetail(detail: detail, insight: insight)
                self?.updateChrome(connectionState: connectionState, errorMessage: errorMessage)
            }
            .store(in: &cancellables)

        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyLocalization()
                self.renderDetail(detail: self.store.selectedNodeDetail, insight: self.store.captureInsight)
                self.updateChrome(connectionState: self.store.connectionState, errorMessage: self.store.errorMessage)
                self.liveHostsTableView.reloadData()
                self.recentHostsTableView.reloadData()
                self.hierarchyOutlineView.reloadData()
            }
            .store(in: &cancellables)

        applyCurrentStoreState()
    }

    private func applyLocalization() {
        titleLabel.stringValue = L10n.appName
        subtitleLabel.stringValue = L10n.mainSubtitle
        refreshButton.title = L10n.refresh
        highlightButton.title = L10n.highlight
        disconnectButton.title = L10n.disconnect
        searchField.placeholderString = L10n.searchPlaceholder
        liveHostsLabel.stringValue = L10n.liveHosts
        recentHostsLabel.stringValue = L10n.recentSessions
        hierarchyTitleLabel.stringValue = L10n.hierarchy
        inspectorTitleLabel.stringValue = L10n.inspector
        previewView.placeholderText = L10n.previewPlaceholder
    }

    private func applyCurrentStoreState() {
        liveHosts = store.discoveredHosts
        recentHosts = store.recentHosts
        liveHostsTableView.reloadData()
        recentHostsTableView.reloadData()
        updateCapture(store.capture)
        renderDetail(detail: store.selectedNodeDetail, insight: store.captureInsight)
        updateChrome(connectionState: store.connectionState, errorMessage: store.errorMessage)
    }

    private func updateCapture(_ capture: ViewScopeCapturePayload?) {
        emptyStateView.isHidden = capture != nil
        captureSplitView.isHidden = capture == nil
        rebuildOutlineTree(from: capture)
        refreshButton.isEnabled = store.connectionState.activeHost != nil
        disconnectButton.isEnabled = store.connectionState.activeHost != nil
    }

    private func rebuildOutlineTree(from capture: ViewScopeCapturePayload?) {
        guard let capture else {
            outlineRoots = []
            visibleOutlineRoots = []
            hierarchyOutlineView.reloadData()
            return
        }

        outlineRoots = capture.rootNodeIDs.compactMap { OutlineItem.make(nodeID: $0, nodes: capture.nodes) }
        visibleOutlineRoots = filterOutlineTree(roots: outlineRoots, query: searchQuery)
        hierarchyOutlineView.reloadData()
        hierarchyOutlineView.expandItem(nil, expandChildren: searchQuery.isEmpty == false)

        if let selectedNodeID = store.selectedNodeID,
           let item = findItem(withID: selectedNodeID, in: visibleOutlineRoots) {
            expandAncestors(of: item)
            let row = hierarchyOutlineView.row(forItem: item)
            if row >= 0 {
                hierarchyOutlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                hierarchyOutlineView.scrollRowToVisible(row)
            }
        } else if let firstRoot = visibleOutlineRoots.first {
            hierarchyOutlineView.expandItem(firstRoot)
        }
    }

    private func renderDetail(detail: ViewScopeNodeDetailPayload?, insight: CaptureHistoryInsight) {
        detailStackView.arrangedSubviews.forEach { view in
            detailStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let capture = store.capture else { return }

        addDetailSection(summaryCard(capture: capture, insight: insight))
        addDetailSection(previewCard(detail: detail))

        if let detail {
            addDetailSection(textListCard(title: L10n.ancestry, rows: detail.ancestry))
            for section in detail.sections {
                addDetailSection(propertyCard(section: section))
            }
            addDetailSection(textListCard(title: L10n.constraints, rows: detail.constraints))
        } else {
            addDetailSection(placeholderCard())
        }
    }

    private func updateChrome(connectionState: WorkspaceConnectionState, errorMessage: String?) {
        connectionBadge.text = {
            switch connectionState {
            case .idle:
                return L10n.idleBadge
            case .connecting:
                return L10n.linkingBadge
            case .connected:
                return L10n.liveBadge
            case .failed:
                return L10n.errorBadge
            }
        }()
        let textColor: NSColor = {
            switch connectionState {
            case .connected:
                return NSColor(calibratedRed: 0.06, green: 0.48, blue: 0.32, alpha: 1)
            case .failed:
                return NSColor(calibratedRed: 0.66, green: 0.19, blue: 0.19, alpha: 1)
            default:
                return NSColor(calibratedRed: 0.11, green: 0.43, blue: 0.63, alpha: 1)
            }
        }()
        let backgroundColor: NSColor = {
            switch connectionState {
            case .connected:
                return NSColor(calibratedRed: 0.88, green: 0.96, blue: 0.91, alpha: 1)
            case .failed:
                return NSColor(calibratedRed: 0.99, green: 0.90, blue: 0.90, alpha: 1)
            default:
                return NSColor(calibratedRed: 0.86, green: 0.94, blue: 0.98, alpha: 1)
            }
        }()
        connectionBadge.applyStyle(textColor: textColor, backgroundColor: backgroundColor)
        statusLabel.stringValue = errorMessage ?? connectionState.statusText
        refreshButton.isEnabled = store.connectionState.activeHost != nil
        disconnectButton.isEnabled = store.connectionState.activeHost != nil
        highlightButton.isEnabled = store.selectedNodeDetail != nil
    }

    private func addDetailSection(_ view: NSView) {
        detailStackView.addArrangedSubview(view)
        view.snp.makeConstraints { make in
            make.width.equalTo(detailStackView)
        }
    }

    private func summaryCard(capture: ViewScopeCapturePayload, insight: CaptureHistoryInsight) -> NSView {
        let card = makeCardView()
        let title = cardHeaderLabel(L10n.sessionSummary)
        let rows = [
            infoRow(title: L10n.detailHost, value: capture.host.displayName),
            infoRow(title: L10n.detailBundle, value: capture.host.bundleIdentifier),
            infoRow(title: L10n.detailVersion, value: L10n.hostVersionAndBuild(capture.host.version, capture.host.build)),
            infoRow(title: L10n.detailNodes, value: String(capture.summary.nodeCount)),
            infoRow(title: L10n.detailWindows, value: String(capture.summary.windowCount)),
            infoRow(title: L10n.detailCapture, value: L10n.captureDuration(capture.summary.captureDurationMilliseconds)),
            infoRow(title: L10n.detailHistory, value: L10n.historySummary(count: insight.totalCaptures, averageMilliseconds: insight.averageDurationMilliseconds))
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        card.addSubview(title)
        card.addSubview(stack)
        title.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(18)
        }
        stack.snp.makeConstraints { make in
            make.top.equalTo(title.snp.bottom).offset(14)
            make.leading.trailing.bottom.equalToSuperview().inset(18)
        }
        return card
    }

    private func previewCard(detail: ViewScopeNodeDetailPayload?) -> NSView {
        let card = makeCardView()
        let title = cardHeaderLabel(L10n.canvasPreview)
        previewView.image = detail.flatMap { payload in
            guard let base64 = payload.screenshotPNGBase64,
                  let data = Data(base64Encoded: base64) else { return nil }
            return NSImage(data: data)
        }
        previewView.canvasSize = detail?.screenshotSize ?? .zero
        previewView.highlightRect = detail?.highlightedRect ?? .zero

        card.addSubview(title)
        card.addSubview(previewView)
        title.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(18)
        }
        previewView.snp.makeConstraints { make in
            make.top.equalTo(title.snp.bottom).offset(12)
            make.leading.trailing.bottom.equalToSuperview().inset(18)
            make.height.equalTo(280)
        }
        return card
    }

    private func propertyCard(section: ViewScopePropertySection) -> NSView {
        let card = makeCardView()
        let title = cardHeaderLabel(section.title)
        let rows = section.items.map { infoRow(title: $0.title, value: $0.value) }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        card.addSubview(title)
        card.addSubview(stack)
        title.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(18)
        }
        stack.snp.makeConstraints { make in
            make.top.equalTo(title.snp.bottom).offset(14)
            make.leading.trailing.bottom.equalToSuperview().inset(18)
        }
        return card
    }

    private func textListCard(title: String, rows: [String]) -> NSView {
        let card = makeCardView()
        let heading = cardHeaderLabel(title)
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.31, alpha: 1)
        textView.string = rows.joined(separator: "\n")
        textView.textContainerInset = NSSize(width: 0, height: 6)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        card.addSubview(heading)
        card.addSubview(scrollView)
        heading.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(18)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(heading.snp.bottom).offset(12)
            make.leading.trailing.bottom.equalToSuperview().inset(18)
            make.height.equalTo(120)
        }
        return card
    }

    private func placeholderCard() -> NSView {
        let card = makeCardView()
        let label = NSTextField(wrappingLabelWithString: L10n.pickNodePlaceholder)
        label.textColor = .secondaryLabelColor
        card.addSubview(label)
        label.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(18)
        }
        return card
    }

    private func makeCardView() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.backgroundColor = NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(calibratedRed: 0.87, green: 0.90, blue: 0.92, alpha: 1).cgColor
        return card
    }

    private func configureSidebarSectionLabel(_ label: NSTextField) {
        label.font = NSFont(name: "Avenir Next Demi Bold", size: 13) ?? .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor(calibratedRed: 0.83, green: 0.88, blue: 0.91, alpha: 1)
    }

    private func sidebarCardView(containing contentView: NSView) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.29, alpha: 1).cgColor
        card.addSubview(contentView)
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(10)
        }
        return card
    }

    private func configureSectionTitleLabel(_ label: NSTextField) {
        label.font = NSFont(name: "Avenir Next Demi Bold", size: 16) ?? .systemFont(ofSize: 16, weight: .semibold)
    }

    private func cardHeaderLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont(name: "Avenir Next Demi Bold", size: 14) ?? .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func infoRow(title: String, value: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.snp.makeConstraints { make in
            make.width.equalTo(116)
        }

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.textColor = NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.29, alpha: 1)
        valueLabel.maximumNumberOfLines = 4

        let row = NSStackView(views: [titleLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    private func filterOutlineTree(roots: [OutlineItem], query: String) -> [OutlineItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return roots }
        let lowercasedQuery = trimmed.lowercased()
        return roots.compactMap { $0.filtered(matching: lowercasedQuery) }
    }

    private func findItem(withID nodeID: String, in roots: [OutlineItem]) -> OutlineItem? {
        for root in roots {
            if root.node.id == nodeID {
                return root
            }
            if let child = findItem(withID: nodeID, in: root.children) {
                return child
            }
        }
        return nil
    }

    private func expandAncestors(of item: OutlineItem) {
        var current = item.parent
        while let value = current {
            hierarchyOutlineView.expandItem(value)
            current = value.parent
        }
    }

    @objc private func refreshCapture(_ sender: Any?) {
        Task { await store.refreshCapture() }
    }

    @objc private func highlightSelection(_ sender: Any?) {
        Task { await store.highlightCurrentSelection() }
    }

    @objc private func disconnectHost(_ sender: Any?) {
        store.disconnect()
    }

    @objc private func handleLiveHostSelection(_ sender: Any?) {
        let row = liveHostsTableView.clickedRow >= 0 ? liveHostsTableView.clickedRow : liveHostsTableView.selectedRow
        guard liveHosts.indices.contains(row) else { return }
        Task { await store.connect(to: liveHosts[row]) }
        liveHostsTableView.deselectAll(nil)
    }

    @objc private func handleRecentHostSelection(_ sender: Any?) {
        let row = recentHostsTableView.clickedRow >= 0 ? recentHostsTableView.clickedRow : recentHostsTableView.selectedRow
        guard recentHosts.indices.contains(row) else { return }
        Task { await store.connect(using: recentHosts[row]) }
        recentHostsTableView.deselectAll(nil)
    }

    private func selectNodeFromPreview(at canvasPoint: CGPoint) {
        guard let capture = store.capture,
              let nodeID = previewHitTester.deepestNodeID(at: canvasPoint, in: capture) else {
            return
        }

        let selectionTriggered = revealNodeInHierarchy(nodeID, capture: capture)
        guard selectionTriggered == false, store.selectedNodeID != nodeID else { return }
        Task { await store.selectNode(withID: nodeID) }
    }

    @discardableResult
    private func revealNodeInHierarchy(_ nodeID: String, capture: ViewScopeCapturePayload) -> Bool {
        if let item = findItem(withID: nodeID, in: visibleOutlineRoots) {
            return selectOutlineItem(item)
        }

        guard !searchQuery.isEmpty else { return false }
        searchQuery = ""
        searchField.stringValue = ""
        rebuildOutlineTree(from: capture)

        if let item = findItem(withID: nodeID, in: visibleOutlineRoots) {
            return selectOutlineItem(item)
        }
        return false
    }

    private func selectOutlineItem(_ item: OutlineItem) -> Bool {
        expandAncestors(of: item)
        let row = hierarchyOutlineView.row(forItem: item)
        guard row >= 0 else { return false }
        let selectionChanged = hierarchyOutlineView.selectedRow != row
        hierarchyOutlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        hierarchyOutlineView.scrollRowToVisible(row)
        return selectionChanged
    }
}

extension MainViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchQuery = searchField.stringValue
        rebuildOutlineTree(from: store.capture)
    }
}

extension MainViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == liveHostsTableView {
            return max(liveHosts.count, 1)
        }
        if tableView == recentHostsTableView {
            return max(recentHosts.count, 1)
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SessionCell")
        let cellView: SessionCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? SessionCellView {
            cellView = reused
        } else {
            cellView = SessionCellView(frame: .zero)
            cellView.identifier = identifier
        }

        if tableView == liveHostsTableView {
            if liveHosts.isEmpty {
                cellView.configure(title: L10n.noHostsOnlineTitle, subtitle: L10n.noHostsOnlineSubtitle, detail: nil, accentColor: .systemBlue)
            } else {
                let host = liveHosts[row]
                cellView.configure(
                    title: host.displayName,
                    subtitle: host.bundleIdentifier,
                    detail: L10n.recentHostDetail(version: host.version, processIdentifier: host.processIdentifier),
                    accentColor: .systemTeal
                )
            }
        } else {
            if recentHosts.isEmpty {
                cellView.configure(title: L10n.noRecentSessionsTitle, subtitle: L10n.noRecentSessionsSubtitle, detail: nil, accentColor: .systemOrange)
            } else {
                let record = recentHosts[row]
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                formatter.locale = AppLocalization.shared.locale
                let detail = formatter.localizedString(for: record.lastConnectedAt, relativeTo: Date())
                cellView.configure(title: record.displayName, subtitle: record.bundleIdentifier, detail: detail, accentColor: .systemOrange)
            }
        }

        return cellView
    }
}

extension MainViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? OutlineItem)
        return node?.children.count ?? visibleOutlineRoots.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? OutlineItem else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = item as? OutlineItem
        return node?.children[index] ?? visibleOutlineRoots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? OutlineItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HierarchyCell")
        let cellView: HierarchyCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? HierarchyCellView {
            cellView = reused
        } else {
            cellView = HierarchyCellView(frame: .zero)
            cellView.identifier = identifier
        }
        cellView.configure(with: node.node)
        return cellView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = hierarchyOutlineView.selectedRow
        guard row >= 0,
              let item = hierarchyOutlineView.item(atRow: row) as? OutlineItem else {
            Task { await store.selectNode(withID: nil) }
            return
        }
        Task { await store.selectNode(withID: item.node.id) }
    }
}

private final class OutlineItem: NSObject {
    let node: ViewScopeHierarchyNode
    weak var parent: OutlineItem?
    var children: [OutlineItem]

    init(node: ViewScopeHierarchyNode, children: [OutlineItem]) {
        self.node = node
        self.children = children
        super.init()
        self.children.forEach { $0.parent = self }
    }

    static func make(nodeID: String, nodes: [String: ViewScopeHierarchyNode]) -> OutlineItem? {
        guard let node = nodes[nodeID] else { return nil }
        let children = node.childIDs.compactMap { make(nodeID: $0, nodes: nodes) }
        return OutlineItem(node: node, children: children)
    }

    func filtered(matching query: String) -> OutlineItem? {
        let children = self.children.compactMap { $0.filtered(matching: query) }
        if matches(query: query) || !children.isEmpty {
            return OutlineItem(node: node, children: children)
        }
        return nil
    }

    private func matches(query: String) -> Bool {
        let haystack = [node.className, node.title, node.subtitle ?? ""].joined(separator: " ").lowercased()
        return haystack.contains(query)
    }
}

private final class SessionCellView: NSTableCellView {
    private let dotView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor(calibratedRed: 0.19, green: 0.24, blue: 0.31, alpha: 1).cgColor

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 5
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        subtitleLabel.textColor = NSColor(calibratedRed: 0.79, green: 0.84, blue: 0.88, alpha: 1)
        detailLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = NSColor(calibratedRed: 0.65, green: 0.74, blue: 0.79, alpha: 1)

        let labels = NSStackView(views: [titleLabel, subtitleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        addSubview(dotView)
        addSubview(labels)
        dotView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(14)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(10)
        }
        labels.snp.makeConstraints { make in
            make.leading.equalTo(dotView.snp.trailing).offset(12)
            make.trailing.equalToSuperview().inset(14)
            make.centerY.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, subtitle: String, detail: String?, accentColor: NSColor) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        dotView.layer?.backgroundColor = accentColor.cgColor
    }
}

private final class HierarchyCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeView = CapsuleBadgeView(fontSize: 10, horizontalInset: 8, verticalInset: 3, minimumHeight: 20)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        badgeView.applyStyle(
            textColor: NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.60, alpha: 1),
            backgroundColor: NSColor(calibratedRed: 0.89, green: 0.95, blue: 0.98, alpha: 1)
        )

        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        addSubview(labels)
        addSubview(badgeView)
        labels.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(badgeView.snp.leading).offset(-10)
        }
        badgeView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
            make.width.greaterThanOrEqualTo(72)
            make.height.equalTo(20)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with node: ViewScopeHierarchyNode) {
        titleLabel.stringValue = node.title
        let subtitle = [node.className.components(separatedBy: ".").last ?? node.className, node.subtitle].compactMap { $0 }.joined(separator: " • ")
        subtitleLabel.stringValue = subtitle
        badgeView.text = node.kind == .window ? L10n.hierarchyBadgeWindow : node.isHidden ? L10n.hierarchyBadgeHidden : L10n.hierarchyBadgeView
    }
}

private final class IntegrationGuideView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let swiftPackageCard = CodeCardView()
    private let cocoaPodsCard = CodeCardView()
    private let carthageCard = CodeCardView()
    private var cancellables = Set<AnyCancellable>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.backgroundColor = NSColor.white.cgColor

        titleLabel.font = NSFont(name: "Avenir Next Demi Bold", size: 24) ?? .systemFont(ofSize: 24, weight: .semibold)

        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [swiftPackageCard, cocoaPodsCard, carthageCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(stack)

        titleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(28)
        }
        subtitleLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(28)
        }
        stack.snp.makeConstraints { make in
            make.top.equalTo(subtitleLabel.snp.bottom).offset(20)
            make.leading.trailing.bottom.equalToSuperview().inset(28)
        }
        [swiftPackageCard, cocoaPodsCard, carthageCard].forEach { card in
            card.snp.makeConstraints { make in
                make.width.equalTo(stack)
            }
        }

        applyLocalization()
        bindLocalization()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyLocalization() {
        titleLabel.stringValue = L10n.integrationTitle
        subtitleLabel.stringValue = L10n.integrationSubtitle
        swiftPackageCard.configure(
            title: L10n.integrationSwiftPackageManager,
            snippet: ".package(url: \"https://github.com/wangwanjie/ViewScope.git\", from: \"1.0.0\")\nimport ViewScopeServer\nViewScopeInspector.start()"
        )
        cocoaPodsCard.configure(
            title: L10n.integrationCocoaPods,
            snippet: "pod 'ViewScopeServer', :git => 'https://github.com/wangwanjie/ViewScope.git', :tag => 'v1.0.0', :configurations => ['Debug']"
        )
        carthageCard.configure(
            title: L10n.integrationCarthage,
            snippet: "github \"wangwanjie/ViewScope\" ~> 1.0"
        )
    }

    private func bindLocalization() {
        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyLocalization()
            }
            .store(in: &cancellables)
    }
}

private final class CodeCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.backgroundColor = NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.92, alpha: 1).cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        codeLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        codeLabel.lineBreakMode = .byCharWrapping
        codeLabel.textColor = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.31, alpha: 1)

        addSubview(titleLabel)
        addSubview(codeLabel)
        titleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(16)
        }
        codeLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview().inset(16)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, snippet: String) {
        titleLabel.stringValue = title
        codeLabel.stringValue = snippet
    }
}
