import AppKit

/// 叠在 SceneKit 预览上的 2D 覆盖层：测量标注与提示文字。
///
/// 只负责绘制，不参与事件处理（`hitTest` 返回 nil），鼠标事件会穿透到下面的 SCNView。
/// 坐标与 SCNView 一致（左下角原点），由控制器把画布坐标投影后传入。
final class PreviewMeasurementOverlayView: NSView {
    struct Line: Equatable {
        let start: CGPoint
        let end: CGPoint
        let label: String
        let isHorizontal: Bool
    }

    struct Model: Equatable {
        var anchorRect: CGRect?
        var targetRect: CGRect?
        var lines: [Line] = []
        var hint: String?

        static let empty = Model()
    }

    var model = Model.empty {
        didSet {
            guard oldValue != model else {
                return
            }
            needsDisplay = true
        }
    }

    private let measureColor = NSColor.systemPink
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let anchorRect = model.anchorRect {
            let path = NSBezierPath(rect: anchorRect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            measureColor.setStroke()
            path.stroke()
        }
        if let targetRect = model.targetRect {
            let path = NSBezierPath(rect: targetRect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            measureColor.setStroke()
            path.stroke()
        }

        for line in model.lines {
            drawMeasurementLine(line)
        }

        if let hint = model.hint {
            drawHint(hint)
        }
    }

    private func drawMeasurementLine(_ line: Line) {
        let path = NSBezierPath()
        path.move(to: line.start)
        path.line(to: line.end)
        // 两端画短横线，便于看清起止边。
        let capLength: CGFloat = 4
        if line.isHorizontal {
            path.move(to: CGPoint(x: line.start.x, y: line.start.y - capLength))
            path.line(to: CGPoint(x: line.start.x, y: line.start.y + capLength))
            path.move(to: CGPoint(x: line.end.x, y: line.end.y - capLength))
            path.line(to: CGPoint(x: line.end.x, y: line.end.y + capLength))
        } else {
            path.move(to: CGPoint(x: line.start.x - capLength, y: line.start.y))
            path.line(to: CGPoint(x: line.start.x + capLength, y: line.start.y))
            path.move(to: CGPoint(x: line.end.x - capLength, y: line.end.y))
            path.line(to: CGPoint(x: line.end.x + capLength, y: line.end.y))
        }
        path.lineWidth = 1
        measureColor.setStroke()
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white
        ]
        let text = line.label as NSString
        let textSize = text.size(withAttributes: attributes)
        let midpoint = CGPoint(x: (line.start.x + line.end.x) / 2, y: (line.start.y + line.end.y) / 2)
        let padding = CGSize(width: 4, height: 1)
        var labelRect = CGRect(
            x: midpoint.x - textSize.width / 2 - padding.width,
            y: midpoint.y - textSize.height / 2 - padding.height,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        // 水平线的标签放在线上方，垂直线的标签放在线右侧，避免压住线本身。
        if line.isHorizontal {
            labelRect.origin.y += textSize.height / 2 + 4
        } else {
            labelRect.origin.x += textSize.width / 2 + 8
        }
        let background = NSBezierPath(roundedRect: labelRect, xRadius: 3, yRadius: 3)
        measureColor.setFill()
        background.fill()
        text.draw(
            at: CGPoint(x: labelRect.minX + padding.width, y: labelRect.minY + padding.height),
            withAttributes: attributes
        )
    }

    private func drawHint(_ hint: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let text = hint as NSString
        let textSize = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: (bounds.width - textSize.width) / 2 - 8,
            y: bounds.height - textSize.height - 20,
            width: textSize.width + 16,
            height: textSize.height + 8
        )
        let background = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
        background.fill()
        text.draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 4), withAttributes: attributes)
    }
}
