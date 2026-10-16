import AppKit
import Combine
import QuartzCore
import SnapKit
import ViewScopeServer

@MainActor
/// 预览面板总控。
///
/// 使用单一 `PreviewLayeredSceneView`（SCNView）同时处理 flat 和 layered 两种显示模式，
/// flat 模式为 rotation=0 的 3D 场景，layered 模式有旋转和 z 间距。
/// 预览之上叠加 2D 覆盖层（测量标注）与状态栏（光标坐标、取色结果）。
final class PreviewPanelController: NSViewController {
    private enum Layout {
        static let consoleHeight: CGFloat = 240
        static let verticalSpacing: CGFloat = 12
    }

    /// 方向键导航加载节点详情的防抖时长。
    private static let keyboardSelectionDebounceInterval: TimeInterval = 0.12

    private let store: WorkspaceStore
    private let panelView = WorkspacePanelContainerView()
    private let previewContainerView = NSView()
    private let consoleHostView = NSView()
    private let loadingProgressView = WorkspaceLoadingProgressView()
    private let layeredSceneView = PreviewLayeredSceneView(frame: .zero)
    private let measurementOverlayView = PreviewMeasurementOverlayView(frame: .zero)
    private let statusContainerView = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let colorSwatchView = NSView()
    private let guideView = IntegrationGuideView()
    private let consoleController: ConsolePanelController
    private let geometry = ViewHierarchyGeometry()
    private let renderStateBuilder = PreviewPanelRenderStateBuilder()
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
    private let resetViewButton = NSButton()
    private let measureButton = NSButton()
    private let colorPickerButton = NSButton()
    private let diagnosticsButton = NSButton()
    private let focusButton = NSButton()
    private let clearFocusButton = NSButton()
    private let visibilityButton = NSButton()
    private let highlightButton = NSButton()
    private var settingsPopover: NSPopover?
    private var diagnosticsPopover: NSPopover?
    private var consoleHeightConstraint: Constraint?
    private var previewBottomToConsoleConstraint: Constraint?
    /// 上一次居中所针对的聚焦节点；变化时（包括清除聚焦）只居中一次。
    private var lastCenteredFocusNodeID: String??
    private var lastRenderedDisplayMode: WorkspacePreviewDisplayMode?
    private var isConsoleToggleEnabled = false
    private var lastConsoleVisibility: Bool?
    private var renderCache = PreviewPanelRenderCache.empty
    private var renderScheduled = false
    private var lastLaidOutPreviewSize = CGSize.zero
    private var lastPreviewImage: NSImage?
    private var lastCanvasSize = CGSize.zero
    private var lastCursorCanvasPoint: CGPoint?
    private var colorSampler = PreviewColorSampler()
    private var transientStatusMessage: String?
    private var transientStatusTimer: Timer?
    private var keyboardSelectionTimer: Timer?
    private var flagsMonitor: Any?
    private var lastDiagnosticsCaptureKey: String?

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
        // 测试里经常先读取 `controller.view`，随后才补 frame。
        // 先给一个可布局的默认尺寸，避免 SceneKit / Auto Layout 在 0x0 首帧下产生日志和错误状态。
        panelView.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        view = panelView
        panelView.setAccessibilityElement(true)
        panelView.setAccessibilityRole(.group)
        panelView.setAccessibilityIdentifier("workspace.previewPanel")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bindStore()
        bindInspectionTools()
        renderCurrentState()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
        installFlagsMonitorIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeFlagsMonitor()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let previewSize = previewContainerView.bounds.size

        guard previewSize.width > 0.5,
              previewSize.height > 0.5,
              previewSize != lastLaidOutPreviewSize else {
            return
        }

        lastLaidOutPreviewSize = previewSize
        scheduleRenderCurrentState()
    }

    override func magnify(with event: NSEvent) {
        guard store.capture != nil else {
            super.magnify(with: event)
            return
        }
        layeredSceneView.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard store.capture != nil else {
            super.scrollWheel(with: event)
            return
        }
        layeredSceneView.scrollWheel(with: event)
    }

    override func rotate(with event: NSEvent) {
        if handleActivePreviewRotation(CGFloat(event.rotation)) {
            return
        }
        super.rotate(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - 界面

    private func buildUI() {
        panelView.setTitle(L10n.canvasPreview)
        panelView.contentView.wantsLayer = true
        panelView.contentView.layer?.masksToBounds = true
        previewContainerView.wantsLayer = true
        previewContainerView.layer?.masksToBounds = true
        consoleHostView.wantsLayer = true
        consoleHostView.layer?.masksToBounds = true
        addChild(consoleController)
        configureToolbarButton(zoomOutButton, symbolName: "minus.magnifyingglass", toolTip: L10n.previewZoomOut, action: #selector(zoomOut(_:)))
        configureToolbarButton(zoomInButton, symbolName: "plus.magnifyingglass", toolTip: L10n.previewZoomIn, action: #selector(zoomIn(_:)))
        configureToolbarButton(resetViewButton, symbolName: "arrow.counterclockwise", toolTip: L10n.previewToolsResetView, action: #selector(resetView(_:)))
        configureToolbarButton(measureButton, symbolName: "ruler", toolTip: L10n.previewToolsMeasure, action: #selector(toggleMeasurement(_:)))
        measureButton.setButtonType(.pushOnPushOff)
        configureToolbarButton(colorPickerButton, symbolName: "eyedropper", toolTip: L10n.previewToolsColorPicker, action: #selector(toggleColorPicker(_:)))
        colorPickerButton.setButtonType(.pushOnPushOff)
        configureToolbarButton(diagnosticsButton, symbolName: "exclamationmark.triangle", toolTip: L10n.previewToolsDiagnostics, action: #selector(showDiagnostics(_:)))
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

        [
            zoomOutButton, zoomResetButton, zoomInButton, resetViewButton, displayModeControl,
            measureButton, colorPickerButton, diagnosticsButton,
            consoleToggleButton, previewSettingsButton, focusButton, clearFocusButton, visibilityButton, highlightButton
        ].forEach {
            panelView.accessoryStackView.addArrangedSubview($0)
        }

        panelView.contentView.addSubview(previewContainerView)
        panelView.contentView.addSubview(consoleHostView)
        previewContainerView.addSubview(layeredSceneView)
        previewContainerView.addSubview(measurementOverlayView)
        previewContainerView.addSubview(statusContainerView)
        previewContainerView.addSubview(guideView)
        previewContainerView.addSubview(loadingProgressView)
        previewContainerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            previewBottomToConsoleConstraint = make.bottom.equalTo(consoleHostView.snp.top).offset(0).constraint
        }
        consoleHostView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            consoleHeightConstraint = make.height.equalTo(0).constraint
        }
        consoleHostView.isHidden = true
        consoleHostView.alphaValue = 0
        consoleController.view.isHidden = true
        consoleController.view.alphaValue = 0
        layeredSceneView.isHidden = true
        layeredSceneView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        measurementOverlayView.snp.makeConstraints { make in
            make.edges.equalTo(layeredSceneView)
        }
        guideView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        loadingProgressView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(2)
        }
        buildStatusView()

        layeredSceneView.onNodeClick = { [weak self] nodeID, modifiers in
            self?.handleNodeClick(nodeID, modifiers: modifiers)
        }
        layeredSceneView.onNodeDoubleClick = { [weak self] nodeID in
            self?.selectNode(withID: nodeID, focusAfterSelection: true)
        }
        layeredSceneView.onScaleChanged = { [weak self] scale in
            self?.store.setPreviewScale(scale)
        }
        layeredSceneView.onHoverChanged = { [weak self] nodeID in
            guard let self else {
                return
            }
            if let nodeID {
                self.store.inspectionTools.setHoveredNodeIDCoalesced(nodeID)
            } else {
                self.store.inspectionTools.clearHover()
            }
        }
        layeredSceneView.onCursorCanvasPointChanged = { [weak self] point in
            self?.lastCursorCanvasPoint = point
            self?.updateStatusView()
        }
        layeredSceneView.onColorPickClick = { [weak self] point in
            self?.copyColor(at: point)
        }
        layeredSceneView.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        layeredSceneView.onViewportChanged = { [weak self] in
            self?.updateMeasurementOverlay()
        }
    }

    private func buildStatusView() {
        statusContainerView.wantsLayer = true
        statusContainerView.layer?.cornerRadius = 6
        statusContainerView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        statusContainerView.isHidden = true
        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        colorSwatchView.wantsLayer = true
        colorSwatchView.layer?.cornerRadius = 3
        colorSwatchView.layer?.borderWidth = 1
        colorSwatchView.layer?.borderColor = NSColor.separatorColor.cgColor
        colorSwatchView.isHidden = true

        let stack = NSStackView(views: [colorSwatchView, statusLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        statusContainerView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8))
        }
        colorSwatchView.snp.makeConstraints { make in
            make.width.height.equalTo(12)
        }
        statusContainerView.snp.makeConstraints { make in
            make.leading.bottom.equalToSuperview().inset(10)
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

        Publishers.CombineLatest4(
            store.$previewLayerSpacing,
            store.$previewShowsLayerBorders,
            store.$expandedNodeIDs,
            store.$showsSystemWrapperViews
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.scheduleRenderCurrentState()
            }
            .store(in: &cancellables)

        store.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRenderCurrentState()
            }
            .store(in: &cancellables)

        store.$isLoadingWorkspace
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRenderCurrentState()
            }
            .store(in: &cancellables)
    }

    private func bindInspectionTools() {
        let tools = store.inspectionTools

        // @Published 在 willSet 阶段发布；统一切到下一个 runloop，保证读到的是最新值。
        tools.$hoveredNodeID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] nodeID in
                self?.layeredSceneView.hoveredNodeID = nodeID
                self?.updateMeasurementOverlay()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(tools.$isMeasurementEnabled, tools.$isTemporaryMeasurementActive, tools.$measurementAnchorNodeID)
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled, _, _ in
                self?.measureButton.state = isEnabled ? .on : .off
                self?.updateMeasurementOverlay()
            }
            .store(in: &cancellables)

        tools.$isColorPickerEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.colorPickerButton.state = isEnabled ? .on : .off
                self?.layeredSceneView.isColorPickerActive = isEnabled
                self?.updateStatusView()
            }
            .store(in: &cancellables)

        tools.$showsDiagnostics
            .receive(on: RunLoop.main)
            .sink { [weak self] showsDiagnostics in
                self?.layeredSceneView.showsDiagnostics = showsDiagnostics
            }
            .store(in: &cancellables)
    }

    // MARK: - 渲染

    private func renderCurrentState() {
        let snapshot = PreviewPanelSnapshot(store: store)
        let (renderState, nextRenderCache) = renderStateBuilder.makeState(
            snapshot: snapshot,
            cache: renderCache,
            isConsoleToggleEnabled: isConsoleToggleEnabled,
            geometry: geometry
        )
        renderCache = nextRenderCache
        let context = renderState.context
        let hasRenderablePreviewBounds =
            previewContainerView.bounds.width > 0.5 &&
            previewContainerView.bounds.height > 0.5

        guideView.isHidden = snapshot.capture != nil || snapshot.isLoadingWorkspace
        layeredSceneView.isHidden = snapshot.capture == nil
        measurementOverlayView.isHidden = snapshot.capture == nil
        lastPreviewImage = renderState.previewImage
        lastCanvasSize = context.previewCanvasSize

        if snapshot.isLoadingWorkspace {
            loadingProgressView.startAnimating()
        } else if snapshot.capture != nil {
            loadingProgressView.finishAnimatingIfNeeded()
        } else {
            loadingProgressView.stopImmediately()
        }

        panelView.setTitle(L10n.canvasPreview, subtitle: snapshot.focusedNodeTitle)

        // 显示模式变化：只切换旋转与 z 间距（带动画），不重建平面。
        let isChangingDisplayMode = lastRenderedDisplayMode != nil && snapshot.previewDisplayMode != lastRenderedDisplayMode
        if isChangingDisplayMode {
            layeredSceneView.setDimension(snapshot.previewDisplayMode, animated: true)
        }

        if hasRenderablePreviewBounds {
            layeredSceneView.applyRenderState(
                capture: snapshot.capture,
                image: renderState.previewImage,
                canvasSize: context.previewCanvasSize,
                selectedNodeID: snapshot.selectedNodeID,
                focusedNodeID: snapshot.focusedNodeID,
                highlightedCanvasRect: context.selectionRect,
                previewRootNodeID: context.previewRootNodeID,
                geometryMode: context.geometryMode,
                displayMode: snapshot.previewDisplayMode,
                zoomScale: snapshot.previewScale,
                previewLayerSpacing: snapshot.previewLayerSpacing,
                previewShowsLayerBorders: snapshot.previewShowsLayerBorders,
                previewExpandedNodeIDs: snapshot.expandedNodeIDs,
                showsSystemWrapperViews: snapshot.showsSystemWrapperViews
            )
        }

        applyToolbarState(renderState.toolbarState)
        applyDiagnostics(capture: snapshot.capture)

        // 聚焦节点变化（含清除聚焦）时只居中一次：有聚焦居中到聚焦节点，清除后回到整张画布。
        if hasRenderablePreviewBounds,
           lastCenteredFocusNodeID != .some(snapshot.focusedNodeID) {
            let isInitialRender = lastCenteredFocusNodeID == nil
            lastCenteredFocusNodeID = .some(snapshot.focusedNodeID)
            if isInitialRender == false || snapshot.focusedNodeID != nil {
                layeredSceneView.centerOnNode(snapshot.focusedNodeID, animated: isInitialRender == false)
            }
        }

        applyConsoleVisibility(
            renderState.toolbarState.shouldShowConsolePanel,
            animated: lastConsoleVisibility != nil
        )

        lastRenderedDisplayMode = snapshot.previewDisplayMode
        updateMeasurementOverlay()
        updateStatusView()
    }

    private func scheduleRenderCurrentState() {
        if Thread.isMainThread, view.window == nil {
            renderCurrentState()
            return
        }
        guard renderScheduled == false else {
            return
        }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.renderScheduled = false
            self.renderCurrentState()
        }
    }

    /// 诊断结果按 capture 缓存；只在抓取变化时把严重程度表推给预览，并刷新工具栏徽标。
    private func applyDiagnostics(capture: ViewScopeCapturePayload?) {
        let key = capture.map { "\($0.captureID)|\($0.nodes.count)" }
        guard key != lastDiagnosticsCaptureKey else {
            return
        }
        lastDiagnosticsCaptureKey = key
        let report = store.inspectionTools.diagnosticsReport(for: capture)
        var severities: [String: LayoutDiagnosticIssue.Severity] = [:]
        for nodeID in report.issuesByNodeID.keys {
            if let severity = report.maximumSeverity(for: nodeID) {
                severities[nodeID] = severity
            }
        }
        layeredSceneView.diagnosticSeverities = severities
        let problemCount = (report.countsBySeverity[.error] ?? 0) + (report.countsBySeverity[.warning] ?? 0)
        diagnosticsButton.title = problemCount > 0 ? "\(problemCount)" : ""
        diagnosticsButton.imagePosition = problemCount > 0 ? .imageLeading : .imageOnly
        diagnosticsButton.contentTintColor = (report.countsBySeverity[.error] ?? 0) > 0
            ? .systemRed
            : (problemCount > 0 ? .systemOrange : nil)
        diagnosticsButton.isEnabled = capture != nil
    }

    // MARK: - 测量与状态栏

    /// 宿主屏幕缩放：优先 host 信息，其次截图元数据，默认 2。
    private var hostScale: CGFloat {
        if let screenScale = store.capture?.host.screenScale, screenScale > 0 {
            return CGFloat(screenScale)
        }
        if let bitmapScale = store.capture?.previewBitmaps.first?.scale, bitmapScale > 0 {
            return CGFloat(bitmapScale)
        }
        return 2
    }

    private func updateMeasurementOverlay() {
        let tools = store.inspectionTools
        guard tools.isMeasurementActive, store.capture != nil else {
            measurementOverlayView.model = .empty
            return
        }
        guard layeredSceneView.isFlatProjection else {
            measurementOverlayView.model = PreviewMeasurementOverlayView.Model(hint: L10n.previewToolsMeasureUnavailableIn3D)
            return
        }
        guard let anchorNodeID = tools.measurementAnchorNodeID ?? store.selectedNodeID,
              let anchorRect = layeredSceneView.visibleCanvasRect(for: anchorNodeID) else {
            measurementOverlayView.model = PreviewMeasurementOverlayView.Model(hint: L10n.previewToolsMeasureHint)
            return
        }

        var model = PreviewMeasurementOverlayView.Model()
        model.anchorRect = layeredSceneView.viewRect(forCanvasRect: anchorRect, nodeID: anchorNodeID)
        guard let targetNodeID = tools.hoveredNodeID,
              targetNodeID != anchorNodeID,
              let targetRect = layeredSceneView.visibleCanvasRect(for: targetNodeID) else {
            measurementOverlayView.model = model
            return
        }

        model.targetRect = layeredSceneView.viewRect(forCanvasRect: targetRect, nodeID: targetNodeID)
        let calculator = MeasurementCalculator(scale: hostScale)
        let result = calculator.measure(anchor: anchorRect, target: targetRect)
        model.lines = result.lines.compactMap { line in
            guard let start = layeredSceneView.viewPoint(forCanvasPoint: line.start),
                  let end = layeredSceneView.viewPoint(forCanvasPoint: line.end) else {
                return nil
            }
            return PreviewMeasurementOverlayView.Line(
                start: start,
                end: end,
                label: line.label,
                isHorizontal: line.axis == .horizontal
            )
        }
        measurementOverlayView.model = model
    }

    private func updateStatusView() {
        guard store.capture != nil else {
            statusContainerView.isHidden = true
            return
        }
        if let transientStatusMessage {
            statusLabel.stringValue = transientStatusMessage
            colorSwatchView.isHidden = true
            statusContainerView.isHidden = false
            return
        }
        guard let point = lastCursorCanvasPoint else {
            statusContainerView.isHidden = true
            return
        }

        var text = L10n.previewToolsCursorPosition(
            MeasurementCalculator.format(point.x),
            MeasurementCalculator.format(point.y)
        )
        if store.inspectionTools.isColorPickerEnabled,
           let image = lastPreviewImage,
           let color = colorSampler.color(at: point, in: image, canvasSize: lastCanvasSize) {
            text += "   \(PreviewColorSampler.hexString(for: color))"
            colorSwatchView.layer?.backgroundColor = color.cgColor
            colorSwatchView.isHidden = false
        } else {
            colorSwatchView.isHidden = true
        }
        statusLabel.stringValue = text
        statusContainerView.isHidden = false
    }

    private func copyColor(at canvasPoint: CGPoint) {
        guard let image = lastPreviewImage,
              let color = colorSampler.color(at: canvasPoint, in: image, canvasSize: lastCanvasSize) else {
            return
        }
        let hex = PreviewColorSampler.hexString(for: color)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        showTransientStatus(L10n.previewToolsColorCopied(hex))
    }

    private func showTransientStatus(_ message: String) {
        transientStatusTimer?.invalidate()
        transientStatusMessage = message
        updateStatusView()
        transientStatusTimer = MainRunLoopScheduler.schedule(after: 1.5) { [weak self] in
            self?.transientStatusMessage = nil
            self?.updateStatusView()
        }
    }

    // MARK: - 键盘

    /// 预览区快捷键。返回 true 表示已处理。
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if modifiers.contains(.command) {
            if characters == "f" {
                store.inspectionTools.searchFocusRequests.send()
                return true
            }
            return false
        }

        switch event.keyCode {
        case 53:
            return handleEscape()
        case 123:
            return navigateSelection(.previousSibling)
        case 124:
            return navigateSelection(.nextSibling)
        case 125:
            return navigateSelection(.firstChild)
        case 126:
            return navigateSelection(.parent)
        default:
            break
        }

        switch characters {
        case "+", "=":
            store.zoomInPreview()
            return true
        case "-", "_":
            store.zoomOutPreview()
            return true
        case "0":
            store.resetPreviewZoom()
            return true
        case "r":
            resetView(nil)
            return true
        default:
            return false
        }
    }

    /// Esc：依次取消测量参照、取色、测量模式、聚焦。
    private func handleEscape() -> Bool {
        let tools = store.inspectionTools
        if tools.measurementAnchorNodeID != nil {
            tools.measurementAnchorNodeID = nil
            return true
        }
        if tools.isColorPickerEnabled {
            tools.isColorPickerEnabled = false
            return true
        }
        if tools.isMeasurementEnabled {
            tools.isMeasurementEnabled = false
            return true
        }
        if store.focusedNodeID != nil {
            store.clearFocus()
            return true
        }
        return false
    }

    private enum NavigationDirection {
        case parent
        case firstChild
        case previousSibling
        case nextSibling
    }

    /// 方向键在展示层级中移动选中：上 = 父节点，下 = 第一个子节点，左右 = 兄弟节点。
    private func navigateSelection(_ direction: NavigationDirection) -> Bool {
        guard let capture = store.capture,
              let selectedNodeID = store.selectedNodeID else {
            return false
        }
        let showsWrappers = store.showsSystemWrapperViews
        let parentID = ViewHierarchyPresentation.presentedParentNodeID(
            of: selectedNodeID,
            nodes: capture.nodes,
            showsSystemWrappers: showsWrappers
        )
        let targetNodeID: String?
        switch direction {
        case .parent:
            targetNodeID = parentID
        case .firstChild:
            targetNodeID = ViewHierarchyPresentation.presentedChildNodeIDs(
                of: selectedNodeID,
                nodes: capture.nodes,
                showsSystemWrappers: showsWrappers
            ).first
        case .previousSibling, .nextSibling:
            let siblings = parentID.map {
                ViewHierarchyPresentation.presentedChildNodeIDs(of: $0, nodes: capture.nodes, showsSystemWrappers: showsWrappers)
            } ?? ViewHierarchyPresentation.presentedRootNodeIDs(
                from: capture.rootNodeIDs,
                nodes: capture.nodes,
                showsSystemWrappers: showsWrappers
            )
            if let index = siblings.firstIndex(of: selectedNodeID) {
                let nextIndex = direction == .nextSibling ? index + 1 : index - 1
                targetNodeID = siblings.indices.contains(nextIndex) ? siblings[nextIndex] : nil
            } else {
                targetNodeID = nil
            }
        }
        guard let targetNodeID else {
            return true
        }
        // 连续按键时防抖：只为最后停留的节点请求详情，避免宿主频繁闪烁。
        keyboardSelectionTimer?.invalidate()
        keyboardSelectionTimer = MainRunLoopScheduler.schedule(after: Self.keyboardSelectionDebounceInterval) { [weak self] in
            guard let self else {
                return
            }
            self.store.expandAncestors(of: targetNodeID)
            Task {
                await self.store.selectNode(withID: targetNodeID)
            }
        }
        return true
    }

    // MARK: - Option 临时测量

    private func installFlagsMonitorIfNeeded() {
        guard flagsMonitor == nil else {
            return
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isOptionPressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            if let tools = self?.store.inspectionTools, tools.isTemporaryMeasurementActive != isOptionPressed {
                tools.isTemporaryMeasurementActive = isOptionPressed
            }
            return event
        }
    }

    private func removeFlagsMonitor() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        flagsMonitor = nil
        store.inspectionTools.isTemporaryMeasurementActive = false
    }

    // MARK: - 工具栏

    private func configureToolbarButton(_ button: NSButton, symbolName: String, toolTip: String, action: Selector) {
        button.bezelStyle = .texturedRounded
        // NSButton() 默认标题是“Button/按钮”，纯图标按钮必须清空，否则切到 imageLeading 时会露出来
        button.title = ""
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

    private func updateConsoleToggleAppearance(isEnabled: Bool = false) {
        let symbolName = isEnabled ? "terminal.fill" : "terminal"
        consoleToggleButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        consoleToggleButton.state = isEnabled ? .on : .off
        consoleToggleButton.toolTip = isEnabled ? L10n.previewHideConsole : L10n.previewShowConsole
    }

    private func applyToolbarState(_ state: PreviewToolbarState) {
        if isConsoleToggleEnabled != state.consoleToggleEnabled {
            isConsoleToggleEnabled = state.consoleToggleEnabled
        }

        zoomResetButton.title = state.zoomPercentageTitle
        displayModeControl.selectedSegment = state.selectedDisplaySegment
        consoleToggleButton.isEnabled = state.consoleToggleButtonEnabled
        updateConsoleToggleAppearance(isEnabled: state.consoleToggleEnabled)
        focusButton.isEnabled = state.focusButtonEnabled
        clearFocusButton.isEnabled = state.clearFocusButtonEnabled
        highlightButton.isEnabled = state.highlightButtonEnabled
        visibilityButton.isEnabled = state.visibilityButtonEnabled
        // 没有选中节点时仍显示默认的 eye 图标（按钮处于禁用态），避免出现空白按钮
        visibilityButton.image = NSImage(
            systemSymbolName: state.visibilitySymbolName ?? "eye",
            accessibilityDescription: nil
        )
        visibilityButton.toolTip = state.visibilityToolTip
        let hasCapture = store.capture != nil
        resetViewButton.isEnabled = hasCapture
        measureButton.isEnabled = hasCapture
        colorPickerButton.isEnabled = hasCapture
    }

    private func applyConsoleVisibility(_ showsConsole: Bool, animated: Bool) {
        guard lastConsoleVisibility != showsConsole else {
            return
        }

        lastConsoleVisibility = showsConsole
        let hostView = consoleHostView
        let consoleView = consoleController.view
        let targetHeight = showsConsole ? Layout.consoleHeight : 0
        let targetSpacing = showsConsole ? -Layout.verticalSpacing : 0
        let shouldAnimate =
            animated &&
            view.window != nil &&
            view.bounds.width > 0.5 &&
            view.bounds.height > 0.5

        if showsConsole {
            consoleHeightConstraint?.update(offset: targetHeight)
            previewBottomToConsoleConstraint?.update(offset: targetSpacing)
            hostView.isHidden = false
            attachConsoleViewIfNeeded()
            consoleView.isHidden = false
            consoleView.alphaValue = 1
            hostView.alphaValue = shouldAnimate ? 0 : 1
        } else if shouldAnimate == false {
            consoleView.isHidden = true
            consoleView.alphaValue = 0
            detachConsoleView()
            consoleHeightConstraint?.update(offset: targetHeight)
            previewBottomToConsoleConstraint?.update(offset: targetSpacing)
            hostView.alphaValue = 0
            hostView.isHidden = true
            panelView.contentView.layoutSubtreeIfNeeded()
            return
        }

        let applyChanges = {
            hostView.alphaValue = showsConsole ? 1 : 0
            guard self.view.bounds.width > 0.5, self.view.bounds.height > 0.5 else {
                return
            }
            self.panelView.contentView.layoutSubtreeIfNeeded()
        }

        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                applyChanges()
            } completionHandler: {
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    hostView.isHidden = !showsConsole
                    consoleView.isHidden = !showsConsole
                    consoleView.alphaValue = showsConsole ? 1 : 0
                    if showsConsole == false {
                        self.detachConsoleView()
                    }
                }
            }
        } else {
            applyChanges()
            hostView.isHidden = !showsConsole
            consoleView.isHidden = !showsConsole
            consoleView.alphaValue = showsConsole ? 1 : 0
            if showsConsole == false {
                detachConsoleView()
            }
        }
    }

    private func attachConsoleViewIfNeeded() {
        guard consoleController.view.superview !== consoleHostView else {
            return
        }
        consoleHostView.addSubview(consoleController.view)
        consoleController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func detachConsoleView() {
        guard consoleController.view.superview === consoleHostView else {
            return
        }
        consoleController.view.removeFromSuperview()
    }

    // MARK: - 选中

    private func handleNodeClick(_ nodeID: String, modifiers: NSEvent.ModifierFlags) {
        // 测量模式下 Shift+单击固定参照节点，不改变选中。
        if store.inspectionTools.isMeasurementActive, modifiers.contains(.shift) {
            store.inspectionTools.measurementAnchorNodeID = nodeID
            return
        }
        selectNode(withID: nodeID, focusAfterSelection: false)
    }

    private func selectNode(withID nodeID: String, focusAfterSelection: Bool) {
        keyboardSelectionTimer?.invalidate()
        Task { @MainActor [weak self] in
            await self?.store.selectNode(withID: nodeID)
            if focusAfterSelection {
                self?.store.setFocusedNode(nodeID)
            }
        }
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

    /// 复位视角：旋转、平移、支点与缩放全部回到初始状态。
    @objc private func resetView(_ sender: Any?) {
        layeredSceneView.resetView(animated: true)
        store.resetPreviewZoom()
        if let focusedNodeID = store.focusedNodeID {
            layeredSceneView.centerOnNode(focusedNodeID, animated: true)
        }
    }

    @objc private func toggleMeasurement(_ sender: NSButton) {
        let tools = store.inspectionTools
        tools.isMeasurementEnabled.toggle()
        if tools.isMeasurementEnabled == false {
            tools.measurementAnchorNodeID = nil
        }
    }

    @objc private func toggleColorPicker(_ sender: NSButton) {
        store.inspectionTools.isColorPickerEnabled.toggle()
    }

    @objc private func changeDisplayMode(_ sender: NSSegmentedControl) {
        let nextDisplayMode: WorkspacePreviewDisplayMode = sender.selectedSegment == 1 ? .layered : .flat
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
        guard let nodeID = store.selectedNodeID else {
            return
        }
        Task {
            await store.toggleVisibility(for: nodeID)
        }
    }

    @objc private func highlightSelection(_ sender: Any?) {
        Task {
            await store.highlightCurrentSelection()
        }
    }

    @discardableResult
    func handleActivePreviewRotation(_ rotation: CGFloat) -> Bool {
        guard store.capture != nil else {
            return false
        }
        guard store.previewDisplayMode == .layered else {
            return false
        }
        layeredSceneView.applyRotationGesture(rotation)
        return true
    }

    @objc private func showPreviewSettings(_ sender: NSButton) {
        settingsPopover?.close()

        let controller = PreviewLayerSettingsPopoverController(
            layerSpacing: store.previewLayerSpacing,
            showsLayerBorders: store.previewShowsLayerBorders,
            isLayeredMode: store.previewDisplayMode == .layered,
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

    @objc private func showDiagnostics(_ sender: NSButton) {
        diagnosticsPopover?.close()
        let capture = store.capture
        let report = store.inspectionTools.diagnosticsReport(for: capture)
        let controller = LayoutDiagnosticsPopoverController(
            report: report,
            showsOverlay: store.inspectionTools.showsDiagnostics,
            nodeTitleProvider: { nodeID in
                guard let node = capture?.nodes[nodeID] else {
                    return nodeID
                }
                return ViewTreeNodePresentation.classText(for: node)
            },
            onSelectIssue: { [weak self] issue in
                self?.revealNode(issue.nodeID)
            },
            onShowsOverlayChange: { [weak self] showsOverlay in
                self?.store.inspectionTools.showsDiagnostics = showsOverlay
            }
        )
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        diagnosticsPopover = popover
    }

    /// 从诊断列表定位节点：必要时清除不包含它的聚焦，展开祖先并选中。
    private func revealNode(_ nodeID: String) {
        if let capture = store.capture,
           let focusedNodeID = store.focusedNodeID,
           geometry.isNode(nodeID, descendantOf: focusedNodeID, in: capture) == false {
            store.clearFocus()
        }
        store.expandAncestors(of: nodeID)
        Task { @MainActor [weak self] in
            await self?.store.selectNode(withID: nodeID)
        }
    }
}
