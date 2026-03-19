import AppKit
import CoreImage
import ViewScopeServer

enum PreviewImageSliceGeometry {
    static func imageRect(forCanvasRect rect: CGRect, canvasSize: CGSize, imageSize: CGSize) -> CGRect {
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return .zero
        }

        let scaleX = imageSize.width / canvasSize.width
        let scaleY = imageSize.height / canvasSize.height
        let scaledRect = CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        let flippedRect = CGRect(
            x: scaledRect.origin.x,
            y: imageSize.height - scaledRect.maxY,
            width: scaledRect.width,
            height: scaledRect.height
        )

        return flippedRect.intersection(CGRect(origin: .zero, size: imageSize))
    }
}

final class PreviewCanvasView: NSView {
    private let geometry = ViewHierarchyGeometry()
    private let hitTestResolver = PreviewHitTestResolver()
    private let focusMaskResolver = PreviewFocusMaskResolver()
    private var viewportState = PreviewViewportState()
    private var layerTransform = PreviewLayerTransform()
    private var mouseDownViewPoint: CGPoint?
    private var lastDragViewPoint: CGPoint?
    private var didRotateDuringDrag = false

    var onNodeClick: ((String) -> Void)?
    var onNodeDoubleClick: ((String) -> Void)?
    var onScaleChanged: ((CGFloat) -> Void)?

    var capture: ViewScopeCapturePayload? {
        didSet { needsDisplay = true }
    }

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var canvasSize: CGSize = .zero {
        didSet {
            updateDocumentSize()
            needsDisplay = true
        }
    }

    var selectedNodeID: String? {
        didSet { needsDisplay = true }
    }

    var focusedNodeID: String? {
        didSet { needsDisplay = true }
    }

    var highlightedCanvasRect: CGRect? {
        didSet { needsDisplay = true }
    }

    var displayMode: WorkspacePreviewDisplayMode = .flat {
        didSet {
            needsDisplay = true
        }
    }

    var zoomScale: CGFloat = 1 {
        didSet {
            if abs(viewportState.scale - zoomScale) > 0.0001 {
                viewportState.setScale(zoomScale)
            }
            needsDisplay = true
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
        if displayMode == .layered {
            drawLayeredCanvasBackdrop(in: canvasRect)
            if let image {
                drawLayeredImage(image, in: canvasRect, context: context)
            } else {
                drawLayeredWireframeFallback()
            }
            if let capture {
                drawLayeredPreview(for: capture)
            }
            if let selectedRect = resolvedSelectedRect() {
                drawLayeredSelection(for: selectedRect)
            }
        } else {
            if let image {
                image.draw(in: canvasRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
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
           let focusRect = geometry.canvasRect(for: focusedNodeID, in: capture) {
            guard let focusViewRect = focusMaskResolver.cutoutViewRect(
                displayMode: displayMode,
                focusRect: focusRect,
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

        for nodeID in geometry.visibleNodeIDs(in: capture, rootNodeID: focusedNodeID) {
            guard let rect = geometry.canvasRect(for: nodeID, in: capture) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor.systemGray.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.systemGray.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1 / max(viewportState.scale, 0.001)
            path.stroke()
        }
    }

    private func drawLayeredCanvasBackdrop(in canvasRect: CGRect) {
        let backdrop = bezierPath(for: layerTransform.projectedQuad(for: canvasRect, depth: 0, canvasSize: canvasSize))
        NSColor.textBackgroundColor.setFill()
        backdrop.fill()
    }

    private func drawLayeredWireframeFallback() {
        guard let capture else { return }
        for nodeID in geometry.visibleNodeIDs(in: capture) {
            guard let node = capture.nodes[nodeID],
                  let rect = geometry.canvasRect(for: nodeID, in: capture) else { continue }
            let quad = layerTransform.projectedQuad(
                for: rect,
                depth: CGFloat(max(0, node.depth)),
                canvasSize: canvasSize
            )
            let path = bezierPath(for: quad)
            NSColor.systemGray.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.systemGray.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1 / max(viewportState.scale, 0.001)
            path.stroke()
        }
    }

    private func drawLayeredImage(_ image: NSImage, in canvasRect: CGRect, context: CGContext) {
        guard let imageData = image.tiffRepresentation,
              let baseImage = CIImage(data: imageData) else {
            return
        }

        let scaleX = canvasRect.width / max(baseImage.extent.width, 1)
        let scaleY = canvasRect.height / max(baseImage.extent.height, 1)
        let scaledImage = baseImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let quad = layerTransform.projectedQuad(for: canvasRect, depth: 0, canvasSize: canvasSize)

        guard let filter = CIFilter(name: "CIPerspectiveTransform") else {
            return
        }
        filter.setValue(scaledImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: ciPoint(fromCanvasPoint: quad[0])), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: ciPoint(fromCanvasPoint: quad[1])), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: ciPoint(fromCanvasPoint: quad[2])), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: ciPoint(fromCanvasPoint: quad[3])), forKey: "inputBottomLeft")

        guard let outputImage = filter.outputImage?.cropped(to: CGRect(origin: .zero, size: canvasSize)) else {
            return
        }

        CIContext(cgContext: context, options: nil).draw(
            outputImage,
            in: canvasRect,
            from: CGRect(origin: .zero, size: canvasSize)
        )
    }

    private func drawLayeredPreview(for capture: ViewScopeCapturePayload) {
        let ciContext = NSGraphicsContext.current.map { CIContext(cgContext: $0.cgContext, options: nil) }
        let baseImage: CIImage? = image.flatMap { previewImage in
            guard let data = previewImage.tiffRepresentation else { return nil }
            return CIImage(data: data)
        }
        let nodeIDs = geometry.visibleNodeIDs(in: capture)
        for nodeID in nodeIDs {
            guard let rect = geometry.canvasRect(for: nodeID, in: capture),
                  let node = capture.nodes[nodeID] else { continue }

            if let baseImage, let ciContext, node.kind == .view, node.depth > 0 {
                drawLayeredImageSlice(
                    from: baseImage,
                    for: rect,
                    depth: CGFloat(max(0, node.depth)),
                    context: ciContext
                )
            }

            let quad = layerTransform.projectedQuad(
                for: rect,
                depth: CGFloat(max(0, node.depth)),
                canvasSize: canvasSize
            )
            let outline = bezierPath(for: quad)
            NSColor.white.withAlphaComponent(nodeID == selectedNodeID ? 0.2 : min(0.14, 0.04 + CGFloat(node.depth) * 0.015)).setFill()
            outline.fill()
            NSColor.systemBlue.withAlphaComponent(nodeID == selectedNodeID ? 0.72 : min(0.34, 0.08 + CGFloat(node.depth) * 0.03)).setStroke()
            outline.lineWidth = (nodeID == selectedNodeID ? 1.8 : 0.9) / max(viewportState.scale, 0.001)
            outline.stroke()
        }
    }

    private func drawLayeredImageSlice(from baseImage: CIImage, for rect: CGRect, depth: CGFloat, context: CIContext) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }

        let imageSize = baseImage.extent.size
        let cropRect = PreviewImageSliceGeometry.imageRect(
            forCanvasRect: rect,
            canvasSize: canvasSize,
            imageSize: imageSize
        )
        guard cropRect.width > 0.5, cropRect.height > 0.5,
              canvasSize.width > 0.5,
              canvasSize.height > 0.5,
              let filter = CIFilter(name: "CIPerspectiveTransform") else {
            return
        }

        let scaleX = imageSize.width / canvasSize.width
        let scaleY = imageSize.height / canvasSize.height
        let croppedImage = baseImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .transformed(by: CGAffineTransform(scaleX: 1 / scaleX, y: 1 / scaleY))
        let quad = layerTransform.projectedQuad(for: rect, depth: depth, canvasSize: canvasSize)
        filter.setValue(croppedImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: ciPoint(fromCanvasPoint: quad[0])), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: ciPoint(fromCanvasPoint: quad[1])), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: ciPoint(fromCanvasPoint: quad[2])), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: ciPoint(fromCanvasPoint: quad[3])), forKey: "inputBottomLeft")

        guard let outputImage = filter.outputImage?.cropped(to: CGRect(origin: .zero, size: canvasSize)) else {
            return
        }

        context.draw(outputImage, in: CGRect(origin: .zero, size: canvasSize), from: CGRect(origin: .zero, size: canvasSize))
    }

    private func drawLayeredSelection(for rect: CGRect) {
        let path = bezierPath(
            for: layerTransform.projectedQuad(
                for: rect,
                depth: CGFloat(selectedNodeDepth),
                canvasSize: canvasSize
            )
        )
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
        viewportState.viewRect(forCanvasRect: rect)
    }

    func centerOnCanvasRect(_ rect: CGRect?) {
        guard let rect else { return }
        viewportState.center(onCanvasRect: rect)
        needsDisplay = true
    }

    private func resolvedSelectedRect() -> CGRect? {
        if let highlightedCanvasRect {
            return highlightedCanvasRect
        }
        guard let capture, let selectedNodeID else { return nil }
        return geometry.canvasRect(for: selectedNodeID, in: capture)
    }

    private var selectedNodeDepth: Int {
        guard let capture, let selectedNodeID, let node = capture.nodes[selectedNodeID] else {
            return 0
        }
        return max(0, node.depth)
    }

    private func nodeID(atViewPoint point: CGPoint) -> String? {
        guard let capture else { return nil }
        return hitTestResolver.nodeID(
            atViewPoint: point,
            capture: capture,
            viewportState: viewportState,
            focusedNodeID: focusedNodeID,
            displayMode: displayMode,
            layerTransform: layerTransform
        )
    }

    private func applyViewportTransform(to context: CGContext) {
        context.concatenate(viewportState.canvasToViewTransform)
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

    private func ciPoint(fromCanvasPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: canvasSize.height - point.y)
    }
}
