import AppKit

/// 主窗口统一的配色与尺寸定义，所有面板从这里取值，保证视觉一致。
enum WorkspaceTheme {
    // MARK: - 尺寸

    enum Metrics {
        /// 标题栏行高度，与 unified 工具栏下红绿灯的垂直中心对齐。
        static let titlebarHeight: CGFloat = 52
        /// 工具栏内容让出红绿灯的宽度。
        static let trafficLightsInset: CGFloat = 92
        /// 面板卡片之间以及卡片与窗口边缘的间距。
        static let panelGap: CGFloat = 8
        static let panelCornerRadius: CGFloat = 10
        static let panelHeaderHeight: CGFloat = 38
        static let sectionCornerRadius: CGFloat = 8
    }

    // MARK: - 颜色

    /// 窗口底色：比面板稍暗，用来衬托面板卡片。
    static let canvasBackground = dynamicColor(light: 0xE9E9EC, dark: 0x141416)
    /// 面板卡片底色。
    static let panelBackground = dynamicColor(light: 0xFFFFFF, dark: 0x1E1E21)
    /// 面板卡片描边，只做轻微的轮廓提示。
    static let panelBorder = dynamicColor(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.07)
    /// 面板内部的分隔线。
    static let hairline = dynamicColor(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.07)
    /// 面板内分组（如 Inspector 分区）的浅色填充。
    static let groupedFill = dynamicColor(light: 0x000000, lightAlpha: 0.035, dark: 0xFFFFFF, darkAlpha: 0.04)
    /// 预览画布底色，比面板再暗一档，突出截图内容。
    static let canvasWell = dynamicColor(light: 0xF3F3F5, dark: 0x18181A)

    /// 状态胶囊配色：文字使用系统语义色，背景为同色低透明度，自动适配深浅色。
    static func badgeColors(tint: NSColor) -> (text: NSColor, background: NSColor) {
        (tint, tint.withAlphaComponent(0.16))
    }

    private static func dynamicColor(
        light: UInt32,
        lightAlpha: CGFloat = 1,
        dark: UInt32,
        darkAlpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isDark {
                return color(hex: dark, alpha: darkAlpha)
            }
            return color(hex: light, alpha: lightAlpha)
        }
    }

    private static func color(hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension NSView {
    /// 在当前视图外观下解析动态颜色并转为 CGColor（layer 颜色不会自动跟随外观变化）。
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}
