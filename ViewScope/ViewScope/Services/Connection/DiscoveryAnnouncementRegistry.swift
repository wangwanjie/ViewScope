import Foundation
import ViewScopeServer

/// 多来源 announcement 的合并与过期逻辑（纯值类型，便于测试）。
///
/// - 同一 identifier 只保留一条，后到的覆盖先到的；
/// - 每条记录保存客户端本地的“最后一次看到”时间，超过宽限期才移除，
///   避免宿主停在断点、探测暂时失败时立刻从列表消失；
/// - 使用本地接收时间而非 announcement.updatedAt，不受宿主（真机）时钟偏差影响。
nonisolated struct DiscoveryAnnouncementRegistry {
    struct Entry: Equatable {
        var announcement: ViewScopeHostAnnouncement
        var lastSeen: Date
    }

    static let defaultGracePeriod: TimeInterval = 15

    let gracePeriod: TimeInterval
    private(set) var entries: [String: Entry] = [:]

    init(gracePeriod: TimeInterval = DiscoveryAnnouncementRegistry.defaultGracePeriod) {
        self.gracePeriod = gracePeriod
    }

    /// 记录一次发现。返回对外可见内容是否变化（只有 updatedAt 不同视为未变化）。
    @discardableResult
    mutating func record(_ announcement: ViewScopeHostAnnouncement, at date: Date) -> Bool {
        let previous = entries[announcement.identifier]?.announcement
        entries[announcement.identifier] = Entry(announcement: announcement, lastSeen: date)
        guard let previous else {
            return true
        }
        return Self.isEquivalent(previous, announcement) == false
    }

    @discardableResult
    mutating func remove(identifier: String) -> Bool {
        entries.removeValue(forKey: identifier) != nil
    }

    /// 移除满足条件的记录，返回是否有记录被移除。
    @discardableResult
    mutating func removeAll(where shouldRemove: (ViewScopeHostAnnouncement) -> Bool) -> Bool {
        let before = entries.count
        entries = entries.filter { _, entry in
            shouldRemove(entry.announcement) == false
        }
        return entries.count != before
    }

    /// 移除某台 usb 设备（按序列号）上的全部宿主。
    @discardableResult
    mutating func removeAnnouncements(onDeviceSerial serial: String) -> Bool {
        removeAll { announcement in
            let transport = announcement.resolvedTransport
            return transport.kind == .usbmux && transport.deviceSerial == serial
        }
    }

    /// 移除超过宽限期未再出现的记录，返回是否有记录被移除。
    @discardableResult
    mutating func prune(now: Date) -> Bool {
        let gracePeriod = self.gracePeriod
        let before = entries.count
        entries = entries.filter { _, entry in
            now.timeIntervalSince(entry.lastSeen) < gracePeriod
        }
        return entries.count != before
    }

    /// 排序后的列表：先按平台（macOS 在前），再按名称、设备名、进程号。
    var sortedAnnouncements: [ViewScopeHostAnnouncement] {
        entries.values.map(\.announcement).sorted(by: Self.isOrderedBefore)
    }

    // MARK: - 工具

    /// 忽略 updatedAt 比较两条 announcement。
    static func isEquivalent(_ left: ViewScopeHostAnnouncement, _ right: ViewScopeHostAnnouncement) -> Bool {
        var normalized = left
        normalized.updatedAt = right.updatedAt
        return normalized == right
    }

    static func platformRank(_ platform: ViewScopePlatform) -> Int {
        switch platform {
        case .macOS:
            return 0
        case .macCatalyst:
            return 1
        case .iOS:
            return 2
        case .iPadOS:
            return 3
        case .visionOS:
            return 4
        case .tvOS:
            return 5
        }
    }

    static func isOrderedBefore(_ left: ViewScopeHostAnnouncement, _ right: ViewScopeHostAnnouncement) -> Bool {
        let leftRank = platformRank(left.resolvedPlatform)
        let rightRank = platformRank(right.resolvedPlatform)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        let nameOrder = left.displayName.localizedCaseInsensitiveCompare(right.displayName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        let deviceOrder = (left.deviceName ?? "").localizedCaseInsensitiveCompare(right.deviceName ?? "")
        if deviceOrder != .orderedSame {
            return deviceOrder == .orderedAscending
        }
        if left.processIdentifier != right.processIdentifier {
            return left.processIdentifier < right.processIdentifier
        }
        return left.identifier < right.identifier
    }
}
