#if os(macOS)
import AppKit

/// 把客户端传来的 console reference 解析为真实对象。
@MainActor
enum ViewScopeConsoleTargetResolver {
    /// `.view/.layer/.viewController/.window` 走 sourceNodeID → context；
    /// `.viewController` 从视图找到精确拥有它的 VC；`.returnedObject` 返回 nil（由 evaluator 的缓存处理）。
    ///
    /// 解析出的对象地址必须与 `objectID` 一致，防止节点 ID 被复用到别的对象上时误操作（B6）。
    static func resolve(_ reference: ViewScopeRemoteObjectReference, in context: ViewScopeSnapshotBuilder.ReferenceContext) -> AnyObject? {
        guard reference.kind != .returnedObject else {
            return nil
        }
        let lookupID = reference.sourceNodeID ?? reference.objectID
        guard let inspectable = context.nodeReferences[lookupID],
              let resolved = ViewScopeResolvedReference(inspectable) else {
            return nil
        }

        let candidate: AnyObject?
        switch (reference.kind, resolved) {
        case (.window, .window(let window)):
            candidate = window
        case (.view, .view(let view)):
            candidate = view
        case (.view, .layer(let layer)):
            candidate = layer.viewScopeHostView
        case (.layer, .layer(let layer)):
            candidate = layer
        case (.layer, .view(let view)):
            candidate = view.layer
        case (.viewController, .view(let view)):
            candidate = view.viewScopeExactRootOwningViewController
        case (.viewController, .layer(let layer)):
            candidate = layer.viewScopeHostView?.viewScopeExactRootOwningViewController
        case (.viewController, .viewController(let controller)):
            candidate = controller
        default:
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
}
#endif
