import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

struct DiscoveryAnnouncementRegistryTests {
    @Test func mergesByIdentifierAndIgnoresUpdatedAtOnlyChanges() {
        var registry = DiscoveryAnnouncementRegistry(gracePeriod: 15)
        let base = Date(timeIntervalSince1970: 0)
        let first = ConnectionTestFixtures.announcement(identifier: "a", updatedAt: base)

        let changed1 = registry.record(first, at: base)

        #expect(changed1)
        // 只有 updatedAt 变化：不算对外变化，但刷新 lastSeen
        var refreshed = first
        refreshed.updatedAt = base.addingTimeInterval(5)
        let changed2 = registry.record(refreshed, at: base.addingTimeInterval(5))
        #expect(changed2 == false)
        #expect(registry.entries.count == 1)
        #expect(registry.entries["a"]?.lastSeen == base.addingTimeInterval(5))

        // 内容变化（端口不同）：算变化，且仍只有一条
        var moved = first
        moved.port = 47301
        let changed3 = registry.record(moved, at: base.addingTimeInterval(6))
        #expect(changed3)
        #expect(registry.sortedAnnouncements.map(\.port) == [47301])
    }

    @Test func keepsEntriesWithinGracePeriod() {
        var registry = DiscoveryAnnouncementRegistry(gracePeriod: 15)
        let base = Date(timeIntervalSince1970: 0)
        registry.record(ConnectionTestFixtures.announcement(identifier: "a"), at: base)
        registry.record(ConnectionTestFixtures.announcement(identifier: "b"), at: base.addingTimeInterval(10))

        let changed4 = registry.prune(now: base.addingTimeInterval(14.9))

        #expect(changed4 == false)
        #expect(registry.entries.count == 2)

        let changed5 = registry.prune(now: base.addingTimeInterval(15.1))

        #expect(changed5)
        #expect(registry.entries.keys.sorted() == ["b"])

        let changed6 = registry.prune(now: base.addingTimeInterval(25.1))

        #expect(changed6)
        #expect(registry.entries.isEmpty)
    }

    @Test func removesByIdentifierAndDeviceSerial() {
        var registry = DiscoveryAnnouncementRegistry()
        let now = Date()
        let usbTransport = ViewScopeHostTransport(kind: .usbmux, deviceID: 3, deviceSerial: "SERIAL", connectionType: "USB")
        registry.record(ConnectionTestFixtures.announcement(identifier: "mac"), at: now)
        registry.record(ConnectionTestFixtures.announcement(identifier: "SERIAL|ios", transport: usbTransport), at: now)

        let changed7 = registry.removeAnnouncements(onDeviceSerial: "OTHER")

        #expect(changed7 == false)
        let changed8 = registry.removeAnnouncements(onDeviceSerial: "SERIAL")
        #expect(changed8)
        #expect(registry.entries.keys.sorted() == ["mac"])
        let changed9 = registry.remove(identifier: "mac")
        #expect(changed9)
        let changed10 = registry.remove(identifier: "mac")
        #expect(changed10 == false)
    }

    @Test func sortsByPlatformThenName() {
        var registry = DiscoveryAnnouncementRegistry()
        let now = Date()
        registry.record(ConnectionTestFixtures.announcement(identifier: "1", displayName: "Alpha", platform: .iOS), at: now)
        registry.record(ConnectionTestFixtures.announcement(identifier: "2", displayName: "Zulu", platform: nil), at: now)
        registry.record(ConnectionTestFixtures.announcement(identifier: "3", displayName: "beta", platform: .macOS), at: now)
        registry.record(ConnectionTestFixtures.announcement(identifier: "4", displayName: "Alpha", platform: .iOS, deviceName: "A Phone"), at: now)

        #expect(registry.sortedAnnouncements.map(\.identifier) == ["3", "2", "1", "4"])
    }
}

/// 假的 usbmuxd 设备监听器。
final class FakeUSBDeviceMonitor: ViewScopeUSBDeviceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ViewScopeUSBDeviceMonitorEvent) -> Void)?
    private var stopCount = 0

    var stops: Int {
        lock.withLock {
            stopCount
        }
    }

    func start(eventHandler: @escaping @Sendable (ViewScopeUSBDeviceMonitorEvent) -> Void) {
        lock.withLock {
            handler = eventHandler
        }
    }

    func stop() {
        lock.withLock {
            stopCount += 1
            handler = nil
        }
    }

    func send(_ event: ViewScopeUSBDeviceMonitorEvent) {
        let handler = lock.withLock {
            self.handler
        }
        handler?(event)
    }
}

@Suite(.serialized)
@MainActor
struct DiscoveryCenterTests {
    private func makeConfiguration() -> DiscoveryCenter.Configuration {
        var configuration = DiscoveryCenter.Configuration()
        configuration.portRange = 47300...47303
        configuration.observesDistributedNotifications = false
        configuration.scansLoopback = false
        configuration.monitorsUSBDevices = false
        configuration.pruneInterval = 60
        return configuration
    }

    @Test func loopbackScanRecordsAnnouncementsWithLoopbackTransport() async {
        var configuration = makeConfiguration()
        configuration.loopbackProbe = { port, _ in
            guard port == 47302 else {
                return nil
            }
            return ConnectionTestFixtures.announcement(identifier: "sim-host", port: 0, platform: .iOS)
        }
        let center = DiscoveryCenter(configuration: configuration)

        await center.performLoopbackScan()

        #expect(center.announcements.count == 1)
        #expect(center.announcements.first?.port == 47302)
        #expect(center.announcements.first?.resolvedTransport == .loopback)
    }

    @Test func usbDevicesAreScannedAndAnnouncementsRewritten() async {
        let monitor = FakeUSBDeviceMonitor()
        var configuration = makeConfiguration()
        configuration.monitorsUSBDevices = true
        configuration.usbScanInterval = 60
        configuration.makeDeviceMonitor = {
            monitor
        }
        configuration.usbProbe = { device, port, _ in
            guard port == 47300 else {
                return nil
            }
            return ConnectionTestFixtures.announcement(
                identifier: "app",
                platform: .iOS,
                deviceName: "Van's iPhone"
            )
        }
        let center = DiscoveryCenter(configuration: configuration)
        center.start()
        defer {
            center.stop()
        }

        monitor.send(.attached(ViewScopeUSBDevice(deviceID: 9, serial: "UDID-1", connectionType: "USB")))

        let discovered = await connectionTestWait {
            center.announcements.isEmpty == false
        }
        #expect(discovered)
        let announcement = center.announcements.first
        #expect(announcement?.identifier == "UDID-1|app")
        #expect(announcement?.port == 47300)
        #expect(announcement?.resolvedTransport.kind == .usbmux)
        #expect(announcement?.resolvedTransport.deviceID == 9)
        #expect(announcement?.resolvedTransport.deviceSerial == "UDID-1")

        // 设备名由宿主上报补全
        let named = await connectionTestWait {
            center.usbDevices.first?.name == "Van's iPhone"
        }
        #expect(named)

        // 拔出设备：其上的宿主立即移除
        monitor.send(.detached(deviceID: 9))
        let removed = await connectionTestWait {
            center.announcements.isEmpty && center.usbDevices.isEmpty
        }
        #expect(removed)
    }

    @Test func terminationRemovesImmediatelyAndPruneHonorsGracePeriod() {
        let center = DiscoveryCenter(configuration: makeConfiguration())
        let now = Date()
        center.record(ConnectionTestFixtures.announcement(identifier: "a"), at: now)
        center.record(ConnectionTestFixtures.announcement(identifier: "b"), at: now)
        #expect(center.announcements.count == 2)

        center.handleTermination(identifier: "a")
        #expect(center.announcements.map(\.identifier) == ["b"])

        center.pruneStaleAnnouncements(now: now.addingTimeInterval(10))
        #expect(center.announcements.count == 1)
        center.pruneStaleAnnouncements(now: now.addingTimeInterval(16))
        #expect(center.announcements.isEmpty)
    }

    @Test func startAndStopAreIdempotent() {
        let monitor = FakeUSBDeviceMonitor()
        var configuration = makeConfiguration()
        configuration.monitorsUSBDevices = true
        configuration.makeDeviceMonitor = {
            monitor
        }
        let center = DiscoveryCenter(configuration: configuration)
        center.start()
        center.start()
        center.stop()
        center.stop()
        #expect(monitor.stops == 1)
    }
}
