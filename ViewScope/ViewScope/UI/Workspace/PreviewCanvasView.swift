import AppKit
import CoreImage
import ViewScopeServer

final class PreviewCanvasView: NSView {
    private let geometry = ViewHierarchyGeometry()
    private let hitTestResolver = PreviewHitTestResolver()
    private let focusMaskResolver = PreviewFocusMaskResolver()
    private var viewportState = PreviewViewportState()
    private var layerTransform = PreviewLayerTransform()
    private var expandedNodeIDs = Set<String>()
    private var suppressDisplayInvalidation = false
    private var mouseDownViewPoint: CGPoint?
    private var lastDragViewPoint: CGPoint?
    private var didRotateDuringDrag = false

    var onNodeClick: ((String) -> Void)?
    var onNodeDoubleClick: ((String) -> Void)?
    var onScaleChanged: ((CGFloat) -> Void)?

    var capture: ViewScopeCapturePayload? {
        didSet { invalidateDisplay() }
    }

    var image: NSImage? {
        didSet { invalidateDisplay() }
    }

    var canvasSize: CGSize = .zero {
        didSet {
            updateDocumentSize()
            invalidateDisplay()
        }
    }

    var selectedNodeID: String? {
        didSet { invalidateDisplay() }
    }

    var focusedNodeID: String? {
        didSet { invalidateDisplay() }
    }

    var highlightedCanvasRect: CGRect? {
        didSet { invalidateDisplay() }
    }

    var previewRootNodeID: String? {
        didSet { invalidateDisplay() }
    }

    var geometryMode: PreviewCanvasGeometryMode = .directGlobalCanvasRect {
        didSet { invalidateDisplay() }
    }

    var displayMode: WorkspacePreviewDisplayMode = .flat {
        didSet {
            invalidateDisplay()
        }
    }

    var previewLayerSpacing: CGFloat = 22 {
        didSet {
            layerTransform.depthSpacing = previewLayerSpacing
            invalidateDisplay()
        }
    }

    var previewShowsLayerBorders = true {
        didSet { invalidateDisplay() }
    }

    var previewExpandedNodeIDs = Set<String>() {
        didSet {
            expandedNodeIDs = previewExpandedNodeIDs
            invalidateDisplay()
        }
    }

    var zoomScale: CGFloat = 1 {
        didSet {
            if abs(viewportState.scale - zoomScale) > 0.0001 {
                viewportState.setScale(zoomScale)
            }
            invalidateDisplay()
        }
    }

    var minimumViewportSize: CGSize = .zero {
        didSet {
            guard abs(oldValue.width - minimumViewportSize.width) > 0.5 ||
                    abs(oldValue.height - minimumViewportSize.height) > 0.5 else {
                return
            }
            updateDocumentSize()
        }
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("workspace.previewCanvas")
        updateDocumentSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBackground()

        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return
        }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()
        applyViewportTransform(to: context)

        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let layeredRenderPlan = capture.map {
            PreviewLayeredRenderPlan.make(
                capture: $0,
                canvasSize: canvasSize,
                selectedNodeID: selectedNodeID,
                focusedNodeID: focusedNodeID,
                previewRootNodeID: previewRootNodeID,
                expandedNodeIDs: expandedNodeIDs,
                geometryMode: geometryMode,
                layerTransform: layerTransform
            )
        }
        if displayMode == .layered {
            drawLayeredCanvasBackdrop(in: layeredRenderPlan?.baseImageQuad ?? layerTransform.projectedQuad(for: canvasRect, depth: 0, canvasSize: canvasSize))
            if let image, let layeredRenderPlan {
                if layeredRenderPlan.planes.isEmpty {
                    drawLayeredImage(
                        image,
                        in: canvasRect,
                        projectedQuad: layeredRenderPlan.baseImageQuad,
                        context: context
                    )
                } else {
                    drawLayeredPlanes(image, plan: layeredRenderPlan, in: canvasRect, context: context)
                }
            } else {
                drawLayeredWireframeFallback(plan: layeredRenderPlan)
            }
            if let selectedNodeID,
               let overlayQuad = layeredRenderPlan?.overlay(for: selectedNodeID)?.quad {
                drawLayeredSelection(for: overlayQuad)
            } else if let selectedRect = resolvedSelectedRect() {
                drawLayeredSelection(
                    for: layerTransform.projectedQuad(for: selectedRect, depth: 0, canvasSize: canvasSize)
                )
            }
        } else {
            if let image {
                image.draw(
                    in: canvasRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: false,
                    hints: nil
                )
            } else {
                drawWireframeFallback()
            }

            if let selectedRect = resolvedSelectedRect() {
                let path = NSBezierPath(roundedRect: selectedRect, xRadius: 8, yRadius: 8)
                NSColor.systemBlue.withAlphaComponent(0.12).setFill()
                path.fill()
                NSColor.systemBlue.setStroke()
                path.lineWidth = 2 / max(viewportState.scale, 0.001)
                path.stroke()
            }
        }

        context.restoreGState()

        if let capture, let focusedNodeID,
           let focusRect = geometry.canvasRect(
            for: focusedNodeID,
            in: capture,
            coordinateRootNodeID: previewRootNodeID,
            mode: geometryMode
           ) {
            guard let focusViewRect = focusMaskResolver.cutoutViewRect(
                displayMode: displayMode,
                focusRect: displayCanvasRect(fromNormalizedRect: focusRect),
                canvasSize: canvasSize,
                viewportState: viewportState,
                layerTransform: layerTransform
            ) else {
                return
            }
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(roundedRect: focusViewRect, xRadius: 10, yRadius: 10))
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.12).setFill()
            path.fill()
        }

    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownViewPoint = point
        lastDragViewPoint = point
        didRotateDuringDrag = false
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            viewportState.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            needsDisplay = true
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        let nextScale = min(max(viewportState.scale * (1 + event.magnification), 0.35), 4)
        viewportState.setScale(
            nextScale,
            keepingCanvasPoint: viewportState.canvasPoint(forViewPoint: convert(event.locationInWindow, from: nil)),
            anchoredAt: convert(event.locationInWindow, from: nil)
        )
        zoomScale = viewportState.scale
        onScaleChanged?(viewportState.scale)
        needsDisplay = true
    }

    override func rotate(with event: NSEvent) {
        guard displayMode == .layered else { return }
        layerTransform.drag(by: CGSize(width: CGFloat(event.rotation) * 1.8, height: 0))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard displayMode == .layered,
              let lastDragViewPoint,
              let mouseDownViewPoint else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let totalDistance = hypot(point.x - mouseDownViewPoint.x, point.y - mouseDownViewPoint.y)
        if totalDistance > 3 {
            didRotateDuringDrag = true
        }
        guard didRotateDuringDrag else {
            self.lastDragViewPoint = point
            return
        }

        layerTransform.drag(by: CGSize(
            width: point.x - lastDragViewPoint.x,
            height: point.y - lastDragViewPoint.y
        ))
        self.lastDragViewPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownViewPoint = nil
            lastDragViewPoint = nil
            didRotateDuringDrag = false
        }

        guard didRotateDuringDrag == false else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let nodeID = nodeID(atViewPoint: point) else { return }
        if event.clickCount >= 2 {
            onNodeDoubleClick?(nodeID)
        } else {
            onNodeClick?(nodeID)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        viewportState.setViewportSize(newSize)
        invalidateDisplay()
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
        suppressDisplayInvalidation = true
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
        suppressDisplayInvalidation = false
        needsDisplay = true
    }

    private func drawBackground() {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let borderRect = bounds.insetBy(dx: 8, dy: 8)
        let roundedRect = NSBezierPath(roundedRect: borderRect, xRadius: 14, yRadius: 14)
        NSColor.underPageBackgroundColor.setFill()
        roundedRect.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        roundedRect.lineWidth = 1
        roundedRect.stroke()
    }

    private func drawWireframeFallback() {
        guard let capture else { return }

        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: canvasSize)).fill()

        let rootNodeID = previewRootNodeID ?? focusedNodeID
        for nodeID in geometry.visibleNodeIDs(in: capture, rootNodeID: rootNodeID) {
            guard let normalizedRect = geometry.canvasRect(
                for: nodeID,
                in: capture,
                coordinateRootNodeID: rootNodeID,
                mode: geometryMode
            ) else { continue }
            let rect = displayCanvasRect(fromNormalizedRect: normalizedRect)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor.systemGray.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.systemGray.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1 / max(viewportState.scale, 0.001)
            path.stroke()
        }
    }

    private func drawLayeredCanvasBackdrop(in quad: [CGPoint]) {
        let backdrop = bezierPath(for: quad)
        NSColor.textBackgroundColor.setFill()
        backdrop.fill()
    }

    private func drawLayeredWireframeFallback(plan: PreviewLayeredRenderPlan?) {
        guard let plan else { return }
        for plane in plan.planes {
            let path = bezierPath(for: plane.quad)
            NSColor.systemGray.withAlphaComponent(0.16).setFill()
            path.fill()
            guard previewShowsLayerBorders else { continue }
            NSColor.systemGray.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1 / max(viewportState.scale, 0.001)
            path.stroke()
        }
    }

    private func drawLayeredPlanes(_ image: NSImage, plan: PreviewLayeredRenderPlan, in canvasRect: CGRect, context: CGContext) {
        for plane in plan.planes {
            guard let planeImage = makeLayeredPlaneImage(from: image, plane: plane, canvasRect: canvasRect) else {
                continue
            }
            drawLayeredImage(
                planeImage,
                in: canvasRect,
                projectedQuad: plane.quad,
                context: context
            )
            guard previewShowsLayerBorders else { continue }
            let planeBorder = bezierPath(for: plane.quad)
            NSColor.systemBlue.withAlphaComponent(0.18).setStroke()
            planeBorder.lineWidth = 1 / max(viewportState.scale, 0.001)
            planeBorder.stroke()
        }
    }

    private func makeLayeredPlaneImage(
        from image: NSImage,
        plane: PreviewLayeredRenderPlan.Plane,
        canvasRect: CGRect
    ) -> NSImage? {
        guard plane.regions.isEmpty == false else { return nil }

        let planeImage = NSImage(size: canvasRect.size)
        planeImage.lockFocusFlipped(true)
        NSColor.clear.setFill()
        canvasRect.fill()

        for region in plane.regions {
            NSGraphicsContext.saveGraphicsState()
            let clipPath = NSBezierPath(rect: region.rect)
            for punchedOutRect in region.punchedOutRects {
                clipPath.append(NSBezierPath(rect: punchedOutRect))
            }
            clipPath.windingRule = .evenOdd
            clipPath.addClip()
            image.draw(
                in: canvasRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: nil
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        planeImage.unlockFocus()
        return planeImage
    }

    private func drawLayeredImage(_ image: NSImage, in canvasRect: CGRect, projectedQuad: [CGPoint], context: CGContext) {
        guard let imageData = image.tiffRepresentation,
              let baseImage = CIImage(data: imageData) else {
            return
        }

        let scaleX = canvasRect.width / max(baseImage.extent.width, 1)
        let scaleY = canvasRect.height / max(baseImage.extent.height, 1)
        let scaledImage = baseImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let orientedImage = scaledImage.transformed(
            by: CGAffineTransform(translationX: 0, y: canvasRect.height).scaledBy(x: 1, y: -1)
        )

        guard let filter = CIFilter(name: "CIPerspectiveTransform") else {
            return
        }
        guard let inputQuad = PreviewImagePerspectiveMapping.quad(
            projectedQuad: projectedQuad,
            canvasSize: canvasSize
        ) else {
            return
        }
        filter.setValue(orientedImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: inputQuad.topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: inputQuad.topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: inputQuad.bottomRight), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: inputQuad.bottomLeft), forKey: "inputBottomLeft")

        guard let outputImage = filter.outputImage?.cropped(to: CGRect(origin: .zero, size: canvasSize)) else {
            return
        }

        CIContext(cgContext: context, options: nil).draw(
            outputImage,
            in: canvasRect,
            from: CGRect(origin: .zero, size: canvasSize)
        )
    }

    private func drawLayeredPreview(plan: PreviewLayeredRenderPlan) {
        for overlay in plan.overlayQuads {
            guard overlay.isSelected == false else { continue }
            let outline = bezierPath(for: overlay.quad)
            NSColor.white.withAlphaComponent(overlay.style.fillAlpha).setFill()
            outline.fill()
            guard previewShowsLayerBorders else { continue }
            NSColor.systemBlue.withAlphaComponent(overlay.style.strokeAlpha).setStroke()
            outline.lineWidth = overlay.style.strokeWidth / max(viewportState.scale, 0.001)
            outline.stroke()
        }
    }

    private func drawLayeredSelection(for quad: [CGPoint]) {
        let path = bezierPath(for: quad)
        NSColor.systemBlue.withAlphaComponent(0.14).setFill()
        path.fill()
        NSColor.systemBlue.setStroke()
        path.lineWidth = 2 / max(viewportState.scale, 0.001)
        path.stroke()
    }

    private func updateDocumentSize() {
        let width = max(bounds.width, minimumViewportSize.width, 1)
        let height = max(bounds.height, minimumViewportSize.height, 1)
        viewportState.setCanvasSize(canvasSize)
        viewportState.setViewportSize(CGSize(width: width, height: height))
        if abs(viewportState.scale - zoomScale) > 0.0001 {
            viewportState.setScale(zoomScale)
        }
    }

    func viewRect(fromCanvasRect rect: CGRect) -> CGRect {
        viewportState.viewRect(forCanvasRect: displayCanvasRect(fromNormalizedRect: rect))
    }

    func centerOnCanvasRect(_ rect: CGRect?) {
        guard let rect else { return }
        viewportState.center(onCanvasRect: displayCanvasRect(fromNormalizedRect: rect))
        needsDisplay = true
    }

    func visibleCanvasRect() -> CGRect {
        PreviewCanvasCoordinateSpace.normalizedRect(
            fromDisplayRect: viewportState.visibleCanvasRect,
            canvasSize: canvasSize
        )
    }

    private func resolvedSelectedRect() -> CGRect? {
        if let highlightedCanvasRect {
            return displayCanvasRect(fromNormalizedRect: highlightedCanvasRect)
        }
        guard let capture, let selectedNodeID else { return nil }
        let rootNodeID = previewRootNodeID
        guard let normalizedRect = geometry.canvasRect(
            for: selectedNodeID,
            in: capture,
            coordinateRootNodeID: rootNodeID,
            mode: geometryMode
        ) else {
            return nil
        }
        return displayCanvasRect(fromNormalizedRect: normalizedRect)
    }

    private func nodeID(atViewPoint point: CGPoint) -> String? {
        guard let capture else { return nil }
        return hitTestResolver.nodeID(
            atViewPoint: point,
            capture: capture,
            viewportState: viewportState,
            focusedNodeID: focusedNodeID,
            previewRootNodeID: previewRootNodeID,
            expandedNodeIDs: expandedNodeIDs,
            displayMode: displayMode,
            geometryMode: geometryMode,
            layerTransform: layerTransform
        )
    }

    private func applyViewportTransform(to context: CGContext) {
        context.concatenate(viewportState.canvasToViewTransform)
    }

    private func invalidateDisplay() {
        guard suppressDisplayInvalidation == false else { return }
        needsDisplay = true
    }

    private func bezierPath(for quad: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = quad.first else { return path }
        path.move(to: first)
        for point in quad.dropFirst() {
            path.line(to: point)
        }
        path.close()
        return path
    }

    private func displayCanvasRect(fromNormalizedRect rect: CGRect) -> CGRect {
        PreviewCanvasCoordinateSpace.displayRect(
            fromNormalizedRect: rect,
            canvasSize: canvasSize
        )
    }
}
