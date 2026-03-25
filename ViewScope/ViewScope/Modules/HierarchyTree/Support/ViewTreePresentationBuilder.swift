import Foundation
import ViewScopeServer

struct ViewTreePresentationBuilder {
    func buildRoots(
        capture: ViewScopeCapturePayload?,
        focusedNodeID: String?,
        showsSystemWrappers: Bool,
        query: String
    ) -> [ViewTreeNodeItem] {
        guard let capture else { return [] }

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
        guard !normalizedQuery.isEmpty else { return presentationRoots }
        return presentationRoots.compactMap { $0.filtered(matching: normalizedQuery) }
    }
}
