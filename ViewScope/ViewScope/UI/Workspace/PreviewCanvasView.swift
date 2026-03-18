import AppKit
import SnapKit
import ViewScopeServer

final class PreviewCanvasView: NSView {
    private let geometry = ViewHierarchyGeometry()
    private let padding: CGFloat = 28

    var onCanvasClick: ((CGPoint) -> Void)?
    var onCanvasDoubleClick: ((CGPoint) -> Void)?

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

    var displayMode: WorkspacePreviewDisplayMode = .flat {
        didSet { needsDisplay = true }
    }

    var zoomScale: CGFloat = 1 {
        didSet {
            updateDocumentSize()
            needsDisplay = true
        }
    }

    var minimumViewportSize: CGSize = .zero {
        didSet { updateDocumentSize() }
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
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

        let drawingRect = canvasDrawingRect
        if let image {
            image.draw(in: drawingRect)
        } else {
            drawWireframeFallback(in: drawingRect)
        }

        if let capture, displayMode == .layered {
            drawLayeredPreview(for: capture)
        }

        if let capture, let focusedNodeID,
           let focusRect = geometry.canvasRect(for: focusedNodeID, in: capture) {
            let viewRect = viewRect(fromCanvasRect: focusRect)
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(roundedRect: viewRect, xRadius: 10, yRadius: 10))
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.12).setFill()
            path.fill()
        }

        if let capture, let selectedNodeID,
           let selectedRect = geometry.canvasRect(for: selectedNodeID, in: capture) {
            let viewRect = viewRect(fromCanvasRect: selectedRect)
            let path = NSBezierPath(roundedRect: viewRect, xRadius: 8, yRadius: 8)
            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.systemBlue.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = canvasPoint(for: convert(event.locationInWindow, from: nil)) else {
            return
        }
        if event.clickCount >= 2 {
            onCanvasDoubleClick?(point)
        } else {
            onCanvasClick?(point)
        }
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

    private func drawWireframeFallback(in drawingRect: CGRect) {
        guard let capture else { return }

        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: drawingRect).fill()

        for nodeID in geometry.visibleNodeIDs(in: capture, rootNodeID: focusedNodeID) {
            guard let rect = geometry.canvasRect(for: nodeID, in: capture) else { continue }
            let viewRect = viewRect(fromCanvasRect: rect)
            let path = NSBezierPath(roundedRect: viewRect, xRadius: 4, yRadius: 4)
            NSColor.systemGray.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.systemGray.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawLayeredPreview(for capture: ViewScopeCapturePayload) {
        let nodeIDs = geometry.visibleNodeIDs(in: capture, rootNodeID: focusedNodeID)
        for nodeID in nodeIDs {
            guard let rect = geometry.canvasRect(for: nodeID, in: capture),
                  let node = capture.nodes[nodeID] else { continue }
            let viewRect = viewRect(fromCanvasRect: rect)
            let relativeDepth = max(0, node.depth - (capture.nodes[focusedNodeID ?? ""]?.depth ?? 0))
            let offset = CGFloat(relativeDepth) * 1.5
            let insetRect = viewRect.offsetBy(dx: offset, dy: offset)
            let outline = NSBezierPath(roundedRect: insetRect, xRadius: 4, yRadius: 4)
            NSColor.systemBlue.withAlphaComponent(min(0.16, 0.04 + CGFloat(relativeDepth) * 0.01)).setStroke()
            outline.lineWidth = nodeID == selectedNodeID ? 1.6 : 0.8
            outline.stroke()
        }
    }

    private var canvasDrawingRect: CGRect {
        let scaledSize = CGSize(width: canvasSize.width * zoomScale, height: canvasSize.height * zoomScale)
        let availableWidth = max(bounds.width - padding * 2, scaledSize.width)
        let originX = max(padding, (bounds.width - min(bounds.width - padding * 2, scaledSize.width)) / 2)
        let originY = max(padding, (bounds.height - min(bounds.height - padding * 2, scaledSize.height)) / 2)
        return CGRect(
            x: originX + max(0, (availableWidth - scaledSize.width) / 2),
            y: originY,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    private func updateDocumentSize() {
        let scaledSize = CGSize(width: canvasSize.width * zoomScale, height: canvasSize.height * zoomScale)
        let width = max(minimumViewportSize.width, scaledSize.width + padding * 2)
        let height = max(minimumViewportSize.height, scaledSize.height + padding * 2)
        frame.size = CGSize(width: width, height: height)
    }

    func viewRect(fromCanvasRect rect: CGRect) -> CGRect {
        let drawingRect = canvasDrawingRect
        return CGRect(
            x: drawingRect.minX + rect.minX * zoomScale,
            y: drawingRect.minY + (canvasSize.height - rect.maxY) * zoomScale,
            width: rect.width * zoomScale,
            height: rect.height * zoomScale
        )
    }

    private func canvasPoint(for point: CGPoint) -> CGPoint? {
        let drawingRect = canvasDrawingRect
        guard drawingRect.contains(point), zoomScale > 0 else {
            return nil
        }

        let x = (point.x - drawingRect.minX) / zoomScale
        let y = canvasSize.height - ((point.y - drawingRect.minY) / zoomScale)
        return CGPoint(
            x: max(0, min(canvasSize.width, x)),
            y: max(0, min(canvasSize.height, y))
        )
    }
}
