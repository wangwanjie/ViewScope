import CoreGraphics
import ViewScopeServer

struct PreviewHitTester {
    func deepestNodeID(at canvasPoint: CGPoint, in capture: ViewScopeCapturePayload) -> String? {
        for rootNodeID in capture.rootNodeIDs.reversed() {
            if let match = deepestNodeID(
                for: rootNodeID,
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

        let globalRect = globalRect(
            for: node,
            parentOrigin: parentOrigin,
            parentIsFlipped: parentIsFlipped,
            parentBoundsHeight: parentBoundsHeight
        )
        guard globalRect.contains(canvasPoint) else {
            return nil
        }

        for childID in node.childIDs.reversed() {
            if let match = deepestNodeID(
                for: childID,
                at: canvasPoint,
                in: nodes,
                parentOrigin: globalRect.origin,
                parentIsFlipped: node.isFlipped,
                parentBoundsHeight: CGFloat(node.bounds.height)
            ) {
                return match
            }
        }

        return node.id
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
            y = parentOrigin.y + parentBoundsHeight - CGFloat(node.frame.y) - CGFloat(node.frame.height)
        } else {
            y = parentOrigin.y + CGFloat(node.frame.y)
        }

        return CGRect(
            x: x,
            y: y,
            width: CGFloat(node.frame.width),
            height: CGFloat(node.frame.height)
        )
    }
}

private extension ViewScopeRect {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
