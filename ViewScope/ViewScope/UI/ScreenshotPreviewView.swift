import AppKit
import Combine
import ViewScopeServer

/// Renders the latest screenshot preview and forwards canvas-space hit tests to the controller.
final class ScreenshotPreviewView: NSView {
    private var cancellables = Set<AnyCancellable>()

    var onCanvasClick: ((CGPoint) -> Void)?
    var placeholderText: String = L10n.previewPlaceholder {
        didSet { needsDisplay = true }
    }

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var canvasSize: ViewScopeSize = .zero {
        didSet { needsDisplay = true }
    }

    var highlightRect: ViewScopeRect = .zero {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bindLocalization()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard image != nil, canvasSize.width > 0, canvasSize.height > 0 else { return }
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let roundedBounds = NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20)
        NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.98, alpha: 1).setFill()
        roundedBounds.fill()
        NSColor(calibratedRed: 0.84, green: 0.88, blue: 0.90, alpha: 1).setStroke()
        roundedBounds.lineWidth = 1
        roundedBounds.stroke()

        let insetBounds = bounds.insetBy(dx: 18, dy: 18)
        guard let image else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centeredParagraphStyle
            ]
            let attributed = NSAttributedString(string: placeholderText, attributes: attributes)
            attributed.draw(in: insetBounds)
            return
        }

        let imageRect = aspectFitRect(for: image.size, inside: insetBounds)
        image.draw(in: imageRect)

        guard canvasSize.width > 0, canvasSize.height > 0, highlightRect.width > 0, highlightRect.height > 0 else {
            return
        }

        let scale = min(imageRect.width / canvasSize.width, imageRect.height / canvasSize.height)
        let drawingY = canvasSize.height - highlightRect.y - highlightRect.height
        let overlayRect = NSRect(
            x: imageRect.minX + highlightRect.x * scale,
            y: imageRect.minY + drawingY * scale,
            width: highlightRect.width * scale,
            height: highlightRect.height * scale
        )

        let overlayPath = NSBezierPath(roundedRect: overlayRect, xRadius: 10, yRadius: 10)
        NSColor.systemBlue.withAlphaComponent(0.10).setFill()
        overlayPath.fill()
        NSColor.systemBlue.setStroke()
        overlayPath.lineWidth = 2
        overlayPath.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvasPoint = canvasPoint(for: convert(event.locationInWindow, from: nil)) else {
            return
        }
        onCanvasClick?(canvasPoint)
    }

    private func aspectFitRect(for size: NSSize, inside container: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return container }
        let widthRatio = container.width / size.width
        let heightRatio = container.height / size.height
        let scale = min(widthRatio, heightRatio)
        let targetSize = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: container.midX - targetSize.width / 2,
            y: container.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    private var centeredParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }

    private func canvasPoint(for point: NSPoint) -> CGPoint? {
        guard let image,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return nil
        }

        let insetBounds = bounds.insetBy(dx: 18, dy: 18)
        let imageRect = aspectFitRect(for: image.size, inside: insetBounds)
        guard imageRect.contains(point) else {
            return nil
        }

        let scale = min(imageRect.width / canvasSize.width, imageRect.height / canvasSize.height)
        guard scale > 0 else { return nil }

        let relativeX = (point.x - imageRect.minX) / scale
        let relativeY = (point.y - imageRect.minY) / scale
        let canvasY = canvasSize.height - relativeY

        return CGPoint(
            x: max(0, min(canvasSize.width, relativeX)),
            y: max(0, min(canvasSize.height, canvasY))
        )
    }

    private func bindLocalization() {
        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.placeholderText = L10n.previewPlaceholder
            }
            .store(in: &cancellables)
    }
}
