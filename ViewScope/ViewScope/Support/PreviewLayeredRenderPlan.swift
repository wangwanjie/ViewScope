import CoreGraphics
import ViewScopeServer

struct PreviewLayeredRenderPlan {
    struct Overlay {
        struct Style {
            let fillAlpha: CGFloat
            let strokeAlpha: CGFloat
            let strokeWidth: CGFloat
        }

        let nodeID: String
        let quad: [CGPoint]
        let relativeDepth: CGFloat
        let isSelected: Bool
        let style: Style
    }

    struct Plane {
        struct Region {
            let nodeID: String
            let rect: CGRect
            let punchedOutRects: [CGRect]
        }

        let relativeDepth: CGFloat
        let quad: [CGPoint]
        let regions: [Region]
    }

    let baseImageQuad: [CGPoint]
    let planes: [Plane]
    let overlayQuads: [Overlay]

    static func make(
        capture: ViewScopeCapturePayload,
        canvasSize: CGSize,
        selectedNodeID: String?,
        focusedNodeID: String?,
        previewRootNodeID: String? = nil,
        expandedNodeIDs: Set<String> = [],
        geometryMode: PreviewCanvasGeometryMode = .directGlobalCanvasRect,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry(),
        layerTransform: PreviewLayerTransform
    ) -> PreviewLayeredRenderPlan {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let rootNodeIDs = previewRootNodeID.map { [$0] } ?? focusedNodeID.map { [$0] } ?? capture.rootNodeIDs
        let coordinateRootNodeID = previewRootNodeID
        let geometryVisibleNodeIDs = Set(
            geometry.visibleNodeIDs(in: capture, rootNodeID: previewRootNodeID ?? focusedNodeID)
        )
        let visibleNodes = visibleNodes(
            rootNodeIDs: rootNodeIDs,
            capture: capture,
            expandedNodeIDs: expandedNodeIDs
        )

        var overlayQuads: [Overlay] = []
        var regionsByPlaneDepth: [Int: [Plane.Region]] = [:]

        for visibleNode in visibleNodes {
            guard geometryVisibleNodeIDs.contains(visibleNode.nodeID),
                  let normalizedRect = geometry.canvasRect(
                    for: visibleNode.nodeID,
                    in: capture,
                    coordinateRootNodeID: coordinateRootNodeID,
                    mode: geometryMode
                  ) else {
                continue
            }

            let rect = PreviewCanvasCoordinateSpace.displayRect(
                fromNormalizedRect: normalizedRect,
                canvasSize: canvasSize
            )
            let relativeDepth = CGFloat(visibleNode.planeDepth)

            overlayQuads.append(
                Overlay(
                    nodeID: visibleNode.nodeID,
                    quad: layerTransform.projectedQuad(for: rect, depth: relativeDepth, canvasSize: canvasSize),
                    relativeDepth: relativeDepth,
                    isSelected: visibleNode.nodeID == selectedNodeID,
                    style: style(
                        for: visibleNode.nodeID,
                        selectedNodeID: selectedNodeID,
                        relativeDepth: relativeDepth
                    )
                )
            )

            let punchedOutRects = visibleNode.expandedChildIDs.compactMap { childID -> CGRect? in
                guard geometryVisibleNodeIDs.contains(childID),
                      let childRect = geometry.canvasRect(
                        for: childID,
                        in: capture,
                        coordinateRootNodeID: coordinateRootNodeID,
                        mode: geometryMode
                      ) else {
                    return nil
                }
                return PreviewCanvasCoordinateSpace.displayRect(
                    fromNormalizedRect: childRect,
                    canvasSize: canvasSize
                )
            }
            regionsByPlaneDepth[visibleNode.planeDepth, default: []].append(
                Plane.Region(
                    nodeID: visibleNode.nodeID,
                    rect: rect,
                    punchedOutRects: punchedOutRects
                )
            )
        }

        let planes = regionsByPlaneDepth.keys.sorted().map { planeDepth in
            Plane(
                relativeDepth: CGFloat(planeDepth),
                quad: layerTransform.projectedQuad(
                    for: canvasRect,
                    depth: CGFloat(planeDepth),
                    canvasSize: canvasSize
                ),
                regions: regionsByPlaneDepth[planeDepth] ?? []
            )
        }

        return PreviewLayeredRenderPlan(
            baseImageQuad: planes.first?.quad ?? layerTransform.projectedQuad(
                for: canvasRect,
                depth: 0,
                canvasSize: canvasSize
            ),
            planes: planes,
            overlayQuads: overlayQuads
        )
    }

    func overlay(for nodeID: String) -> Overlay? {
        overlayQuads.first { $0.nodeID == nodeID }
    }

    private static func style(
        for nodeID: String,
        selectedNodeID: String?,
        relativeDepth: CGFloat
    ) -> Overlay.Style {
        if nodeID == selectedNodeID {
            return Overlay.Style(fillAlpha: 0.2, strokeAlpha: 0.72, strokeWidth: 1.8)
        }
        return Overlay.Style(
            fillAlpha: min(0.14, 0.04 + relativeDepth * 0.015),
            strokeAlpha: min(0.34, 0.08 + relativeDepth * 0.03),
            strokeWidth: 0.9
        )
    }

    private struct VisibleNode {
        let nodeID: String
        let planeDepth: Int
        let expandedChildIDs: [String]
    }

    private static func visibleNodes(
        rootNodeIDs: [String],
        capture: ViewScopeCapturePayload,
        expandedNodeIDs: Set<String>
    ) -> [VisibleNode] {
        var result: [VisibleNode] = []

        func visit(nodeID: String, planeDepth: Int, expandsAutomatically: Bool) {
            guard let node = capture.nodes[nodeID] else { return }
            let shouldExpand = expandsAutomatically || expandedNodeIDs.contains(nodeID)
            let expandedChildIDs = shouldExpand ? node.childIDs.filter { capture.nodes[$0] != nil } : []

            result.append(
                VisibleNode(
                    nodeID: nodeID,
                    planeDepth: planeDepth,
                    expandedChildIDs: expandedChildIDs
                )
            )

            guard shouldExpand else { return }
            for childID in expandedChildIDs {
                visit(nodeID: childID, planeDepth: planeDepth + 1, expandsAutomatically: false)
            }
        }

        for rootNodeID in rootNodeIDs {
            visit(nodeID: rootNodeID, planeDepth: 0, expandsAutomatically: true)
        }

        return result
    }
}
