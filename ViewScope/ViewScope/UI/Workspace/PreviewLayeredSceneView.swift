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
    private var stageRotation = CGPoint(
        x: PreviewLayeredSceneConstants.defaultPitch,
        y: PreviewLayeredSceneConstants.defaultYaw
    )
    private var stageTranslation = CGPoint.zero
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
            if displayMode == .layered, oldValue == .flat {
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

    func enterLayeredMode(fromVisibleCanvasRect visibleCanvasRect: CGRect?) {
        // 从 flat 进入 3D 时，尽量让用户当前看到的区域落在舞台中心。
        if let visibleCanvasRect,
           visibleCanvasRect.width > 0.5,
           visibleCanvasRect.height > 0.5 {
            stageTranslation = translationForCentering(displayRect: visibleCanvasRect)
        }

        let targetRotation = PreviewLayeredSceneInteraction.rotationWhenEnteringLayered(from: .zero)
        stageRotation = targetRotation
        applyStageTransform(rotation: .zero, animated: false)
        applyStageTransform(rotation: targetRotation, animated: true)
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
        previewExpandedNodeIDs: Set<String>
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
            previewExpandedNodeIDs != self.previewExpandedNodeIDs

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

        let nextStructuralState = StructuralState(
            captureID: capture.captureID,
            imageSize: image.size,
            canvasSize: canvasSize,
            displayMode: displayMode,
            previewRootNodeID: previewRootNodeID,
            expandedNodeIDs: previewExpandedNodeIDs.sorted(),
            geometryMode: geometryMode,
            layerSpacing: previewLayerSpacing,
            showsLayerBorders: previewShowsLayerBorders
        )

        let nextPlan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: canvasSize,
            expandedNodeIDs: previewExpandedNodeIDs,
            previewRootNodeID: previewRootNodeID,
            geometryMode: geometryMode
        )

        if structuralState != nextStructuralState || plan != nextPlan {
            rebuildScene(plan: nextPlan, rootImage: image)
            structuralState = nextStructuralState
        } else {
            self.plan = nextPlan
        }

        updateSelectionAppearance()
        updateCamera()
    }

    /// 当 capture / 几何 / 展开状态等结构变化时，直接整棵重建 scene。
    private func rebuildScene(plan: PreviewLayeredScenePlan, rootImage: NSImage) {
        stageNode.childNodes.forEach { $0.removeFromParentNode() }
        displayNodes.removeAll(keepingCapacity: true)
        self.plan = plan

        let renderableItems = plan.items.filter {
            $0.displayRect.width > 0.5 &&
            $0.displayRect.height > 0.5
        }
        let centeredMidZIndex = CGFloat(renderableItems.map(\.zIndex).max() ?? 0) * 0.5
        let centeredPlaneDepth = CGFloat(plan.planes.map(\.depth).max() ?? 0) * 0.5
        let zStep = displayMode == .flat
            ? PreviewLayeredSceneConstants.flatDepthStep
            : max(0.08, previewLayerSpacing * 0.005)

        for plane in plan.planes {
            // plane marker 只表达“这一代内容位于哪个 z 平面”，
            // 真实可见内容仍由 display node 承载。
            let planeNode = SCNNode()
            planeNode.name = "content-plane-\(plane.depth)"
            planeNode.position.z = (CGFloat(plane.depth) - centeredPlaneDepth) * zStep
            stageNode.addChildNode(planeNode)
        }

        for item in renderableItems {
            let displayNode = PreviewLayeredDisplayNode()
            displayNode.configure(
                item: item,
                rootImage: rootImage,
                canvasSize: plan.canvasSize,
                unitScale: PreviewLayeredSceneConstants.unitScale,
                centeredZIndex: CGFloat(item.zIndex) - centeredMidZIndex,
                zStep: zStep,
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
        selectionOverlayNode.isHidden = true
        selectionBorderNode.geometry = nil
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
            SCNTransaction.animationDuration = 0.18
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            apply()
            SCNTransaction.commit()
        } else {
            apply()
        }
    }

    private func updateCamera() {
        guard let camera = cameraNode.camera else { return }

        let clampedZoom = min(max(zoomScale, PreviewLayeredSceneConstants.minimumZoom), PreviewLayeredSceneConstants.maximumZoom)
        let normalizedZoom = (clampedZoom - PreviewLayeredSceneConstants.minimumZoom) /
            (PreviewLayeredSceneConstants.maximumZoom - PreviewLayeredSceneConstants.minimumZoom)
        camera.focalLength = 20 + (normalizedZoom * normalizedZoom * 730)
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

private enum PreviewLayeredSceneConstants {
    static let unitScale: CGFloat = 0.01
    static let defaultPitch: CGFloat = (-10 * .pi) / 180
    static let defaultYaw: CGFloat = (15 * .pi) / 180
    static let selectableCategoryMask = 1 << 1
    static let minimumZoom: CGFloat = 0.35
    static let maximumZoom: CGFloat = 4
    static let flatDepthStep: CGFloat = 0.01
    static let maskNodeZOffset: CGFloat = 0.001
    static let borderNodeZOffset: CGFloat = 0.002
    static let selectionOverlayZOffset: CGFloat = 0.01

    static func translationFactor(for zoomScale: CGFloat) -> CGFloat {
        let normalizedZoom = (min(max(zoomScale, minimumZoom), maximumZoom) - minimumZoom) / (maximumZoom - minimumZoom)
        return (1 - normalizedZoom) * 0.7 + 0.3
    }
}

struct PreviewLayeredSceneInteraction {
    static func updatedRotation(current: CGPoint, delta: CGPoint) -> CGPoint {
        normalizedRotation(
            CGPoint(
                x: current.x - delta.y * 0.004,
                y: current.y + delta.x * 0.01
            )
        )
    }

    static func rotationWhenEnteringLayered(from _: CGPoint) -> CGPoint {
        CGPoint(
            x: PreviewLayeredSceneConstants.defaultPitch,
            y: PreviewLayeredSceneConstants.defaultYaw
        )
    }

    static func normalizedRotation(_ rotation: CGPoint) -> CGPoint {
        CGPoint(
            x: normalizedAngle(rotation.x),
            y: normalizedAngle(rotation.y)
        )
    }

    private static func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var result = angle
        while result <= -.pi {
            result += .pi * 2
        }
        while result >= .pi {
            result -= .pi * 2
        }
        return result
    }
}

private final class PreviewLayeredDisplayNode {
    let node = SCNNode()

    private let contentPlane = SCNPlane(width: 1, height: 1)
    private let contentNode = SCNNode()
    private let maskPlane = SCNPlane(width: 1, height: 1)
    private let maskNode = SCNNode()
    private let borderNode = SCNNode()
    private var item: PreviewLayeredScenePlan.Item?

    var zPosition: CGFloat {
        CGFloat(node.position.z)
    }

    init() {
        contentPlane.firstMaterial?.isDoubleSided = true
        contentPlane.firstMaterial?.lightingModel = .constant
        contentPlane.firstMaterial?.diffuse.contents = NSColor.clear
        contentNode.geometry = contentPlane
        node.addChildNode(contentNode)

        maskPlane.firstMaterial?.isDoubleSided = true
        maskPlane.firstMaterial?.lightingModel = .constant
        maskPlane.firstMaterial?.diffuse.contents = NSColor.clear
        maskPlane.firstMaterial?.transparency = 0
        maskPlane.firstMaterial?.writesToDepthBuffer = false
        maskPlane.firstMaterial?.readsFromDepthBuffer = false
        maskNode.geometry = maskPlane
        maskNode.position.z = PreviewLayeredSceneConstants.maskNodeZOffset
        node.addChildNode(maskNode)

        borderNode.position.z = PreviewLayeredSceneConstants.borderNodeZOffset
        node.addChildNode(borderNode)
    }

    func configure(
        item: PreviewLayeredScenePlan.Item,
        rootImage: NSImage,
        canvasSize: CGSize,
        unitScale: CGFloat,
        centeredZIndex: CGFloat,
        zStep: CGFloat,
        showsBorder: Bool,
        selectableCategoryMask: Int
    ) {
        // 一个 scene item 对应一个真正可见的 SceneKit 平面节点。
        // 几何位置来自 scene plan，纹理则从根截图裁切。
        self.item = item
        node.name = "display-\(item.nodeID)"
        contentNode.name = item.nodeID
        contentNode.categoryBitMask = selectableCategoryMask
        contentNode.renderingOrder = item.displayOrder * 10
        maskNode.renderingOrder = item.displayOrder * 10 + 1
        borderNode.renderingOrder = item.displayOrder * 10 + 2

        let width = max(item.displayRect.width * unitScale, 0.001)
        let height = max(item.displayRect.height * unitScale, 0.001)
        contentPlane.width = width
        contentPlane.height = height
        maskPlane.width = width
        maskPlane.height = height

        contentPlane.firstMaterial?.diffuse.contents = PreviewLayeredSceneSnapshotFactory.makeTextureImage(
            for: item,
            rootImage: rootImage,
            canvasSize: canvasSize
        )

        node.position = SCNVector3(
            Float((item.displayRect.midX - (canvasSize.width / 2)) * unitScale),
            Float(((canvasSize.height / 2) - item.displayRect.midY) * unitScale),
            Float(centeredZIndex * zStep)
        )

        updateAppearance(isSelected: false, isFocused: false, showsBorder: showsBorder)
    }

    func updateAppearance(isSelected: Bool, isFocused: Bool, showsBorder: Bool) {
        guard let item else { return }

        if isSelected {
            maskNode.isHidden = false
            maskPlane.firstMaterial?.diffuse.contents = NSColor.systemBlue
            maskNode.opacity = 0.35
        } else if isFocused {
            maskNode.isHidden = false
            maskPlane.firstMaterial?.diffuse.contents = NSColor.systemBlue
            maskNode.opacity = 0.18
        } else {
            maskNode.isHidden = true
            maskNode.opacity = 0
        }

        if showsBorder || isSelected || isFocused {
            borderNode.isHidden = false
            borderNode.geometry = PreviewLayeredSceneSnapshotFactory.makeBorderGeometry(
                size: item.displayRect.size,
                unitScale: PreviewLayeredSceneConstants.unitScale,
                color: isSelected
                    ? NSColor.systemBlue
                    : NSColor.systemBlue.withAlphaComponent(isFocused ? 0.55 : 0.22)
            )
        } else {
            borderNode.isHidden = true
            borderNode.geometry = nil
        }
    }
}

private enum PreviewLayeredSceneSnapshotFactory {
    static func makeTextureImage(
        for item: PreviewLayeredScenePlan.Item,
        rootImage: NSImage,
        canvasSize: CGSize
    ) -> NSImage {
        makeItemImage(
            for: item,
            rootImage: rootImage,
            canvasSize: canvasSize
        )
    }

    static func makeItemImage(
        for item: PreviewLayeredScenePlan.Item,
        rootImage: NSImage,
        canvasSize: CGSize
    ) -> NSImage {
        // 这里是 3D 纹理裁切的关键边界：
        // - `item.displayRect` 仍保持数据源 top-left 语义，供 scene 布局使用
        // - `textureRect` 只在这里临时转成图像对应的 display 坐标，供像素裁切使用
        let targetSize = item.displayRect.size
        let textureRect = PreviewCanvasCoordinateSpace.displayRect(
            fromNormalizedRect: item.displayRect,
            canvasSize: canvasSize
        )
        guard targetSize.width > 0,
              targetSize.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0,
              let cgImage = rootImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }

        let bounds = CGRect(origin: .zero, size: targetSize)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: max(Int(ceil(targetSize.width)), 1),
            height: max(Int(ceil(targetSize.height)), 1),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }

        context.clear(bounds)
        context.translateBy(x: 0, y: targetSize.height)
        context.scaleBy(x: 1, y: -1)

        let clipPath = CGMutablePath()
        clipPath.addRect(bounds)
        for punchedOutRect in item.punchedOutRects {
            // punch-out 使用 item 自己的局部纹理坐标；
            // 清掉后该区域的内容交给更前面的图层自己显示。
            let localRect = punchedOutRect
                .offsetBy(dx: -item.displayRect.minX, dy: -item.displayRect.minY)
                .intersection(bounds)
            guard localRect.isNull == false, localRect.isEmpty == false else {
                continue
            }
            clipPath.addRect(localRect)
        }
        context.addPath(clipPath)
        context.clip(using: .evenOdd)

        let drawRect = CGRect(
            x: -textureRect.minX,
            y: -textureRect.minY,
            width: canvasSize.width,
            height: canvasSize.height
        )
        context.interpolationQuality = .high
        context.draw(cgImage, in: drawRect)

        guard let itemCGImage = context.makeImage() else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        return NSImage(cgImage: itemCGImage, size: targetSize)
    }
    static func makeBorderGeometry(size: CGSize, unitScale: CGFloat, color: NSColor) -> SCNGeometry {
        let halfWidth = Float(size.width * unitScale * 0.5)
        let halfHeight = Float(size.height * unitScale * 0.5)
        let vertices = [
            SCNVector3(-halfWidth, halfHeight, 0),
            SCNVector3(halfWidth, halfHeight, 0),
            SCNVector3(halfWidth, -halfHeight, 0),
            SCNVector3(-halfWidth, -halfHeight, 0)
        ]
        let indices: [UInt8] = [0, 1, 1, 2, 2, 3, 3, 0]

        let source = SCNGeometrySource(vertices: vertices)
        let data = Data(indices)
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: 4,
            bytesPerIndex: MemoryLayout<UInt8>.size
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.isDoubleSided = true
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.diffuse.contents = color
        geometry.firstMaterial?.readsFromDepthBuffer = false
        geometry.firstMaterial?.writesToDepthBuffer = false
        return geometry
    }
}
