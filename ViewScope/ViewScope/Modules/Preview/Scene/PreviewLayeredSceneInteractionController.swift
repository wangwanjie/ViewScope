import CoreGraphics

struct PreviewLayeredSceneInteraction {
    static func updatedRotation(current: CGPoint, delta: CGPoint) -> CGPoint {
        normalizedRotation(
            CGPoint(
                x: current.x - delta.y * 0.004,
                y: current.y + delta.x * 0.01
            )
        )
    }

    static func rotationWhenEnteringLayered(from _: CGPoint) -> CGPoint {
        CGPoint(
            x: PreviewLayeredSceneConstants.defaultPitch,
            y: PreviewLayeredSceneConstants.defaultYaw
        )
    }

    static func normalizedRotation(_ rotation: CGPoint) -> CGPoint {
        CGPoint(
            x: normalizedAngle(rotation.x),
            y: normalizedAngle(rotation.y)
        )
    }

    private static func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var result = angle
        while result <= -.pi {
            result += .pi * 2
        }
        while result >= .pi {
            result -= .pi * 2
        }
        return result
    }
}
