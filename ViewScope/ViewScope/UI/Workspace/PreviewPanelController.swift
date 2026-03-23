import AppKit
import Combine
import QuartzCore
import SnapKit
import ViewScopeServer

struct PreviewImageResolver {
    struct Resolution: Equatable {
        let cacheKey: String
        let base64PNG: String
        let size: CGSize
    }

    static func resolve(
        capture: ViewScopeCapturePayload?,
        preferredRootNodeID: String?,
        detail: ViewScopeNodeDetailPayload?
    ) -> Resolution? {
        if let capture,
           let preferredRootNodeID,
           let bitmap = capture.previewBitmaps.first(where: { $0.rootNodeID == preferredRootNodeID }) {
            return Resolution(
                cacheKey: "bitmap:\(capture.captureID):\(preferredRootNodeID)",
                base64PNG: bitmap.pngBase64,
                size: bitmap.size.cgSize
            )
        }

        guard let detail,
              let base64PNG = detail.screenshotPNGBase64,
              base64PNG.isEmpty == false else {
            return nil
        }

        let rootNodeID = preferredRootNodeID ?? detail.screenshotRootNodeID ?? detail.nodeID
        let captureKey = capture?.captureID ?? "detail-only"
        return Resolution(
            cacheKey: "detail:\(captureKey):\(rootNodeID)",
            base64PNG: base64PNG,
            size: detail.screenshotSize.cgSize
        )
    }
}

@MainActor
final class PreviewPanelController: NSViewController {
    private enum Layout {
        static let consoleHeight: CGFloat = 240
        static let verticalSpacing: CGFloat = 12
    }

    private let store: WorkspaceStore
    private let panelView = WorkspacePanelContainerView()
    private let previewContainerView = NSView()
    private let canvasView = PreviewCanvasView()
    private let layeredSceneView = PreviewLayeredSceneView(frame: .zero)
    private let guideView = IntegrationGuideView()
    private let consoleController: ConsolePanelController
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
    private let consoleToggleButton = NSButton()
    private let previewSettingsButton = NSButton()
    private let focusButton = NSButton()
    private let clearFocusButton = NSButton()
    private let visibilityButton = NSButton()
    private let highlightButton = NSButton()
    private var settingsPopover: NSPopover?
    private var consoleHeightConstraint: Constraint?
    private var previewBottomToConsoleConstraint: Constraint?
    private var autoCenterFocusKey: String?
    private var lastRenderedDisplayMode: WorkspacePreviewDisplayMode?
    private var lastRenderedFocusedNodeID: String?
    private var lastResolvedSelectionNodeID: String?
    private var lastResolvedSelectionRect: CGRect?
    private var lastResolvedGeometryMode: PreviewCanvasGeometryMode?
    private var lastResolvedSelectionGeometryMode: PreviewCanvasGeometryMode?
    private var isConsoleToggleEnabled = false
    private var lastConsoleVisibility: Bool?
    private var cachedPreviewImageKey: String?
    private var cachedPreviewImage: NSImage?
    private var renderScheduled = false
    private var pendingLayeredEntryVisibleCanvasRect: CGRect?

    init(store: WorkspaceStore) {
        self.store = store
        self.consoleController = ConsolePanelController(store: store)
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

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        canvasView.minimumViewportSize = previewContainerView.bounds.size
    }

    override func magnify(with event: NSEvent) {
        if let responder = activePreviewResponder() {
            responder.magnify(with: event)
            return
        }
        super.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if let responder = activePreviewResponder() {
            responder.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func rotate(with event: NSEvent) {
        if handleActivePreviewRotation(CGFloat(event.rotation)) {
            return
        }
        super.rotate(with: event)
    }

    private func buildUI() {
        panelView.setTitle(L10n.canvasPreview)
        panelView.contentView.wantsLayer = true
        panelView.contentView.layer?.masksToBounds = true
        previewContainerView.wantsLayer = true
        previewContainerView.layer?.masksToBounds = true
        addChild(consoleController)
        configureToolbarButton(zoomOutButton, symbolName: "minus.magnifyingglass", toolTip: L10n.previewZoomOut, action: #selector(zoomOut(_:)))
        configureToolbarButton(zoomInButton, symbolName: "plus.magnifyingglass", toolTip: L10n.previewZoomIn, action: #selector(zoomIn(_:)))
        configureToolbarButton(focusButton, symbolName: "scope", toolTip: L10n.previewFocusSelection, action: #selector(focusSelection(_:)))
        configureToolbarButton(clearFocusButton, symbolName: "escape", toolTip: L10n.previewClearFocus, action: #selector(clearFocus(_:)))
        configureToolbarButton(visibilityButton, symbolName: "eye", toolTip: L10n.previewToggleVisibility, action: #selector(toggleVisibility(_:)))
        configureToolbarButton(highlightButton, symbolName: "wand.and.stars", toolTip: L10n.previewHighlightSelection, action: #selector(highlightSelection(_:)))
        configureToolbarButton(previewSettingsButton, symbolName: "slider.horizontal.3", toolTip: L10n.previewLayerSettings, action: #selector(showPreviewSettings(_:)))
        configureConsoleToggleButton()

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

        [zoomOutButton, zoomResetButton, zoomInButton, displayModeControl, consoleToggleButton, previewSettingsButton, focusButton, clearFocusButton, visibilityButton, highlightButton].forEach {
            panelView.accessoryStackView.addArrangedSubview($0)
        }

        panelView.contentView.addSubview(previewContainerView)
        panelView.contentView.addSubview(consoleController.view)
        previewContainerView.addSubview(canvasView)
        previewContainerView.addSubview(layeredSceneView)
        previewContainerView.addSubview(guideView)
        previewContainerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            previewBottomToConsoleConstraint = make.bottom.equalTo(consoleController.view.snp.top).offset(0).constraint
        }
        consoleController.view.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            consoleHeightConstraint = make.height.equalTo(0).constraint
        }
        consoleController.view.isHidden = true
        consoleController.view.alphaValue = 0
        canvasView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        layeredSceneView.snp.makeConstraints { make in
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
        layeredSceneView.onNodeClick = { [weak self] nodeID in
            self?.selectNode(withID: nodeID, focusAfterSelection: false)
        }
        layeredSceneView.onNodeDoubleClick = { [weak self] nodeID in
            self?.selectNode(withID: nodeID, focusAfterSelection: true)
        }
        layeredSceneView.onScaleChanged = { [weak self] scale in
            self?.store.setPreviewScale(scale)
        }
    }

    private func bindStore() {
        Publishers.CombineLatest4(store.$capture, store.$selectedNodeDetail, store.$selectedNodeID, store.$focusedNodeID)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.scheduleRenderCurrentState()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(store.$previewScale, store.$previewDisplayMode, AppLocalization.shared.$language)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.scheduleRenderCurrentState()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(store.$previewLayerSpacing, store.$previewShowsLayerBorders, store.$expandedNodeIDs)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.scheduleRenderCurrentState()
            }
            .store(in: &cancellables)

        store.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRenderCurrentState()
            }
            .store(in: &cancellables)
    }

    private func renderCurrentState() {
        let capture = store.capture
        let consoleAvailable = store.connectionState.supportsConsole
        let isEnteringLayeredFromFlat = store.previewDisplayMode == .layered && lastRenderedDisplayMode == .flat
        let entryVisibleCanvasRect = isEnteringLayeredFromFlat
            ? (pendingLayeredEntryVisibleCanvasRect ?? canvasView.visibleCanvasRect())
            : nil
        guideView.isHidden = capture != nil
        canvasView.isHidden = capture == nil || store.previewDisplayMode != .flat
        layeredSceneView.isHidden = capture == nil || store.previewDisplayMode != .layered
        let previewRootNodeID = resolvedPreviewRootNodeID(capture: capture, detail: store.selectedNodeDetail)
        let previewResolution = PreviewImageResolver.resolve(
            capture: capture,
            preferredRootNodeID: previewRootNodeID,
            detail: store.selectedNodeDetail
        )
        let previewImage = resolvedPreviewImage(from: previewResolution)
        let previewCanvasSize = capture == nil ? .zero : resolvedCanvasSize(
            capture: capture,
            imageResolution: previewResolution
        )
        let geometryMode = resolvedGeometryMode(capture: capture, detail: store.selectedNodeDetail)
        let selectionRect = capture == nil ? nil : resolvedSelectionRect(
            capture: capture,
            detail: store.selectedNodeDetail,
            previewRootNodeID: previewRootNodeID,
            geometryMode: geometryMode
        )

        panelView.setTitle(L10n.canvasPreview, subtitle: store.focusedNode?.title)

        canvasView.applyRenderState(
            capture: capture,
            image: previewImage,
            canvasSize: previewCanvasSize,
            selectedNodeID: store.selectedNodeID,
            focusedNodeID: store.focusedNodeID,
            highlightedCanvasRect: selectionRect,
            previewRootNodeID: previewRootNodeID,
            geometryMode: geometryMode,
            displayMode: store.previewDisplayMode,
            zoomScale: store.previewScale,
            previewLayerSpacing: store.previewLayerSpacing,
            previewShowsLayerBorders: store.previewShowsLayerBorders,
            previewExpandedNodeIDs: store.expandedNodeIDs
        )

        if store.previewDisplayMode == .layered {
            layeredSceneView.applyRenderState(
                capture: capture,
                image: previewImage,
                canvasSize: previewCanvasSize,
                selectedNodeID: store.selectedNodeID,
                focusedNodeID: store.focusedNodeID,
                highlightedCanvasRect: selectionRect,
                previewRootNodeID: previewRootNodeID,
                geometryMode: geometryMode,
                displayMode: store.previewDisplayMode,
                zoomScale: store.previewScale,
                previewLayerSpacing: store.previewLayerSpacing,
                previewShowsLayerBorders: store.previewShowsLayerBorders,
                previewExpandedNodeIDs: store.expandedNodeIDs
            )
            if isEnteringLayeredFromFlat {
                layeredSceneView.enterLayeredMode(fromVisibleCanvasRect: entryVisibleCanvasRect)
                pendingLayeredEntryVisibleCanvasRect = nil
            }
        }

        zoomResetButton.title = "\(Int(round(store.previewScale * 100)))%"
        displayModeControl.selectedSegment = store.previewDisplayMode == .flat ? 0 : 1
        if consoleAvailable == false, isConsoleToggleEnabled {
            isConsoleToggleEnabled = false
        }
        consoleToggleButton.isEnabled = capture != nil && consoleAvailable
        updateConsoleToggleAppearance()
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

        applyConsoleVisibility(
            shouldShowConsole(capture: capture),
            animated: lastConsoleVisibility != nil
        )

        if PreviewPanelRenderDecisions.shouldRecenterFullCanvas(
            displayMode: store.previewDisplayMode,
            lastRenderedDisplayMode: lastRenderedDisplayMode,
            focusedNodeID: store.focusedNodeID,
            lastRenderedFocusedNodeID: lastRenderedFocusedNodeID,
            canvasSize: canvasView.canvasSize
        ), store.previewDisplayMode == .layered,
           isEnteringLayeredFromFlat == false {
            layeredSceneView.centerOnNode(store.focusedNodeID ?? store.selectedNodeID ?? previewRootNodeID, animated: false)
        }
        lastRenderedDisplayMode = store.previewDisplayMode
        lastRenderedFocusedNodeID = store.focusedNodeID
    }

    private func scheduleRenderCurrentState() {
        guard renderScheduled == false else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.renderCurrentState()
        }
    }

    private func configureToolbarButton(_ button: NSButton, symbolName: String, toolTip: String, action: Selector) {
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.target = self
        button.action = action
    }

    private func configureConsoleToggleButton() {
        consoleToggleButton.setButtonType(.toggle)
        consoleToggleButton.bezelStyle = .texturedRounded
        consoleToggleButton.imagePosition = .imageOnly
        consoleToggleButton.target = self
        consoleToggleButton.action = #selector(toggleConsolePanel(_:))
        consoleToggleButton.setAccessibilityIdentifier("workspace.previewConsoleToggle")
        updateConsoleToggleAppearance()
    }

    private func updateConsoleToggleAppearance() {
        let symbolName = isConsoleToggleEnabled ? "terminal.fill" : "terminal"
        consoleToggleButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        consoleToggleButton.state = isConsoleToggleEnabled ? .on : .off
        consoleToggleButton.toolTip = isConsoleToggleEnabled ? L10n.previewHideConsole : L10n.previewShowConsole
    }

    private func shouldShowConsole(capture: ViewScopeCapturePayload?) -> Bool {
        capture != nil &&
            store.selectedNodeID != nil &&
            store.connectionState.supportsConsole &&
            isConsoleToggleEnabled
    }

    private func applyConsoleVisibility(_ showsConsole: Bool, animated: Bool) {
        guard lastConsoleVisibility != showsConsole else { return }

        lastConsoleVisibility = showsConsole
        let consoleView = consoleController.view
        let targetHeight = showsConsole ? Layout.consoleHeight : 0
        let targetSpacing = showsConsole ? -Layout.verticalSpacing : 0

        if showsConsole {
            consoleView.isHidden = false
        }

        let applyChanges = {
            self.consoleHeightConstraint?.update(offset: targetHeight)
            self.previewBottomToConsoleConstraint?.update(offset: targetSpacing)
            consoleView.alphaValue = showsConsole ? 1 : 0
            self.panelView.contentView.layoutSubtreeIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                applyChanges()
            } completionHandler: {
                Task { @MainActor in
                    consoleView.isHidden = !showsConsole
                }
            }
        } else {
            applyChanges()
            consoleView.isHidden = !showsConsole
        }
    }

    private func resolvedPreviewImage(from resolution: PreviewImageResolver.Resolution?) -> NSImage? {
        guard let resolution else {
            cachedPreviewImageKey = nil
            cachedPreviewImage = nil
            return nil
        }

        if cachedPreviewImageKey == resolution.cacheKey {
            return cachedPreviewImage
        }

        guard let data = Data(base64Encoded: resolution.base64PNG),
              let image = NSImage(data: data) else {
            cachedPreviewImageKey = nil
            cachedPreviewImage = nil
            return nil
        }

        cachedPreviewImageKey = resolution.cacheKey
        cachedPreviewImage = image
        return image
    }

    private func resolvedCanvasSize(capture: ViewScopeCapturePayload?, imageResolution: PreviewImageResolver.Resolution?) -> CGSize {
        if let imageResolution,
           imageResolution.size.width > 0,
           imageResolution.size.height > 0 {
            return imageResolution.size
        }
        if let rootID = resolvedPreviewRootNodeID(capture: capture, detail: store.selectedNodeDetail) ?? capture?.rootNodeIDs.first,
           let rootNode = capture?.nodes[rootID] {
            return CGSize(width: CGFloat(rootNode.frame.width), height: CGFloat(rootNode.frame.height))
        }
        return .zero
    }

    private func resolvedPreviewRootNodeID(
        capture: ViewScopeCapturePayload?,
        detail: ViewScopeNodeDetailPayload?
    ) -> String? {
        guard let capture else { return nil }
        if store.focusedNodeID == nil,
           let detail,
           detail.nodeID == store.selectedNodeID,
           let screenshotRootNodeID = detail.screenshotRootNodeID {
            return screenshotRootNodeID
        }
        let anchorNodeID = store.focusedNodeID ?? store.selectedNodeID ?? capture.rootNodeIDs.first
        guard var currentNodeID = anchorNodeID else { return capture.rootNodeIDs.first }

        while let parentID = capture.nodes[currentNodeID]?.parentID {
            currentNodeID = parentID
        }
        return currentNodeID
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
        guard store.focusedNodeID != nil else {
            return
        }
        layeredSceneView.centerOnNode(store.focusedNodeID, animated: true)
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
            previewRootNodeID: resolvedPreviewRootNodeID(capture: capture, detail: detail),
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
        previewRootNodeID: String?,
        geometryMode: PreviewCanvasGeometryMode
    ) -> CGRect? {
        let selectionRect = PreviewPanelRenderDecisions.selectionRect(
            capture: capture,
            selectedNodeID: store.selectedNodeID,
            detail: detail,
            previewRootNodeID: previewRootNodeID,
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
        let nextDisplayMode: WorkspacePreviewDisplayMode = sender.selectedSegment == 1 ? .layered : .flat
        if nextDisplayMode == .layered, store.previewDisplayMode == .flat {
            pendingLayeredEntryVisibleCanvasRect = canvasView.visibleCanvasRect()
        }
        store.setPreviewDisplayMode(nextDisplayMode)
    }

    @objc private func toggleConsolePanel(_ sender: NSButton) {
        isConsoleToggleEnabled = sender.state == .on
        updateConsoleToggleAppearance()
        renderCurrentState()
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

    @discardableResult
    func handleActivePreviewRotation(_ rotation: CGFloat) -> Bool {
        guard store.capture != nil else { return false }
        guard store.previewDisplayMode == .layered else { return false }
        layeredSceneView.applyRotationGesture(rotation)
        return true
    }

    @objc private func showPreviewSettings(_ sender: NSButton) {
        settingsPopover?.close()

        let controller = PreviewLayerSettingsPopoverController(
            layerSpacing: store.previewLayerSpacing,
            showsLayerBorders: store.previewShowsLayerBorders,
            onLayerSpacingChange: { [weak self] spacing in
                self?.store.setPreviewLayerSpacing(spacing)
            },
            onShowsLayerBordersChange: { [weak self] showsBorders in
                self?.store.setPreviewShowsLayerBorders(showsBorders)
            }
        )
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        settingsPopover = popover
    }

    private func activePreviewResponder() -> NSResponder? {
        guard store.capture != nil else { return nil }
        return store.previewDisplayMode == .layered ? layeredSceneView : canvasView
    }
}

@MainActor
private final class PreviewLayerSettingsPopoverController: NSViewController {
    private let spacingSlider = NSSlider(value: 22, minValue: 10, maxValue: 150, target: nil, action: nil)
    private let spacingValueLabel = NSTextField(labelWithString: "")
    private let borderToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let onLayerSpacingChange: (CGFloat) -> Void
    private let onShowsLayerBordersChange: (Bool) -> Void

    init(
        layerSpacing: CGFloat,
        showsLayerBorders: Bool,
        onLayerSpacingChange: @escaping (CGFloat) -> Void,
        onShowsLayerBordersChange: @escaping (Bool) -> Void
    ) {
        self.onLayerSpacingChange = onLayerSpacingChange
        self.onShowsLayerBordersChange = onShowsLayerBordersChange
        super.init(nibName: nil, bundle: nil)
        spacingSlider.doubleValue = layerSpacing
        borderToggle.state = showsLayerBorders ? .on : .off
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        view = container

        let spacingTitleLabel = NSTextField(labelWithString: L10n.previewLayerSpacing)
        spacingTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        spacingValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        spacingValueLabel.alignment = .right

        spacingSlider.target = self
        spacingSlider.action = #selector(handleSpacingSlider(_:))

        borderToggle.title = L10n.previewLayerBorders
        borderToggle.target = self
        borderToggle.action = #selector(handleBorderToggle(_:))

        container.addSubview(spacingTitleLabel)
        container.addSubview(spacingValueLabel)
        container.addSubview(spacingSlider)
        container.addSubview(borderToggle)

        spacingTitleLabel.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(12)
        }
        spacingValueLabel.snp.makeConstraints { make in
            make.centerY.equalTo(spacingTitleLabel)
            make.trailing.equalToSuperview().inset(12)
            make.leading.greaterThanOrEqualTo(spacingTitleLabel.snp.trailing).offset(12)
        }
        spacingSlider.snp.makeConstraints { make in
            make.top.equalTo(spacingTitleLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(12)
        }
        borderToggle.snp.makeConstraints { make in
            make.top.equalTo(spacingSlider.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview().inset(12)
        }

        updateSpacingValueLabel()
        preferredContentSize = NSSize(width: 260, height: 104)
    }

    @objc private func handleSpacingSlider(_ sender: NSSlider) {
        let spacing = CGFloat(sender.doubleValue)
        updateSpacingValueLabel()
        onLayerSpacingChange(spacing)
    }

    @objc private func handleBorderToggle(_ sender: NSButton) {
        onShowsLayerBordersChange(sender.state == .on)
    }

    private func updateSpacingValueLabel() {
        spacingValueLabel.stringValue = String(format: "%.0f", spacingSlider.doubleValue)
    }
}

struct PreviewPanelRenderDecisions {
    static func geometryMode(
        capture: ViewScopeCapturePayload?,
        selectedNodeID: String?,
        detail: ViewScopeNodeDetailPayload?,
        previewRootNodeID: String? = nil,
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
                coordinateRootNodeID: previewRootNodeID,
                mode: .directGlobalCanvasRect
              ),
              let legacyRect = geometry.canvasRect(
                for: selectedNodeID,
                in: capture,
                coordinateRootNodeID: previewRootNodeID,
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
        previewRootNodeID: String? = nil,
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
           let rect = geometry.canvasRect(
            for: selectedNodeID,
            in: capture,
            coordinateRootNodeID: previewRootNodeID,
            mode: geometryMode
           ) {
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
        guard canvasSize.width > 0,
              canvasSize.height > 0 else {
            return false
        }
        if lastRenderedDisplayMode != displayMode {
            return true
        }
        return focusedNodeID != lastRenderedFocusedNodeID
    }
}
