import CoreGraphics
import Testing
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct PreviewLayerTransformTests {
    @Test func previewCanvasDisplayRectFlipsNormalizedYIntoCanvasSpace() async throws {
        let rect = PreviewCanvasCoordinateSpace.displayRect(
            fromNormalizedRect: CGRect(x: 10, y: 20, width: 30, height: 40),
            canvasSize: CGSize(width: 100, height: 100)
        )

        #expect(rect == CGRect(x: 10, y: 40, width: 30, height: 40))
    }

    @Test func previewCanvasDisplayRectPreservesFullCanvasBounds() async throws {
        let rect = PreviewCanvasCoordinateSpace.displayRect(
            fromNormalizedRect: CGRect(x: 0, y: 0, width: 100, height: 80),
            canvasSize: CGSize(width: 100, height: 80)
        )

        #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    @Test func relativeDepthPinsFocusedNodeToCanvasPlane() async throws {
        #expect(PreviewLayerTransform.relativeDepth(nodeDepth: 3, focusDepth: 3) == 0)
        #expect(PreviewLayerTransform.relativeDepth(nodeDepth: 5, focusDepth: 3) == 2)
        #expect(PreviewLayerTransform.relativeDepth(nodeDepth: 1, focusDepth: 3) == 0)
    }

    @Test func dragWrapsYawInsteadOfClamping() async throws {
        var transform = PreviewLayerTransform(yaw: .pi - 0.05, pitch: 0)

        transform.drag(by: CGSize(width: 30, height: 0))

        #expect(transform.yaw < 0)
        #expect(abs(transform.yaw) < .pi)
    }

    @Test func dragMovesPitchInSameDirectionAsVerticalDrag() async throws {
        var transform = PreviewLayerTransform(yaw: 0, pitch: 0)

        transform.drag(by: CGSize(width: 0, height: 20))

        #expect(transform.pitch > 0)
    }

    @Test func projectedQuadCreatesVisiblePerspectiveTilt() async throws {
        let transform = PreviewLayerTransform(yaw: 0.24, pitch: -0.18)
        let rect = CGRect(x: 292, y: 152, width: 760, height: 408)

        let quad = transform.projectedQuad(
            for: rect,
            depth: 2,
            canvasSize: CGSize(width: 1200, height: 640)
        )

        #expect(quad.count == 4)
        #expect(abs(quad[0].y - quad[1].y) > 1)
        #expect(abs(quad[0].x - quad[3].x) > 1)
    }

    @Test func layeredImagePerspectiveMappingUsesProjectedQuadOrderDirectly() async throws {
        let mapping = try #require(
            PreviewImagePerspectiveMapping.quad(
                projectedQuad: [
                    CGPoint(x: 0, y: 0),
                    CGPoint(x: 100, y: 0),
                    CGPoint(x: 100, y: 80),
                    CGPoint(x: 0, y: 80)
                ],
                canvasSize: CGSize(width: 100, height: 80)
            )
        )

        #expect(mapping.topLeft == CGPoint(x: 0, y: 0))
        #expect(mapping.topRight == CGPoint(x: 100, y: 0))
        #expect(mapping.bottomRight == CGPoint(x: 100, y: 80))
        #expect(mapping.bottomLeft == CGPoint(x: 0, y: 80))
    }

    @Test func layeredHitTestingUsesFocusedRelativeDepthPlan() async throws {
        let capture = SampleFixture.capture()
        let focusedNodeID = "window-0-view-1-2"
        let viewport = PreviewViewportState(
            canvasSize: CGSize(width: 1200, height: 640),
            viewportSize: CGSize(width: 900, height: 700)
        )
        let transform = PreviewLayerTransform(yaw: -0.16, pitch: 0.12)
        let plan = PreviewLayeredRenderPlan.make(
            capture: capture,
            canvasSize: viewport.canvasSize,
            selectedNodeID: focusedNodeID,
            focusedNodeID: focusedNodeID,
            layerTransform: transform
        )
        let chartOverlay = try #require(plan.overlay(for: focusedNodeID))
        let canvasPoint = CGPoint(
            x: chartOverlay.quad.map(\.x).reduce(0, +) / CGFloat(chartOverlay.quad.count),
            y: chartOverlay.quad.map(\.y).reduce(0, +) / CGFloat(chartOverlay.quad.count)
        )
        let viewPoint = try #require(viewport.viewPoint(forCanvasPoint: canvasPoint))

        let resolved = PreviewHitTestResolver().nodeID(
            atViewPoint: viewPoint,
            capture: capture,
            viewportState: viewport,
            focusedNodeID: focusedNodeID,
            displayMode: .layered,
            geometryMode: .directGlobalCanvasRect,
            layerTransform: transform
        )

        #expect(resolved == focusedNodeID)
    }

    @Test func layeredHitTestingUsesProjectedGeometry() async throws {
        let capture = SampleFixture.capture()
        var viewport = PreviewViewportState(
            canvasSize: CGSize(width: 1200, height: 640),
            viewportSize: CGSize(width: 900, height: 700)
        )
        viewport.setScale(1.1, keepingCanvasPoint: CGPoint(x: 600, y: 320), anchoredAt: CGPoint(x: 450, y: 350))

        let transform = PreviewLayerTransform(yaw: 0.28, pitch: -0.2)
        let plan = PreviewLayeredRenderPlan.make(
            capture: capture,
            canvasSize: viewport.canvasSize,
            selectedNodeID: nil,
            focusedNodeID: nil,
            geometryMode: .directGlobalCanvasRect,
            layerTransform: transform
        )
        let quad = try #require(plan.overlay(for: "window-0-view-1-2")?.quad)
        let canvasPoint = CGPoint(
            x: quad.map(\.x).reduce(0, +) / CGFloat(quad.count),
            y: quad.map(\.y).reduce(0, +) / CGFloat(quad.count)
        )
        let viewPoint = try #require(viewport.viewPoint(forCanvasPoint: canvasPoint))

        let resolved = PreviewHitTestResolver().nodeID(
            atViewPoint: viewPoint,
            capture: capture,
            viewportState: viewport,
            focusedNodeID: nil,
            displayMode: .layered,
            geometryMode: .directGlobalCanvasRect,
            layerTransform: transform
        )

        #expect(resolved == "window-0-view-1-2")
    }

    @Test func layeredHitTestingIgnoresFocusedSubtreeRoot() async throws {
        let capture = SampleFixture.capture()
        let viewport = PreviewViewportState(
            canvasSize: CGSize(width: 1200, height: 640),
            viewportSize: CGSize(width: 900, height: 700)
        )

        let transform = PreviewLayerTransform(yaw: 0.18, pitch: 0.1)
        let plan = PreviewLayeredRenderPlan.make(
            capture: capture,
            canvasSize: viewport.canvasSize,
            selectedNodeID: nil,
            focusedNodeID: "window-0-view-1-2",
            geometryMode: .directGlobalCanvasRect,
            layerTransform: transform
        )
        let quad = try #require(plan.overlay(for: "window-0-view-0-0")?.quad)
        let canvasPoint = CGPoint(
            x: quad.map(\.x).reduce(0, +) / CGFloat(quad.count),
            y: quad.map(\.y).reduce(0, +) / CGFloat(quad.count)
        )
        let viewPoint = try #require(viewport.viewPoint(forCanvasPoint: canvasPoint))

        let resolved = PreviewHitTestResolver().nodeID(
            atViewPoint: viewPoint,
            capture: capture,
            viewportState: viewport,
            focusedNodeID: "window-0-view-1-2",
            displayMode: .layered,
            geometryMode: .directGlobalCanvasRect,
            layerTransform: transform
        )

        #expect(resolved == "window-0-view-0-0")
    }

    @Test func layeredModeDoesNotCreateFocusMaskCutout() async throws {
        let resolver = PreviewFocusMaskResolver()
        let viewport = PreviewViewportState(
            canvasSize: CGSize(width: 1200, height: 640),
            viewportSize: CGSize(width: 900, height: 700)
        )

        let cutout = resolver.cutoutViewRect(
            displayMode: .layered,
            focusRect: CGRect(x: 292, y: 152, width: 760, height: 408),
            canvasSize: viewport.canvasSize,
            viewportState: viewport,
            layerTransform: PreviewLayerTransform()
        )

        #expect(cutout == nil)
    }
}
