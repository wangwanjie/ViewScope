import AppKit
import ViewScopeServer

final class ScreenshotPreviewView: NSView {
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
            let text = "Select a node to render the latest screenshot preview."
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centeredParagraphStyle
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
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
}
