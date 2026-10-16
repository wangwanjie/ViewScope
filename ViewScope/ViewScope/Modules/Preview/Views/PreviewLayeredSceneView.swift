import AppKit
import SceneKit
import ViewScopeServer

/// 唯一预览画布（SCNView），同时处理 flat 和 layered 两种显示模式。
///
/// flat 模式：rotation = 0、z 间距极小，看起来像一张截图。
/// layered 模式：有旋转角度、z 间距拉开，真正的 3D 分层。
///
/// 核心约定：
/// - 节点位置直接使用统一的 top-left 画布坐标；
/// - 只有“独立显示”的节点才建 SceneKit 平面，纹理从根截图按可见区域裁切；
/// - 节点前后关系由 `PreviewLayeredScenePlan` 的 zIndex 决定。
///
/// 增量更新：
/// - 结构（capture / 截图 / 展开状态 / 预览根）变化：重新生成计划，按 nodeID 复用平面与纹理；
/// - 层间距、显示模式变化：只更新 z 位置（可动画）；
/// - 边框、选中、悬停、诊断变化：只更新外观与覆盖层。
final class PreviewLayeredSceneView: SCNView {
    /// 结构性输入；相同则无需重新生成计划。
    private struct StructuralState: Equatable {
        let captureID: String
        let imageIdentifier: ObjectIdentifier
        let canvasSize: CGSize
        let previewRootNodeID: String?
        let focusedNodeID: String?
        let expandedNodeIDs: Set<String>
        let showsSystemWrapperViews: Bool
    }

    /// 命中测试结果：节点与命中点的画布坐标。
    struct HitResult {
        let nodeID: String?
        let canvasPoint: CGPoint
    }

    private let stageNode = SCNNode()
    private let cameraNode = SCNNode()
    private let selectionOverlayNode = SCNNode()
    private let selectionFillPlane = SCNPlane(width: 1, height: 1)
    private let selectionFillNode = SCNNode()
    private let selectionBorderNode = SCNNode()
    private let hoverOverlayNode = SCNNode()
    private let diagnosticsOverlayNode = SCNNode()

    private var displayNodes: [String: PreviewLayeredDisplayNode] = [:]
    private(set) var plan: PreviewLayeredScenePlan?
    private var hitTestResolver: PreviewHitTestResolver?
    private var structuralState: StructuralState?
    /// 纹理缓存：命名空间为 captureID + 截图对象，同一次抓取的多次刷新复用纹理。
    private var textureCache: [String: NSImage] = [:]
    private var textureCacheOrder: [String] = []
    private var textureCacheNamespace: String?
    private var normalizedRootImage: NSImage?
    private var rootPixelScale: CGFloat = 1
    private var decodedNodeImages: [String: NSImage] = [:]
    private var nodeScreenshotIndex: [String: ViewScopeNodePreviewScreenshotSet] = [:]

    /// 旋转（x = pitch，y = yaw）。
    private var stageRotation = CGPoint.zero
    /// 屏幕空间平移（scene 单位），作用在旋转之后，因此平移方向始终与屏幕一致。
    private var stageTranslation = CGPoint.zero
    /// 旋转支点（stage 坐标，scene 单位）：居中某节点时把支点移到它的中心，旋转不会把它甩出视野。
    private var stagePivot = CGPoint.zero
    /// 用户是否手动旋转过，切回 3D 时恢复上次角度而非默认角度。
    private var hasUserRotated = false
    private var mouseDownPoint: CGPoint?
    private var lastDragPoint: CGPoint?
    private var didDrag = false
    private var dragPans = false
    private var suppressSceneRefresh = false
    private var trackingAreaRef: NSTrackingArea?
    private var pendingHoverPoint: CGPoint?
    private var isHoverProcessingScheduled = false

    var onNodeClick: ((String, NSEvent.ModifierFlags) -> Void)?
    var onNodeDoubleClick: ((String) -> Void)?
    var onScaleChanged: ((CGFloat) -> Void)?
    /// 鼠标悬停的节点变化（nil 表示离开所有节点）。
    var onHoverChanged: ((String?) -> Void)?
    /// 光标所在的画布坐标（nil 表示不在画布上）。
    var onCursorCanvasPointChanged: ((CGPoint?) -> Void)?
    /// 取色模式下单击：返回画布坐标。
    var onColorPickClick: ((CGPoint) -> Void)?
    /// 键盘事件交给控制器统一处理；返回 true 表示已处理。
    var onKeyDown: ((NSEvent) -> Bool)?
    /// 相机或节点位置变化（覆盖层需要重新投影）。
    var onViewportChanged: (() -> Void)?
    /// 是否处于取色模式（单击不选中节点）。
    var isColorPickerActive = false

    var capture: ViewScopeCapturePayload? {
        didSet {
            guard suppressSceneRefresh == false else {
                return
            }
            refreshScene()
        }
    }

    var image: NSImage? {
        didSet {
            guard suppressSceneRefresh == false else {
                return
            }
            refreshScene()
        }
    }

    var canvasSize: CGSize = .zero {
        didSet {
            guard suppressSceneRefresh == false else {
                return
            }
            refreshScene()
        }
    }

    var selectedNodeID: String? {
        didSet {
            guard suppressSceneRefresh == false else {
                return
            }
            updateSelectionAppearance()
        }
    }

    /// 聚焦节点：预览只显示聚焦子树（与层级树一致），因此属于结构性输入。
    var focusedNodeID: String? {
        didSet {
            guard suppressSceneRefresh == false, oldValue != focusedNodeID else {
                return
            }
            refreshScene()
        }
    }

    var highlightedCanvasRect: CGRect? {
        didSet {
            guard suppressSceneRefresh == false else {
                return
            }
            updateSelectionAppearance()
        }
    }

    var previewRootNodeID: String? {
        didSet {
            guard suppressSceneRefresh == false else {
                return
            }
            refreshScene()
        }
    }

    var geometryMode: PreviewCanvasGeometryMode = .directGlobalCanvasRect

    /// 显示模式只影响旋转与 z 间距，不触发结构重建。
    var displayMode: WorkspacePreviewDisplayMode = .flat {
        didSet {
            guard suppressSceneRefresh == false, oldValue != displayMode else {
                return
            }
            applyDimension(animated: false)
        }
    }

    var previewLayerSpacing: CGFloat = 22 {
        didSet {
            guard suppressSceneRefresh == false, oldValue != previewLayerSpacing else {
                return
            }
            updateZPositions(animated: false)
        }
    }

    var previewShowsLayerBorders = true {
        didSet {
            guard suppressSceneRefresh == false, oldValue != previewShowsLayerBorders else {
                return
            }
            updateSelectionAppearance()
        }
    }

    var previewExpandedNodeIDs = Set<String>() {
        didSet {
            guard suppressSceneRefresh == false else {
                return
            }
            refreshScene()
        }
    }

    var showsSystemWrapperViews = false {
        didSet {
            guard suppressSceneRefresh == false else {
                return
            }
            refreshScene()
        }
    }

    /// 悬停节点（树或预览任一侧），以虚线框显示。
    var hoveredNodeID: String? {
        didSet {
            guard oldValue != hoveredNodeID else {
                return
            }
            updateHoverOverlay()
        }
    }

    /// 布局诊断：nodeID -> 最高严重程度。为空或 `showsDiagnostics == false` 时不描边。
    var diagnosticSeverities: [String: LayoutDiagnosticIssue.Severity] = [:] {
        didSet {
            guard oldValue != diagnosticSeverities else {
                return
            }
            updateDiagnosticsOverlay()
        }
    }

    var showsDiagnostics = true {
        didSet {
            guard oldValue != showsDiagnostics else {
                return
            }
            updateDiagnosticsOverlay()
        }
    }

    var zoomScale: CGFloat = 1 {
        didSet {
            guard oldValue != zoomScale else {
                return
            }
            updateCamera()
        }
    }

    /// 当前是否处于无旋转的平面投影（测量、取色等 2D 工具只在此时精确）。
    var isFlatProjection: Bool {
        displayMode == .flat || (abs(stageRotation.x) < 0.0001 && abs(stageRotation.y) < 0.0001)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateCamera()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        lastDragPoint = point
        didDrag = false
        // flat 模式下拖拽平移；layered 模式下拖拽旋转，按住 Shift 时平移。
        dragPans = displayMode == .flat || event.modifierFlags.contains(.shift)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastDragPoint else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - (mouseDownPoint?.x ?? point.x), point.y - (mouseDownPoint?.y ?? point.y)) > 2 {
            didDrag = true
        }
        guard didDrag else {
            return
        }

        let delta = CGPoint(x: point.x - lastDragPoint.x, y: point.y - lastDragPoint.y)
        if dragPans {
            let unitsPerPoint = currentUnitsPerPoint()
            stageTranslation.x += delta.x * unitsPerPoint
            stageTranslation.y += delta.y * unitsPerPoint
            clampTranslation()
            applyStageTransform()
        } else {
            stageRotation = PreviewLayeredSceneInteraction.updatedRotation(
                current: stageRotation,
                delta: delta
            )
            hasUserRotated = true
            applyStageTransform()
        }
        self.lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            lastDragPoint = nil
            didDrag = false
        }

        guard didDrag == false else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let hit = hitResult(at: point)
        if isColorPickerActive {
            if let hit {
                onColorPickClick?(hit.canvasPoint)
            }
            return
        }
        guard let nodeID = hit?.nodeID else {
            return
        }
        if event.clickCount >= 2 {
            onNodeDoubleClick?(nodeID)
        } else {
            onNodeClick?(nodeID, event.modifierFlags)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // 合并高频的鼠标移动：同一个 runloop 周期只做一次命中测试。
        pendingHoverPoint = convert(event.locationInWindow, from: nil)
        guard isHoverProcessingScheduled == false else {
            return
        }
        isHoverProcessingScheduled = true
        MainRunLoopScheduler.perform { [weak self] in
            self?.processPendingHover()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pendingHoverPoint = nil
        onHoverChanged?(nil)
        onCursorCanvasPointChanged?(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 4
            let nextScale = zoomScale * (1 - (delta * 0.01))
            setZoomScale(nextScale, anchorPoint: point, notifiesStore: true)
            return
        }

        // 精确滚动（触控板）的 delta 单位是 pt；传统滚轮的 delta 是“行”，换算成固定距离。
        let multiplier = event.hasPreciseScrollingDeltas ? 1 : PreviewLayeredSceneConstants.lineScrollDistance
        let unitsPerPoint = currentUnitsPerPoint()
        stageTranslation.x += event.scrollingDeltaX * multiplier * unitsPerPoint
        stageTranslation.y -= event.scrollingDeltaY * multiplier * unitsPerPoint
        clampTranslation()
        applyStageTransform()
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let nextScale = zoomScale * (1 + event.magnification)
        setZoomScale(nextScale, anchorPoint: point, notifiesStore: true)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - 公共操作

    func applyRotationGesture(_ rotation: CGFloat) {
        guard displayMode == .layered else {
            return
        }
        stageRotation = PreviewLayeredSceneInteraction.updatedRotation(
            current: stageRotation,
            delta: CGPoint(x: rotation * 1.8, y: 0)
        )
        hasUserRotated = true
        applyStageTransform()
    }

    /// 把某个节点居中（支点移到节点中心，平移归零）；nodeID 为 nil 时居中整个画布。
    func centerOnNode(_ nodeID: String?, animated: Bool = false) {
        if let nodeID, let item = plan?.item(for: nodeID) {
            stagePivot = sceneCenter(for: item.visibleRect)
        } else {
            stagePivot = .zero
        }
        stageTranslation = .zero
        applyStageTransform(animated: animated)
    }

    /// 复位视角：旋转回默认角度、平移与支点归零。缩放由调用方通过 store 复位。
    func resetView(animated: Bool) {
        hasUserRotated = false
        stageRotation = displayMode == .layered
            ? PreviewLayeredSceneInteraction.rotationWhenEnteringLayered(from: .zero)
            : .zero
        stageTranslation = .zero
        stagePivot = .zero
        applyStageTransform(animated: animated)
    }

    /// 切换显示模式（flat ↔ layered），带可选动画。只改旋转与 z 位置，不重建平面。
    func setDimension(_ dimension: WorkspacePreviewDisplayMode, animated: Bool) {
        guard dimension != displayMode else {
            return
        }
        suppressSceneRefresh = true
        displayMode = dimension
        suppressSceneRefresh = false
        applyDimension(animated: animated)
    }

    func applyRenderState(
        capture: ViewScopeCapturePayload?,
        image: NSImage?,
        canvasSize: CGSize,
        selectedNodeID: String?,
        focusedNodeID: String?,
        highlightedCanvasRect: CGRect?,
        previewRootNodeID: String?,
        geometryMode: PreviewCanvasGeometryMode,
        displayMode: WorkspacePreviewDisplayMode,
        zoomScale: CGFloat,
        previewLayerSpacing: CGFloat,
        previewShowsLayerBorders: Bool,
        previewExpandedNodeIDs: Set<String>,
        showsSystemWrapperViews: Bool
    ) {
        let needsStructuralRefresh =
            capture?.captureID != self.capture?.captureID ||
            image !== self.image ||
            canvasSize != self.canvasSize ||
            previewRootNodeID != self.previewRootNodeID ||
            focusedNodeID != self.focusedNodeID ||
            previewExpandedNodeIDs != self.previewExpandedNodeIDs ||
            showsSystemWrapperViews != self.showsSystemWrapperViews ||
            (capture != nil && plan == nil)
        let needsDimensionUpdate = displayMode != self.displayMode
        let needsDepthUpdate = previewLayerSpacing != self.previewLayerSpacing

        suppressSceneRefresh = true
        self.capture = capture
        self.image = image
        self.canvasSize = canvasSize
        self.selectedNodeID = selectedNodeID
        self.focusedNodeID = focusedNodeID
        self.highlightedCanvasRect = highlightedCanvasRect
        self.previewRootNodeID = previewRootNodeID
        self.geometryMode = geometryMode
        self.displayMode = displayMode
        self.zoomScale = zoomScale
        self.previewLayerSpacing = previewLayerSpacing
        self.previewShowsLayerBorders = previewShowsLayerBorders
        self.previewExpandedNodeIDs = previewExpandedNodeIDs
        self.showsSystemWrapperViews = showsSystemWrapperViews
        suppressSceneRefresh = false

        if needsStructuralRefresh {
            refreshScene()
        }
        if needsDimensionUpdate {
            applyDimension(animated: false)
        } else if needsDepthUpdate, needsStructuralRefresh == false {
            updateZPositions(animated: false)
        }
        if needsStructuralRefresh == false {
            updateSelectionAppearance()
            updateCamera()
        }
    }

    /// 画布坐标的矩形投影到视图坐标（仅在平面投影下精确），供 2D 覆盖层使用。
    func viewRect(forCanvasRect rect: CGRect, nodeID: String?) -> CGRect? {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return nil
        }
        let z = nodeID.flatMap { planeZ(for: $0) } ?? 0
        let topLeft = viewPoint(forCanvasPoint: CGPoint(x: rect.minX, y: rect.minY), z: z)
        let bottomRight = viewPoint(forCanvasPoint: CGPoint(x: rect.maxX, y: rect.maxY), z: z)
        guard let topLeft, let bottomRight else {
            return nil
        }
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    /// 画布坐标点投影到视图坐标（y 向上的 NSView 坐标）。
    func viewPoint(forCanvasPoint point: CGPoint, z: CGFloat = 0) -> CGPoint? {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return nil
        }
        let unitScale = PreviewLayeredSceneConstants.unitScale
        let local = SCNVector3(
            (point.x - canvasSize.width / 2) * unitScale,
            (canvasSize.height / 2 - point.y) * unitScale,
            z
        )
        if isFlatProjection {
            // 无旋转时按相机参数解析计算：使用模型值（动画目标值），不依赖 SceneKit 的 presentation 状态，
            // 动画进行中或尚未渲染时覆盖层也能对齐最终位置。
            let unitsPerPoint = currentUnitsPerPoint()
            let distance = PreviewLayeredSceneConstants.cameraDistance
            let worldX = local.x - stagePivot.x + stageTranslation.x
            let worldY = local.y - stagePivot.y + stageTranslation.y
            let perspective = distance / max(distance - local.z, 0.001)
            return CGPoint(
                x: bounds.midX + worldX / unitsPerPoint * perspective,
                y: bounds.midY + worldY / unitsPerPoint * perspective
            )
        }
        let world = stageNode.convertPosition(local, to: nil)
        let projected = projectPoint(world)
        return CGPoint(x: projected.x, y: projected.y)
    }

    /// 视图坐标点下的节点与画布坐标。
    func hitResult(at viewPoint: CGPoint) -> HitResult? {
        let results = hitTest(viewPoint, options: [
            SCNHitTestOption.categoryBitMask: PreviewLayeredSceneConstants.selectableCategoryMask,
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.ignoreHiddenNodes: false
        ])
        var hits: [PreviewHitTestResolver.PlaneHit] = []
        for result in results {
            guard let planeNodeID = result.node.name,
                  let item = plan?.item(for: planeNodeID) else {
                continue
            }
            let unitScale = PreviewLayeredSceneConstants.unitScale
            let local = result.localCoordinates
            let rect = item.visibleRect
            let canvasPoint = CGPoint(
                x: rect.midX + CGFloat(local.x) / unitScale,
                y: rect.midY - CGFloat(local.y) / unitScale
            )
            hits.append(PreviewHitTestResolver.PlaneHit(planeNodeID: planeNodeID, canvasPoint: canvasPoint))
        }
        guard let firstHit = hits.first else {
            return nil
        }
        return HitResult(nodeID: hitTestResolver?.nodeID(for: hits), canvasPoint: firstHit.canvasPoint)
    }

    /// 节点的可见区域（统一画布坐标）。
    func visibleCanvasRect(for nodeID: String) -> CGRect? {
        plan?.item(for: nodeID)?.visibleRect
    }

    // MARK: - 初始化

    private func commonInit() {
        // SceneKit 只负责舞台和相机，真正的节点构造在 `refreshScene` 里。
        let scene = SCNScene()
        self.scene = scene
        allowsCameraControl = false
        showsStatistics = false
        backgroundColor = .clear
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("workspace.previewLayeredScene")

        stageNode.name = "stage"
        scene.rootNode.addChildNode(stageNode)

        selectionOverlayNode.name = "selection-overlay"
        selectionFillPlane.firstMaterial?.isDoubleSided = true
        selectionFillPlane.firstMaterial?.lightingModel = .constant
        selectionFillPlane.firstMaterial?.diffuse.contents = NSColor.systemBlue
        selectionFillPlane.firstMaterial?.writesToDepthBuffer = false
        selectionFillPlane.firstMaterial?.readsFromDepthBuffer = false
        selectionFillNode.geometry = selectionFillPlane
        // 覆盖层永远最后绘制，flat 模式下也不会被子层纹理盖住。
        selectionFillNode.renderingOrder = PreviewLayeredSceneConstants.overlayRenderingOrder
        selectionBorderNode.renderingOrder = PreviewLayeredSceneConstants.overlayRenderingOrder + 1
        selectionOverlayNode.addChildNode(selectionFillNode)
        selectionBorderNode.position.z = PreviewLayeredSceneConstants.borderNodeZOffset
        selectionOverlayNode.addChildNode(selectionBorderNode)
        selectionOverlayNode.isHidden = true

        hoverOverlayNode.name = "hover-overlay"
        hoverOverlayNode.renderingOrder = PreviewLayeredSceneConstants.overlayRenderingOrder + 3
        diagnosticsOverlayNode.name = "diagnostics-overlay"
        diagnosticsOverlayNode.renderingOrder = PreviewLayeredSceneConstants.overlayRenderingOrder + 2
        attachOverlayNodes()

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.zNear = 0.01
        camera.zFar = 500
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, PreviewLayeredSceneConstants.cameraDistance)
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode

        applyStageTransform()
        updateCamera()
    }

    private func attachOverlayNodes() {
        for overlay in [diagnosticsOverlayNode, selectionOverlayNode, hoverOverlayNode] where overlay.parent !== stageNode {
            stageNode.addChildNode(overlay)
        }
    }

    // MARK: - 结构刷新

    private func refreshScene() {
        guard let capture,
              let image,
              canvasSize.width > 0,
              canvasSize.height > 0,
              image.size.width > 0,
              image.size.height > 0 else {
            clearScene()
            return
        }

        let nextStructuralState = StructuralState(
            captureID: capture.captureID,
            imageIdentifier: ObjectIdentifier(image),
            canvasSize: canvasSize,
            previewRootNodeID: previewRootNodeID,
            focusedNodeID: focusedNodeID,
            expandedNodeIDs: previewExpandedNodeIDs,
            showsSystemWrapperViews: showsSystemWrapperViews
        )
        guard nextStructuralState != structuralState || plan == nil else {
            updateSelectionAppearance()
            updateCamera()
            return
        }

        prepareTextureNamespace(capture: capture, image: image)
        let nextPlan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: canvasSize,
            expandedNodeIDs: previewExpandedNodeIDs,
            previewRootNodeID: previewRootNodeID,
            geometryMode: geometryMode,
            showsSystemWrapperViews: showsSystemWrapperViews,
            isolatedRootNodeID: focusedNodeID
        )
        reconcileDisplayNodes(plan: nextPlan, capture: capture)
        plan = nextPlan
        hitTestResolver = PreviewHitTestResolver(plan: nextPlan, capture: capture)
        structuralState = nextStructuralState

        updateZPositions(animated: false)
        updateSelectionAppearance()
        updateCamera()
    }

    /// 按 nodeID 复用已有平面：只有纹理 key 变化的平面才重新裁切纹理。
    private func reconcileDisplayNodes(plan: PreviewLayeredScenePlan, capture: ViewScopeCapturePayload) {
        // 只有独立显示的节点需要平面；折叠节点的像素已经包含在所属平面的纹理里。
        let renderableItems = plan.items.filter {
            $0.displayingIndependently &&
                $0.visibleRect.width > 0.5 &&
                $0.visibleRect.height > 0.5
        }
        let orderedItems = renderableItems.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex {
                return lhs.zIndex < rhs.zIndex
            }
            return lhs.displayOrder < rhs.displayOrder
        }

        var nextDisplayNodes: [String: PreviewLayeredDisplayNode] = [:]
        nextDisplayNodes.reserveCapacity(orderedItems.count)
        for (order, item) in orderedItems.enumerated() {
            let displayNode = displayNodes[item.nodeID] ?? PreviewLayeredDisplayNode()
            let textureKey = textureKey(for: item, capture: capture)
            displayNode.configure(
                item: item,
                textureKey: textureKey,
                canvasSize: plan.canvasSize,
                // 按 (zIndex, displayOrder) 由后往前绘制，每个平面占 4 个渲染序号。
                renderingOrder: order * 4
            ) {
                self.textureImage(for: item, key: textureKey, capture: capture, canvasSize: plan.canvasSize)
            }
            if displayNode.node.parent !== stageNode {
                stageNode.addChildNode(displayNode.node)
            }
            nextDisplayNodes[item.nodeID] = displayNode
        }

        for (nodeID, displayNode) in displayNodes where nextDisplayNodes[nodeID] == nil {
            displayNode.node.removeFromParentNode()
        }
        displayNodes = nextDisplayNodes
        attachOverlayNodes()
    }

    private func clearScene() {
        for displayNode in displayNodes.values {
            displayNode.node.removeFromParentNode()
        }
        displayNodes.removeAll()
        attachOverlayNodes()
        plan = nil
        hitTestResolver = nil
        structuralState = nil
        textureCache.removeAll()
        textureCacheOrder.removeAll()
        textureCacheNamespace = nil
        normalizedRootImage = nil
        decodedNodeImages.removeAll()
        nodeScreenshotIndex.removeAll()
        selectionOverlayNode.isHidden = true
        selectionBorderNode.geometry = nil
        hoverOverlayNode.geometry = nil
        diagnosticsOverlayNode.childNodes.forEach { $0.removeFromParentNode() }
        updateSelectionOverlay()
    }

    // MARK: - 纹理

    private func prepareTextureNamespace(capture: ViewScopeCapturePayload, image: NSImage) {
        let namespace = "\(capture.captureID)|\(ObjectIdentifier(image).hashValue)|\(canvasSize.width)x\(canvasSize.height)"
        guard namespace != textureCacheNamespace else {
            return
        }
        textureCacheNamespace = namespace
        textureCache.removeAll(keepingCapacity: true)
        textureCacheOrder.removeAll(keepingCapacity: true)
        normalizedRootImage = nil
        decodedNodeImages.removeAll(keepingCapacity: true)
        // 截图集合按 nodeID 建索引，避免每个平面线性查找。
        var index: [String: ViewScopeNodePreviewScreenshotSet] = [:]
        for screenshotSet in capture.nodePreviewScreenshots {
            index[screenshotSet.nodeID] = screenshotSet
        }
        nodeScreenshotIndex = index
        rootPixelScale = PreviewLayeredSceneSnapshotFactory.pixelScale(of: image, canvasSize: canvasSize)
        // 新的 capture 会让所有平面的纹理 key 失效（key 中包含命名空间）。
    }

    private enum TextureSource: String {
        case root
        case shell
        case solo
        case group
    }

    private func textureSource(for item: PreviewLayeredScenePlan.Item, capture: ViewScopeCapturePayload) -> TextureSource {
        if let source = nodeScreenshotSource(for: item, capture: capture) {
            return source
        }
        if previewExpandedNodeIDs.contains(item.nodeID),
           item.nodeID == previewRootNodeID || capture.rootNodeIDs.contains(item.nodeID) {
            return .shell
        }
        return .root
    }

    /// 纹理 key：命名空间 + 节点 + 来源 + 可见区域 + punch-out。任一变化才需要重新裁切。
    private func textureKey(for item: PreviewLayeredScenePlan.Item, capture: ViewScopeCapturePayload) -> String {
        let source = textureSource(for: item, capture: capture)
        let rect = item.visibleRect
        var key = "\(textureCacheNamespace ?? "")|\(item.nodeID)|\(source.rawValue)|\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)"
        for punchedOutRect in item.punchedOutRects {
            key += "|\(punchedOutRect.minX),\(punchedOutRect.minY),\(punchedOutRect.width),\(punchedOutRect.height)"
        }
        return key
    }

    private func textureImage(
        for item: PreviewLayeredScenePlan.Item,
        key: String,
        capture: ViewScopeCapturePayload,
        canvasSize: CGSize
    ) -> NSImage {
        if let cached = textureCache[key] {
            return cached
        }
        let image: NSImage
        let source = textureSource(for: item, capture: capture)
        switch source {
        case .solo, .group:
            if let nodeImage = nodePreviewImage(for: item, capture: capture) {
                image = PreviewLayeredSceneSnapshotFactory.makeTextureImage(
                    fromNodeImage: nodeImage,
                    item: item,
                    pixelScale: rootPixelScale,
                    appliesPunchOuts: source == .group
                )
            } else {
                image = rootCropTexture(for: item, canvasSize: canvasSize)
            }
        case .shell:
            image = PreviewLayeredSceneSnapshotFactory.makeTransparentTopLeftImage(size: item.visibleRect.size)
        case .root:
            image = rootCropTexture(for: item, canvasSize: canvasSize)
        }
        storeTexture(image, for: key)
        return image
    }

    private func rootCropTexture(for item: PreviewLayeredScenePlan.Item, canvasSize: CGSize) -> NSImage {
        let rootImage: NSImage
        if let normalizedRootImage {
            rootImage = normalizedRootImage
        } else if let image {
            let normalized = PreviewLayeredSceneSnapshotFactory.makeTopLeftWorkingImage(from: image, size: canvasSize)
            normalizedRootImage = normalized
            rootImage = normalized
        } else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        return PreviewLayeredSceneSnapshotFactory.makeTextureImage(
            for: item,
            rootImage: rootImage,
            canvasSize: canvasSize,
            pixelScale: rootPixelScale
        )
    }

    /// 简单的 FIFO 上限，避免反复展开/折叠时缓存无限增长。
    private func storeTexture(_ image: NSImage, for key: String) {
        textureCache[key] = image
        textureCacheOrder.append(key)
        let limit = 1024
        guard textureCacheOrder.count > limit else {
            return
        }
        let overflow = textureCacheOrder.count - limit
        for staleKey in textureCacheOrder.prefix(overflow) {
            textureCache.removeValue(forKey: staleKey)
        }
        textureCacheOrder.removeFirst(overflow)
    }

    /// 节点自身截图的来源：展开的容器优先 solo（不含子节点），否则 group。
    /// 截图尺寸与节点画布尺寸不一致（存在 transform）时放弃截图，避免拉伸变形。
    private func nodeScreenshotSource(for item: PreviewLayeredScenePlan.Item, capture: ViewScopeCapturePayload) -> TextureSource? {
        guard let screenshotSet = nodeScreenshotIndex[item.nodeID] else {
            return nil
        }
        let size = screenshotSet.size
        guard abs(CGFloat(size.width) - item.displayRect.width) <= 1,
              abs(CGFloat(size.height) - item.displayRect.height) <= 1 else {
            return nil
        }
        let prefersSolo = previewExpandedNodeIDs.contains(item.nodeID) &&
            (capture.nodes[item.nodeID]?.childIDs.isEmpty == false)
        if prefersSolo, let solo = screenshotSet.soloPNGBase64, solo.isEmpty == false {
            return .solo
        }
        if let group = screenshotSet.groupPNGBase64, group.isEmpty == false {
            return .group
        }
        return nil
    }

    private func nodePreviewImage(for item: PreviewLayeredScenePlan.Item, capture: ViewScopeCapturePayload) -> NSImage? {
        guard let source = nodeScreenshotSource(for: item, capture: capture),
              let screenshotSet = nodeScreenshotIndex[item.nodeID] else {
            return nil
        }
        let cacheKey = "\(item.nodeID)|\(source.rawValue)"
        if let cached = decodedNodeImages[cacheKey] {
            return cached
        }
        let base64PNG = source == .solo ? screenshotSet.soloPNGBase64 : screenshotSet.groupPNGBase64
        guard let base64PNG,
              let data = Data(base64Encoded: base64PNG),
              let image = NSImage(data: data) else {
            return nil
        }
        image.size = screenshotSet.size.cgSize
        decodedNodeImages[cacheKey] = image
        return image
    }

    // MARK: - z 位置

    private func applyDimension(animated: Bool) {
        if displayMode == .layered, hasUserRotated == false {
            stageRotation = PreviewLayeredSceneInteraction.rotationWhenEnteringLayered(from: .zero)
        }
        applyStageTransform(animated: animated)
        updateZPositions(animated: animated)
    }

    /// 就地更新所有平面的 z 位置：flat ↔ layered 切换、层间距拖动都只走这里。
    private func updateZPositions(animated: Bool) {
        guard let plan else {
            return
        }
        let renderedItems = plan.items.filter { displayNodes[$0.nodeID] != nil }
        let centeredMidZIndex = CGFloat(renderedItems.map(\.zIndex).max() ?? 0) * 0.5
        let zStep = PreviewLayeredSceneConstants.depthStep(displayMode: displayMode, layerSpacing: previewLayerSpacing)
        var itemCountByZIndex: [Int: Int] = [:]

        let applyPositions = {
            for item in renderedItems {
                let countAtCurrentZIndex = itemCountByZIndex[item.zIndex, default: 0]
                itemCountByZIndex[item.zIndex] = countAtCurrentZIndex + 1
                let z = (CGFloat(item.zIndex) - centeredMidZIndex) * zStep +
                    CGFloat(countAtCurrentZIndex) * PreviewLayeredSceneConstants.sameZIndexBiasStep
                self.displayNodes[item.nodeID]?.updateZPosition(z)
            }
            self.updateOverlayPositions()
        }

        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            applyPositions()
            SCNTransaction.commit()
        } else {
            applyPositions()
        }
        onViewportChanged?()
    }

    /// 节点所在平面的 z；折叠节点取所属平面的 z。
    private func planeZ(for nodeID: String) -> CGFloat? {
        guard let item = plan?.item(for: nodeID) else {
            return nil
        }
        return displayNodes[item.planeOwnerNodeID]?.zPosition ?? displayNodes[item.nodeID]?.zPosition
    }

    // MARK: - 外观与覆盖层

    private func updateSelectionAppearance() {
        let usesExplicitSelectionOverlay = selectedNodeID != nil && highlightedCanvasRect != nil
        for (nodeID, displayNode) in displayNodes {
            displayNode.updateAppearance(
                isSelected: usesExplicitSelectionOverlay == false && nodeID == selectedNodeID,
                isFocused: nodeID == focusedNodeID,
                showsBorder: previewShowsLayerBorders
            )
        }
        updateOverlayPositions()
    }

    private func updateOverlayPositions() {
        updateSelectionOverlay()
        updateHoverOverlay()
        updateDiagnosticsOverlay()
    }

    private func updateSelectionOverlay() {
        guard let selectedNodeID,
              let highlightedCanvasRect,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            selectionOverlayNode.isHidden = true
            selectionBorderNode.geometry = nil
            return
        }

        let displayRect = plan?.item(for: selectedNodeID)?.visibleRect ?? highlightedCanvasRect
        guard displayRect.width > 0.5,
              displayRect.height > 0.5 else {
            selectionOverlayNode.isHidden = true
            selectionBorderNode.geometry = nil
            return
        }

        let unitScale = PreviewLayeredSceneConstants.unitScale
        selectionFillPlane.width = max(displayRect.width * unitScale, 0.001)
        selectionFillPlane.height = max(displayRect.height * unitScale, 0.001)
        selectionFillNode.opacity = 0.24
        selectionBorderNode.geometry = PreviewLayeredSceneSnapshotFactory.makeBorderGeometry(
            size: displayRect.size,
            unitScale: unitScale,
            color: NSColor.systemBlue
        )

        let center = sceneCenter(for: displayRect)
        // overlay 放在所属平面前面一点；找不到平面时放在最前面。
        let baseZ = planeZ(for: selectedNodeID) ?? (displayNodes.values.map(\.zPosition).max() ?? 0)
        let overlayZ = baseZ + PreviewLayeredSceneConstants.selectionOverlayZOffset
        selectionOverlayNode.position = SCNVector3(center.x, center.y, overlayZ)
        selectionOverlayNode.isHidden = false
    }

    private func updateHoverOverlay() {
        guard let hoveredNodeID,
              hoveredNodeID != selectedNodeID,
              let item = plan?.item(for: hoveredNodeID),
              item.visibleRect.width > 0.5,
              item.visibleRect.height > 0.5 else {
            hoverOverlayNode.geometry = nil
            return
        }
        let z = (planeZ(for: hoveredNodeID) ?? 0) + PreviewLayeredSceneConstants.hoverOverlayZOffset
        let unitScale = PreviewLayeredSceneConstants.unitScale
        let segments = PreviewLayeredSceneSnapshotFactory.rectangleSegments(
            center: sceneCenter(for: item.visibleRect),
            size: CGSize(width: item.visibleRect.width * unitScale, height: item.visibleRect.height * unitScale),
            z: z,
            dashLength: 4 * unitScale
        )
        hoverOverlayNode.geometry = PreviewLayeredSceneSnapshotFactory.makeSegmentsGeometry(
            segments: segments,
            color: NSColor.systemTeal
        )
    }

    /// 诊断描边：同一种颜色的所有矩形合并成一个几何体，数量再多也只有两个 draw call。
    private func updateDiagnosticsOverlay() {
        diagnosticsOverlayNode.childNodes.forEach { $0.removeFromParentNode() }
        guard showsDiagnostics,
              diagnosticSeverities.isEmpty == false,
              let plan else {
            return
        }
        let unitScale = PreviewLayeredSceneConstants.unitScale
        var segmentsBySeverity: [LayoutDiagnosticIssue.Severity: [(SCNVector3, SCNVector3)]] = [:]
        for (nodeID, severity) in diagnosticSeverities where severity >= .warning {
            guard let item = plan.item(for: nodeID),
                  item.visibleRect.width > 0.5,
                  item.visibleRect.height > 0.5 else {
                continue
            }
            let z = (planeZ(for: nodeID) ?? 0) + PreviewLayeredSceneConstants.diagnosticsOverlayZOffset
            segmentsBySeverity[severity, default: []].append(
                contentsOf: PreviewLayeredSceneSnapshotFactory.rectangleSegments(
                    center: sceneCenter(for: item.visibleRect),
                    size: CGSize(width: item.visibleRect.width * unitScale, height: item.visibleRect.height * unitScale),
                    z: z
                )
            )
        }
        for (severity, segments) in segmentsBySeverity {
            guard let geometry = PreviewLayeredSceneSnapshotFactory.makeSegmentsGeometry(
                segments: segments,
                color: severity.color.withAlphaComponent(0.9)
            ) else {
                continue
            }
            let node = SCNNode(geometry: geometry)
            node.name = "diagnostics-\(severity.rawValue)"
            node.renderingOrder = PreviewLayeredSceneConstants.overlayRenderingOrder + 2
            diagnosticsOverlayNode.addChildNode(node)
        }
    }

    // MARK: - 相机与舞台

    private func applyStageTransform(rotation: CGPoint? = nil, animated: Bool = false) {
        let nextRotation = rotation ?? (displayMode == .flat ? .zero : stageRotation)
        let apply = {
            // 变换顺序：先把支点移到原点，再旋转，最后做屏幕空间平移。
            self.stageNode.pivot = SCNMatrix4MakeTranslation(self.stagePivot.x, self.stagePivot.y, 0)
            self.stageNode.eulerAngles = SCNVector3(nextRotation.x, nextRotation.y, 0)
            self.stageNode.position = SCNVector3(self.stageTranslation.x, self.stageTranslation.y, 0)
        }

        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            apply()
            SCNTransaction.commit()
        } else {
            apply()
        }
        onViewportChanged?()
    }

    private func baseFocalLength() -> CGFloat? {
        guard canvasSize.width > 0.5, canvasSize.height > 0.5,
              bounds.width > 0.5, bounds.height > 0.5 else {
            return nil
        }
        let fillRatio = PreviewLayeredSceneConstants.defaultFillRatio
        let fitScale = min(bounds.width / canvasSize.width, bounds.height / canvasSize.height) * fillRatio
        // SCNCamera 的投影矩阵以**垂直** sensor 尺寸（默认 24mm）为基准，
        // 因此从 fitScale 反推 focalLength 时必须用 sensorHeight 和 bounds.height。
        return fitScale * PreviewLayeredSceneConstants.cameraDistance * PreviewLayeredSceneConstants.cameraSensorHeight /
            (bounds.height * PreviewLayeredSceneConstants.unitScale)
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, PreviewLayeredSceneConstants.minimumZoom), PreviewLayeredSceneConstants.maximumZoom)
    }

    private func updateCamera() {
        guard let camera = cameraNode.camera,
              let baseFocalLength = baseFocalLength() else {
            return
        }
        camera.focalLength = baseFocalLength * clampedZoom(zoomScale)
        onViewportChanged?()
    }

    /// 在 z=0 平面上，每个视图 pt 对应多少 scene 单位。
    private func unitsPerPoint(forZoom zoom: CGFloat) -> CGFloat {
        guard let baseFocalLength = baseFocalLength(), bounds.height > 0.5 else {
            return PreviewLayeredSceneConstants.unitScale
        }
        let focalLength = baseFocalLength * clampedZoom(zoom)
        let visibleHeight = PreviewLayeredSceneConstants.cameraDistance * PreviewLayeredSceneConstants.cameraSensorHeight / focalLength
        return visibleHeight / bounds.height
    }

    private func currentUnitsPerPoint() -> CGFloat {
        unitsPerPoint(forZoom: zoomScale)
    }

    private func clampTranslation() {
        let unitScale = PreviewLayeredSceneConstants.unitScale
        let unitsPerPoint = currentUnitsPerPoint()
        stageTranslation = PreviewLayeredSceneInteraction.clampedTranslation(
            stageTranslation,
            contentSize: CGSize(width: canvasSize.width * unitScale, height: canvasSize.height * unitScale),
            viewportSize: CGSize(width: bounds.width * unitsPerPoint, height: bounds.height * unitsPerPoint)
        )
    }

    private func setZoomScale(_ value: CGFloat, anchorPoint: CGPoint?, notifiesStore: Bool) {
        let clampedValue = clampedZoom(value)
        guard abs(clampedValue - zoomScale) > 0.0001 else {
            return
        }
        if let anchorPoint {
            // 以光标为锚点：缩放前后光标下的内容点保持不动。
            let cursorOffset = CGPoint(x: anchorPoint.x - bounds.midX, y: anchorPoint.y - bounds.midY)
            stageTranslation = PreviewLayeredSceneInteraction.anchoredTranslation(
                translation: stageTranslation,
                cursorOffset: cursorOffset,
                unitsPerPointBefore: unitsPerPoint(forZoom: zoomScale),
                unitsPerPointAfter: unitsPerPoint(forZoom: clampedValue)
            )
        }
        zoomScale = clampedValue
        clampTranslation()
        applyStageTransform()
        if notifiesStore {
            onScaleChanged?(clampedValue)
        }
    }

    private func sceneCenter(for displayRect: CGRect) -> CGPoint {
        CGPoint(
            x: (displayRect.midX - (canvasSize.width / 2)) * PreviewLayeredSceneConstants.unitScale,
            y: ((canvasSize.height / 2) - displayRect.midY) * PreviewLayeredSceneConstants.unitScale
        )
    }

    private func processPendingHover() {
        isHoverProcessingScheduled = false
        guard let point = pendingHoverPoint else {
            return
        }
        pendingHoverPoint = nil
        let hit = hitResult(at: point)
        onHoverChanged?(hit?.nodeID)
        onCursorCanvasPointChanged?(hit?.canvasPoint)
    }
}
