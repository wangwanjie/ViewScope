import CoreGraphics

struct PreviewViewportState {
    private(set) var canvasSize: CGSize
    private(set) var viewportSize: CGSize
    private(set) var scale: CGFloat
    private(set) var contentOffset: CGPoint
    private(set) var rotationAngle: CGFloat
    let padding: CGFloat

    init(
        canvasSize: CGSize = .zero,
        viewportSize: CGSize = .zero,
        padding: CGFloat = 28,
        scale: CGFloat = 1,
        contentOffset: CGPoint = .zero,
        rotationAngle: CGFloat = 0
    ) {
        self.canvasSize = canvasSize
        self.viewportSize = viewportSize
        self.padding = padding
        self.scale = max(scale, 0.0001)
        self.contentOffset = contentOffset
        self.rotationAngle = rotationAngle
        clampContentOffset()
    }

    var visibleCanvasRect: CGRect {
        guard isReady else { return .zero }
        let visibleViewport = effectiveViewportRect
        let canvasPoints = [
            canvasPointInBounds(forViewPoint: visibleViewport.origin),
            canvasPointInBounds(forViewPoint: CGPoint(x: visibleViewport.maxX, y: visibleViewport.minY)),
            canvasPointInBounds(forViewPoint: CGPoint(x: visibleViewport.maxX, y: visibleViewport.maxY)),
            canvasPointInBounds(forViewPoint: CGPoint(x: visibleViewport.minX, y: visibleViewport.maxY))
        ]

        let minX = canvasPoints.map(\.x).min() ?? 0
        let minY = canvasPoints.map(\.y).min() ?? 0
        let maxX = canvasPoints.map(\.x).max() ?? 0
        let maxY = canvasPoints.map(\.y).max() ?? 0

        return CGRect(
            x: max(0, min(canvasSize.width, minX)),
            y: max(0, min(canvasSize.height, minY)),
            width: max(0, min(canvasSize.width, maxX) - max(0, min(canvasSize.width, minX))),
            height: max(0, min(canvasSize.height, maxY) - max(0, min(canvasSize.height, minY)))
        )
    }

    mutating func setCanvasSize(_ size: CGSize) {
        let anchor = canvasPoint(forViewPoint: visibleViewportCenter)
        canvasSize = size
        reanchor(canvasPoint: anchor, anchorViewPoint: visibleViewportCenter)
    }

    mutating func setViewportSize(_ size: CGSize) {
        let anchor = canvasPoint(forViewPoint: visibleViewportCenter)
        viewportSize = size
        reanchor(canvasPoint: anchor, anchorViewPoint: visibleViewportCenter)
    }

    mutating func setScale(_ newScale: CGFloat) {
        setScale(newScale, keepingCanvasPoint: canvasPoint(forViewPoint: visibleViewportCenter), anchoredAt: visibleViewportCenter)
    }

    mutating func setScale(_ newScale: CGFloat, keepingCanvasPoint anchorCanvasPoint: CGPoint?, anchoredAt anchorViewPoint: CGPoint) {
        scale = max(newScale, 0.0001)
        reanchor(canvasPoint: anchorCanvasPoint, anchorViewPoint: anchorViewPoint)
    }

    mutating func pan(by delta: CGSize) {
        guard isReady else { return }
        contentOffset.x += delta.width
        contentOffset.y += delta.height
        clampContentOffset()
    }

    mutating func rotate(by delta: CGFloat) {
        guard isReady else { return }
        let anchor = canvasPoint(forViewPoint: visibleViewportCenter)
        rotationAngle += delta
        reanchor(canvasPoint: anchor, anchorViewPoint: visibleViewportCenter)
    }

    mutating func resetRotation() {
        guard isReady else { return }
        let anchor = canvasPoint(forViewPoint: visibleViewportCenter)
        rotationAngle = 0
        reanchor(canvasPoint: anchor, anchorViewPoint: visibleViewportCenter)
    }

    mutating func center(onCanvasRect rect: CGRect) {
        guard isReady else { return }
        let targetCenter = CGPoint(x: rect.midX, y: rect.midY)
        guard let currentViewPoint = viewPoint(forCanvasPoint: targetCenter) else { return }
        contentOffset.x += visibleViewportCenter.x - currentViewPoint.x
        contentOffset.y += visibleViewportCenter.y - currentViewPoint.y
        clampContentOffset()
    }

    var canvasToViewTransform: CGAffineTransform {
        transform(contentOffset: contentOffset)
    }

    func viewPoint(forCanvasPoint point: CGPoint) -> CGPoint? {
        guard isReady else { return nil }
        return point.applying(canvasToViewTransform)
    }

    func canvasPoint(forViewPoint point: CGPoint) -> CGPoint? {
        guard isReady else { return nil }
        let canvasPoint = canvasPointInBounds(forViewPoint: point)
        guard canvasBounds.insetBy(dx: -0.5, dy: -0.5).contains(canvasPoint) else {
            return nil
        }
        return CGPoint(
            x: max(0, min(canvasSize.width, canvasPoint.x)),
            y: max(0, min(canvasSize.height, canvasPoint.y))
        )
    }

    func viewRect(forCanvasRect rect: CGRect) -> CGRect {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ].compactMap(viewPoint(forCanvasPoint:))

        guard !points.isEmpty else { return .zero }
        let minX = points.map(\.x).min() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private var isReady: Bool {
        canvasSize.width > 0 && canvasSize.height > 0 && viewportSize.width > 0 && viewportSize.height > 0
    }

    private var canvasBounds: CGRect {
        CGRect(origin: .zero, size: canvasSize)
    }

    private var effectiveViewportRect: CGRect {
        CGRect(origin: .zero, size: viewportSize).insetBy(dx: padding, dy: padding)
    }

    private var visibleViewportCenter: CGPoint {
        CGPoint(x: effectiveViewportRect.midX, y: effectiveViewportRect.midY)
    }

    private var scaledCanvasSize: CGSize {
        CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
    }

    private var baseOrigin: CGPoint {
        let visibleRect = effectiveViewportRect
        let scaledSize = scaledCanvasSize

        let originX: CGFloat
        if scaledSize.width <= visibleRect.width {
            originX = visibleRect.minX + (visibleRect.width - scaledSize.width) / 2
        } else {
            originX = visibleRect.minX
        }

        let originY: CGFloat
        if scaledSize.height <= visibleRect.height {
            originY = visibleRect.minY + (visibleRect.height - scaledSize.height) / 2
        } else {
            originY = visibleRect.minY
        }

        return CGPoint(x: originX, y: originY)
    }

    private var baseCenter: CGPoint {
        CGPoint(x: baseOrigin.x + scaledCanvasSize.width / 2, y: baseOrigin.y + scaledCanvasSize.height / 2)
    }

    private func canvasPointInBounds(forViewPoint point: CGPoint) -> CGPoint {
        point.applying(canvasToViewTransform.inverted())
    }

    private func zeroOffsetContentBounds() -> CGRect {
        canvasBounds.applying(transform(contentOffset: .zero))
    }

    private mutating func reanchor(canvasPoint: CGPoint?, anchorViewPoint: CGPoint) {
        contentOffset = .zero
        guard let canvasPoint else {
            clampContentOffset()
            return
        }
        if let movedViewPoint = viewPoint(forCanvasPoint: canvasPoint) {
            contentOffset.x += anchorViewPoint.x - movedViewPoint.x
            contentOffset.y += anchorViewPoint.y - movedViewPoint.y
        }
        clampContentOffset()
    }

    private mutating func clampContentOffset() {
        guard isReady else {
            contentOffset = .zero
            return
        }

        let bounds = zeroOffsetContentBounds()
        let visibleRect = effectiveViewportRect

        let minOffsetX = visibleRect.maxX - bounds.maxX
        let maxOffsetX = visibleRect.minX - bounds.minX
        contentOffset.x = min(
            max(contentOffset.x, min(minOffsetX, maxOffsetX)),
            max(minOffsetX, maxOffsetX)
        )

        let minOffsetY = visibleRect.maxY - bounds.maxY
        let maxOffsetY = visibleRect.minY - bounds.minY
        contentOffset.y = min(
            max(contentOffset.y, min(minOffsetY, maxOffsetY)),
            max(minOffsetY, maxOffsetY)
        )
    }

    private func transform(contentOffset: CGPoint) -> CGAffineTransform {
        guard isReady else { return .identity }

        let center = CGPoint(
            x: baseCenter.x + contentOffset.x,
            y: baseCenter.y + contentOffset.y
        )

        return CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .scaledBy(x: 1, y: -1)
            .rotated(by: rotationAngle)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -canvasSize.width / 2, y: -canvasSize.height / 2)
    }
}
