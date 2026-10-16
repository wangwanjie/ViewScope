import AppKit
import CoreGraphics
import ViewScopeServer

/// 决定当前预览图应该来自 capture bitmap 还是 detail screenshot。
///
/// 原则：
/// - 优先使用与当前 preview root 匹配的 capture 级截图；
/// - 其次使用根节点与 preview root 一致的 detail 截图（避免回退到别的窗口）；
/// - 最后才回退到任意一张 capture 截图或 detail 截图。
struct PreviewImageResolver {
    struct Resolution: Equatable {
        let cacheKey: String
        let base64PNG: String
        let size: CGSize
        let rootNodeID: String
    }

    static func resolve(
        capture: ViewScopeCapturePayload?,
        preferredRootNodeID: String?,
        detail: ViewScopeNodeDetailPayload?
    ) -> Resolution? {
        if let capture,
           let preferredRootNodeID,
           let bitmap = capture.previewBitmaps.first(where: { $0.rootNodeID == preferredRootNodeID }) {
            return Resolution(
                cacheKey: "bitmap:\(capture.captureID):\(preferredRootNodeID)",
                base64PNG: bitmap.pngBase64,
                size: bitmap.size.cgSize,
                rootNodeID: bitmap.rootNodeID
            )
        }

        // detail 截图明确属于 preview root 时，优先于“随便取第一张窗口截图”。
        if let preferredRootNodeID,
           let detail,
           detail.screenshotRootNodeID == preferredRootNodeID,
           let resolution = detailResolution(capture: capture, preferredRootNodeID: preferredRootNodeID, detail: detail) {
            return resolution
        }

        if let capture,
           let bitmap = capture.previewBitmaps.first {
            return Resolution(
                cacheKey: "bitmap:\(capture.captureID):\(bitmap.rootNodeID)",
                base64PNG: bitmap.pngBase64,
                size: bitmap.size.cgSize,
                rootNodeID: bitmap.rootNodeID
            )
        }

        guard let detail else {
            return nil
        }
        return detailResolution(capture: capture, preferredRootNodeID: preferredRootNodeID, detail: detail)
    }

    private static func detailResolution(
        capture: ViewScopeCapturePayload?,
        preferredRootNodeID: String?,
        detail: ViewScopeNodeDetailPayload
    ) -> Resolution? {
        guard let base64PNG = detail.screenshotPNGBase64,
              base64PNG.isEmpty == false else {
            return nil
        }
        let rootNodeID = detail.screenshotRootNodeID ?? preferredRootNodeID ?? detail.nodeID
        let captureKey = capture?.captureID ?? "detail-only"
        return Resolution(
            cacheKey: "detail:\(captureKey):\(rootNodeID)",
            base64PNG: base64PNG,
            size: detail.screenshotSize.cgSize,
            rootNodeID: rootNodeID
        )
    }
}

struct PreviewRenderContext {
    let capture: ViewScopeCapturePayload?
    let selectedNodeID: String?
    let focusedNodeID: String?
    let previewRootNodeID: String?
    let previewResolution: PreviewImageResolver.Resolution?
    let previewCanvasSize: CGSize
    let geometryMode: PreviewCanvasGeometryMode
    let selectionRect: CGRect?
}

struct PreviewRenderContextCache {
    var lastResolvedSelectionNodeID: String?
    var lastResolvedSelectionRect: CGRect?
    var lastResolvedGeometryMode: PreviewCanvasGeometryMode?
    var lastResolvedSelectionGeometryMode: PreviewCanvasGeometryMode?

    static let empty = PreviewRenderContextCache()
}

struct PreviewRenderContextBuilder {
    func makeContext(
        capture: ViewScopeCapturePayload?,
        detail: ViewScopeNodeDetailPayload?,
        selectedNodeID: String?,
        focusedNodeID: String?,
        cache: PreviewRenderContextCache,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry()
    ) -> (context: PreviewRenderContext, cache: PreviewRenderContextCache) {
        var nextCache = cache

        guard let capture else {
            nextCache.lastResolvedGeometryMode = nil
            nextCache.lastResolvedSelectionNodeID = nil
            nextCache.lastResolvedSelectionRect = nil
            nextCache.lastResolvedSelectionGeometryMode = nil
            return (
                PreviewRenderContext(
                    capture: nil,
                    selectedNodeID: selectedNodeID,
                    focusedNodeID: focusedNodeID,
                    previewRootNodeID: nil,
                    previewResolution: nil,
                    previewCanvasSize: .zero,
                    geometryMode: .directGlobalCanvasRect,
                    selectionRect: nil
                ),
                nextCache
            )
        }

        let requestedPreviewRootNodeID = resolvedPreviewRootNodeID(
            capture: capture,
            selectedNodeID: selectedNodeID,
            focusedNodeID: focusedNodeID
        )
        let previewResolution = PreviewImageResolver.resolve(
            capture: capture,
            preferredRootNodeID: requestedPreviewRootNodeID,
            detail: detail
        )
        let previewRootNodeID = previewResolution?.rootNodeID ?? requestedPreviewRootNodeID
        let previewCanvasSize = resolvedCanvasSize(
            capture: capture,
            previewRootNodeID: previewRootNodeID,
            imageResolution: previewResolution
        )
        let geometryMode = resolvedGeometryMode(
            capture: capture,
            selectedNodeID: selectedNodeID,
            detail: detail,
            previewRootNodeID: previewRootNodeID,
            geometry: geometry,
            cache: &nextCache
        )
        var selectionRect = resolvedSelectionRect(
            capture: capture,
            selectedNodeID: selectedNodeID,
            detail: detail,
            previewRootNodeID: previewRootNodeID,
            geometryMode: geometryMode,
            geometry: geometry,
            cache: &nextCache
        )
        // 截图回退到了别的窗口时，选中节点不在当前预览根下，不能把选中框画到无关的画面上。
        if let selectedNodeID,
           let previewRootNodeID,
           capture.nodes[selectedNodeID] != nil,
           capture.nodes[previewRootNodeID] != nil,
           isSelection(selectedNodeID, inside: previewRootNodeID, capture: capture, geometry: geometry) == false {
            selectionRect = nil
        }

        return (
            PreviewRenderContext(
                capture: capture,
                selectedNodeID: selectedNodeID,
                focusedNodeID: focusedNodeID,
                previewRootNodeID: previewRootNodeID,
                previewResolution: previewResolution,
                previewCanvasSize: previewCanvasSize,
                geometryMode: geometryMode,
                selectionRect: selectionRect
            ),
            nextCache
        )
    }

    /// 选中节点与预览根同属一个窗口（预览根是它的祖先，或预览根是它所在窗口）。
    private func isSelection(
        _ selectedNodeID: String,
        inside previewRootNodeID: String,
        capture: ViewScopeCapturePayload,
        geometry: ViewHierarchyGeometry
    ) -> Bool {
        if geometry.isNode(selectedNodeID, descendantOf: previewRootNodeID, in: capture) {
            return true
        }
        // 选中的是窗口节点本身，或预览根是窗口下的根视图：按窗口归属判断。
        if let previewRootParentID = capture.nodes[previewRootNodeID]?.parentID,
           capture.nodes[previewRootParentID]?.kind == .window {
            return geometry.isNode(selectedNodeID, descendantOf: previewRootParentID, in: capture)
        }
        return false
    }

    private func resolvedCanvasSize(
        capture: ViewScopeCapturePayload,
        previewRootNodeID: String?,
        imageResolution: PreviewImageResolver.Resolution?
    ) -> CGSize {
        if let imageResolution,
           imageResolution.size.width > 0,
           imageResolution.size.height > 0 {
            return imageResolution.size
        }
        if let rootID = previewRootNodeID ?? capture.rootNodeIDs.first,
           let rootNode = capture.nodes[rootID] {
            return CGSize(width: CGFloat(rootNode.frame.width), height: CGFloat(rootNode.frame.height))
        }
        return .zero
    }

    private func resolvedPreviewRootNodeID(
        capture: ViewScopeCapturePayload,
        selectedNodeID: String?,
        focusedNodeID: String?
    ) -> String? {
        let anchorNodeID = focusedNodeID ?? selectedNodeID ?? capture.rootNodeIDs.first
        return PreviewPanelRenderDecisions.previewRootNodeID(
            capture: capture,
            anchorNodeID: anchorNodeID
        )
    }

    private func resolvedGeometryMode(
        capture: ViewScopeCapturePayload,
        selectedNodeID: String?,
        detail: ViewScopeNodeDetailPayload?,
        previewRootNodeID: String?,
        geometry: ViewHierarchyGeometry,
        cache: inout PreviewRenderContextCache
    ) -> PreviewCanvasGeometryMode {
        // 服务端始终发送统一画布坐标（normalizedCanvasRect），无需自动检测。
        cache.lastResolvedGeometryMode = .directGlobalCanvasRect
        return .directGlobalCanvasRect
    }

    private func resolvedSelectionRect(
        capture: ViewScopeCapturePayload,
        selectedNodeID: String?,
        detail: ViewScopeNodeDetailPayload?,
        previewRootNodeID: String?,
        geometryMode: PreviewCanvasGeometryMode,
        geometry: ViewHierarchyGeometry,
        cache: inout PreviewRenderContextCache
    ) -> CGRect? {
        let selectionRect = PreviewPanelRenderDecisions.selectionRect(
            capture: capture,
            selectedNodeID: selectedNodeID,
            detail: detail,
            previewRootNodeID: previewRootNodeID,
            geometryMode: geometryMode,
            geometry: geometry
        )

        if let selectedNodeID {
            if let detail,
               detail.nodeID == selectedNodeID,
               let selectionRect {
                cache.lastResolvedSelectionNodeID = selectedNodeID
                cache.lastResolvedSelectionRect = selectionRect
                cache.lastResolvedSelectionGeometryMode = geometryMode
                return selectionRect
            }

            if cache.lastResolvedSelectionNodeID == selectedNodeID,
               cache.lastResolvedSelectionGeometryMode == geometryMode,
               let lastResolvedSelectionRect = cache.lastResolvedSelectionRect {
                return lastResolvedSelectionRect
            }
        }

        cache.lastResolvedSelectionNodeID = selectedNodeID
        cache.lastResolvedSelectionRect = selectionRect
        cache.lastResolvedSelectionGeometryMode = geometryMode
        return selectionRect
    }
}
