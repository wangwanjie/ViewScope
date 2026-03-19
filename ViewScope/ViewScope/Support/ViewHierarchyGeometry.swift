import CoreGraphics
import ViewScopeServer

struct ViewHierarchyGeometry {
    func deepestNodeID(at canvasPoint: CGPoint, in capture: ViewScopeCapturePayload, rootNodeID: String? = nil) -> String? {
        let rootNodeIDs = rootNodeID.map { [$0] } ?? capture.rootNodeIDs
        for nodeID in rootNodeIDs.reversed() {
            if let match = deepestNodeID(
                for: nodeID,
                at: canvasPoint,
                in: capture.nodes,
                parentOrigin: .zero,
                parentIsFlipped: false,
                parentBoundsHeight: 0
            ) {
                return match
            }
        }
        return nil
    }

    func canvasRect(for nodeID: String, in capture: ViewScopeCapturePayload) -> CGRect? {
        for rootNodeID in capture.rootNodeIDs {
            if let rect = canvasRect(
                for: nodeID,
                searchNodeID: rootNodeID,
                in: capture.nodes,
                parentOrigin: .zero,
                parentIsFlipped: false,
                parentBoundsHeight: 0
            ) {
                return rect
            }
        }
        return nil
    }

    func visibleNodeIDs(in capture: ViewScopeCapturePayload, rootNodeID: String? = nil) -> [String] {
        let rootNodeIDs = rootNodeID.map { [$0] } ?? capture.rootNodeIDs
        var orderedNodeIDs: [String] = []
        for nodeID in rootNodeIDs {
            appendVisibleNodeIDs(nodeID, nodes: capture.nodes, into: &orderedNodeIDs)
        }
        return orderedNodeIDs
    }

    private func deepestNodeID(
        for nodeID: String,
        at canvasPoint: CGPoint,
        in nodes: [String: ViewScopeHierarchyNode],
        parentOrigin: CGPoint,
        parentIsFlipped: Bool,
        parentBoundsHeight: CGFloat
    ) -> String? {
        guard let node = nodes[nodeID], !node.isHidden else {
            return nil
        }

        let rect = globalRect(
            for: node,
            parentOrigin: parentOrigin,
            parentIsFlipped: parentIsFlipped,
            parentBoundsHeight: parentBoundsHeight
        )
        guard rect.contains(canvasPoint) else {
            return nil
        }

        for childID in node.childIDs.reversed() {
            if let match = deepestNodeID(
                for: childID,
                at: canvasPoint,
                in: nodes,
                parentOrigin: rect.origin,
                parentIsFlipped: node.isFlipped,
                parentBoundsHeight: CGFloat(node.bounds.height)
            ) {
                return match
            }
        }

        return node.id
    }

    private func canvasRect(
        for targetNodeID: String,
        searchNodeID: String,
        in nodes: [String: ViewScopeHierarchyNode],
        parentOrigin: CGPoint,
        parentIsFlipped: Bool,
        parentBoundsHeight: CGFloat
    ) -> CGRect? {
        guard let node = nodes[searchNodeID] else {
            return nil
        }

        let rect = globalRect(
            for: node,
            parentOrigin: parentOrigin,
            parentIsFlipped: parentIsFlipped,
            parentBoundsHeight: parentBoundsHeight
        )
        if node.id == targetNodeID {
            return rect
        }

        for childID in node.childIDs {
            if let rect = canvasRect(
                for: targetNodeID,
                searchNodeID: childID,
                in: nodes,
                parentOrigin: rect.origin,
                parentIsFlipped: node.isFlipped,
                parentBoundsHeight: CGFloat(node.bounds.height)
            ) {
                return rect
            }
        }

        return nil
    }

    private func appendVisibleNodeIDs(_ nodeID: String, nodes: [String: ViewScopeHierarchyNode], into result: inout [String]) {
        guard let node = nodes[nodeID], !node.isHidden else {
            return
        }
        result.append(nodeID)
        node.childIDs.forEach { appendVisibleNodeIDs($0, nodes: nodes, into: &result) }
    }

    private func globalRect(
        for node: ViewScopeHierarchyNode,
        parentOrigin: CGPoint,
        parentIsFlipped: Bool,
        parentBoundsHeight: CGFloat
    ) -> CGRect {
        if node.kind == .window {
            return node.frame.cgRect
        }

        let x = parentOrigin.x + CGFloat(node.frame.x)
        let y: CGFloat
        if parentIsFlipped {
            y = parentOrigin.y + CGFloat(node.frame.y)
        } else {
            y = parentOrigin.y + parentBoundsHeight - CGFloat(node.frame.y) - CGFloat(node.frame.height)
        }

        return CGRect(
            x: x,
            y: y,
            width: CGFloat(node.frame.width),
            height: CGFloat(node.frame.height)
        )
    }
}

#if DEBUG
struct PreviewHitTester {
    private let geometry = ViewHierarchyGeometry()

    func deepestNodeID(at canvasPoint: CGPoint, in capture: ViewScopeCapturePayload) -> String? {
        geometry.deepestNodeID(at: canvasPoint, in: capture)
    }
}
#endif
