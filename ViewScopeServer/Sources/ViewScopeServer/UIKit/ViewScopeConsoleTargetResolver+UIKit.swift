#if os(iOS)
import UIKit

/// 把 console 请求里的 `ViewScopeRemoteObjectReference` 解析为真实对象。
///
/// 解析路径：`sourceNodeID` → 最近一次抓取的 `ReferenceContext` → 按 `kind` 取 window / view / layer / 精确 VC，
/// 最后校验对象地址与 `objectID` 一致，防止节点 ID 被新对象复用后误命中（审计 B6）。
@MainActor
enum ViewScopeConsoleTargetResolver {
    static func resolve(
        _ reference: ViewScopeRemoteObjectReference,
        in context: ViewScopeSnapshotBuilder.ReferenceContext
    ) -> AnyObject? {
        // 与 AppKit 实现一致：没有 sourceNodeID 时尝试把 objectID 当作节点 ID 查找。
        let lookupID = reference.sourceNodeID ?? reference.objectID
        guard reference.kind != .returnedObject,
              let base = context.nodeReferences[lookupID]?.resolvedObject else {
            return nil
        }

        let candidate: AnyObject?
        switch reference.kind {
        case .window:
            candidate = window(from: base)
        case .view:
            candidate = view(from: base)
        case .layer:
            candidate = (base as? CALayer) ?? view(from: base)?.layer
        case .viewController:
            if let controller = base as? UIViewController {
                candidate = controller
            } else if let controller = view(from: base)?.kg_viewScopeExactViewController {
                candidate = controller
            } else {
                // 窗口节点的 console target 里提供的是 rootViewController。
                candidate = window(from: base)?.rootViewController
            }
        case .returnedObject:
            candidate = nil
        }

        guard let candidate else {
            return nil
        }
        guard ViewScopeNodeIdentity.address(reference.objectID, matches: candidate) else {
            return nil
        }
        return candidate
    }

    private static func view(from object: AnyObject) -> UIView? {
        if let view = object as? UIView {
            return view
        }
        if let layer = object as? CALayer {
            return layer.kg_viewScopeHostView
        }
        if let controller = object as? UIViewController {
            return controller.viewIfLoaded
        }
        return nil
    }

    private static func window(from object: AnyObject) -> UIWindow? {
        if let window = object as? UIWindow {
            return window
        }
        if let view = view(from: object) {
            return (view as? UIWindow) ?? view.window
        }
        if let layer = object as? CALayer {
            return layer.kg_viewScopeWindow
        }
        return nil
    }
}
#endif
