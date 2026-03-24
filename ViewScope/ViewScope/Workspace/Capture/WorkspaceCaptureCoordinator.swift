import Foundation
import ViewScopeServer

struct WorkspaceCaptureSelectionSnapshot {
    let selectedNodeID: String?
    let focusedNodeID: String?
}

struct WorkspaceImportedCaptureState {
    let capture: ViewScopeCapturePayload
    let selectedNodeDetail: ViewScopeNodeDetailPayload?
    let selectedNodeID: String?
    let focusedNodeID: String?
    let expandedNodeIDs: Set<String>
}

@MainActor
final class WorkspaceCaptureCoordinator {
    func snapshotSelection(
        selectedNodeID: String?,
        focusedNodeID: String?
    ) -> WorkspaceCaptureSelectionSnapshot {
        WorkspaceCaptureSelectionSnapshot(
            selectedNodeID: selectedNodeID,
            focusedNodeID: focusedNodeID
        )
    }

    func requestCapture(using session: any WorkspaceSessionProtocol) async throws -> ViewScopeCapturePayload {
        try await session.requestCapture()
    }

    func makePreviewExport(
        capture: ViewScopeCapturePayload,
        selectedNodeDetail: ViewScopeNodeDetailPayload?,
        previewBitmap: ViewScopePreviewBitmap?,
        previewContext: WorkspaceRawPreviewExport.PreviewContext
    ) -> WorkspaceRawPreviewExport {
        WorkspaceRawPreviewExport(
            formatVersion: 1,
            exportedAt: Date(),
            capture: capture,
            selectedNodeDetail: selectedNodeDetail,
            previewBitmap: previewBitmap,
            previewContext: previewContext
        )
    }

    func importedState(from export: WorkspaceRawPreviewExport) -> WorkspaceImportedCaptureState {
        let selectedNodeID = export.previewContext.selectedNodeID.flatMap {
            export.capture.nodes[$0] != nil ? $0 : nil
        }
        let focusedNodeID = export.previewContext.focusedNodeID.flatMap {
            export.capture.nodes[$0] != nil ? $0 : nil
        }
        let expandedNodeIDs = Set(export.previewContext.expandedNodeIDs.filter {
            export.capture.nodes[$0] != nil && export.capture.rootNodeIDs.contains($0) == false
        })

        var importedCapture = export.capture
        if let previewBitmap = export.previewBitmap,
           importedCapture.previewBitmaps.contains(where: { $0.rootNodeID == previewBitmap.rootNodeID }) == false {
            importedCapture.previewBitmaps.append(previewBitmap)
        }

        return WorkspaceImportedCaptureState(
            capture: importedCapture,
            selectedNodeDetail: export.selectedNodeDetail,
            selectedNodeID: selectedNodeID,
            focusedNodeID: focusedNodeID,
            expandedNodeIDs: expandedNodeIDs
        )
    }
}
