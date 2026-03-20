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

    let baseImageQuad: [CGPoint]
    let overlayQuads: [Overlay]

    static func make(
        capture: ViewScopeCapturePayload,
        canvasSize: CGSize,
        selectedNodeID: String?,
        focusedNodeID: String?,
        geometryMode: PreviewCanvasGeometryMode = .directGlobalCanvasRect,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry(),
        layerTransform: PreviewLayerTransform
    ) -> PreviewLayeredRenderPlan {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let focusDepth = capture.nodes[focusedNodeID ?? ""]?.depth ?? 0
        let overlayQuads = geometry.visibleNodeIDs(in: capture).compactMap { nodeID -> Overlay? in
            guard let node = capture.nodes[nodeID],
                  let normalizedRect = geometry.canvasRect(for: nodeID, in: capture, mode: geometryMode) else {
                return nil
            }
            let rect = PreviewCanvasCoordinateSpace.displayRect(
                fromNormalizedRect: normalizedRect,
                canvasSize: canvasSize
            )

            let relativeDepth = PreviewLayerTransform.relativeDepth(
                nodeDepth: node.depth,
                focusDepth: focusDepth
            )

            return Overlay(
                nodeID: nodeID,
                quad: layerTransform.projectedQuad(
                    for: rect,
                    depth: relativeDepth,
                    canvasSize: canvasSize
                ),
                relativeDepth: relativeDepth,
                isSelected: nodeID == selectedNodeID,
                style: style(
                    for: nodeID,
                    selectedNodeID: selectedNodeID,
                    relativeDepth: relativeDepth
                )
            )
        }

        return PreviewLayeredRenderPlan(
            baseImageQuad: layerTransform.projectedQuad(
                for: canvasRect,
                depth: 0,
                canvasSize: canvasSize
            ),
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
}
