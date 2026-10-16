import Foundation
import ViewScopeServer

struct ViewTreePresentationBuilder {
    /// 生成层级树的根节点。
    ///
    /// - `query`：搜索关键字（不区分大小写），为空时不过滤；
    /// - `nodeFilter`：额外的节点条件（例如“只看有问题的节点”），与关键字同时满足才算命中。
    func buildRoots(
        capture: ViewScopeCapturePayload?,
        focusedNodeID: String?,
        showsSystemWrappers: Bool,
        query: String,
        nodeFilter: ((ViewScopeHierarchyNode) -> Bool)? = nil
    ) -> [ViewTreeNodeItem] {
        guard let capture else {
            return []
        }

        let rootNodeIDs = focusedNodeID.map { [$0] } ?? capture.rootNodeIDs
        let presentationRootNodeIDs = ViewHierarchyPresentation.presentedRootNodeIDs(
            from: rootNodeIDs,
            nodes: capture.nodes,
            showsSystemWrappers: showsSystemWrappers
        )
        let presentationRoots = presentationRootNodeIDs.compactMap {
            ViewTreeNodeItem.make(
                nodeID: $0,
                nodes: capture.nodes,
                showsSystemWrappers: showsSystemWrappers
            )
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedQuery.isEmpty == false || nodeFilter != nil else {
            return presentationRoots
        }
        return presentationRoots.compactMap { root in
            root.filtered { node in
                if let nodeFilter, nodeFilter(node) == false {
                    return false
                }
                guard normalizedQuery.isEmpty == false else {
                    return true
                }
                return ViewTreeNodePresentation.matches(node: node, query: normalizedQuery)
            }
        }
    }
}
