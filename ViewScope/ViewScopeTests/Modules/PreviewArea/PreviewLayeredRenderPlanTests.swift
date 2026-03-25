import CoreGraphics
import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct PreviewLayeredRenderPlanTests {
    @Test func layeredPlanUsesSingleBaseImagePlane() async throws {
        let capture = SampleFixture.capture()
        let canvasSize = CGSize(width: 1200, height: 640)
        let transform = PreviewLayerTransform(yaw: 0.22, pitch: -0.12)

        let plan = PreviewLayeredRenderPlan.make(
            capture: capture,
            canvasSize: canvasSize,
            selectedNodeID: nil,
            focusedNodeID: nil,
            layerTransform: transform
        )

        #expect(plan.baseImageQuad == transform.projectedQuad(
            for: CGRect(origin: .zero, size: canvasSize),
            depth: 0,
            canvasSize: canvasSize
        ))
        #expect(plan.overlayQuads.count == 3)
    }

    @Test func layeredPlanCollapsesSubtreesUntilExpanded() async throws {
        let capture = SampleFixture.capture()
        let plan = PreviewLayeredRenderPlan.make(
            capture: capture,
            canvasSize: CGSize(width: 1200, height: 640),
            selectedNodeID: nil,
            focusedNodeID: nil,
            layerTransform: PreviewLayerTransform(yaw: 0.18, pitch: -0.2)
        )

        #expect(plan.overlay(for: "window-0")?.relativeDepth == 0)
        #expect(plan.overlay(for: "window-0-view-0")?.relativeDepth == 1)
        #expect(plan.overlay(for: "window-0-view-1")?.relativeDepth == 1)
        #expect(plan.overlay(for: "window-0-view-1-2") == nil)
    }

    @Test func layeredPlanRecursivelyAllocatesPlanesForExpandedNodes() async throws {
        let capture = SampleFixture.capture()

        let plan = PreviewLayeredRenderPlan.make(
            capture: capture,
            canvasSize: CGSize(width: 1200, height: 640),
            selectedNodeID: "window-0-view-1-2",
            focusedNodeID: nil,
            expandedNodeIDs: ["window-0-view-1"],
            layerTransform: PreviewLayerTransform(yaw: -0.22, pitch: 0.16)
        )

        let chartOverlay = try #require(plan.overlay(for: "window-0-view-1-2"))
        let siblingOverlay = try #require(plan.overlay(for: "window-0-view-1-1"))

        #expect(plan.overlayQuads.count == 7)
        #expect(chartOverlay.quad.count == 4)
        #expect(chartOverlay.relativeDepth == 2)
        #expect(chartOverlay.isSelected)
        #expect(chartOverlay.style.fillAlpha > 0)
        #expect(chartOverlay.style.strokeAlpha > 0)
        #expect(chartOverlay.style.strokeWidth == 1.8)
        #expect(siblingOverlay.relativeDepth == 2)
    }

    @Test func layeredPlanPromotesPresentedChildrenAcrossHiddenSystemWrapperChains() async throws {
        let workspaceRect = CGRect(x: 228, y: 0, width: 952, height: 688)
        let stackRect = CGRect(x: 458.5, y: 293, width: 491.5, height: 102)
        let capture = makeWrapperPromotedCapture(workspaceRect: workspaceRect, stackRect: stackRect)

        let plan = PreviewLayeredRenderPlan.make(
            capture: capture,
            canvasSize: CGSize(width: 1180, height: 688),
            selectedNodeID: nil,
            focusedNodeID: nil,
            expandedNodeIDs: ["split", "workspace", "stack", "root"],
            layerTransform: PreviewLayerTransform(yaw: 0.18, pitch: -0.2)
        )

        #expect(plan.overlay(for: "wrapper") == nil)
        #expect(plan.overlay(for: "workspace")?.relativeDepth == 2)
        #expect(plan.overlay(for: "stack")?.relativeDepth == 3)
    }

    private func makeWrapperPromotedCapture(
        workspaceRect: CGRect,
        stackRect: CGRect
    ) -> ViewScopeCapturePayload {
        let nodes: [String: ViewScopeHierarchyNode] = [
            "root": makeNode(
                id: "root",
                parentID: nil,
                kind: .window,
                className: "NSWindow",
                childIDs: ["split"],
                frame: CGRect(x: 0, y: 0, width: 1180, height: 688),
                depth: 0,
                isFlipped: false
            ),
            "split": makeNode(
                id: "split",
                parentID: "root",
                kind: .view,
                className: "NSSplitView",
                childIDs: ["sidebar", "wrapper"],
                frame: CGRect(x: 0, y: 0, width: 1180, height: 688),
                depth: 1,
                isFlipped: true
            ),
            "sidebar": makeNode(
                id: "sidebar",
                parentID: "split",
                kind: .view,
                className: "NSView",
                childIDs: [],
                frame: CGRect(x: 0, y: 0, width: 228, height: 688),
                depth: 2,
                isFlipped: true
            ),
            "wrapper": makeNode(
                id: "wrapper",
                parentID: "split",
                kind: .view,
                className: "_NSSplitViewItemViewWrapper",
                childIDs: ["workspace"],
                frame: workspaceRect,
                depth: 2,
                isFlipped: true
            ),
            "workspace": makeNode(
                id: "workspace",
                parentID: "wrapper",
                kind: .view,
                className: "WorkspaceDropView",
                childIDs: ["stack"],
                frame: workspaceRect,
                depth: 3,
                isFlipped: false
            ),
            "stack": makeNode(
                id: "stack",
                parentID: "workspace",
                kind: .view,
                className: "NSStackView",
                childIDs: [],
                frame: stackRect,
                depth: 4,
                isFlipped: false
            )
        ]

        return ViewScopeCapturePayload(
            host: ViewScopeHostInfo(
                displayName: "Fixture Host",
                bundleIdentifier: "cn.vanjay.fixture",
                version: "1.0",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true
            ),
            capturedAt: Date(timeIntervalSinceReferenceDate: 0),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: nodes,
            captureID: "layered-render-wrapper-promoted-fixture",
            previewBitmaps: []
        )
    }

    private func makeNode(
        id: String,
        parentID: String?,
        kind: ViewScopeHierarchyNode.Kind,
        className: String,
        childIDs: [String],
        frame: CGRect,
        depth: Int,
        isFlipped: Bool
    ) -> ViewScopeHierarchyNode {
        ViewScopeHierarchyNode(
            id: id,
            parentID: parentID,
            kind: kind,
            className: className,
            title: id,
            subtitle: nil,
            frame: ViewScopeRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            bounds: ViewScopeRect(x: 0, y: 0, width: frame.width, height: frame.height),
            childIDs: childIDs,
            isHidden: false,
            alphaValue: 1,
            wantsLayer: true,
            isFlipped: isFlipped,
            clippingEnabled: false,
            depth: depth
        )
    }
}
