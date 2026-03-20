import CoreGraphics

struct PreviewImagePerspectiveMapping {
    struct Quad: Equatable {
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomRight: CGPoint
        let bottomLeft: CGPoint
    }

    static func quad(projectedQuad: [CGPoint], canvasSize: CGSize) -> Quad? {
        guard projectedQuad.count == 4 else { return nil }
        return Quad(
            topLeft: ciPoint(fromCanvasPoint: projectedQuad[0], canvasSize: canvasSize),
            topRight: ciPoint(fromCanvasPoint: projectedQuad[1], canvasSize: canvasSize),
            bottomRight: ciPoint(fromCanvasPoint: projectedQuad[2], canvasSize: canvasSize),
            bottomLeft: ciPoint(fromCanvasPoint: projectedQuad[3], canvasSize: canvasSize)
        )
    }

    private static func ciPoint(fromCanvasPoint point: CGPoint, canvasSize _: CGSize) -> CGPoint {
        point
    }
}
