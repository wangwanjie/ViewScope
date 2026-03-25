import CoreGraphics
import ViewScopeServer
@testable import ViewScope

@MainActor
struct PreviewHitTester {
    private let geometry = ViewHierarchyGeometry()

    func deepestNodeID(at canvasPoint: CGPoint, in capture: ViewScopeCapturePayload) -> String? {
        geometry.deepestNodeID(at: canvasPoint, in: capture)
    }
}
