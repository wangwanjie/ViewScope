import CoreGraphics
import Foundation

/// 实时修改失败的原因。
enum ViewScopeMutationError: Error, Equatable {
    case unsupportedProperty
    case invalidValue
    case targetDeallocated

    func message(in language: ViewScopeInterfaceLanguage) -> String {
        switch self {
        case .unsupportedProperty:
            return language.text("server.error.unsupported_mutation")
        case .invalidValue:
            return language.text("server.error.invalid_mutation_value")
        case .targetDeallocated:
            return language.text("server.error.selected_node_gone")
        }
    }
}

/// 通用数值转换，拒绝非有限数与越界值（替代 `Int(value)` / `UInt(value)` 的 trap）。
enum ViewScopeNumberConversion {
    static func int(_ value: Double?) throws -> Int {
        guard let value, value.isFinite else {
            throw ViewScopeMutationError.invalidValue
        }
        // 只接受整数值，且必须能被 Int 精确表示；1e30、-1e30 之类不会触发 trap。
        guard let result = Int(exactly: value.rounded()) else {
            throw ViewScopeMutationError.invalidValue
        }
        return result
    }

    static func uint(_ value: Double?) throws -> UInt {
        guard let value, value.isFinite, value >= 0 else {
            throw ViewScopeMutationError.invalidValue
        }
        guard let result = UInt(exactly: value.rounded()) else {
            throw ViewScopeMutationError.invalidValue
        }
        return result
    }

    static func cgFloat(_ value: Double?) throws -> CGFloat {
        guard let value, value.isFinite else {
            throw ViewScopeMutationError.invalidValue
        }
        // 限制在合理范围内，避免极大值让布局引擎溢出。
        guard abs(value) <= 1_000_000_000 else {
            throw ViewScopeMutationError.invalidValue
        }
        return CGFloat(value)
    }

    /// 非负 CGFloat（宽高、圆角、边框宽度等）；负数会被夹到 0。
    static func nonNegativeCGFloat(_ value: Double?) throws -> CGFloat {
        max(0, try cgFloat(value))
    }

    /// 0...1 区间（透明度等）。
    static func unitInterval(_ value: Double?) throws -> CGFloat {
        let result = try cgFloat(value)
        return max(0, min(1, result))
    }

    /// 把 Double 安全转换为可编码的有限数；非有限数返回 0。
    static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

/// 颜色字符串解析（#RRGGBB / #RRGGBBAA，sRGB）。
enum ViewScopeColorParsing {
    static func rgba(fromHex string: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        var sanitized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.hasPrefix("#") {
            sanitized.removeFirst()
        }
        guard sanitized.count == 6 || sanitized.count == 8,
              sanitized.allSatisfy({ $0.isHexDigit }),
              let rawValue = UInt64(sanitized, radix: 16) else {
            return nil
        }

        if sanitized.count == 8 {
            return (
                red: Double((rawValue & 0xFF00_0000) >> 24) / 255,
                green: Double((rawValue & 0x00FF_0000) >> 16) / 255,
                blue: Double((rawValue & 0x0000_FF00) >> 8) / 255,
                alpha: Double(rawValue & 0x0000_00FF) / 255
            )
        }
        return (
            red: Double((rawValue & 0xFF0000) >> 16) / 255,
            green: Double((rawValue & 0x00FF00) >> 8) / 255,
            blue: Double(rawValue & 0x0000FF) / 255,
            alpha: 1
        )
    }

    static func hexString(red: Double, green: Double, blue: Double, alpha: Double) -> String {
        func component(_ value: Double) -> Int {
            guard value.isFinite else {
                return 0
            }
            return Int((max(0, min(1, value)) * 255).rounded())
        }
        let r = component(red)
        let g = component(green)
        let b = component(blue)
        let a = component(alpha)
        // 与旧版本保持一致：始终输出 8 位 #RRGGBBAA。
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    /// 生成 sRGB 的 CGColor，供两个平台共用。
    static func cgColor(fromHex string: String) -> CGColor? {
        guard let rgba = rgba(fromHex: string),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGColor(colorSpace: colorSpace, components: [CGFloat(rgba.red), CGFloat(rgba.green), CGFloat(rgba.blue), CGFloat(rgba.alpha)])
    }

    /// 把 CGColor 转成十六进制字符串（先转换到 sRGB）。
    static func hexString(from color: CGColor?) -> String? {
        guard let color,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3 else {
            return nil
        }
        let alpha = components.count >= 4 ? components[3] : converted.alpha
        return hexString(red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]), alpha: Double(alpha))
    }
}
