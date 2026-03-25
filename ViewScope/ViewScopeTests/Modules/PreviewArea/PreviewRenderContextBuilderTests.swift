import CoreGraphics
import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct PreviewRenderContextBuilderTests {
    @Test func renderContextPrefersCaptureBitmapThenFallsBackToDetailScreenshot() async throws {
        let capture = makeCapture(withBitmap: true)
        let detail = makeDetail()
        let builder = PreviewRenderContextBuilder()

        let (bitmapContext, cacheAfterBitmap) = builder.makeContext(
            capture: capture,
            detail: detail,
            selectedNodeID: "root",
            focusedNodeID: nil,
            cache: .empty,
            geometry: ViewHierarchyGeometry()
        )

        #expect(bitmapContext.previewRootNodeID == "root")
        #expect(bitmapContext.previewResolution?.cacheKey == "bitmap:\(capture.captureID):root")
        #expect(bitmapContext.previewResolution?.base64PNG == onePixelPNGBase64)
        #expect(bitmapContext.previewCanvasSize == CGSize(width: 320, height: 240))

        var captureWithoutBitmap = capture
        captureWithoutBitmap.previewBitmaps = []

        let (fallbackContext, _) = builder.makeContext(
            capture: captureWithoutBitmap,
            detail: detail,
            selectedNodeID: "root",
            focusedNodeID: nil,
            cache: cacheAfterBitmap,
            geometry: ViewHierarchyGeometry()
        )

        #expect(fallbackContext.previewResolution?.cacheKey == "detail:\(capture.captureID):root")
        #expect(fallbackContext.previewResolution?.base64PNG == onePixelPNGBase64)
    }

    @Test func toolbarStateReflectsFocusVisibilityAndConsoleAvailability() {
        let node = makeNode(id: "root", isHidden: true)
        let state = PreviewToolbarStateBuilder().makeState(
            capture: makeCapture(withBitmap: true),
            selectedNodeID: "root",
            focusedNodeID: "root",
            selectedNode: node,
            previewScale: 1.25,
            previewDisplayMode: .layered,
            supportsConsole: false,
            isConsoleToggleEnabled: true
        )

        #expect(state.zoomPercentageTitle == "125%")
        #expect(state.selectedDisplaySegment == 1)
        #expect(state.consoleToggleEnabled == false)
        #expect(state.consoleToggleButtonEnabled == false)
        #expect(state.focusButtonEnabled)
        #expect(state.clearFocusButtonEnabled)
        #expect(state.highlightButtonEnabled)
        #expect(state.visibilityButtonEnabled)
        #expect(state.visibilitySymbolName == "eye.slash")
        #expect(state.visibilityToolTip == L10n.hierarchyMenuShowView)
        #expect(state.shouldShowConsolePanel == false)
    }

    private func makeCapture(withBitmap: Bool) -> ViewScopeCapturePayload {
        let node = makeNode(id: "root")
        return ViewScopeCapturePayload(
            host: makeHostInfo(),
            capturedAt: Date(timeIntervalSinceReferenceDate: 0),
            summary: ViewScopeCaptureSummary(
                nodeCount: 1,
                windowCount: 1,
                visibleWindowCount: 1,
                captureDurationMilliseconds: 8
            ),
            rootNodeIDs: ["root"],
            nodes: ["root": node],
            captureID: "capture-1",
            previewBitmaps: withBitmap ? [
                ViewScopePreviewBitmap(
                    rootNodeID: "root",
                    pngBase64: onePixelPNGBase64,
                    size: ViewScopeSize(width: 320, height: 240),
                    capturedAt: Date(timeIntervalSinceReferenceDate: 0)
                )
            ] : []
        )
    }

    private func makeDetail() -> ViewScopeNodeDetailPayload {
        ViewScopeNodeDetailPayload(
            nodeID: "root",
            host: makeHostInfo(),
            sections: [],
            constraints: [],
            ancestry: ["Fixture", "root"],
            screenshotPNGBase64: onePixelPNGBase64,
            screenshotSize: ViewScopeSize(width: 320, height: 240),
            highlightedRect: ViewScopeRect(x: 24, y: 32, width: 120, height: 80),
            consoleTargets: []
        )
    }

    private func makeNode(id: String, isHidden: Bool = false) -> ViewScopeHierarchyNode {
        ViewScopeHierarchyNode(
            id: id,
            parentID: nil,
            kind: .view,
            className: "NSView",
            title: id,
            subtitle: nil,
            frame: ViewScopeRect(x: 0, y: 0, width: 320, height: 240),
            bounds: ViewScopeRect(x: 0, y: 0, width: 320, height: 240),
            childIDs: [],
            isHidden: isHidden,
            alphaValue: 1,
            wantsLayer: true,
            isFlipped: true,
            clippingEnabled: false,
            depth: 0
        )
    }

    private func makeHostInfo() -> ViewScopeHostInfo {
        ViewScopeHostInfo(
            displayName: "Fixture",
            bundleIdentifier: "cn.vanjay.fixture",
            version: "1.0",
            build: "1",
            processIdentifier: 1,
            runtimeVersion: viewScopeServerRuntimeVersion,
            supportsHighlighting: true
        )
    }

    private let onePixelPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5WqXcAAAAASUVORK5CYII="
}
