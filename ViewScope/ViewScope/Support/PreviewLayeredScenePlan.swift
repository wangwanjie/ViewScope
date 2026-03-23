import CoreGraphics
import ViewScopeServer

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

    static func make(
        capture: ViewScopeCapturePayload,
        canvasSize: CGSize,
        expandedNodeIDs: Set<String>,
        previewRootNodeID: String? = nil,
        geometryMode: PreviewCanvasGeometryMode = .directGlobalCanvasRect,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry()
    ) -> PreviewLayeredScenePlan {
        let rootNodeIDs = previewRootNodeID.map { [$0] } ?? capture.rootNodeIDs
        let geometryVisibleNodeIDs = Set(geometry.visibleNodeIDs(in: capture, rootNodeID: previewRootNodeID))
        let visibleNodes = visibleNodes(rootNodeIDs: rootNodeIDs, capture: capture, expandedNodeIDs: expandedNodeIDs)

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
        expandedNodeIDs: Set<String>
    ) -> [VisibleNode] {
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
            let visibleChildIDs = node.childIDs.filter { childID in
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
