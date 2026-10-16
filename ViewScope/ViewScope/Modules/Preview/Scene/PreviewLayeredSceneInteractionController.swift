import CoreGraphics

struct PreviewLayeredSceneInteraction {
    /// 拖拽旋转：水平拖动改变偏航角（yaw），垂直拖动改变俯仰角（pitch）。
    /// 俯仰角限制在 ±80° 内，避免把画面翻到背面；偏航角允许任意旋转并归一到 (-π, π)。
    static func updatedRotation(current: CGPoint, delta: CGPoint) -> CGPoint {
        let pitch = current.x - delta.y * 0.004
        let yaw = current.y + delta.x * 0.01
        return CGPoint(
            x: clampedPitch(normalizedAngle(pitch)),
            y: normalizedAngle(yaw)
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
            x: clampedPitch(normalizedAngle(rotation.x)),
            y: normalizedAngle(rotation.y)
        )
    }

    static func clampedPitch(_ pitch: CGFloat) -> CGFloat {
        let limit = PreviewLayeredSceneConstants.maximumPitch
        return min(max(pitch, -limit), limit)
    }

    /// 以光标为锚点缩放时的新平移量：保证缩放前后光标下的内容点不动。
    ///
    /// - Parameters:
    ///   - translation: 当前平移（scene 单位）。
    ///   - cursorOffset: 光标相对视图中心的偏移（pt，y 向上）。
    ///   - unitsPerPointBefore: 缩放前每 pt 对应的 scene 单位。
    ///   - unitsPerPointAfter: 缩放后每 pt 对应的 scene 单位。
    static func anchoredTranslation(
        translation: CGPoint,
        cursorOffset: CGPoint,
        unitsPerPointBefore: CGFloat,
        unitsPerPointAfter: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: translation.x + cursorOffset.x * (unitsPerPointAfter - unitsPerPointBefore),
            y: translation.y + cursorOffset.y * (unitsPerPointAfter - unitsPerPointBefore)
        )
    }

    /// 把平移限制在内容附近：最多把内容中心移出视图中心一个“内容尺寸 + 半个视口”的距离。
    static func clampedTranslation(
        _ translation: CGPoint,
        contentSize: CGSize,
        viewportSize: CGSize
    ) -> CGPoint {
        let limitX = contentSize.width / 2 + viewportSize.width / 2
        let limitY = contentSize.height / 2 + viewportSize.height / 2
        return CGPoint(
            x: min(max(translation.x, -limitX), limitX),
            y: min(max(translation.y, -limitY), limitY)
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
