import AppKit

@MainActor
final class ViewScopeOverlayController {
    private let window: NSWindow
    private let highlightView = ViewScopeHighlightView(frame: .zero)
    private var hideWorkItem: DispatchWorkItem?

    init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = highlightView
        panel.orderOut(nil)
        window = panel
    }

    func show(highlight rect: NSRect, in hostWindow: NSWindow, duration: TimeInterval) {
        hideWorkItem?.cancel()

        let windowFrame = hostWindow.convertToScreen(rect)
        window.setFrame(windowFrame.insetBy(dx: -6, dy: -6), display: true)
        highlightView.highlightRect = NSRect(origin: NSPoint(x: 6, y: 6), size: windowFrame.size)
        window.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            self?.window.orderOut(nil)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, 0.25), execute: workItem)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        window.orderOut(nil)
    }
}

private final class ViewScopeHighlightView: NSView {
    var highlightRect: NSRect = .zero {
        didSet {
            needsDisplay = true
        }
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !highlightRect.isEmpty else { return }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10)
        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        path.fill()

        path.lineWidth = 3
        NSColor.systemBlue.setStroke()
        path.stroke()
    }
}
