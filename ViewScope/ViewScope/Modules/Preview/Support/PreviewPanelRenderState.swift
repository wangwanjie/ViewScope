import AppKit
import CoreGraphics
import ViewScopeServer

struct PreviewPanelSnapshot {
    let capture: ViewScopeCapturePayload?
    let detail: ViewScopeNodeDetailPayload?
    let selectedNodeID: String?
    let selectedNode: ViewScopeHierarchyNode?
    let focusedNodeID: String?
    let focusedNodeTitle: String?
    let previewScale: CGFloat
    let previewDisplayMode: WorkspacePreviewDisplayMode
    let previewLayerSpacing: CGFloat
    let previewShowsLayerBorders: Bool
    let expandedNodeIDs: Set<String>
    let showsSystemWrapperViews: Bool
    let supportsConsole: Bool

    init(store: WorkspaceStore) {
        capture = store.capture
        detail = store.selectedNodeDetail
        selectedNodeID = store.selectedNodeID
        selectedNode = store.selectedNode
        focusedNodeID = store.focusedNodeID
        focusedNodeTitle = store.focusedNode?.title
        previewScale = store.previewScale
        previewDisplayMode = store.previewDisplayMode
        previewLayerSpacing = store.previewLayerSpacing
        previewShowsLayerBorders = store.previewShowsLayerBorders
        expandedNodeIDs = store.expandedNodeIDs
        showsSystemWrapperViews = store.showsSystemWrapperViews
        supportsConsole = store.connectionState.supportsConsole
    }
}

struct PreviewPanelRenderState {
    let context: PreviewRenderContext
    let previewImage: NSImage?
    let toolbarState: PreviewToolbarState
}

struct PreviewPanelRenderCache {
    var renderContext = PreviewRenderContextCache.empty
    var previewImageKey: String?
    var previewImage: NSImage?

    static let empty = PreviewPanelRenderCache()
}

struct PreviewPanelRenderStateBuilder {
    private let contextBuilder = PreviewRenderContextBuilder()
    private let toolbarStateBuilder = PreviewToolbarStateBuilder()

    func makeState(
        snapshot: PreviewPanelSnapshot,
        cache: PreviewPanelRenderCache,
        isConsoleToggleEnabled: Bool,
        geometry: ViewHierarchyGeometry = ViewHierarchyGeometry()
    ) -> (state: PreviewPanelRenderState, cache: PreviewPanelRenderCache) {
        var nextCache = cache
        let (context, nextRenderContextCache) = contextBuilder.makeContext(
            capture: snapshot.capture,
            detail: snapshot.detail,
            selectedNodeID: snapshot.selectedNodeID,
            focusedNodeID: snapshot.focusedNodeID,
            cache: cache.renderContext,
            geometry: geometry
        )
        nextCache.renderContext = nextRenderContextCache

        let previewImage = resolvedPreviewImage(from: context.previewResolution, cache: &nextCache)
        let toolbarState = toolbarStateBuilder.makeState(
            capture: snapshot.capture,
            selectedNodeID: snapshot.selectedNodeID,
            focusedNodeID: snapshot.focusedNodeID,
            selectedNode: snapshot.selectedNode,
            previewScale: snapshot.previewScale,
            previewDisplayMode: snapshot.previewDisplayMode,
            supportsConsole: snapshot.supportsConsole,
            isConsoleToggleEnabled: isConsoleToggleEnabled
        )

        return (
            PreviewPanelRenderState(
                context: context,
                previewImage: previewImage,
                toolbarState: toolbarState
            ),
            nextCache
        )
    }

    private func resolvedPreviewImage(
        from resolution: PreviewImageResolver.Resolution?,
        cache: inout PreviewPanelRenderCache
    ) -> NSImage? {
        guard let resolution else {
            cache.previewImageKey = nil
            cache.previewImage = nil
            return nil
        }

        if cache.previewImageKey == resolution.cacheKey {
            return cache.previewImage
        }

        guard let data = Data(base64Encoded: resolution.base64PNG),
              let image = NSImage(data: data) else {
            cache.previewImageKey = nil
            cache.previewImage = nil
            return nil
        }

        cache.previewImageKey = resolution.cacheKey
        cache.previewImage = image
        return image
    }
}
