import AppKit
import CoreGraphics
import ViewScopeServer

struct PreviewPanelRenderDecisions {
    /// 服务端始终发送统一画布坐标，直接返回 directGlobalCanvasRect。
    static func geometryMode(
        capture: ViewScopeCapturePayload?,
        selectedNodeID: String?,
        detail: ViewScopeNodeDetailPayload?,
        previewRootNodeID: String? = nil,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry()
    ) -> PreviewCanvasGeometryMode? {
        return .directGlobalCanvasRect
    }

    static func selectionRect(
        capture: ViewScopeCapturePayload?,
        selectedNodeID: String?,
        detail: ViewScopeNodeDetailPayload?,
        previewRootNodeID: String? = nil,
        geometryMode: PreviewCanvasGeometryMode,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry()
    ) -> CGRect? {
        guard let selectedNodeID else {
            return nil
        }
        if let capture,
           let rect = geometry.canvasRect(
               for: selectedNodeID,
               in: capture,
               coordinateRootNodeID: previewRootNodeID,
               mode: geometryMode
           )
        {
            return rect
        }
        if let detail,
           detail.nodeID == selectedNodeID
        {
            return detail.highlightedRect.cgRect
        }
        return nil
    }

    static func autoCenterFocusKey(
        focusedNodeID: String?,
        capture: ViewScopeCapturePayload?
    ) -> String? {
        guard let focusedNodeID else {
            return nil
        }
        return [
            capture?.capturedAt.timeIntervalSinceReferenceDate.description ?? "nil",
            focusedNodeID
        ].joined(separator: "|")
    }

    static func previewRootNodeID(
        capture: ViewScopeCapturePayload,
        anchorNodeID: String?
    ) -> String? {
        guard var currentNodeID = anchorNodeID ?? capture.rootNodeIDs.first else {
            return capture.rootNodeIDs.first
        }

        if capture.nodes[currentNodeID]?.kind == .window {
            return capture.nodes[currentNodeID]?.childIDs.first ?? currentNodeID
        }

        while let parentID = capture.nodes[currentNodeID]?.parentID,
              let parentNode = capture.nodes[parentID]
        {
            if parentNode.kind == .window {
                return currentNodeID
            }
            currentNodeID = parentID
        }
        return currentNodeID
    }

    static func shouldRecenterFullCanvas(
        displayMode: WorkspacePreviewDisplayMode,
        lastRenderedDisplayMode: WorkspacePreviewDisplayMode?,
        focusedNodeID: String?,
        lastRenderedFocusedNodeID: String?,
        canvasSize: CGSize
    ) -> Bool {
        guard canvasSize.width > 0,
              canvasSize.height > 0
        else {
            return false
        }
        if lastRenderedDisplayMode != displayMode {
            return true
        }
        return focusedNodeID != lastRenderedFocusedNodeID
    }
}
