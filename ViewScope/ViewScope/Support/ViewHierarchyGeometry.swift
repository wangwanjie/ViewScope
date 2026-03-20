import CoreGraphics
import ViewScopeServer

enum PreviewCanvasGeometryMode {
    case directGlobalCanvasRect
    case legacyLocalFrames
}

struct ViewHierarchyGeometry {
    func deepestNodeID(
        at canvasPoint: CGPoint,
        in capture: ViewScopeCapturePayload,
        rootNodeID: String? = nil,
        mode: PreviewCanvasGeometryMode = .directGlobalCanvasRect
    ) -> String? {
        let rootNodeIDs = rootNodeID.map { [$0] } ?? capture.rootNodeIDs
        for nodeID in rootNodeIDs.reversed() {
            if let match = deepestNodeID(for: nodeID, at: canvasPoint, in: capture.nodes, mode: mode) {
                return match
            }
        }
        return nil
    }

    func canvasRect(
        for nodeID: String,
        in capture: ViewScopeCapturePayload,
        mode: PreviewCanvasGeometryMode = .directGlobalCanvasRect
    ) -> CGRect? {
        for rootNodeID in capture.rootNodeIDs {
            if let rect = canvasRect(for: nodeID, searchNodeID: rootNodeID, in: capture.nodes, mode: mode) {
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
        mode: PreviewCanvasGeometryMode,
        parentOrigin: CGPoint = .zero,
        parentIsFlipped: Bool = false,
        parentBoundsHeight: CGFloat = 0
    ) -> String? {
        guard let node = nodes[nodeID], !node.isHidden else {
            return nil
        }

        let rect = resolvedRect(
            for: nodeID,
            in: nodes,
            mode: mode,
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
                mode: mode,
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
        mode: PreviewCanvasGeometryMode,
        parentOrigin: CGPoint = .zero,
        parentIsFlipped: Bool = false,
        parentBoundsHeight: CGFloat = 0
    ) -> CGRect? {
        guard let node = nodes[searchNodeID] else {
            return nil
        }

        let rect = resolvedRect(
            for: searchNodeID,
            in: nodes,
            mode: mode,
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
                mode: mode,
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

    private func resolvedRect(
        for nodeID: String,
        in nodes: [String: ViewScopeHierarchyNode],
        mode: PreviewCanvasGeometryMode,
        parentOrigin: CGPoint,
        parentIsFlipped: Bool,
        parentBoundsHeight: CGFloat
    ) -> CGRect {
        guard let node = nodes[nodeID] else { return .zero }
        switch mode {
        case .directGlobalCanvasRect:
            return node.frame.cgRect
        case .legacyLocalFrames:
            return legacyGlobalRect(
                for: node,
                parentOrigin: parentOrigin,
                parentIsFlipped: parentIsFlipped,
                parentBoundsHeight: parentBoundsHeight
            )
        }
    }

    private func legacyGlobalRect(
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
