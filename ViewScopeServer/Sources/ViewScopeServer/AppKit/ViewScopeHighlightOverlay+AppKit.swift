#if os(macOS)
import AppKit

/// 在宿主窗口上方短暂显示高亮框。
@MainActor
final class ViewScopeHighlightOverlay {
    private let window: NSWindow
    private let highlightView = ViewScopeHighlightView(frame: .zero)
    private var hideWorkItem: DispatchWorkItem?
    private weak var attachedHostWindow: NSWindow?

    init() {
        let panel = ViewScopeHighlightPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = highlightView
        panel.orderOut(nil)
        window = panel
    }

    func show(reference: ViewScopeInspectableReference, duration: TimeInterval) {
        guard let (rect, hostWindow) = Self.highlightTarget(for: reference) else {
            return
        }
        show(highlight: rect, in: hostWindow, duration: duration)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        detach()
        window.orderOut(nil)
    }

    /// 抓取时用于排除高亮浮层自身（窗口或视图）。
    func isOverlayObject(_ object: AnyObject) -> Bool {
        if object === window || object === highlightView {
            return true
        }
        if let view = object as? NSView {
            return view.window === window
        }
        return false
    }

    /// 计算高亮矩形（窗口坐标）与所在窗口。
    static func highlightTarget(for reference: ViewScopeInspectableReference) -> (NSRect, NSWindow)? {
        switch reference {
        case .window(let weakWindow):
            guard let window = weakWindow.object else {
                return nil
            }
            // 窗口坐标系原点在窗口左下角，整个窗口 frame 即 (0, 0, w, h)。
            return (NSRect(origin: .zero, size: window.frame.size), window)
        case .view(let weakView):
            guard let view = weakView.object, let window = view.window else {
                return nil
            }
            return (view.convert(view.bounds, to: nil), window)
        case .layer(let weakLayer):
            guard let layer = weakLayer.object,
                  let window = layer.viewScopeWindow,
                  let rect = layer.viewScopeFrameInWindow else {
                return nil
            }
            return (rect, window)
        case .viewController(let weakController):
            guard let controller = weakController.object,
                  controller.isViewLoaded,
                  let window = controller.view.window else {
                return nil
            }
            return (controller.view.convert(controller.view.bounds, to: nil), window)
        case .object:
            return nil
        }
    }

    private func show(highlight rect: NSRect, in hostWindow: NSWindow, duration: TimeInterval) {
        hideWorkItem?.cancel()
        attach(to: hostWindow)

        let windowFrame = hostWindow.convertToScreen(rect)
        window.setFrame(windowFrame.insetBy(dx: -6, dy: -6), display: true)
        highlightView.highlightRect = NSRect(
            origin: NSPoint(x: 6, y: 6),
            size: NSSize(width: max(window.frame.width - 12, 0), height: max(window.frame.height - 12, 0))
        )
        window.orderFront(nil)

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        let safeDuration = duration.isFinite ? duration : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + min(max(safeDuration, 0.25), 30), execute: workItem)
    }

    private func attach(to hostWindow: NSWindow) {
        guard attachedHostWindow !== hostWindow else {
            return
        }
        detach()
        hostWindow.addChildWindow(window, ordered: .above)
        attachedHostWindow = hostWindow
    }

    private func detach() {
        if let parent = window.parent {
            parent.removeChildWindow(window)
        }
        attachedHostWindow = nil
    }
}

/// 高亮浮层专用的 panel 子类，便于在抓取时按类型识别并排除。
final class ViewScopeHighlightPanel: NSPanel {}

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

        guard !highlightRect.isEmpty else {
            return
        }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10)
        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        path.fill()

        path.lineWidth = 3
        NSColor.systemBlue.setStroke()
        path.stroke()
    }
}
#endif
