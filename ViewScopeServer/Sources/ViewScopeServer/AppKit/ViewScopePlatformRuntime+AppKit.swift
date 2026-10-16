#if os(macOS)
import AppKit
import Foundation
import Security

/// macOS 平台元信息。
@MainActor
enum ViewScopePlatformRuntime {
    static var platform: ViewScopePlatform {
        .macOS
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.patchVersion > 0 {
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// 通过 sysctl 读取 `hw.model`，例如 "MacBookPro18,3"。
    static var deviceModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Mac"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "Mac"
        }
        // 去掉结尾的 \0 再解码。
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static var isSimulator: Bool {
        false
    }

    static var screenScale: Double {
        Double(NSScreen.main?.backingScaleFactor ?? 1)
    }

    /// macOS 继续通过 DistributedNotificationCenter 广播 announcement。
    static var supportsDistributedDiscovery: Bool {
        true
    }

    static func isSandboxed() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let rawValue = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) else {
            return false
        }
        if let value = rawValue as? Bool {
            return value
        }
        if let value = rawValue as? NSNumber {
            return value.boolValue
        }
        return false
    }
}
#endif
