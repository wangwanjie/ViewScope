import AppKit
import Combine
import SnapKit
import ViewScopeServer

@MainActor
final class PreviewPanelController: NSViewController {
    private let store: WorkspaceStore
    private let panelView = WorkspacePanelContainerView()
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
    private var autoCenterFocusKey: String?
    private var lastRenderedDisplayMode: WorkspacePreviewDisplayMode?
    private var lastRenderedFocusedNodeID: String?
    private var lastResolvedSelectionNodeID: String?
    private var lastResolvedSelectionRect: CGRect?
    private var lastResolvedGeometryMode: PreviewCanvasGeometryMode?
    private var lastResolvedSelectionGeometryMode: PreviewCanvasGeometryMode?

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
        panelView.setAccessibilityIdentifier("workspace.previewPanel")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bindStore()
        renderCurrentState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        canvasView.minimumViewportSize = panelView.contentView.bounds.size
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

        panelView.contentView.addSubview(canvasView)
        panelView.contentView.addSubview(guideView)
        canvasView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        guideView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        canvasView.onNodeClick = { [weak self] nodeID in
            self?.selectNode(withID: nodeID, focusAfterSelection: false)
        }
        canvasView.onNodeDoubleClick = { [weak self] nodeID in
            self?.selectNode(withID: nodeID, focusAfterSelection: true)
        }
        canvasView.onScaleChanged = { [weak self] scale in
            self?.store.setPreviewScale(scale)
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
        canvasView.isHidden = capture == nil
        let previewImage = capture == nil ? nil : decodedPreviewImage(from: store.selectedNodeDetail)
        let previewCanvasSize = capture == nil ? .zero : resolvedCanvasSize(capture: capture, detail: store.selectedNodeDetail)
        let geometryMode = resolvedGeometryMode(capture: capture, detail: store.selectedNodeDetail)
        let selectionRect = capture == nil ? nil : resolvedSelectionRect(
            capture: capture,
            detail: store.selectedNodeDetail,
            geometryMode: geometryMode
        )

        panelView.setTitle(L10n.canvasPreview, subtitle: store.focusedNode?.title)

        canvasView.capture = capture
        canvasView.image = previewImage
        canvasView.canvasSize = previewCanvasSize
        canvasView.selectedNodeID = store.selectedNodeID
        canvasView.focusedNodeID = store.focusedNodeID
        canvasView.highlightedCanvasRect = selectionRect
        canvasView.geometryMode = geometryMode
        canvasView.displayMode = store.previewDisplayMode
        canvasView.zoomScale = store.previewScale

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

        let nextAutoCenterFocusKey = PreviewPanelRenderDecisions.autoCenterFocusKey(
            focusedNodeID: store.focusedNodeID,
            capture: capture
        )
        if autoCenterFocusKey != nextAutoCenterFocusKey {
            autoCenterFocusKey = nextAutoCenterFocusKey
            centerSelectionIfNeeded()
        }

        if PreviewPanelRenderDecisions.shouldRecenterFullCanvas(
            displayMode: store.previewDisplayMode,
            lastRenderedDisplayMode: lastRenderedDisplayMode,
            focusedNodeID: store.focusedNodeID,
            lastRenderedFocusedNodeID: lastRenderedFocusedNodeID,
            canvasSize: canvasView.canvasSize
        ) {
            canvasView.centerOnCanvasRect(CGRect(origin: .zero, size: canvasView.canvasSize))
        }
        lastRenderedDisplayMode = store.previewDisplayMode
        lastRenderedFocusedNodeID = store.focusedNodeID
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

    private func selectNode(withID nodeID: String, focusAfterSelection: Bool) {
        Task { @MainActor [weak self] in
            await self?.store.selectNode(withID: nodeID)
            if focusAfterSelection {
                self?.store.setFocusedNode(nodeID)
            }
        }
    }

    private func centerSelectionIfNeeded() {
        guard store.previewDisplayMode == .flat,
              store.focusedNodeID != nil else {
            return
        }
        guard let rect = resolvedSelectionRect(
            capture: store.capture,
            detail: store.selectedNodeDetail,
            geometryMode: resolvedGeometryMode(capture: store.capture, detail: store.selectedNodeDetail)
        ) else {
            return
        }
        canvasView.centerOnCanvasRect(rect.insetBy(dx: -40, dy: -40))
    }

    private func resolvedGeometryMode(
        capture: ViewScopeCapturePayload?,
        detail: ViewScopeNodeDetailPayload?
    ) -> PreviewCanvasGeometryMode {
        guard let capture else {
            lastResolvedGeometryMode = nil
            return .directGlobalCanvasRect
        }
        if let inferredMode = PreviewPanelRenderDecisions.geometryMode(
            capture: capture,
            selectedNodeID: store.selectedNodeID,
            detail: detail,
            geometry: geometry
        ) {
            lastResolvedGeometryMode = inferredMode
            return inferredMode
        }
        return lastResolvedGeometryMode ?? .directGlobalCanvasRect
    }

    private func resolvedSelectionRect(
        capture: ViewScopeCapturePayload?,
        detail: ViewScopeNodeDetailPayload?,
        geometryMode: PreviewCanvasGeometryMode
    ) -> CGRect? {
        let selectionRect = PreviewPanelRenderDecisions.selectionRect(
            capture: capture,
            selectedNodeID: store.selectedNodeID,
            detail: detail,
            geometryMode: geometryMode,
            geometry: geometry
        )

        if let selectedNodeID = store.selectedNodeID {
            if let detail,
               detail.nodeID == selectedNodeID,
               let selectionRect {
                lastResolvedSelectionNodeID = selectedNodeID
                lastResolvedSelectionRect = selectionRect
                lastResolvedSelectionGeometryMode = geometryMode
                return selectionRect
            }

            if lastResolvedSelectionNodeID == selectedNodeID,
               lastResolvedSelectionGeometryMode == geometryMode,
               let lastResolvedSelectionRect {
                return lastResolvedSelectionRect
            }
        }

        lastResolvedSelectionNodeID = store.selectedNodeID
        lastResolvedSelectionRect = selectionRect
        lastResolvedSelectionGeometryMode = geometryMode
        return selectionRect
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

struct PreviewPanelRenderDecisions {
    static func geometryMode(
        capture: ViewScopeCapturePayload?,
        selectedNodeID: String?,
        detail: ViewScopeNodeDetailPayload?,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry()
    ) -> PreviewCanvasGeometryMode? {
        guard let capture,
              let selectedNodeID,
              let detail,
              detail.nodeID == selectedNodeID else {
            return nil
        }
        let targetRect = detail.highlightedRect.cgRect
        guard let directRect = geometry.canvasRect(
                for: selectedNodeID,
                in: capture,
                mode: .directGlobalCanvasRect
              ),
              let legacyRect = geometry.canvasRect(
                for: selectedNodeID,
                in: capture,
                mode: .legacyLocalFrames
              ) else {
            return nil
        }

        return rectDistance(from: directRect, to: targetRect) <= rectDistance(from: legacyRect, to: targetRect)
            ? .directGlobalCanvasRect
            : .legacyLocalFrames
    }

    static func selectionRect(
        capture: ViewScopeCapturePayload?,
        selectedNodeID: String?,
        detail: ViewScopeNodeDetailPayload?,
        geometryMode: PreviewCanvasGeometryMode,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry()
    ) -> CGRect? {
        guard let selectedNodeID else {
            return nil
        }
        if let detail,
           detail.nodeID == selectedNodeID {
            return detail.highlightedRect.cgRect
        }
        if let capture,
           let rect = geometry.canvasRect(for: selectedNodeID, in: capture, mode: geometryMode) {
            return rect
        }
        return nil
    }

    private static func rectDistance(from lhs: CGRect, to rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) +
            abs(lhs.minY - rhs.minY) +
            abs(lhs.width - rhs.width) +
            abs(lhs.height - rhs.height)
    }

    static func autoCenterFocusKey(
        focusedNodeID: String?,
        capture: ViewScopeCapturePayload?
    ) -> String? {
        guard let focusedNodeID else {
            return nil
        }
        return [
            capture?.capturedAt.timeIntervalSinceReferenceDate.description ?? "nil",
            focusedNodeID
        ].joined(separator: "|")
    }

    static func shouldRecenterFullCanvas(
        displayMode: WorkspacePreviewDisplayMode,
        lastRenderedDisplayMode: WorkspacePreviewDisplayMode?,
        focusedNodeID: String?,
        lastRenderedFocusedNodeID: String?,
        canvasSize: CGSize
    ) -> Bool {
        guard displayMode == .layered,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return false
        }
        if lastRenderedDisplayMode != displayMode {
            return true
        }
        return focusedNodeID != lastRenderedFocusedNodeID
    }
}
