import CoreGraphics
import Testing
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
}
