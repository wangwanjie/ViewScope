import CoreGraphics
import ViewScopeServer

/// 描述抓取到的节点 frame 属于哪一种几何语义。
///
/// - `directGlobalCanvasRect`：服务端已经归一成相对截图根节点的全局画布坐标。
/// - `legacyLocalFrames`：历史数据仍然是父子相对坐标，需要客户端递归换算并处理 flipped。
enum PreviewCanvasGeometryMode {
    case directGlobalCanvasRect
    @available(*, deprecated, message: "服务端始终发送统一画布坐标，不再需要 legacy 路径")
    case legacyLocalFrames
}

/// 负责把节点树恢复成“可命中、可高亮、可绘制”的统一画布矩形。
///
/// 预览模块的几何链路都先经过这里：
/// 服务端抓取 -> `ViewHierarchyGeometry` 还原 rect -> 2D / 3D 各自渲染。
struct ViewHierarchyGeometry {
    /// 在统一画布坐标中做命中测试。
    ///
    /// - `rootNodeID` 决定遍历哪棵子树。
    /// - `coordinateRootNodeID` 决定传入点属于哪个局部坐标系；
    ///   如果当前只预览某个子树，需要先把点平移回全局画布再命中。
    func deepestNodeID(
        at canvasPoint: CGPoint,
        in capture: ViewScopeCapturePayload,
        rootNodeID: String? = nil,
        coordinateRootNodeID: String? = nil,
        mode: PreviewCanvasGeometryMode = .directGlobalCanvasRect
    ) -> String? {
        let resolvedCanvasPoint = translatedCanvasPoint(
            canvasPoint,
            in: capture,
            coordinateRootNodeID: coordinateRootNodeID,
            mode: mode
        )
        let rootNodeIDs = rootNodeID.map { [$0] } ?? capture.rootNodeIDs
        for nodeID in rootNodeIDs.reversed() {
            if let match = deepestNodeID(for: nodeID, at: resolvedCanvasPoint, in: capture.nodes, mode: mode) {
                return match
            }
        }
        return nil
    }

    /// 返回节点在统一画布坐标下的矩形。
    ///
    /// 如果指定了 `coordinateRootNodeID`，结果会减去该根节点的原点，
    /// 让调用方拿到“相对当前 preview root”的局部画布坐标。
    func canvasRect(
        for nodeID: String,
        in capture: ViewScopeCapturePayload,
        coordinateRootNodeID: String? = nil,
        mode: PreviewCanvasGeometryMode = .directGlobalCanvasRect
    ) -> CGRect? {
        for rootNodeID in capture.rootNodeIDs {
            if let rect = canvasRect(for: nodeID, searchNodeID: rootNodeID, in: capture.nodes, mode: mode) {
                return translatedRect(
                    rect,
                    in: capture,
                    coordinateRootNodeID: coordinateRootNodeID,
                    mode: mode
                )
            }
        }
        return nil
    }

    /// 返回可见节点的遍历顺序。
    ///
    /// 后续 layered render/scene plan 都依赖这个顺序建立 plane 与 overlay。
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

    /// 把“相对 preview root 的点”平移回全局画布坐标。
    private func translatedCanvasPoint(
        _ point: CGPoint,
        in capture: ViewScopeCapturePayload,
        coordinateRootNodeID: String?,
        mode: PreviewCanvasGeometryMode
    ) -> CGPoint {
        guard let coordinateRootNodeID,
              let rootRect = canvasRect(for: coordinateRootNodeID, in: capture, coordinateRootNodeID: nil, mode: mode) else {
            return point
        }
        return CGPoint(x: point.x + rootRect.minX, y: point.y + rootRect.minY)
    }

    /// 把全局画布 rect 转成“相对 preview root”的局部画布 rect。
    private func translatedRect(
        _ rect: CGRect,
        in capture: ViewScopeCapturePayload,
        coordinateRootNodeID: String?,
        mode: PreviewCanvasGeometryMode
    ) -> CGRect {
        guard let coordinateRootNodeID,
              let rootRect = canvasRect(for: coordinateRootNodeID, in: capture, coordinateRootNodeID: nil, mode: mode) else {
            return rect
        }

        return rect.offsetBy(dx: -rootRect.minX, dy: -rootRect.minY)
    }

    /// 服务端始终发送统一画布坐标，直接信任 node.frame。
    private func resolvedRect(
        for nodeID: String,
        in nodes: [String: ViewScopeHierarchyNode],
        mode: PreviewCanvasGeometryMode,
        parentOrigin: CGPoint,
        parentIsFlipped: Bool,
        parentBoundsHeight: CGFloat
    ) -> CGRect {
        guard let node = nodes[nodeID] else { return .zero }
        return node.frame.cgRect
    }
}
