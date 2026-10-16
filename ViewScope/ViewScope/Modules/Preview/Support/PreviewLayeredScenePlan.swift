import CoreGraphics
import ViewScopeServer

/// 供 `PreviewLayeredSceneView` 使用的 scene 计划（flat 与 layered 共用）。
///
/// - 保留数据源的 top-left 画布 rect，直接用于 SceneKit 布局；
/// - 计算 `zIndex`，决定真实前后遮挡；
/// - 提前算好 punch-out rect 与裁剪 rect，供节点纹理裁切、命中测试使用。
///
/// 计划只依赖“结构性”输入（capture、展开状态、预览根、wrapper 开关），
/// 与层间距、边框、选中态无关，因此这些属性变化时不需要重新生成计划。
struct PreviewLayeredScenePlan: Equatable {
    struct Plane: Equatable {
        let depth: Int
        let nodeIDs: [String]
    }

    struct Item: Identifiable, Equatable {
        let nodeID: String
        /// 展示层级（presented hierarchy）中的父节点。
        let parentNodeID: String?
        let depth: Int
        let zIndex: Int
        let displayOrder: Int
        let displayingIndependently: Bool
        /// 节点在统一画布中的完整矩形。名称沿用旧实现，保持调用方兼容。
        let displayRect: CGRect
        let punchedOutRects: [CGRect]
        /// 裁剪祖先（`clippingEnabled`）的交集区域；nil 表示没有裁剪祖先。
        let clipRect: CGRect?
        /// 承载该节点像素的独立平面：独立显示的节点是它自己，折叠节点是最近的独立祖先。
        let planeOwnerNodeID: String

        var id: String { nodeID }

        /// 节点实际可见的区域（被裁剪祖先截掉的部分不算）。
        var visibleRect: CGRect {
            guard let clipRect else {
                return displayRect
            }
            let intersection = clipRect.intersection(displayRect)
            return intersection.isNull ? .zero : intersection
        }
    }

    private struct PendingItem {
        let nodeID: String
        let parentNodeID: String?
        let depth: Int
        let displayOrder: Int
        let displayingIndependently: Bool
        let displayRect: CGRect
        let punchedOutRects: [CGRect]
        let clipRect: CGRect?
        let planeOwnerNodeID: String
    }

    let canvasSize: CGSize
    let planes: [Plane]
    let items: [Item]
    private let itemIndexByNodeID: [String: Int]

    init(canvasSize: CGSize, planes: [Plane], items: [Item]) {
        self.canvasSize = canvasSize
        self.planes = planes
        self.items = items
        var indexByNodeID: [String: Int] = [:]
        indexByNodeID.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            indexByNodeID[item.nodeID] = index
        }
        itemIndexByNodeID = indexByNodeID
    }

    static func == (lhs: PreviewLayeredScenePlan, rhs: PreviewLayeredScenePlan) -> Bool {
        lhs.canvasSize == rhs.canvasSize && lhs.planes == rhs.planes && lhs.items == rhs.items
    }

    var maxDepth: Int {
        planes.map(\.depth).max() ?? 0
    }

    /// O(1) 查找。
    func item(for nodeID: String) -> Item? {
        guard let index = itemIndexByNodeID[nodeID] else {
            return nil
        }
        return items[index]
    }

    /// 生成 scene 结构描述。
    static func make(
        capture: ViewScopeCapturePayload,
        canvasSize: CGSize,
        expandedNodeIDs: Set<String>,
        previewRootNodeID: String? = nil,
        geometryMode: PreviewCanvasGeometryMode = .directGlobalCanvasRect,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry(),
        showsSystemWrapperViews: Bool = false,
        isolatedRootNodeID: String? = nil
    ) -> PreviewLayeredScenePlan {
        let coordinateOrigin = geometry.canvasOrigin(of: previewRootNodeID, in: capture)
        // 聚焦（Focus）时只保留聚焦子树：遍历从聚焦节点开始，坐标仍然相对预览根。
        let isolatedRoot = isolatedRootNodeID.flatMap { nodeID -> String? in
            guard capture.nodes[nodeID] != nil else {
                return nil
            }
            if let previewRootNodeID,
               geometry.isNode(nodeID, descendantOf: previewRootNodeID, in: capture) == false {
                return nil
            }
            return nodeID
        }
        let rawRootNodeIDs = isolatedRoot.map { [$0] } ?? previewRootNodeID.map { [$0] } ?? capture.rootNodeIDs
        let rootNodeIDs = ViewHierarchyPresentation.presentedRootNodeIDs(
            from: rawRootNodeIDs,
            nodes: capture.nodes,
            showsSystemWrappers: showsSystemWrapperViews
        )
        // 一次遍历原始层级，得到“祖先均未隐藏”的节点集合与各节点的裁剪区域。
        let rawInfo = rawTraversal(
            capture: capture,
            rootNodeIDs: rawRootNodeIDs,
            coordinateOrigin: coordinateOrigin,
            initialClipRect: isolatedRoot.flatMap {
                ancestorClipRect(of: $0, capture: capture, coordinateOrigin: coordinateOrigin)
            }
        )
        let visibleNodes = visibleNodes(
            rootNodeIDs: rootNodeIDs,
            capture: capture,
            expandedNodeIDs: expandedNodeIDs,
            showsSystemWrapperViews: showsSystemWrapperViews
        )

        var pendingItems: [PendingItem] = []
        var nodeIDsByPlane: [Int: [String]] = [:]
        pendingItems.reserveCapacity(visibleNodes.count)

        for (displayOrder, visibleNode) in visibleNodes.enumerated() {
            guard let displayRect = rawInfo.rectByNodeID[visibleNode.nodeID] else {
                continue
            }

            // 展开节点的子节点会作为独立平面显示，父纹理里要挖掉它们实际可见的区域。
            let punchedOutRects = visibleNode.expandedChildIDs.compactMap { childID -> CGRect? in
                guard let childRect = rawInfo.rectByNodeID[childID] else {
                    return nil
                }
                if let clipRect = rawInfo.clipRectByNodeID[childID] {
                    let visible = clipRect.intersection(childRect)
                    return visible.isNull || visible.isEmpty ? nil : visible
                }
                return childRect
            }

            pendingItems.append(
                PendingItem(
                    nodeID: visibleNode.nodeID,
                    parentNodeID: visibleNode.parentNodeID,
                    depth: visibleNode.depth,
                    displayOrder: displayOrder,
                    displayingIndependently: visibleNode.displayingIndependently,
                    displayRect: displayRect,
                    punchedOutRects: punchedOutRects,
                    clipRect: rawInfo.clipRectByNodeID[visibleNode.nodeID],
                    planeOwnerNodeID: visibleNode.planeOwnerNodeID
                )
            )
            if visibleNode.displayingIndependently {
                nodeIDsByPlane[visibleNode.depth, default: []].append(visibleNode.nodeID)
            }
        }

        // 先算 zIndex，再把前景层对后景层的遮挡转换成纹理 punch-out。
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let items = assignZIndexes(to: pendingItems, bounds: bounds)
        let punchedOutItems = addOverlapPunchOuts(to: items, bounds: bounds, capture: capture)

        let planes = nodeIDsByPlane.keys.sorted().map { depth in
            Plane(depth: depth, nodeIDs: nodeIDsByPlane[depth] ?? [])
        }

        return PreviewLayeredScenePlan(
            canvasSize: canvasSize,
            planes: planes,
            items: punchedOutItems
        )
    }

    private struct VisibleNode {
        let nodeID: String
        let parentNodeID: String?
        let depth: Int
        let displayingIndependently: Bool
        let expandedChildIDs: [String]
        let planeOwnerNodeID: String
    }

    private struct RawTraversalInfo {
        /// 祖先链全部未隐藏的节点 -> 相对预览根的画布 rect。
        var rectByNodeID: [String: CGRect] = [:]
        /// 有裁剪祖先的节点 -> 裁剪区域。
        var clipRectByNodeID: [String: CGRect] = [:]
    }

    /// 遍历原始层级（不做 wrapper 折叠），O(n)。
    private static func rawTraversal(
        capture: ViewScopeCapturePayload,
        rootNodeIDs: [String],
        coordinateOrigin: CGPoint,
        initialClipRect: CGRect? = nil
    ) -> RawTraversalInfo {
        var info = RawTraversalInfo()
        info.rectByNodeID.reserveCapacity(capture.nodes.count)
        var stack: [(nodeID: String, clipRect: CGRect?)] = rootNodeIDs.reversed().map { ($0, initialClipRect) }
        var visited = Set<String>()

        while let entry = stack.popLast() {
            guard visited.insert(entry.nodeID).inserted,
                  let node = capture.nodes[entry.nodeID],
                  node.isHidden == false else {
                continue
            }
            let rect = node.frame.cgRect.offsetBy(dx: -coordinateOrigin.x, dy: -coordinateOrigin.y)
            info.rectByNodeID[node.id] = rect
            if let clipRect = entry.clipRect {
                info.clipRectByNodeID[node.id] = clipRect
            }

            // 窗口节点的 frame 不在画布坐标系中，不参与裁剪。
            var childClipRect = entry.clipRect
            if node.kind != .window, node.clippingEnabled {
                childClipRect = childClipRect.map { $0.intersection(rect) } ?? rect
            }
            for childID in node.childIDs.reversed() {
                stack.append((childID, childClipRect))
            }
        }
        return info
    }

    /// 从某个节点向上累积裁剪祖先的区域（聚焦子树时，子树根仍受祖先裁剪）。
    private static func ancestorClipRect(
        of nodeID: String,
        capture: ViewScopeCapturePayload,
        coordinateOrigin: CGPoint
    ) -> CGRect? {
        var clipRect: CGRect?
        var currentNodeID = capture.nodes[nodeID]?.parentID
        var steps = 0
        while let candidateID = currentNodeID,
              let candidate = capture.nodes[candidateID],
              steps <= capture.nodes.count {
            if candidate.kind != .window, candidate.clippingEnabled {
                let rect = candidate.frame.cgRect.offsetBy(dx: -coordinateOrigin.x, dy: -coordinateOrigin.y)
                clipRect = clipRect.map { $0.intersection(rect) } ?? rect
            }
            currentNodeID = candidate.parentID
            steps += 1
        }
        return clipRect
    }

    /// 独立显示的节点：zIndex = 之前出现且与之相交的所有节点的最大 zIndex + 1；
    /// 折叠节点继承父节点 zIndex，但它的 rect 仍会参与后续节点的相交判断。
    private static func assignZIndexes(to pendingItems: [PendingItem], bounds: CGRect) -> [Item] {
        var items: [Item] = []
        var zIndexByNodeID: [String: Int] = [:]
        items.reserveCapacity(pendingItems.count)
        var index = CanvasSpatialIndex(bounds: bounds, expectedCount: pendingItems.count)

        for pendingItem in pendingItems {
            let zIndex: Int
            if pendingItem.displayingIndependently {
                var overlappedZIndex: Int?
                for candidate in index.candidateIDs(intersecting: pendingItem.displayRect) {
                    let candidateItem = items[candidate]
                    guard candidateItem.displayRect.intersects(pendingItem.displayRect) else {
                        continue
                    }
                    overlappedZIndex = max(overlappedZIndex ?? candidateItem.zIndex, candidateItem.zIndex)
                }
                zIndex = (overlappedZIndex ?? -1) + 1
            } else if let parentNodeID = pendingItem.parentNodeID,
                      let parentZIndex = zIndexByNodeID[parentNodeID] {
                zIndex = parentZIndex
            } else {
                zIndex = 0
            }

            let item = Item(
                nodeID: pendingItem.nodeID,
                parentNodeID: pendingItem.parentNodeID,
                depth: pendingItem.depth,
                zIndex: zIndex,
                displayOrder: pendingItem.displayOrder,
                displayingIndependently: pendingItem.displayingIndependently,
                displayRect: pendingItem.displayRect,
                punchedOutRects: pendingItem.punchedOutRects,
                clipRect: pendingItem.clipRect,
                planeOwnerNodeID: pendingItem.planeOwnerNodeID
            )
            items.append(item)
            index.insert(pendingItem.displayRect)
            zIndexByNodeID[pendingItem.nodeID] = zIndex
        }

        return items
    }

    /// 计算独立平面纹理需要挖掉的区域，避免同一块像素同时出现在两个平面上：
    ///
    /// 1. 更靠前（zIndex 更大）的独立平面与当前平面相交时，相交区域属于前景平面，必须挖掉；
    /// 2. 当前平面已知是透明的（v3 traits 声明非不透明且没有不透明背景色）时，
    ///    它的纹理是从合成截图里裁出来的，会“透出”下面那些已经独立成层的节点像素。
    ///    这时更靠后（zIndex 更小）且与之相交的独立平面也要挖掉；
    ///    但祖先与后代除外——祖先本来就在它下面整块铺开，后代的像素本来就属于它所在的子树。
    private static func addOverlapPunchOuts(
        to items: [Item],
        bounds: CGRect,
        capture: ViewScopeCapturePayload
    ) -> [Item] {
        let independentIndices = items.indices.filter { items[$0].displayingIndependently }
        var index = CanvasSpatialIndex(bounds: bounds, expectedCount: independentIndices.count)
        for itemIndex in independentIndices {
            index.insert(items[itemIndex].displayRect)
        }
        var parentByNodeID: [String: String] = [:]
        for item in items {
            if let parentNodeID = item.parentNodeID {
                parentByNodeID[item.nodeID] = parentNodeID
            }
        }

        // 判断 ancestorID 是否是 nodeID 在展示层级中的祖先
        func isAncestor(_ ancestorID: String, of nodeID: String) -> Bool {
            var current = parentByNodeID[nodeID]
            while let candidate = current {
                if candidate == ancestorID {
                    return true
                }
                current = parentByNodeID[candidate]
            }
            return false
        }

        var result = items
        for (slot, itemIndex) in independentIndices.enumerated() {
            let item = items[itemIndex]
            let isTransparent = isTransparentNode(capture.nodes[item.nodeID])
            var punchedOutRects = item.punchedOutRects
            var didAppend = false
            for candidateSlot in index.candidateIDs(intersecting: item.displayRect) where candidateSlot != slot {
                let candidate = items[independentIndices[candidateSlot]]
                guard candidate.displayRect.intersects(item.displayRect),
                      punchedOutRects.contains(candidate.displayRect) == false else {
                    continue
                }
                let coversFromFront = candidate.zIndex > item.zIndex
                let showsThroughFromBehind = isTransparent &&
                    candidate.zIndex < item.zIndex &&
                    isAncestor(candidate.nodeID, of: item.nodeID) == false &&
                    isAncestor(item.nodeID, of: candidate.nodeID) == false
                guard coversFromFront || showsThroughFromBehind else {
                    continue
                }
                punchedOutRects.append(candidate.displayRect)
                didAppend = true
            }

            guard didAppend else {
                continue
            }
            result[itemIndex] = Item(
                nodeID: item.nodeID,
                parentNodeID: item.parentNodeID,
                depth: item.depth,
                zIndex: item.zIndex,
                displayOrder: item.displayOrder,
                displayingIndependently: item.displayingIndependently,
                displayRect: item.displayRect,
                punchedOutRects: punchedOutRects,
                clipRect: item.clipRect,
                planeOwnerNodeID: item.planeOwnerNodeID
            )
        }
        return result
    }

    /// 节点是否已知会透出下层像素。
    ///
    /// 只有 v3 宿主通过 traits 明确告知“非不透明且没有不透明背景色”时才算透明；
    /// 没有 traits（旧宿主）时保守地按不透明处理，避免给大量不透明视图挖出错误的空洞。
    private static func isTransparentNode(_ node: ViewScopeHierarchyNode?) -> Bool {
        guard let traits = node?.traits else {
            return false
        }
        if traits.isOpaque == true {
            return false
        }
        if let backgroundAlpha = traits.backgroundAlpha, backgroundAlpha >= 0.99 {
            return false
        }
        return true
    }

    private static func visibleNodes(
        rootNodeIDs: [String],
        capture: ViewScopeCapturePayload,
        expandedNodeIDs: Set<String>,
        showsSystemWrapperViews: Bool
    ) -> [VisibleNode] {
        // 这里把“是否独立分层”和“节点是否存在于 scene 中”拆开：
        // collapsed 节点依然保留 item（用于命中测试与遮挡计算），只是继承父节点的 zIndex/平面。
        var result: [VisibleNode] = []
        result.reserveCapacity(capture.nodes.count)

        struct Entry {
            let nodeID: String
            let parentNodeID: String?
            let depth: Int
            let ancestorsDisplayChildren: Bool
            let expandsAutomatically: Bool
            let planeOwnerNodeID: String?
        }

        // 显式栈先序遍历，顺序与递归版本一致。
        var stack: [Entry] = rootNodeIDs.reversed().map {
            Entry(nodeID: $0, parentNodeID: nil, depth: 0, ancestorsDisplayChildren: true, expandsAutomatically: true, planeOwnerNodeID: nil)
        }
        var visited = Set<String>()

        while let entry = stack.popLast() {
            guard visited.insert(entry.nodeID).inserted,
                  let node = capture.nodes[entry.nodeID],
                  node.isHidden == false else {
                continue
            }

            let shouldExpand = entry.expandsAutomatically || expandedNodeIDs.contains(entry.nodeID)
            let visibleChildIDs = ViewHierarchyPresentation.presentedChildNodeIDs(
                of: entry.nodeID,
                nodes: capture.nodes,
                showsSystemWrappers: showsSystemWrapperViews
            ).filter { childID in
                capture.nodes[childID]?.isHidden == false
            }
            let displayingIndependently = entry.depth == 0 || entry.ancestorsDisplayChildren
            let planeOwnerNodeID = displayingIndependently ? entry.nodeID : (entry.planeOwnerNodeID ?? entry.nodeID)

            result.append(
                VisibleNode(
                    nodeID: entry.nodeID,
                    parentNodeID: entry.parentNodeID,
                    depth: entry.depth,
                    displayingIndependently: displayingIndependently,
                    expandedChildIDs: shouldExpand ? visibleChildIDs : [],
                    planeOwnerNodeID: planeOwnerNodeID
                )
            )

            for childID in visibleChildIDs.reversed() {
                stack.append(
                    Entry(
                        nodeID: childID,
                        parentNodeID: entry.nodeID,
                        depth: entry.depth + 1,
                        ancestorsDisplayChildren: shouldExpand,
                        expandsAutomatically: false,
                        planeOwnerNodeID: planeOwnerNodeID
                    )
                )
            }
        }
        return result
    }
}
