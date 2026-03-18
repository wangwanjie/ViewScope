import AppKit
import Combine
import SnapKit
import ViewScopeServer

@MainActor
final class PreviewPanelController: NSViewController {
    private let store: WorkspaceStore
    private let panelView = WorkspacePanelContainerView()
    private let scrollView = NSScrollView()
    private let canvasView = PreviewCanvasView()
    private let guideView = IntegrationGuideView()
    private let geometry = ViewHierarchyGeometry()
    private var cancellables = Set<AnyCancellable>()

    private let zoomOutButton = NSButton()
    private let zoomResetButton = NSButton(title: "100%", target: nil, action: nil)
    private let zoomInButton = NSButton()
    private let displayModeControl: NSSegmentedControl = {
        let flat = NSImage(systemSymbolName: WorkspacePreviewDisplayMode.flat.symbolName, accessibilityDescription: nil) ?? NSImage()
        let layered = NSImage(systemSymbolName: WorkspacePreviewDisplayMode.layered.symbolName, accessibilityDescription: nil) ?? NSImage()
        return NSSegmentedControl(images: [flat, layered], trackingMode: .selectOne, target: nil, action: nil)
    }()
    private let focusButton = NSButton()
    private let clearFocusButton = NSButton()
    private let visibilityButton = NSButton()
    private let highlightButton = NSButton()

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
        renderCurrentState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        canvasView.minimumViewportSize = scrollView.contentView.bounds.size
    }

    private func buildUI() {
        panelView.setTitle(L10n.canvasPreview)
        configureToolbarButton(zoomOutButton, symbolName: "minus.magnifyingglass", toolTip: L10n.previewZoomOut, action: #selector(zoomOut(_:)))
        configureToolbarButton(zoomInButton, symbolName: "plus.magnifyingglass", toolTip: L10n.previewZoomIn, action: #selector(zoomIn(_:)))
        configureToolbarButton(focusButton, symbolName: "scope", toolTip: L10n.previewFocusSelection, action: #selector(focusSelection(_:)))
        configureToolbarButton(clearFocusButton, symbolName: "escape", toolTip: L10n.previewClearFocus, action: #selector(clearFocus(_:)))
        configureToolbarButton(visibilityButton, symbolName: "eye", toolTip: L10n.previewToggleVisibility, action: #selector(toggleVisibility(_:)))
        configureToolbarButton(highlightButton, symbolName: "wand.and.stars", toolTip: L10n.previewHighlightSelection, action: #selector(highlightSelection(_:)))

        zoomResetButton.bezelStyle = .texturedRounded
        zoomResetButton.target = self
        zoomResetButton.action = #selector(resetZoom(_:))
        zoomResetButton.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomResetButton.toolTip = L10n.previewResetZoom

        displayModeControl.target = self
        displayModeControl.action = #selector(changeDisplayMode(_:))
        displayModeControl.segmentStyle = .texturedRounded
        displayModeControl.setToolTip(L10n.previewDisplayFlat, forSegment: 0)
        displayModeControl.setToolTip(L10n.previewDisplayLayered, forSegment: 1)

        [zoomOutButton, zoomResetButton, zoomInButton, displayModeControl, focusButton, clearFocusButton, visibilityButton, highlightButton].forEach {
            panelView.accessoryStackView.addArrangedSubview($0)
        }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = canvasView

        panelView.contentView.addSubview(scrollView)
        panelView.contentView.addSubview(guideView)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        guideView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        canvasView.onCanvasClick = { [weak self] point in
            self?.selectNode(at: point, focusAfterSelection: false)
        }
        canvasView.onCanvasDoubleClick = { [weak self] point in
            self?.selectNode(at: point, focusAfterSelection: true)
        }
    }

    private func bindStore() {
        Publishers.CombineLatest4(store.$capture, store.$selectedNodeDetail, store.$selectedNodeID, store.$focusedNodeID)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.renderCurrentState()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(store.$previewScale, store.$previewDisplayMode, AppLocalization.shared.$language)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.renderCurrentState()
            }
            .store(in: &cancellables)
    }

    private func renderCurrentState() {
        let capture = store.capture
        guideView.isHidden = capture != nil
        scrollView.isHidden = capture == nil

        panelView.setTitle(L10n.canvasPreview, subtitle: store.focusedNode?.title)

        canvasView.capture = capture
        canvasView.image = decodedPreviewImage(from: store.selectedNodeDetail)
        canvasView.canvasSize = resolvedCanvasSize(capture: capture, detail: store.selectedNodeDetail)
        canvasView.selectedNodeID = store.selectedNodeID
        canvasView.focusedNodeID = store.focusedNodeID
        canvasView.displayMode = store.previewDisplayMode
        canvasView.zoomScale = store.previewScale
        canvasView.minimumViewportSize = scrollView.contentView.bounds.size

        zoomResetButton.title = "\(Int(round(store.previewScale * 100)))%"
        displayModeControl.selectedSegment = store.previewDisplayMode == .flat ? 0 : 1
        focusButton.isEnabled = store.selectedNodeID != nil
        clearFocusButton.isEnabled = store.focusedNodeID != nil
        highlightButton.isEnabled = store.selectedNodeID != nil
        visibilityButton.isEnabled = store.selectedNode?.kind == .view
        visibilityButton.toolTip = L10n.previewToggleVisibility
        if let node = store.selectedNode {
            let symbolName = node.isHidden ? "eye.slash" : "eye"
            visibilityButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            visibilityButton.toolTip = node.isHidden ? L10n.hierarchyMenuShowView : L10n.hierarchyMenuHideView
        }

        centerSelectionIfNeeded()
    }

    private func configureToolbarButton(_ button: NSButton, symbolName: String, toolTip: String, action: Selector) {
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.target = self
        button.action = action
    }

    private func decodedPreviewImage(from detail: ViewScopeNodeDetailPayload?) -> NSImage? {
        guard let base64 = detail?.screenshotPNGBase64,
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        return NSImage(data: data)
    }

    private func resolvedCanvasSize(capture: ViewScopeCapturePayload?, detail: ViewScopeNodeDetailPayload?) -> CGSize {
        if let detail, detail.screenshotSize.width > 0, detail.screenshotSize.height > 0 {
            return detail.screenshotSize.cgSize
        }
        if let rootID = capture?.rootNodeIDs.first,
           let rootNode = capture?.nodes[rootID] {
            return CGSize(width: CGFloat(rootNode.frame.width), height: CGFloat(rootNode.frame.height))
        }
        return .zero
    }

    private func selectNode(at point: CGPoint, focusAfterSelection: Bool) {
        guard let capture = store.capture else { return }
        let nodeID = geometry.deepestNodeID(at: point, in: capture, rootNodeID: store.focusedNodeID)
        guard let nodeID else { return }
        Task { @MainActor [weak self] in
            await self?.store.selectNode(withID: nodeID)
            if focusAfterSelection {
                self?.store.setFocusedNode(nodeID)
            }
        }
    }

    private func centerSelectionIfNeeded() {
        guard let capture = store.capture,
              let selectedNodeID = store.selectedNodeID,
              let rect = geometry.canvasRect(for: selectedNodeID, in: capture) else {
            return
        }
        let targetRect = canvasView.viewRect(fromCanvasRect: rect).insetBy(dx: -40, dy: -40)
        scrollView.contentView.scrollToVisible(targetRect)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func zoomOut(_ sender: Any?) {
        store.zoomOutPreview()
    }

    @objc private func resetZoom(_ sender: Any?) {
        store.resetPreviewZoom()
    }

    @objc private func zoomIn(_ sender: Any?) {
        store.zoomInPreview()
    }

    @objc private func changeDisplayMode(_ sender: NSSegmentedControl) {
        store.setPreviewDisplayMode(sender.selectedSegment == 1 ? .layered : .flat)
    }

    @objc private func focusSelection(_ sender: Any?) {
        store.focusSelectedNode()
    }

    @objc private func clearFocus(_ sender: Any?) {
        store.clearFocus()
    }

    @objc private func toggleVisibility(_ sender: Any?) {
        guard let nodeID = store.selectedNodeID else { return }
        Task { await store.toggleVisibility(for: nodeID) }
    }

    @objc private func highlightSelection(_ sender: Any?) {
        Task { await store.highlightCurrentSelection() }
    }
}
