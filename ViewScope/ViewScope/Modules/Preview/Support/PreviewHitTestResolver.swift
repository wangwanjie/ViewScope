import CoreGraphics
import ViewScopeServer

/// 把 SceneKit 命中的平面换算成“最合适的节点”（纯逻辑，可单测）。
///
/// SceneKit 只为独立平面建了几何体；折叠节点的像素画在所属平面上。
/// 因此点中某个平面后，还要在该平面内（平面所有者 + 它的折叠后代）按几何找到最上层的节点：
/// - 先序遍历序号（displayOrder）越大，绘制越靠前；
/// - 只看节点的可见区域（被裁剪祖先截掉的部分不算）；
/// - 透明容器（有子节点、没有背景色、点击处没有子节点）优先级最低：继续尝试其后方的平面，
///   都不合适时才退回它。
struct PreviewHitTestResolver {
    struct PlaneHit {
        let planeNodeID: String
        /// 命中点在统一画布中的坐标。
        let canvasPoint: CGPoint
    }

    private let plan: PreviewLayeredScenePlan
    private let capture: ViewScopeCapturePayload
    /// 平面所有者 -> 该平面上的所有 item（按 displayOrder 降序，即由前到后）。
    private let itemsByPlaneOwner: [String: [PreviewLayeredScenePlan.Item]]
    /// 展示层级的子节点数量，用于判断“容器”。
    private let childCountByNodeID: [String: Int]

    init(plan: PreviewLayeredScenePlan, capture: ViewScopeCapturePayload) {
        self.plan = plan
        self.capture = capture
        var grouped: [String: [PreviewLayeredScenePlan.Item]] = [:]
        var childCounts: [String: Int] = [:]
        for item in plan.items {
            grouped[item.planeOwnerNodeID, default: []].append(item)
            if let parentNodeID = item.parentNodeID {
                childCounts[parentNodeID, default: 0] += 1
            }
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.displayOrder > $1.displayOrder }
        }
        itemsByPlaneOwner = grouped
        childCountByNodeID = childCounts
    }

    /// `hits` 需按由近到远排序（SceneKit `searchMode: .all` 的返回顺序）。
    func nodeID(for hits: [PlaneHit]) -> String? {
        var fallbackNodeID: String?
        for hit in hits {
            guard let items = itemsByPlaneOwner[hit.planeNodeID] else {
                continue
            }
            for item in items where item.visibleRect.contains(hit.canvasPoint) {
                if isTransparentContainer(item, at: hit.canvasPoint) {
                    if fallbackNodeID == nil {
                        fallbackNodeID = item.nodeID
                    }
                    continue
                }
                return item.nodeID
            }
        }
        return fallbackNodeID
    }

    /// 在平面坐标（2D，无旋转）下直接命中：依次尝试所有平面，前面的平面优先。
    func nodeID(atCanvasPoint point: CGPoint) -> String? {
        let planeOwners = plan.items
            .filter(\.displayingIndependently)
            .sorted { lhs, rhs in
                if lhs.zIndex != rhs.zIndex {
                    return lhs.zIndex > rhs.zIndex
                }
                return lhs.displayOrder > rhs.displayOrder
            }
            .filter { $0.visibleRect.contains(point) }
        return nodeID(for: planeOwners.map { PlaneHit(planeNodeID: $0.nodeID, canvasPoint: point) })
    }

    private func isTransparentContainer(_ item: PreviewLayeredScenePlan.Item, at point: CGPoint) -> Bool {
        guard (childCountByNodeID[item.nodeID] ?? 0) > 0,
              let node = capture.nodes[item.nodeID],
              let traits = node.traits else {
            // 旧宿主没有 traits，无法判断是否透明，按普通节点处理。
            return false
        }
        if traits.isOpaque == true {
            return false
        }
        if let backgroundAlpha = traits.backgroundAlpha, backgroundAlpha > 0.01 {
            return false
        }
        return true
    }
}
