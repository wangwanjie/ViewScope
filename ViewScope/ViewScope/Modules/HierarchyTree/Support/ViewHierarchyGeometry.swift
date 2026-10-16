import CoreGraphics
import ViewScopeServer

/// 描述抓取到的节点 frame 属于哪一种几何语义。
///
/// 服务端始终把 `node.frame` 归一为“相对预览根（窗口根节点）的左上角原点画布坐标”，
/// 因此只剩下 `directGlobalCanvasRect` 一种；保留枚举是为了不破坏现有调用方的签名。
enum PreviewCanvasGeometryMode {
    case directGlobalCanvasRect
}

/// 负责把节点树恢复成“可命中、可高亮、可绘制”的统一画布矩形。
///
/// 预览模块的几何链路都先经过这里：
/// 服务端抓取 -> `ViewHierarchyGeometry` 还原 rect -> 2D / 3D 各自渲染。
struct ViewHierarchyGeometry {
    /// 在统一画布坐标中做命中测试，返回最深的可见节点。
    ///
    /// - `rootNodeID` 决定遍历哪棵子树。
    /// - `coordinateRootNodeID` 决定传入点属于哪个局部坐标系；
    ///   如果当前只预览某个子树，需要先把点平移回全局画布再命中。
    /// - 开启 `clippingEnabled` 的祖先会裁掉超出范围的子节点，被裁掉的区域不会命中。
    func deepestNodeID(
        at canvasPoint: CGPoint,
        in capture: ViewScopeCapturePayload,
        rootNodeID: String? = nil,
        coordinateRootNodeID: String? = nil,
        mode: PreviewCanvasGeometryMode = .directGlobalCanvasRect
    ) -> String? {
        let origin = canvasOrigin(of: coordinateRootNodeID, in: capture)
        let resolvedCanvasPoint = CGPoint(x: canvasPoint.x + origin.x, y: canvasPoint.y + origin.y)
        let rootNodeIDs = rootNodeID.map { [$0] } ?? capture.rootNodeIDs
        for nodeID in rootNodeIDs.reversed() {
            if let match = deepestNodeID(for: nodeID, at: resolvedCanvasPoint, in: capture.nodes, clipRect: nil) {
                return match
            }
        }
        return nil
    }

    /// 返回节点在统一画布坐标下的矩形，O(1)。
    ///
    /// 如果指定了 `coordinateRootNodeID`，结果会减去该根节点的原点，
    /// 让调用方拿到“相对当前 preview root”的局部画布坐标。
    func canvasRect(
        for nodeID: String,
        in capture: ViewScopeCapturePayload,
        coordinateRootNodeID: String? = nil,
        mode: PreviewCanvasGeometryMode = .directGlobalCanvasRect
    ) -> CGRect? {
        guard let node = capture.nodes[nodeID] else {
            return nil
        }
        let origin = canvasOrigin(of: coordinateRootNodeID, in: capture)
        return node.frame.cgRect.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    /// 预览根在全局画布中的原点；未指定或找不到时为 `.zero`。
    func canvasOrigin(of coordinateRootNodeID: String?, in capture: ViewScopeCapturePayload) -> CGPoint {
        guard let coordinateRootNodeID,
              let rootNode = capture.nodes[coordinateRootNodeID] else {
            return .zero
        }
        return CGPoint(x: rootNode.frame.x, y: rootNode.frame.y)
    }

    /// 返回可见节点的遍历顺序（先序、跳过隐藏子树）。
    func visibleNodeIDs(in capture: ViewScopeCapturePayload, rootNodeID: String? = nil) -> [String] {
        let rootNodeIDs = rootNodeID.map { [$0] } ?? capture.rootNodeIDs
        var orderedNodeIDs: [String] = []
        var stack = Array(rootNodeIDs.reversed())
        while let nodeID = stack.popLast() {
            guard let node = capture.nodes[nodeID], node.isHidden == false else {
                continue
            }
            orderedNodeIDs.append(nodeID)
            stack.append(contentsOf: node.childIDs.reversed())
        }
        return orderedNodeIDs
    }

    /// 判断 `nodeID` 是否为 `ancestorID` 自身或其后代（沿原始 parentID 链向上查找）。
    func isNode(_ nodeID: String, descendantOf ancestorID: String, in capture: ViewScopeCapturePayload) -> Bool {
        var currentNodeID: String? = nodeID
        var steps = 0
        while let candidate = currentNodeID, steps <= capture.nodes.count {
            if candidate == ancestorID {
                return true
            }
            currentNodeID = capture.nodes[candidate]?.parentID
            steps += 1
        }
        return false
    }

    private func deepestNodeID(
        for nodeID: String,
        at canvasPoint: CGPoint,
        in nodes: [String: ViewScopeHierarchyNode],
        clipRect: CGRect?
    ) -> String? {
        guard let node = nodes[nodeID], node.isHidden == false else {
            return nil
        }

        let rect = node.frame.cgRect
        let visibleRect = clipRect.map { $0.intersection(rect) } ?? rect
        // 窗口节点不在画布坐标系里，直接向下查找。
        let isWindow = node.kind == .window
        if isWindow == false {
            guard visibleRect.isNull == false, visibleRect.contains(canvasPoint) else {
                return nil
            }
        }

        var childClipRect = clipRect
        if isWindow == false, node.clippingEnabled {
            childClipRect = visibleRect
        }
        for childID in node.childIDs.reversed() {
            if let match = deepestNodeID(for: childID, at: canvasPoint, in: nodes, clipRect: childClipRect) {
                return match
            }
        }

        if isWindow, rect.contains(canvasPoint) == false {
            return nil
        }
        return node.id
    }
}
