import CoreGraphics

struct WorkspacePreviewImportState {
    let scale: CGFloat
    let displayMode: WorkspacePreviewDisplayMode
    let layerSpacing: CGFloat
    let showsLayerBorders: Bool
}

@MainActor
final class WorkspacePreviewState {
    func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.35), 4)
    }

    func clampedLayerSpacing(_ value: CGFloat) -> CGFloat {
        min(max(value, 10), 150)
    }

    func makePreviewContext(
        selectedNodeID: String?,
        focusedNodeID: String?,
        previewRootNodeID: String?,
        geometryMode: String,
        previewScale: CGFloat,
        previewDisplayMode: WorkspacePreviewDisplayMode,
        previewLayerSpacing: CGFloat,
        previewShowsLayerBorders: Bool,
        expandedNodeIDs: Set<String>
    ) -> WorkspaceRawPreviewExport.PreviewContext {
        WorkspaceRawPreviewExport.PreviewContext(
            selectedNodeID: selectedNodeID,
            focusedNodeID: focusedNodeID,
            previewRootNodeID: previewRootNodeID,
            geometryMode: geometryMode,
            previewScale: Double(previewScale),
            previewDisplayMode: previewDisplayMode,
            previewLayerSpacing: Double(previewLayerSpacing),
            previewShowsLayerBorders: previewShowsLayerBorders,
            expandedNodeIDs: expandedNodeIDs.sorted()
        )
    }

    func importedState(
        from context: WorkspaceRawPreviewExport.PreviewContext
    ) -> WorkspacePreviewImportState {
        WorkspacePreviewImportState(
            scale: clampedScale(CGFloat(context.previewScale)),
            displayMode: context.previewDisplayMode,
            layerSpacing: clampedLayerSpacing(CGFloat(context.previewLayerSpacing)),
            showsLayerBorders: context.previewShowsLayerBorders
        )
    }
}
