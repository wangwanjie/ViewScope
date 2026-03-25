import CoreGraphics
import Testing
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct PreviewViewportStateTests {
    @Test func canvasPointRoundTripsAfterPanAndZoom() async throws {
        var state = PreviewViewportState(
            canvasSize: CGSize(width: 1200, height: 640),
            viewportSize: CGSize(width: 820, height: 620)
        )

        state.setScale(1.8, keepingCanvasPoint: CGPoint(x: 600, y: 320), anchoredAt: CGPoint(x: 410, y: 310))
        state.pan(by: CGSize(width: -120, height: 90))

        let target = CGPoint(x: 320, y: 180)
        let viewPoint = try #require(state.viewPoint(forCanvasPoint: target))
        let converted = try #require(state.canvasPoint(forViewPoint: viewPoint))

        #expect(abs(converted.x - target.x) < 0.5)
        #expect(abs(converted.y - target.y) < 0.5)
    }

    @Test func canvasPointRoundTripsAfterRotation() async throws {
        var state = PreviewViewportState(
            canvasSize: CGSize(width: 1200, height: 640),
            viewportSize: CGSize(width: 900, height: 700)
        )

        state.setScale(1.25, keepingCanvasPoint: CGPoint(x: 520, y: 240), anchoredAt: CGPoint(x: 450, y: 350))
        state.pan(by: CGSize(width: 40, height: -30))
        state.rotate(by: .pi / 12)

        let target = CGPoint(x: 760, y: 408)
        let viewPoint = try #require(state.viewPoint(forCanvasPoint: target))
        let converted = try #require(state.canvasPoint(forViewPoint: viewPoint))

        #expect(abs(converted.x - target.x) < 0.5)
        #expect(abs(converted.y - target.y) < 0.5)
    }

    @Test func panClampsVisibleCanvasRectInsideBounds() async throws {
        var state = PreviewViewportState(
            canvasSize: CGSize(width: 1200, height: 640),
            viewportSize: CGSize(width: 720, height: 480)
        )

        state.setScale(2, keepingCanvasPoint: CGPoint(x: 600, y: 320), anchoredAt: CGPoint(x: 360, y: 240))
        state.pan(by: CGSize(width: -5000, height: 5000))

        let visibleRect = state.visibleCanvasRect
        #expect(visibleRect.minX >= 0)
        #expect(visibleRect.minY >= 0)
        #expect(visibleRect.maxX <= 1200)
        #expect(visibleRect.maxY <= 640)
    }

    @Test func panAllowsMovementOnAxisThatFitsInsideViewport() async throws {
        var state = PreviewViewportState(
            canvasSize: CGSize(width: 1200, height: 640),
            viewportSize: CGSize(width: 900, height: 900)
        )

        let before = state.viewRect(forCanvasRect: CGRect(origin: .zero, size: CGSize(width: 1200, height: 640)))
        state.pan(by: CGSize(width: 0, height: 96))
        let after = state.viewRect(forCanvasRect: CGRect(origin: .zero, size: CGSize(width: 1200, height: 640)))

        #expect(abs(after.minY - before.minY) > 1)
        #expect(after.minY >= 28)
        #expect(after.maxY <= 872)
    }
}
