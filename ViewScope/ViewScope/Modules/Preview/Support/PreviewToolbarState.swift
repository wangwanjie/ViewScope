import CoreGraphics
import ViewScopeServer

struct PreviewToolbarState {
    let zoomPercentageTitle: String
    let selectedDisplaySegment: Int
    let consoleToggleEnabled: Bool
    let consoleToggleButtonEnabled: Bool
    let focusButtonEnabled: Bool
    let clearFocusButtonEnabled: Bool
    let highlightButtonEnabled: Bool
    let visibilityButtonEnabled: Bool
    let visibilitySymbolName: String?
    let visibilityToolTip: String
    let shouldShowConsolePanel: Bool
}

struct PreviewToolbarStateBuilder {
    func makeState(
        capture: ViewScopeCapturePayload?,
        selectedNodeID: String?,
        focusedNodeID: String?,
        selectedNode: ViewScopeHierarchyNode?,
        previewScale: CGFloat,
        previewDisplayMode: WorkspacePreviewDisplayMode,
        supportsConsole: Bool,
        isConsoleToggleEnabled: Bool
    ) -> PreviewToolbarState {
        let normalizedConsoleToggleEnabled = supportsConsole ? isConsoleToggleEnabled : false
        let consoleToggleButtonEnabled = capture != nil && supportsConsole

        var visibilityToolTip = L10n.previewToggleVisibility
        var visibilitySymbolName: String?
        let visibilityButtonEnabled = selectedNode?.kind == .view
        if let selectedNode {
            visibilitySymbolName = selectedNode.isHidden ? "eye.slash" : "eye"
            visibilityToolTip = selectedNode.isHidden ? L10n.hierarchyMenuShowView : L10n.hierarchyMenuHideView
        }

        return PreviewToolbarState(
            zoomPercentageTitle: "\(Int(round(previewScale * 100)))%",
            selectedDisplaySegment: previewDisplayMode == .flat ? 0 : 1,
            consoleToggleEnabled: normalizedConsoleToggleEnabled,
            consoleToggleButtonEnabled: consoleToggleButtonEnabled,
            focusButtonEnabled: selectedNodeID != nil,
            clearFocusButtonEnabled: focusedNodeID != nil,
            highlightButtonEnabled: selectedNodeID != nil,
            visibilityButtonEnabled: visibilityButtonEnabled,
            visibilitySymbolName: visibilitySymbolName,
            visibilityToolTip: visibilityToolTip,
            shouldShowConsolePanel: capture != nil &&
                selectedNodeID != nil &&
                supportsConsole &&
                normalizedConsoleToggleEnabled
        )
    }
}
