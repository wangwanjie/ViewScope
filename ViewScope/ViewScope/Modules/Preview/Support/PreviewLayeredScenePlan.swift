import CoreGraphics
import ViewScopeServer

/// 供 `PreviewLayeredSceneView` 使用的 3D scene 计划。
///
/// 和 `PreviewLayeredRenderPlan` 的核心区别：
/// - 这里保留数据源的 top-left 画布 rect，直接用于 SceneKit 布局。
/// - 这里会计算 Lookin 风格的 `zIndex`，决定真实前后遮挡。
/// - 这里会提前算好 punch-out rect，供节点纹理裁切使用。
struct PreviewLayeredScenePlan: Equatable {
    struct Plane: Equatable {
        let depth: Int
        let nodeIDs: [String]
    }

    struct Item: Identifiable, Equatable {
        let nodeID: String
        let depth: Int
        let zIndex: Int
        let displayOrder: Int
        let displayingIndependently: Bool
        let displayRect: CGRect
        let punchedOutRects: [CGRect]

        var id: String { nodeID }
    }

    private struct PendingItem {
        let nodeID: String
        let depth: Int
        let displayOrder: Int
        let parentNodeID: String?
        let displayingIndependently: Bool
        let displayRect: CGRect
        let punchedOutRects: [CGRect]
    }

    let canvasSize: CGSize
    let planes: [Plane]
    let items: [Item]

    var maxDepth: Int {
        planes.map(\.depth).max() ?? 0
    }

    func item(for nodeID: String) -> Item? {
        items.first { $0.nodeID == nodeID }
    }

    /// 生成 3D scene 的结构描述。
    ///
    /// `displayRect` 在 3D 里其实是“统一画布 rect”，名称沿用只是为了保持调用方兼容。
    static func make(
        capture: ViewScopeCapturePayload,
        canvasSize: CGSize,
        expandedNodeIDs: Set<String>,
        previewRootNodeID: String? = nil,
        geometryMode: PreviewCanvasGeometryMode = .directGlobalCanvasRect,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry(),
        showsSystemWrapperViews: Bool = false
    ) -> PreviewLayeredScenePlan {
        let rawRootNodeIDs = previewRootNodeID.map { [$0] } ?? capture.rootNodeIDs
        let rootNodeIDs = ViewHierarchyPresentation.presentedRootNodeIDs(
            from: rawRootNodeIDs,
            nodes: capture.nodes,
            showsSystemWrappers: showsSystemWrapperViews
        )
        let geometryVisibleNodeIDs = Set(geometry.visibleNodeIDs(in: capture, rootNodeID: previewRootNodeID))
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
            guard geometryVisibleNodeIDs.contains(visibleNode.nodeID),
                  let normalizedRect = geometry.canvasRect(
                    for: visibleNode.nodeID,
                    in: capture,
                    coordinateRootNodeID: previewRootNodeID,
                    mode: geometryMode
                  ) else {
                continue
            }

            let displayRect = normalizedRect
            let punchedOutRects = visibleNode.expandedChildIDs.compactMap { childID -> CGRect? in
                guard geometryVisibleNodeIDs.contains(childID),
                      let childRect = geometry.canvasRect(
                        for: childID,
                        in: capture,
                        coordinateRootNodeID: previewRootNodeID,
                        mode: geometryMode
                      ) else {
                    return nil
                }
                return childRect
            }

            pendingItems.append(
                PendingItem(
                    nodeID: visibleNode.nodeID,
                    depth: visibleNode.depth,
                    displayOrder: displayOrder,
                    parentNodeID: visibleNode.parentNodeID,
                    displayingIndependently: visibleNode.displayingIndependently,
                    displayRect: displayRect,
                    punchedOutRects: punchedOutRects
                )
            )
            if visibleNode.displayingIndependently {
                nodeIDsByPlane[visibleNode.depth, default: []].append(visibleNode.nodeID)
            }
        }

        // 先算 Lookin 风格 zIndex，再把前景层对后景层的遮挡转换成纹理 punch-out。
        let items = assignZIndexes(to: pendingItems)
        let punchedOutItems = addOverlapPunchOuts(to: items)

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
    }

    private static func assignZIndexes(to pendingItems: [PendingItem]) -> [Item] {
        var items: [Item] = []
        var itemByNodeID: [String: Item] = [:]
        items.reserveCapacity(pendingItems.count)

        for pendingItem in pendingItems {
            let zIndex: Int
            if pendingItem.displayingIndependently {
                // 独立显示的节点会向前找所有已出现且有交叠的节点，
                // zIndex 取这些节点的最大值 + 1，和 Lookin 的策略一致。
                let overlappedZIndex = items
                    .filter { $0.displayRect.intersects(pendingItem.displayRect) }
                    .map(\.zIndex)
                    .max()
                zIndex = (overlappedZIndex ?? -1) + 1
            } else if let parentNodeID = pendingItem.parentNodeID,
                      let parentItem = itemByNodeID[parentNodeID] {
                zIndex = parentItem.zIndex
            } else {
                zIndex = 0
            }

            let item = Item(
                nodeID: pendingItem.nodeID,
                depth: pendingItem.depth,
                zIndex: zIndex,
                displayOrder: pendingItem.displayOrder,
                displayingIndependently: pendingItem.displayingIndependently,
                displayRect: pendingItem.displayRect,
                punchedOutRects: pendingItem.punchedOutRects
            )
            items.append(item)
            itemByNodeID[pendingItem.nodeID] = item
        }

        return items
    }

    private static func addOverlapPunchOuts(to items: [Item]) -> [Item] {
        let independentlyDisplayedItems = items.filter(\.displayingIndependently)

        return items.map { item in
            guard item.displayingIndependently else {
                return item
            }

            var punchedOutRects = item.punchedOutRects
            let overlapPunchOuts = independentlyDisplayedItems.compactMap { candidate -> CGRect? in
                guard candidate.nodeID != item.nodeID,
                      candidate.zIndex > item.zIndex,
                      candidate.displayRect.intersects(item.displayRect),
                      punchedOutRects.contains(candidate.displayRect) == false else {
                    return nil
                }
                punchedOutRects.append(candidate.displayRect)
                return candidate.displayRect
            }

            guard overlapPunchOuts.isEmpty == false else {
                return item
            }

            return Item(
                nodeID: item.nodeID,
                depth: item.depth,
                zIndex: item.zIndex,
                displayOrder: item.displayOrder,
                displayingIndependently: item.displayingIndependently,
                displayRect: item.displayRect,
                punchedOutRects: punchedOutRects
            )
        }
    }

    private static func visibleNodes(
        rootNodeIDs: [String],
        capture: ViewScopeCapturePayload,
        expandedNodeIDs: Set<String>,
        showsSystemWrapperViews: Bool
    ) -> [VisibleNode] {
        // 这里把“是否独立分层”和“节点是否存在于 scene 中”拆开：
        // collapsed 节点依然保留 item，只是会继承父节点的 zIndex/平面语义。
        var result: [VisibleNode] = []

        func visit(
            nodeID: String,
            parentNodeID: String?,
            depth: Int,
            ancestorsDisplayChildren: Bool,
            expandsAutomatically: Bool
        ) {
            guard let node = capture.nodes[nodeID], node.isHidden == false else {
                return
            }

            let shouldExpand = expandsAutomatically || expandedNodeIDs.contains(nodeID)
            let visibleChildIDs = ViewHierarchyPresentation.presentedChildNodeIDs(
                of: nodeID,
                nodes: capture.nodes,
                showsSystemWrappers: showsSystemWrapperViews
            ).filter { childID in
                capture.nodes[childID]?.isHidden == false
            }
            let expandedChildIDs = shouldExpand ? visibleChildIDs : []
            let displayingIndependently = depth == 0 || ancestorsDisplayChildren

            result.append(
                VisibleNode(
                    nodeID: nodeID,
                    parentNodeID: parentNodeID,
                    depth: depth,
                    displayingIndependently: displayingIndependently,
                    expandedChildIDs: expandedChildIDs
                )
            )

            for childID in visibleChildIDs {
                visit(
                    nodeID: childID,
                    parentNodeID: nodeID,
                    depth: depth + 1,
                    ancestorsDisplayChildren: shouldExpand,
                    expandsAutomatically: false
                )
            }
        }

        for rootNodeID in rootNodeIDs {
            visit(
                nodeID: rootNodeID,
                parentNodeID: nil,
                depth: 0,
                ancestorsDisplayChildren: true,
                expandsAutomatically: true
            )
        }
        return result
    }
}
