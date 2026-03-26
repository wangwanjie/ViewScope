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
final class PreviewPanelController: NSViewController {
    private enum Layout {
        static let consoleHeight: CGFloat = 240
        static let verticalSpacing: CGFloat = 12
    }

    private let store: WorkspaceStore
    private let panelView = WorkspacePanelContainerView()
    private let previewContainerView = NSView()
    private let consoleHostView = NSView()
    private let loadingProgressView = WorkspaceLoadingProgressView()
    private let layeredSceneView = PreviewLayeredSceneView(frame: .zero)
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
    private var isConsoleToggleEnabled = false
    private var lastConsoleVisibility: Bool?
    private var renderCache = PreviewPanelRenderCache.empty
    private var renderScheduled = false
    private var lastLaidOutPreviewSize = CGSize.zero

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
        guard store.capture != nil else { super.magnify(with: event); return }
        layeredSceneView.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard store.capture != nil else { super.scrollWheel(with: event); return }
        layeredSceneView.scrollWheel(with: event)
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
        consoleHostView.wantsLayer = true
        consoleHostView.layer?.masksToBounds = true
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
        panelView.contentView.addSubview(consoleHostView)
        previewContainerView.addSubview(layeredSceneView)
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
        guideView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        loadingProgressView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(2)
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

        if snapshot.isLoadingWorkspace {
            loadingProgressView.startAnimating()
        } else if snapshot.capture != nil {
            loadingProgressView.finishAnimatingIfNeeded()
        } else {
            loadingProgressView.stopImmediately()
        }

        panelView.setTitle(L10n.canvasPreview, subtitle: snapshot.focusedNodeTitle)

        // 检测显示模式变化，先切换维度（含旋转/z间距动画），再更新渲染状态
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

        let nextAutoCenterFocusKey = PreviewPanelRenderDecisions.autoCenterFocusKey(
            focusedNodeID: snapshot.focusedNodeID,
            capture: snapshot.capture
        )
        if autoCenterFocusKey != nextAutoCenterFocusKey {
            autoCenterFocusKey = nextAutoCenterFocusKey
            centerSelectionIfNeeded()
        }

        applyConsoleVisibility(
            renderState.toolbarState.shouldShowConsolePanel,
            animated: lastConsoleVisibility != nil
        )

        if PreviewPanelRenderDecisions.shouldRecenterFullCanvas(
            displayMode: snapshot.previewDisplayMode,
            lastRenderedDisplayMode: lastRenderedDisplayMode,
            focusedNodeID: snapshot.focusedNodeID,
            lastRenderedFocusedNodeID: lastRenderedFocusedNodeID,
            canvasSize: layeredSceneView.canvasSize
        ), isChangingDisplayMode == false {
            layeredSceneView.centerOnNode(snapshot.focusedNodeID ?? snapshot.selectedNodeID ?? context.previewRootNodeID, animated: false)
        }
        lastRenderedDisplayMode = snapshot.previewDisplayMode
        lastRenderedFocusedNodeID = snapshot.focusedNodeID
    }

    private func scheduleRenderCurrentState() {
        if Thread.isMainThread, view.window == nil {
            renderCurrentState()
            return
        }
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
        visibilityButton.image = state.visibilitySymbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        visibilityButton.toolTip = state.visibilityToolTip
    }

    private func applyConsoleVisibility(_ showsConsole: Bool, animated: Bool) {
        guard lastConsoleVisibility != showsConsole else { return }

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
                    guard let self else { return }
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
        guard consoleController.view.superview !== consoleHostView else { return }
        consoleHostView.addSubview(consoleController.view)
        consoleController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func detachConsoleView() {
        guard consoleController.view.superview === consoleHostView else { return }
        consoleController.view.removeFromSuperview()
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
}
