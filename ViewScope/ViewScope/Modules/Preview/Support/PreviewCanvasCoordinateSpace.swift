import CoreGraphics

/// 预览模块里的“坐标翻转边界”只保留在这里。
///
/// 约定：
/// - 数据源 / geometry 使用左上角原点的统一画布坐标。
/// - 2D 画布为了适配 AppKit 视口变换，需要临时转成左下角原点。
/// - 3D SceneKit 布局继续直接使用数据源坐标，不再复用 2D 的翻转结果。
enum PreviewCanvasCoordinateSpace {
    /// 把统一的 top-left 画布坐标转成 2D 实际绘制所用的 display 坐标。
    static func displayRect(
        fromNormalizedRect rect: CGRect,
        canvasSize: CGSize
    ) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: canvasSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// `displayRect` 的逆变换。
    ///
    /// 用于把 2D 视口返回的可见区域、中心点重新还原成数据源语义，
    /// 这样从 flat 进入 3D 时仍能沿用同一套坐标。
    static func normalizedRect(
        fromDisplayRect rect: CGRect,
        canvasSize: CGSize
    ) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: canvasSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
