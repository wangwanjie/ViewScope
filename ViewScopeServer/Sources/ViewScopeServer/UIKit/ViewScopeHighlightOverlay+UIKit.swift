#if os(iOS)
import UIKit

/// iOS 高亮浮层：在目标窗口最上层临时加一个不可交互的蓝色描边视图，到时自动移除。
@MainActor
final class ViewScopeHighlightOverlay {
    /// 当前进程里所有仍挂在窗口上的高亮视图；抓取时据此排除，并在截图前临时隐藏。
    static let activeOverlayViews = NSHashTable<UIView>.weakObjects()

    private var overlayView: ViewScopeUIKitHighlightView?
    /// 每次 show 递增，延时隐藏任务只处理自己那一代，避免旧任务提前移除新浮层。
    private var generation = 0

    init() {}

    func show(reference: ViewScopeInspectableReference, duration: TimeInterval) {
        hide()
        guard let target = Self.highlightTarget(for: reference) else {
            return
        }

        let view = ViewScopeUIKitHighlightView(frame: target.rect.insetBy(dx: -3, dy: -3))
        target.window.addSubview(view)
        overlayView = view
        Self.activeOverlayViews.add(view)

        generation += 1
        let currentGeneration = generation
        let delay = max(duration.isFinite ? duration : 0, 0.25)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else {
                return
            }
            if self.generation == currentGeneration {
                self.hide()
            }
        }
    }

    func hide() {
        if let overlayView {
            Self.activeOverlayViews.remove(overlayView)
            overlayView.removeFromSuperview()
        }
        overlayView = nil
    }

    /// 抓取时用于排除高亮浮层自身（视图或其 layer）。
    func isOverlayObject(_ object: AnyObject) -> Bool {
        Self.isOverlayObject(object)
    }

    /// 静态版本，供快照构建器在没有浮层实例时使用。
    static func isOverlayObject(_ object: AnyObject) -> Bool {
        if object is ViewScopeUIKitHighlightView {
            return true
        }
        if let layer = object as? CALayer,
           layer.delegate is ViewScopeUIKitHighlightView {
            return true
        }
        return false
    }

    /// 计算高亮所在窗口以及窗口坐标系下的矩形。
    private static func highlightTarget(for reference: ViewScopeInspectableReference) -> (window: UIWindow, rect: CGRect)? {
        guard let object = reference.resolvedObject else {
            return nil
        }
        switch object {
        case let window as UIWindow:
            return (window, window.bounds)
        case let view as UIView:
            guard let window = view.window else {
                return nil
            }
            return (window, view.convert(view.bounds, to: window))
        case let layer as CALayer:
            if let hostView = layer.kg_viewScopeHostView {
                if let window = hostView as? UIWindow {
                    return (window, window.bounds)
                }
                guard let window = hostView.window else {
                    return nil
                }
                return (window, hostView.convert(hostView.bounds, to: window))
            }
            guard let window = layer.kg_viewScopeWindow else {
                return nil
            }
            return (window, window.layer.convert(layer.bounds, from: layer))
        case let controller as UIViewController:
            guard let view = controller.viewIfLoaded, let window = view.window else {
                return nil
            }
            return (window, view.convert(view.bounds, to: window))
        default:
            return nil
        }
    }
}

/// 高亮视图：蓝色圆角描边 + 半透明填充，不参与事件与无障碍。
final class ViewScopeUIKitHighlightView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        layer.borderColor = UIColor.systemBlue.cgColor
        layer.borderWidth = 3
        layer.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        nil
    }
}
#endif
