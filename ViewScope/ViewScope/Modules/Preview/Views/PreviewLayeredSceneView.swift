import AppKit
import SceneKit
import ViewScopeServer

/// 真实 3D 预览视图。
///
/// 和 `PreviewCanvasView.layered` 的区别：
/// - `PreviewCanvasView.layered` 是在 2D 里模拟 3D 效果
/// - 这里是真的创建 SceneKit 节点，并支持旋转、平移、缩放
///
/// 核心约定：
/// - 节点位置直接使用统一的 top-left 画布坐标
/// - 节点纹理从根截图按各自 rect 裁切
/// - 节点前后关系由 `PreviewLayeredScenePlan` 的 zIndex 决定
final class PreviewLayeredSceneView: SCNView {
    private struct StructuralState: Equatable {
        let captureID: String?
        let imageSize: CGSize
        let canvasSize: CGSize
        let displayMode: WorkspacePreviewDisplayMode
        let previewRootNodeID: String?
        let expandedNodeIDs: [String]
        let geometryMode: PreviewCanvasGeometryMode
        let layerSpacing: CGFloat
        let showsLayerBorders: Bool
        let showsSystemWrapperViews: Bool
    }

    private let stageNode = SCNNode()
    private let cameraNode = SCNNode()
    private let rightLightNode = SCNNode()
    private let leftLightNode = SCNNode()
    private let selectionOverlayNode = SCNNode()
    private let selectionFillPlane = SCNPlane(width: 1, height: 1)
    private let selectionFillNode = SCNNode()
    private let selectionBorderNode = SCNNode()

    private var displayNodes: [String: PreviewLayeredDisplayNode] = [:]
    private var plan: PreviewLayeredScenePlan?
    private var structuralState: StructuralState?
    private var nodePreviewImageCache: [String: NSImage] = [:]
    private var cachedNodePreviewCaptureID: String?
    private var stageRotation = CGPoint(
        x: PreviewLayeredSceneConstants.defaultPitch,
        y: PreviewLayeredSceneConstants.defaultYaw
    )
    private var stageTranslation = CGPoint.zero
    /// 用户是否手动旋转过，切回 3D 时恢复上次角度而非默认角度。
    private var hasUserRotated = false
    private var mouseDownPoint: CGPoint?
    private var lastDragPoint: CGPoint?
    private var didDrag = false
    private var suppressSceneRefresh = false

    var onNodeClick: ((String) -> Void)?
    var onNodeDoubleClick: ((String) -> Void)?
    var onScaleChanged: ((CGFloat) -> Void)?

    var capture: ViewScopeCapturePayload? {
        didSet {
            guard suppressSceneRefresh == false else { return }
            refreshScene()
        }
    }

    var image: NSImage? {
        didSet {
            guard suppressSceneRefresh == false else { return }
            refreshScene()
        }
    }

    var canvasSize: CGSize = .zero {
        didSet {
            guard suppressSceneRefresh == false else { return }
            refreshScene()
        }
    }

    var selectedNodeID: String? {
        didSet {
            guard suppressSceneRefresh == false else { return }
            updateSelectionAppearance()
        }
    }

    var focusedNodeID: String? {
        didSet {
            guard suppressSceneRefresh == false else { return }
            updateSelectionAppearance()
        }
    }

    var highlightedCanvasRect: CGRect? {
        didSet {
            guard suppressSceneRefresh == false else { return }
            updateSelectionAppearance()
        }
    }

    var previewRootNodeID: String? {
        didSet {
            guard suppressSceneRefresh == false else { return }
            refreshScene()
        }
    }

    var geometryMode: PreviewCanvasGeometryMode = .directGlobalCanvasRect {
        didSet {
            guard suppressSceneRefresh == false else { return }
            refreshScene()
        }
    }

    var displayMode: WorkspacePreviewDisplayMode = .layered {
        didSet {
            guard suppressSceneRefresh == false else { return }
            if displayMode == .layered, oldValue == .flat, !hasUserRotated {
                stageRotation = PreviewLayeredSceneInteraction.rotationWhenEnteringLayered(from: .zero)
            }
            updateStageForDisplayMode(animated: true)
            refreshScene()
        }
    }

    var previewLayerSpacing: CGFloat = 22 {
        didSet {
            guard suppressSceneRefresh == false else { return }
            refreshScene()
        }
    }

    var previewShowsLayerBorders = true {
        didSet {
            guard suppressSceneRefresh == false else { return }
            refreshScene()
        }
    }

    var previewExpandedNodeIDs = Set<String>() {
        didSet {
            guard suppressSceneRefresh == false else { return }
            refreshScene()
        }
    }

    var showsSystemWrapperViews = false {
        didSet {
            guard suppressSceneRefresh == false else { return }
            refreshScene()
        }
    }

    var zoomScale: CGFloat = 1 {
        didSet { updateCamera() }
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        lastDragPoint = point
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard displayMode == .layered,
              let lastDragPoint else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - (mouseDownPoint?.x ?? point.x), point.y - (mouseDownPoint?.y ?? point.y)) > 2 {
            didDrag = true
        }

        let delta = CGPoint(x: point.x - lastDragPoint.x, y: point.y - lastDragPoint.y)
        stageRotation = PreviewLayeredSceneInteraction.updatedRotation(
            current: stageRotation,
            delta: delta
        )
        hasUserRotated = true
        applyStageTransform()
        self.lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            lastDragPoint = nil
            didDrag = false
        }

        guard didDrag == false else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let nodeID = nodeID(at: point) else { return }
        if event.clickCount >= 2 {
            onNodeDoubleClick?(nodeID)
        } else {
            onNodeClick?(nodeID)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let nextScale = zoomScale * (1 - (event.scrollingDeltaY * 0.01))
            setZoomScale(nextScale, notifiesStore: true)
            return
        }

        let factor = PreviewLayeredSceneConstants.translationFactor(for: zoomScale)
        stageTranslation.x += event.scrollingDeltaX * 0.04 * factor
        stageTranslation.y -= event.scrollingDeltaY * 0.04 * factor
        applyStageTransform()
    }

    override func magnify(with event: NSEvent) {
        let nextScale = zoomScale * (1 + event.magnification)
        setZoomScale(nextScale, notifiesStore: true)
    }

    func applyRotationGesture(_ rotation: CGFloat) {
        guard displayMode == .layered else { return }
        stageRotation = PreviewLayeredSceneInteraction.updatedRotation(
            current: stageRotation,
            delta: CGPoint(x: rotation * 1.8, y: 0)
        )
        hasUserRotated = true
        applyStageTransform()
    }

    func centerOnNode(_ nodeID: String?, animated: Bool = false) {
        guard let nodeID,
              let item = plan?.item(for: nodeID) else {
            stageTranslation = .zero
            applyStageTransform(animated: animated)
            return
        }

        stageTranslation = translationForCentering(displayRect: item.displayRect)
        applyStageTransform(animated: animated)
    }

    /// Phase 1: 以 flat 状态（rotation=0）准备 3D 视图，供 crossfade 使用。
    func enterLayeredModeFlat(fromVisibleCanvasRect visibleCanvasRect: CGRect?) {
        if let visibleCanvasRect,
           visibleCanvasRect.width > 0.5,
           visibleCanvasRect.height > 0.5 {
            stageTranslation = translationForCentering(displayRect: visibleCanvasRect)
        }
        // 用户手动旋转过则保留其角度，否则用默认角度
        if !hasUserRotated {
            stageRotation = PreviewLayeredSceneInteraction.rotationWhenEnteringLayered(from: .zero)
        }
        applyStageTransform(rotation: .zero, animated: false)
    }

    /// Phase 2: crossfade 完成后，动画旋转到 3D 目标角度。
    func animateToLayeredRotation() {
        applyStageTransform(rotation: stageRotation, animated: true)
    }

    /// 3D → 2D: 动画旋转回 flat，完成后调用 completion。
    func animateToFlatRotation(completion: @escaping () -> Void) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        SCNTransaction.completionBlock = completion
        stageNode.eulerAngles = SCNVector3(0, 0, 0)
        SCNTransaction.commit()
    }

    /// 兼容旧调用路径（非过渡场景直接进入 3D）。
    func enterLayeredMode(fromVisibleCanvasRect visibleCanvasRect: CGRect?) {
        enterLayeredModeFlat(fromVisibleCanvasRect: visibleCanvasRect)
        animateToLayeredRotation()
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
        // 先比较结构性变化，决定是整棵 scene 重建，还是只刷新选中态 / 相机。
        let needsSceneRefresh =
            capture?.captureID != self.capture?.captureID ||
            image?.size != self.image?.size ||
            canvasSize != self.canvasSize ||
            previewRootNodeID != self.previewRootNodeID ||
            geometryMode != self.geometryMode ||
            displayMode != self.displayMode ||
            previewLayerSpacing != self.previewLayerSpacing ||
            previewShowsLayerBorders != self.previewShowsLayerBorders ||
            previewExpandedNodeIDs != self.previewExpandedNodeIDs ||
            showsSystemWrapperViews != self.showsSystemWrapperViews

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

        updateStageForDisplayMode(animated: false)
        if needsSceneRefresh {
            refreshScene()
        } else {
            updateSelectionAppearance()
            updateCamera()
        }
    }

    private func commonInit() {
        // SceneKit 只负责舞台和相机，真正的节点构造在 `rebuildScene` 里。
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
        selectionOverlayNode.addChildNode(selectionFillNode)
        selectionBorderNode.position.z = PreviewLayeredSceneConstants.borderNodeZOffset
        selectionOverlayNode.addChildNode(selectionBorderNode)
        selectionOverlayNode.isHidden = true
        stageNode.addChildNode(selectionOverlayNode)

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.zNear = 0.01
        camera.zFar = 500
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 34)
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode

        let rightLight = SCNLight()
        rightLight.type = .omni
        rightLight.intensity = 800
        rightLightNode.light = rightLight
        scene.rootNode.addChildNode(rightLightNode)

        let leftLight = SCNLight()
        leftLight.type = .spot
        leftLight.intensity = 520
        leftLightNode.light = leftLight
        scene.rootNode.addChildNode(leftLightNode)

        updateStageForDisplayMode(animated: false)
        updateCamera()
    }

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

        if cachedNodePreviewCaptureID != capture.captureID {
            nodePreviewImageCache.removeAll(keepingCapacity: true)
            cachedNodePreviewCaptureID = capture.captureID
        }

        let nextStructuralState = StructuralState(
            captureID: capture.captureID,
            imageSize: image.size,
            canvasSize: canvasSize,
            displayMode: displayMode,
            previewRootNodeID: previewRootNodeID,
            expandedNodeIDs: previewExpandedNodeIDs.sorted(),
            geometryMode: geometryMode,
            layerSpacing: previewLayerSpacing,
            showsLayerBorders: previewShowsLayerBorders,
            showsSystemWrapperViews: showsSystemWrapperViews
        )

        let nextPlan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: canvasSize,
            expandedNodeIDs: previewExpandedNodeIDs,
            previewRootNodeID: previewRootNodeID,
            geometryMode: geometryMode,
            showsSystemWrapperViews: showsSystemWrapperViews
        )

        if structuralState != nextStructuralState || plan != nextPlan {
            rebuildScene(plan: nextPlan, capture: capture, rootImage: image)
            structuralState = nextStructuralState
        } else {
            self.plan = nextPlan
        }

        updateSelectionAppearance()
        updateCamera()
    }

    /// 当 capture / 几何 / 展开状态等结构变化时，直接整棵重建 scene。
    private func rebuildScene(plan: PreviewLayeredScenePlan, capture: ViewScopeCapturePayload, rootImage: NSImage) {
        stageNode.childNodes.forEach { $0.removeFromParentNode() }
        displayNodes.removeAll(keepingCapacity: true)
        self.plan = plan
        let normalizedRootImage = PreviewLayeredSceneSnapshotFactory.makeTopLeftWorkingImage(
            from: rootImage,
            size: plan.canvasSize
        )

        let renderableItems = plan.items.filter {
            $0.displayRect.width > 0.5 &&
            $0.displayRect.height > 0.5
        }
        let centeredMidZIndex = CGFloat(renderableItems.map(\.zIndex).max() ?? 0) * 0.5
        let centeredPlaneDepth = CGFloat(plan.planes.map(\.depth).max() ?? 0) * 0.5
        let zStep = displayMode == .flat
            ? PreviewLayeredSceneConstants.flatDepthStep
            : max(0.08, previewLayerSpacing * 0.005)
        var itemCountByZIndex: [Int: Int] = [:]

        for plane in plan.planes {
            // plane marker 只表达“这一代内容位于哪个 z 平面”，
            // 真实可见内容仍由 display node 承载。
            let planeNode = SCNNode()
            planeNode.name = "content-plane-\(plane.depth)"
            planeNode.position.z = (CGFloat(plane.depth) - centeredPlaneDepth) * zStep
            stageNode.addChildNode(planeNode)
        }

        for item in renderableItems {
            let countAtCurrentZIndex = itemCountByZIndex[item.zIndex, default: 0]
            itemCountByZIndex[item.zIndex] = countAtCurrentZIndex + 1

            let displayNode = PreviewLayeredDisplayNode()
            displayNode.configure(
                item: item,
                textureImage: resolvedTextureImage(
                    for: item,
                    capture: capture,
                    rootImage: normalizedRootImage,
                    canvasSize: plan.canvasSize
                ),
                canvasSize: plan.canvasSize,
                unitScale: PreviewLayeredSceneConstants.unitScale,
                centeredZIndex: CGFloat(item.zIndex) - centeredMidZIndex,
                zStep: zStep,
                zBias: CGFloat(countAtCurrentZIndex) * PreviewLayeredSceneConstants.sameZIndexBiasStep,
                showsBorder: previewShowsLayerBorders,
                selectableCategoryMask: PreviewLayeredSceneConstants.selectableCategoryMask
            )
            stageNode.addChildNode(displayNode.node)
            displayNodes[item.nodeID] = displayNode
        }

        stageNode.addChildNode(selectionOverlayNode)

        updateLightPositions()
        updateStageForDisplayMode(animated: false)
    }

    private func clearScene() {
        stageNode.childNodes.forEach { $0.removeFromParentNode() }
        stageNode.addChildNode(selectionOverlayNode)
        displayNodes.removeAll()
        plan = nil
        structuralState = nil
        nodePreviewImageCache.removeAll(keepingCapacity: true)
        cachedNodePreviewCaptureID = nil
        selectionOverlayNode.isHidden = true
        selectionBorderNode.geometry = nil
    }

    private func resolvedTextureImage(
        for item: PreviewLayeredScenePlan.Item,
        capture: ViewScopeCapturePayload,
        rootImage: NSImage,
        canvasSize: CGSize
    ) -> NSImage {
        if let image = resolvedNodePreviewImage(for: item, in: capture) {
            return PreviewLayeredSceneSnapshotFactory.makeTextureImage(
                fromSourceImage: image,
                size: item.displayRect.size
            )
        }

        if shouldUseTransparentShellTexture(for: item, in: capture) {
            return PreviewLayeredSceneSnapshotFactory.makeTextureImage(
                fromSourceImage: PreviewLayeredSceneSnapshotFactory.makeTransparentTopLeftImage(size: item.displayRect.size),
                size: item.displayRect.size
            )
        }

        return PreviewLayeredSceneSnapshotFactory.makeTextureImage(
            for: item,
            rootImage: rootImage,
            canvasSize: canvasSize
        )
    }

    private func shouldUseTransparentShellTexture(
        for item: PreviewLayeredScenePlan.Item,
        in capture: ViewScopeCapturePayload
    ) -> Bool {
        guard previewExpandedNodeIDs.contains(item.nodeID) else {
            return false
        }

        return item.nodeID == previewRootNodeID || capture.rootNodeIDs.contains(item.nodeID)
    }

    private func resolvedNodePreviewImage(
        for item: PreviewLayeredScenePlan.Item,
        in capture: ViewScopeCapturePayload
    ) -> NSImage? {
        guard let screenshotSet = capture.nodePreviewScreenshots.first(where: { $0.nodeID == item.nodeID }) else {
            return nil
        }

        let prefersSoloScreenshot: Bool = {
            guard previewExpandedNodeIDs.contains(item.nodeID),
                  let node = capture.nodes[item.nodeID] else {
                return false
            }
            return node.childIDs.isEmpty == false
        }()

        let base64PNG = prefersSoloScreenshot
            ? (screenshotSet.soloPNGBase64 ?? screenshotSet.groupPNGBase64)
            : screenshotSet.groupPNGBase64
        guard let base64PNG, base64PNG.isEmpty == false else {
            return nil
        }

        let cacheKey = "\(capture.captureID):\(item.nodeID):\(prefersSoloScreenshot ? "solo" : "group")"
        if let cached = nodePreviewImageCache[cacheKey] {
            return cached
        }

        guard let data = Data(base64Encoded: base64PNG),
              let image = NSImage(data: data) else {
            return nil
        }

        image.size = screenshotSet.size.cgSize
        nodePreviewImageCache[cacheKey] = image
        return image
    }

    private func updateSelectionAppearance() {
        let focusedNodeID = focusedNodeID
        let usesExplicitSelectionOverlay = selectedNodeID != nil && highlightedCanvasRect != nil
        for (nodeID, displayNode) in displayNodes {
            displayNode.updateAppearance(
                isSelected: usesExplicitSelectionOverlay == false && nodeID == selectedNodeID,
                isFocused: nodeID == focusedNodeID,
                showsBorder: previewShowsLayerBorders
            )
        }
        updateSelectionOverlay()
    }

    private func updateStageForDisplayMode(animated: Bool) {
        if displayMode == .flat {
            applyStageTransform(rotation: .zero, animated: animated)
        } else {
            applyStageTransform(rotation: stageRotation, animated: animated)
        }
    }

    private func applyStageTransform(rotation: CGPoint? = nil, animated: Bool = false) {
        let nextRotation = rotation ?? stageRotation
        let apply = {
            self.stageNode.position = SCNVector3(
                Float(self.stageTranslation.x),
                Float(self.stageTranslation.y),
                0
            )
            self.stageNode.eulerAngles = SCNVector3(
                Float(nextRotation.x),
                Float(nextRotation.y),
                0
            )
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
    }

    private func updateCamera() {
        guard let camera = cameraNode.camera else { return }

        guard canvasSize.width > 0.5, canvasSize.height > 0.5,
              bounds.width > 0.5, bounds.height > 0.5 else {
            return
        }

        // 2D 画布使用 28pt padding 计算可视区域，3D 视图已有 10pt 外部 inset，
        // 再加 18pt 内部 padding 使两者可视区域完全一致，切换时内容大小相同。
        let cameraViewportPadding: CGFloat = 18
        let effectiveW = bounds.width - 2 * cameraViewportPadding
        let effectiveH = bounds.height - 2 * cameraViewportPadding
        guard effectiveW > 1, effectiveH > 1 else { return }

        let fillRatio = PreviewLayeredSceneConstants.defaultFillRatio
        let fitScale = min(effectiveW / canvasSize.width, effectiveH / canvasSize.height) * fillRatio

        // SCNCamera 的投影矩阵以**垂直** sensor 尺寸（默认 24mm）为基准，
        // 水平可视范围 = cameraZ × viewAspect × sensorHeight / focalLength。
        // 因此从 fitScale 反推 focalLength 时必须用 sensorHeight 和 bounds.height。
        let unitScale = PreviewLayeredSceneConstants.unitScale
        let cameraZ = PreviewLayeredSceneConstants.cameraDistance
        let sensorH: CGFloat = 24 // SceneKit 默认 sensorSize.height
        let baseFocalLength = fitScale * cameraZ * sensorH / (bounds.height * unitScale)

        let clampedZoom = min(max(zoomScale, PreviewLayeredSceneConstants.minimumZoom),
                              PreviewLayeredSceneConstants.maximumZoom)
        camera.focalLength = baseFocalLength * clampedZoom

        updateLightPositions()
    }

    private func updateLightPositions() {
        let widthUnits = canvasSize.width * PreviewLayeredSceneConstants.unitScale
        let heightUnits = canvasSize.height * PreviewLayeredSceneConstants.unitScale
        let selectedZ = selectedNodeID.flatMap { displayNodes[$0]?.zPosition } ?? 0
        rightLightNode.position = SCNVector3(Float(widthUnits * 0.5 + 2), Float(heightUnits * 0.5 + 2), Float(selectedZ + 2))
        leftLightNode.position = SCNVector3(Float(-widthUnits * 0.5 - 2), Float(-heightUnits * 0.5 - 2), Float(selectedZ + 2))
    }

    private func setZoomScale(_ value: CGFloat, notifiesStore: Bool) {
        let clampedValue = min(max(value, PreviewLayeredSceneConstants.minimumZoom), PreviewLayeredSceneConstants.maximumZoom)
        guard abs(clampedValue - zoomScale) > 0.0001 else { return }
        zoomScale = clampedValue
        if notifiesStore {
            onScaleChanged?(clampedValue)
        }
    }

    private func nodeID(at point: CGPoint) -> String? {
        let results = hitTest(point, options: [
            SCNHitTestOption.categoryBitMask: PreviewLayeredSceneConstants.selectableCategoryMask,
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue,
            SCNHitTestOption.ignoreHiddenNodes: false
        ])
        return results.first?.node.name
    }

    private func sceneCenter(for displayRect: CGRect) -> CGPoint {
        CGPoint(
            x: (displayRect.midX - (canvasSize.width / 2)) * PreviewLayeredSceneConstants.unitScale,
            y: ((canvasSize.height / 2) - displayRect.midY) * PreviewLayeredSceneConstants.unitScale
        )
    }

    private func translationForCentering(displayRect: CGRect) -> CGPoint {
        let center = sceneCenter(for: displayRect)
        return CGPoint(x: -center.x, y: -center.y)
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

        let displayRect = plan?.item(for: selectedNodeID)?.displayRect
            ?? highlightedCanvasRect
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
        // overlay 永远放在目标节点前面一点，避免被节点自身深度挡住。
        let overlayZ = (displayNodes[selectedNodeID]?.zPosition ?? (displayNodes.values.map(\.zPosition).max() ?? 0)) +
            PreviewLayeredSceneConstants.selectionOverlayZOffset
        selectionOverlayNode.position = SCNVector3(Float(center.x), Float(center.y), Float(overlayZ))
        selectionOverlayNode.isHidden = false
    }
}
