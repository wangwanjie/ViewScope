#if os(iOS)
import Darwin
import Foundation
import UIKit

/// iOS / iPadOS / Mac Catalyst 宿主的平台元信息。
@MainActor
enum ViewScopePlatformRuntime {
    /// 宿主平台：Mac Catalyst 编译产物固定为 `.macCatalyst`，其余按设备 idiom 区分 iPhone / iPad。
    static var platform: ViewScopePlatform {
        #if targetEnvironment(macCatalyst)
        return .macCatalyst
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .iPadOS
        }
        return .iOS
        #endif
    }

    static var osVersion: String {
        UIDevice.current.systemVersion
    }

    /// iOS 16 起未申请权限时系统只返回通用名（例如 "iPhone"），这里按原样上报。
    static var deviceName: String {
        UIDevice.current.name
    }

    /// 设备型号标识，例如 "iPhone15,2"。
    static var deviceModel: String {
        #if targetEnvironment(simulator)
        // 模拟器里 utsname 返回宿主 Mac 的架构（arm64 / x86_64），型号需要从模拟器环境变量里取。
        if let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           identifier.isEmpty == false {
            return identifier
        }
        #endif
        #if targetEnvironment(macCatalyst)
        if let model = sysctlString(named: "hw.model") {
            return model
        }
        #endif
        return machineIdentifier() ?? UIDevice.current.model
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// 主屏幕缩放比例：优先取已连接场景的屏幕，取不到再退回 `UIScreen.main`。
    static var screenScale: Double {
        Double(preferredScreen.scale)
    }

    /// iOS 没有 DistributedNotificationCenter，只走端口段扫描。
    static var supportsDistributedDiscovery: Bool {
        false
    }

    /// iOS 应用天然运行在沙盒中，但 loopback 监听不受限制，因此对发现逻辑而言视为非沙盒。
    static func isSandboxed() -> Bool {
        false
    }

    /// 当前进程优先使用的屏幕。
    static var preferredScreen: UIScreen {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               scene.activationState == .foregroundActive {
                return windowScene.screen
            }
        }
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                return windowScene.screen
            }
        }
        return UIScreen.main
    }

    /// 读取 `utsname.machine`。
    private static func machineIdentifier() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { buffer -> String in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return identifier.isEmpty ? nil : identifier
    }

    /// 读取字符串类型的 sysctl 值（Mac Catalyst 上用于获取 Mac 型号）。
    private static func sysctlString(named name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
        return value.isEmpty ? nil : value
    }
}
#endif
