import CoreGraphics

enum PreviewCanvasCoordinateSpace {
    static func displayRect(fromNormalizedRect rect: CGRect, canvasSize: CGSize) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: canvasSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
