import Foundation
import ViewScopeServer

/// 主界面可请求打开的辅助面板。
enum WorkspacePanelRequest: Equatable {
    case modificationLog
    case captureDiff
}

/// 抓取对比的基线。
struct WorkspaceDiffBaseline: Equatable {
    let capture: ViewScopeCapturePayload
    /// 基线来源名称：宿主名或导入的文件名。
    let name: String
    let createdAt: Date
}

/// 已通过 USB / Wi‑Fi 连接、但未必运行了宿主的 iOS 设备（来自 DiscoveryCenter）。
struct WorkspaceConnectedDevice: Equatable, Identifiable {
    let serial: String
    let name: String
    /// usbmuxd 报告的连接类型，例如 "USB" / "Network"。
    let connectionType: String?

    var id: String { serial }
}

/// 宿主所在“设备”的分组信息。
struct WorkspaceHostDeviceGroup: Equatable {
    let key: String
    let title: String
    let hosts: [ViewScopeHostAnnouncement]
}

/// 宿主身份与展示文案的工具方法。
enum WorkspaceHostPresentation {
    enum DeviceKind: Equatable {
        case mac
        case simulator
        case device(connectionType: String?)
    }

    static func deviceKind(of host: ViewScopeHostAnnouncement) -> DeviceKind {
        if host.resolvedTransport.kind == .usbmux {
            return .device(connectionType: host.resolvedTransport.connectionType)
        }
        switch host.resolvedPlatform {
        case .macOS:
            return .mac
        case .macCatalyst:
            return .mac
        case .iOS, .iPadOS, .tvOS, .visionOS:
            return host.isSimulator == true ? .simulator : .device(connectionType: host.resolvedTransport.connectionType)
        }
    }

    /// 设备分组键：同一台设备上的宿主归为一组。
    static func deviceKey(of host: ViewScopeHostAnnouncement) -> String {
        let transport = host.resolvedTransport
        let serial = transport.deviceSerial ?? ""
        let simulator = host.isSimulator == true ? "sim" : "real"
        return "\(host.resolvedPlatform.rawValue)|\(simulator)|\(serial)|\(host.deviceName ?? "")"
    }

    /// 两个 announcement 是否代表“同一设备上的同一个 App”，用于自动重连。
    static func isSameApplication(_ lhs: ViewScopeHostAnnouncement, _ rhs: ViewScopeHostAnnouncement) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier &&
            lhs.resolvedPlatform == rhs.resolvedPlatform &&
            deviceKey(of: lhs) == deviceKey(of: rhs)
    }

    static func platformTitle(of host: ViewScopeHostAnnouncement) -> String {
        switch deviceKind(of: host) {
        case .mac:
            return host.resolvedPlatform == .macCatalyst ? "Mac Catalyst" : "macOS"
        case .simulator:
            return L10n.hostPlatformSimulator(platformName(host.resolvedPlatform))
        case .device(let connectionType):
            return L10n.hostPlatformDevice(platformName(host.resolvedPlatform), connectionTypeTitle(connectionType))
        }
    }

    /// 设备分组标题，例如 “iOS 模拟器 · iPhone 15 · 17.5”。
    static func deviceTitle(of host: ViewScopeHostAnnouncement) -> String {
        var parts = [platformTitle(of: host)]
        if let deviceName = host.deviceName, deviceName.isEmpty == false {
            parts.append(deviceName)
        }
        if let osVersion = host.osVersion, osVersion.isEmpty == false {
            parts.append(osVersion)
        }
        return parts.joined(separator: " · ")
    }

    /// 宿主条目标题，例如 “Demo 1.2 (34)  ·  com.example.demo”。
    static func hostTitle(of host: ViewScopeHostAnnouncement) -> String {
        var title = host.displayName
        if host.version.isEmpty == false {
            title += " \(host.version)"
            if host.build.isEmpty == false, host.build != host.version {
                title += " (\(host.build))"
            }
        }
        return "\(title)  ·  \(host.bundleIdentifier)"
    }

    /// 按设备分组，组内按名称排序；macOS 本机组排在最前。
    static func groupedByDevice(_ hosts: [ViewScopeHostAnnouncement]) -> [WorkspaceHostDeviceGroup] {
        var order: [String] = []
        var grouped: [String: [ViewScopeHostAnnouncement]] = [:]
        for host in hosts {
            let key = deviceKey(of: host)
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(host)
        }
        let groups = order.compactMap { key -> WorkspaceHostDeviceGroup? in
            guard let hosts = grouped[key], let first = hosts.first else {
                return nil
            }
            let sortedHosts = hosts.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return WorkspaceHostDeviceGroup(key: key, title: deviceTitle(of: first), hosts: sortedHosts)
        }
        return groups.sorted { lhs, rhs in
            let lhsIsMac = lhs.hosts.first.map { deviceKind(of: $0) == .mac } ?? false
            let rhsIsMac = rhs.hosts.first.map { deviceKind(of: $0) == .mac } ?? false
            if lhsIsMac != rhsIsMac {
                return lhsIsMac
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// 已连接但没有发现任何宿主的设备。
    static func devicesWithoutHosts(
        devices: [WorkspaceConnectedDevice],
        hosts: [ViewScopeHostAnnouncement]
    ) -> [WorkspaceConnectedDevice] {
        let serialsWithHosts = Set(hosts.compactMap { $0.resolvedTransport.deviceSerial })
        return devices.filter { serialsWithHosts.contains($0.serial) == false }
    }

    static func connectionTypeTitle(_ connectionType: String?) -> String {
        guard let connectionType else {
            return "USB"
        }
        let normalized = connectionType.lowercased()
        if normalized.contains("network") || normalized.contains("wifi") || normalized.contains("wi-fi") {
            return "Wi‑Fi"
        }
        return "USB"
    }

    private static func platformName(_ platform: ViewScopePlatform) -> String {
        switch platform {
        case .macOS:
            return "macOS"
        case .iOS:
            return "iOS"
        case .iPadOS:
            return "iPadOS"
        case .macCatalyst:
            return "Mac Catalyst"
        case .tvOS:
            return "tvOS"
        case .visionOS:
            return "visionOS"
        }
    }
}
