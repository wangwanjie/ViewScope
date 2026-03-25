import AppKit
import CoreGraphics
import ViewScopeServer

/// 决定当前预览图应该来自 capture bitmap 还是 detail screenshot。
///
/// 原则：
/// - 优先使用与当前 preview root 匹配的 capture 级截图。
/// - 如果 capture 没有对应 bitmap，再回退到 detail 里的截图。
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

        if let capture,
           let bitmap = capture.previewBitmaps.first {
            return Resolution(
                cacheKey: "bitmap:\(capture.captureID):\(bitmap.rootNodeID)",
                base64PNG: bitmap.pngBase64,
                size: bitmap.size.cgSize,
                rootNodeID: bitmap.rootNodeID
            )
        }

        guard let detail,
              let base64PNG = detail.screenshotPNGBase64,
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
        let selectionRect = resolvedSelectionRect(
            capture: capture,
            selectedNodeID: selectedNodeID,
            detail: detail,
            previewRootNodeID: previewRootNodeID,
            geometryMode: geometryMode,
            geometry: geometry,
            cache: &nextCache
        )

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
        // 几何模式优先跟随 detail.highlightedRect 的实测距离，
        // 这样在协议端历史数据混合时，仍能自动选中更可信的一套坐标语义。
        if let inferredMode = PreviewPanelRenderDecisions.geometryMode(
            capture: capture,
            selectedNodeID: selectedNodeID,
            detail: detail,
            previewRootNodeID: previewRootNodeID,
            geometry: geometry
        ) {
            cache.lastResolvedGeometryMode = inferredMode
            return inferredMode
        }
        return cache.lastResolvedGeometryMode ?? .directGlobalCanvasRect
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
