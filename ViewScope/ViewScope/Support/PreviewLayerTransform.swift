import CoreGraphics
import ViewScopeServer

struct PreviewLayerTransform {
    static let defaultYaw: CGFloat = -0.22
    static let defaultPitch: CGFloat = 0.16
    private static let twoPi = CGFloat.pi * 2

    var yaw: CGFloat
    var pitch: CGFloat
    var perspectiveDistance: CGFloat
    var depthSpacing: CGFloat

    init(
        yaw: CGFloat = Self.defaultYaw,
        pitch: CGFloat = Self.defaultPitch,
        perspectiveDistance: CGFloat = 1400,
        depthSpacing: CGFloat = 22
    ) {
        self.yaw = yaw
        self.pitch = pitch
        self.perspectiveDistance = perspectiveDistance
        self.depthSpacing = depthSpacing
    }

    static func relativeDepth(nodeDepth: Int, focusDepth: Int) -> CGFloat {
        CGFloat(max(0, nodeDepth - focusDepth))
    }

    mutating func drag(by delta: CGSize) {
        yaw = normalizedAngle(yaw + delta.width * 0.01)
        pitch = normalizedAngle(pitch + delta.height * 0.01)
    }

    func projectedQuad(for rect: CGRect, depth: CGFloat, canvasSize: CGSize) -> [CGPoint] {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        return corners.map { project($0, depth: depth, canvasSize: canvasSize) }
    }

    func projectedBounds(for rect: CGRect, depth: CGFloat, canvasSize: CGSize) -> CGRect {
        bounds(for: projectedQuad(for: rect, depth: depth, canvasSize: canvasSize))
    }

    func planeAffineTransform(for canvasSize: CGSize) -> CGAffineTransform {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let shear = CGAffineTransform(
            a: 1,
            b: -sin(pitch) * 0.12,
            c: sin(yaw) * 0.18,
            d: 1,
            tx: 0,
            ty: 0
        )
        let scale = CGAffineTransform(
            scaleX: max(0.84, 1 - abs(yaw) * 0.08),
            y: max(0.84, 1 - abs(pitch) * 0.08)
        )

        return CGAffineTransform(translationX: center.x, y: center.y)
            .concatenating(shear)
            .concatenating(scale)
            .translatedBy(x: -center.x, y: -center.y)
    }

    func contains(_ point: CGPoint, in quad: [CGPoint]) -> Bool {
        guard quad.count >= 3 else { return false }

        var containsPoint = false
        var previous = quad[quad.count - 1]
        for current in quad {
            let intersects = ((current.y > point.y) != (previous.y > point.y)) &&
                (point.x < (previous.x - current.x) * (point.y - current.y) / max(previous.y - current.y, 0.0001) + current.x)
            if intersects {
                containsPoint.toggle()
            }
            previous = current
        }
        return containsPoint
    }

    func bounds(for quad: [CGPoint]) -> CGRect {
        guard !quad.isEmpty else { return .zero }
        let minX = quad.map(\.x).min() ?? 0
        let maxX = quad.map(\.x).max() ?? 0
        let minY = quad.map(\.y).min() ?? 0
        let maxY = quad.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var result = angle.truncatingRemainder(dividingBy: Self.twoPi)
        if result <= -.pi {
            result += Self.twoPi
        } else if result > .pi {
            result -= Self.twoPi
        }
        return result
    }

    private func project(_ point: CGPoint, depth: CGFloat, canvasSize: CGSize) -> CGPoint {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let x = point.x - center.x
        let y = point.y - center.y
        let z = depth * depthSpacing

        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)
        let pitchedY = y * cosPitch - z * sinPitch
        let pitchedZ = y * sinPitch + z * cosPitch

        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let yawedX = x * cosYaw + pitchedZ * sinYaw
        let yawedZ = -x * sinYaw + pitchedZ * cosYaw

        let perspective = perspectiveDistance / max(perspectiveDistance - yawedZ, perspectiveDistance * 0.25)
        return CGPoint(
            x: center.x + yawedX * perspective,
            y: center.y + pitchedY * perspective
        )
    }
}

struct PreviewHitTestResolver {
    private let geometry = ViewHierarchyGeometry()

    func nodeID(
        atViewPoint point: CGPoint,
        capture: ViewScopeCapturePayload,
        viewportState: PreviewViewportState,
        focusedNodeID: String?,
        displayMode: WorkspacePreviewDisplayMode,
        geometryMode: PreviewCanvasGeometryMode,
        layerTransform: PreviewLayerTransform
    ) -> String? {
        switch displayMode {
        case .flat:
            guard let canvasPoint = viewportState.canvasPoint(forViewPoint: point) else {
                return nil
            }
            let normalizedPoint = CGPoint(
                x: canvasPoint.x,
                y: viewportState.canvasSize.height - canvasPoint.y
            )
            return geometry.deepestNodeID(
                at: normalizedPoint,
                in: capture,
                rootNodeID: focusedNodeID,
                mode: geometryMode
            )
        case .layered:
            let canvasPoint = viewportState.rawCanvasPoint(forViewPoint: point)
            let plan = PreviewLayeredRenderPlan.make(
                capture: capture,
                canvasSize: viewportState.canvasSize,
                selectedNodeID: nil,
                focusedNodeID: focusedNodeID,
                geometryMode: geometryMode,
                geometry: geometry,
                layerTransform: layerTransform
            )

            for overlay in plan.overlayQuads.reversed() {
                if layerTransform.contains(canvasPoint, in: overlay.quad) {
                    return overlay.nodeID
                }
            }
            return nil
        }
    }
}

struct PreviewFocusMaskResolver {
    func cutoutViewRect(
        displayMode: WorkspacePreviewDisplayMode,
        focusRect: CGRect,
        canvasSize _: CGSize,
        viewportState: PreviewViewportState,
        layerTransform _: PreviewLayerTransform
    ) -> CGRect? {
        switch displayMode {
        case .flat:
            return viewportState.viewRect(forCanvasRect: focusRect)
        case .layered:
            return nil
        }
    }
}
