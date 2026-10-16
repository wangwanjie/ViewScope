import Combine
import Foundation
import ViewScopeServer

@MainActor
/// 汇总多来源的宿主 announcement，维护一份带宽限期的实时列表。
///
/// 来源：
/// 1. macOS `DistributedNotificationCenter` 广播（兼容旧宿主）；
/// 2. loopback 端口扫描（macOS 宿主、iOS 模拟器）；
/// 3. usbmuxd：监听设备接入/拔出，并对每台设备的端口段做隧道探测（iOS 真机）。
final class DiscoveryCenter: NSObject {
    typealias LoopbackProbe = @Sendable (_ port: UInt16, _ timeout: TimeInterval) async -> ViewScopeHostAnnouncement?
    typealias USBProbe = @Sendable (_ device: ViewScopeUSBDevice, _ port: UInt16, _ timeout: TimeInterval) async -> ViewScopeHostAnnouncement?

    struct Configuration {
        var portRange: ClosedRange<UInt16> = viewScopeHostPortRange
        var gracePeriod: TimeInterval = DiscoveryAnnouncementRegistry.defaultGracePeriod
        var pruneInterval: TimeInterval = 1
        var loopbackScanInterval: TimeInterval = 2
        var usbScanInterval: TimeInterval = 3
        /// 单次端口探测超时。
        var probeTimeout: TimeInterval = 1
        /// 每台 usb 设备同时进行的探测数，避免一次性向 usbmuxd 发起过多连接。
        var usbProbeConcurrency = 8
        var observesDistributedNotifications = true
        var scansLoopback = true
        var monitorsUSBDevices = true
        var loopbackProbe: LoopbackProbe = { port, timeout in
            await ViewScopeHostProbe.probeLoopback(port: port, timeout: timeout)
        }
        var usbProbe: USBProbe = { device, port, timeout in
            await ViewScopeHostProbe.probeUSB(device: device, port: port, timeout: timeout)
        }
        var makeDeviceMonitor: @MainActor () -> any ViewScopeUSBDeviceMonitoring = {
            ViewScopeUSBMuxDeviceMonitor()
        }

        static var standard: Configuration {
            Configuration()
        }
    }

    /// 对外唯一的宿主数据源。
    @Published private(set) var announcements: [ViewScopeHostAnnouncement] = []
    /// 当前通过 usbmuxd 接入的设备（含尚未发现宿主的设备）。
    @Published private(set) var usbDevices: [ViewScopeUSBDevice] = []

    private let configuration: Configuration
    private var registry: DiscoveryAnnouncementRegistry
    private var isRunning = false
    /// 每次 start/stop 递增，用于丢弃过期的异步结果。
    private var generation: UInt64 = 0

    private var announcementObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var pruneTask: Task<Void, Never>?
    private var loopbackScanTask: Task<Void, Never>?
    private var isLoopbackScanInFlight = false

    private var deviceMonitor: (any ViewScopeUSBDeviceMonitoring)?
    private var devicesByID: [Int: ViewScopeUSBDevice] = [:]
    /// 从宿主 announcement 中得到的设备名（usbmuxd 通常不提供设备名）。
    private var deviceNamesBySerial: [String: String] = [:]
    private var deviceScanTasks: [Int: Task<Void, Never>] = [:]
    private var deviceIDsScanning: Set<Int> = []

    init(configuration: Configuration) {
        self.configuration = configuration
        self.registry = DiscoveryAnnouncementRegistry(gracePeriod: configuration.gracePeriod)
        super.init()
    }

    override convenience init() {
        self.init(configuration: .standard)
    }

    // MARK: - 生命周期

    func start() {
        guard isRunning == false else {
            return
        }
        isRunning = true
        generation &+= 1

        if configuration.observesDistributedNotifications {
            startObservingNotifications()
        }
        startPruneLoop()
        if configuration.scansLoopback {
            startLoopbackScanLoop()
        }
        if configuration.monitorsUSBDevices {
            startDeviceMonitor()
        }
    }

    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false
        generation &+= 1

        if let announcementObserver {
            DistributedNotificationCenter.default().removeObserver(announcementObserver)
        }
        if let terminationObserver {
            DistributedNotificationCenter.default().removeObserver(terminationObserver)
        }
        announcementObserver = nil
        terminationObserver = nil

        pruneTask?.cancel()
        pruneTask = nil
        loopbackScanTask?.cancel()
        loopbackScanTask = nil
        isLoopbackScanInFlight = false

        deviceMonitor?.stop()
        deviceMonitor = nil
        for task in deviceScanTasks.values {
            task.cancel()
        }
        deviceScanTasks.removeAll()
        deviceIDsScanning.removeAll()
        devicesByID.removeAll()
        publishUSBDevices()
    }

    // MARK: - 通知来源

    private func startObservingNotifications() {
        announcementObserver = DistributedNotificationCenter.default().addObserver(
            forName: viewScopeDiscoveryAnnouncementNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let payload = notification.userInfo?["payload"] as? String
            MainActor.assumeIsolated {
                self?.handleAnnouncementPayload(payload)
            }
        }

        terminationObserver = DistributedNotificationCenter.default().addObserver(
            forName: viewScopeDiscoveryTerminationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let identifier = notification.userInfo?["identifier"] as? String
            MainActor.assumeIsolated {
                self?.handleTermination(identifier: identifier)
            }
        }

        DistributedNotificationCenter.default().postNotificationName(
            viewScopeDiscoveryRequestNotification,
            object: nil,
            userInfo: nil,
            options: [.deliverImmediately]
        )
    }

    private func handleAnnouncementPayload(_ payload: String?) {
        guard let payload,
              let data = payload.data(using: .utf8),
              let announcement = try? ViewScopeConnectionCoding.makeDecoder().decode(ViewScopeHostAnnouncement.self, from: data) else {
            return
        }
        record(announcement, at: Date())
    }

    /// 宿主退出通知：立即移除。
    func handleTermination(identifier: String?) {
        guard let identifier else {
            return
        }
        if registry.remove(identifier: identifier) {
            publishAnnouncements()
        }
    }

    // MARK: - 过期清理

    private func startPruneLoop() {
        let interval = configuration.pruneInterval
        pruneTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: Self.nanoseconds(interval))
                if Task.isCancelled {
                    return
                }
                guard let owner = self else {
                    return
                }
                owner.pruneStaleAnnouncements(now: Date())
            }
        }
    }

    func pruneStaleAnnouncements(now: Date) {
        if registry.prune(now: now) {
            publishAnnouncements()
        }
    }

    // MARK: - loopback 扫描

    private func startLoopbackScanLoop() {
        let interval = configuration.loopbackScanInterval
        loopbackScanTask = Task { [weak self] in
            while Task.isCancelled == false {
                if let owner = self {
                    await owner.performLoopbackScan()
                } else {
                    return
                }
                try? await Task.sleep(nanoseconds: Self.nanoseconds(interval))
            }
        }
    }

    /// 并发探测端口段中的所有端口；上一轮未结束时不开始新一轮。
    func performLoopbackScan() async {
        guard isLoopbackScanInFlight == false else {
            return
        }
        isLoopbackScanInFlight = true
        let scanGeneration = generation
        let probe = configuration.loopbackProbe
        let timeout = configuration.probeTimeout
        let ports = Array(configuration.portRange)

        let results = await withTaskGroup(of: (UInt16, ViewScopeHostAnnouncement?).self) { group in
            for port in ports {
                group.addTask {
                    (port, await probe(port, timeout))
                }
            }
            var collected: [(UInt16, ViewScopeHostAnnouncement?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        guard scanGeneration == generation else {
            // 期间已 stop/restart，丢弃结果（新一代的 isLoopbackScanInFlight 已被重置）
            return
        }
        isLoopbackScanInFlight = false

        let now = Date()
        var changed = false
        for (port, announcement) in results {
            guard var announcement else {
                continue
            }
            announcement.transport = .loopback
            announcement.port = port
            if registry.record(announcement, at: now) {
                changed = true
            }
        }
        if changed {
            publishAnnouncements()
        }
    }

    // MARK: - usbmuxd

    private func startDeviceMonitor() {
        let monitor = configuration.makeDeviceMonitor()
        deviceMonitor = monitor
        let monitorGeneration = generation
        monitor.start { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleDeviceMonitorEvent(event, generation: monitorGeneration)
                }
            }
        }
    }

    func handleDeviceMonitorEvent(_ event: ViewScopeUSBDeviceMonitorEvent, generation eventGeneration: UInt64) {
        guard isRunning, eventGeneration == generation else {
            return
        }
        switch event {
        case .deviceList(let devices):
            var updated: [Int: ViewScopeUSBDevice] = [:]
            for device in devices {
                updated[device.deviceID] = device
            }
            applyDevices(updated, removesMissingDeviceHosts: true)
        case .attached(let device):
            var updated = devicesByID
            updated[device.deviceID] = device
            applyDevices(updated, removesMissingDeviceHosts: true)
        case .detached(let deviceID):
            var updated = devicesByID
            updated.removeValue(forKey: deviceID)
            applyDevices(updated, removesMissingDeviceHosts: true)
        case .connectionLost:
            // usbmuxd 连接中断：清空设备，宿主交给宽限期处理（usbmuxd 很快会重连）
            applyDevices([:], removesMissingDeviceHosts: false)
        }
    }

    private func applyDevices(_ devices: [Int: ViewScopeUSBDevice], removesMissingDeviceHosts: Bool) {
        let previousSerials = Set(devicesByID.values.map(\.serial))
        devicesByID = devices
        let currentSerials = Set(devices.values.map(\.serial))

        if removesMissingDeviceHosts {
            // 设备已拔出：其上的宿主不可达，立即移除
            var changed = false
            for serial in previousSerials.subtracting(currentSerials) {
                if registry.removeAnnouncements(onDeviceSerial: serial) {
                    changed = true
                }
            }
            if changed {
                publishAnnouncements()
            }
        }
        publishUSBDevices()
        reconcileDeviceScanners()
    }

    /// 同一台设备可能同时以 USB 与 Network 出现，只扫描其中一条（优先 USB）。
    private func scanTargetDeviceIDs() -> Set<Int> {
        var preferredBySerial: [String: ViewScopeUSBDevice] = [:]
        for device in devicesByID.values.sorted(by: { $0.deviceID < $1.deviceID }) {
            if let existing = preferredBySerial[device.serial] {
                if existing.isNetwork && device.isNetwork == false {
                    preferredBySerial[device.serial] = device
                }
            } else {
                preferredBySerial[device.serial] = device
            }
        }
        return Set(preferredBySerial.values.map(\.deviceID))
    }

    private func reconcileDeviceScanners() {
        let targets = scanTargetDeviceIDs()
        for (deviceID, task) in deviceScanTasks where targets.contains(deviceID) == false {
            task.cancel()
            deviceScanTasks.removeValue(forKey: deviceID)
        }
        let interval = configuration.usbScanInterval
        for deviceID in targets where deviceScanTasks[deviceID] == nil {
            deviceScanTasks[deviceID] = Task { [weak self] in
                while Task.isCancelled == false {
                    if let owner = self {
                        await owner.performUSBScan(deviceID: deviceID)
                    } else {
                        return
                    }
                    try? await Task.sleep(nanoseconds: Self.nanoseconds(interval))
                }
            }
        }
    }

    /// 对一台设备扫描整个端口段（限制并发）；同一设备上一轮未结束时跳过。
    func performUSBScan(deviceID: Int) async {
        guard let device = devicesByID[deviceID], deviceIDsScanning.contains(deviceID) == false else {
            return
        }
        deviceIDsScanning.insert(deviceID)
        let scanGeneration = generation
        let probe = configuration.usbProbe
        let timeout = configuration.probeTimeout
        let concurrency = max(configuration.usbProbeConcurrency, 1)
        let ports = Array(configuration.portRange)

        let results = await withTaskGroup(of: (UInt16, ViewScopeHostAnnouncement?).self) { group in
            var iterator = ports.makeIterator()
            for _ in 0..<concurrency {
                if let port = iterator.next() {
                    group.addTask {
                        (port, await probe(device, port, timeout))
                    }
                }
            }
            var collected: [(UInt16, ViewScopeHostAnnouncement?)] = []
            while let result = await group.next() {
                collected.append(result)
                if let port = iterator.next() {
                    group.addTask {
                        (port, await probe(device, port, timeout))
                    }
                }
            }
            return collected
        }

        guard scanGeneration == generation else {
            return
        }
        deviceIDsScanning.remove(deviceID)
        guard devicesByID[deviceID] != nil else {
            // 扫描期间设备已拔出
            return
        }

        let now = Date()
        var changed = false
        var namesChanged = false
        for (port, announcement) in results {
            guard let announcement else {
                continue
            }
            let rewritten = Self.rewriteForUSB(announcement, device: device, port: port)
            if registry.record(rewritten, at: now) {
                changed = true
            }
            if let deviceName = announcement.deviceName, deviceName.isEmpty == false,
               deviceNamesBySerial[device.serial] != deviceName {
                deviceNamesBySerial[device.serial] = deviceName
                namesChanged = true
            }
        }
        if changed {
            publishAnnouncements()
        }
        if namesChanged {
            publishUSBDevices()
        }
    }

    /// usb 宿主的 identifier 加上设备序列号前缀，并填写 usbmux 到达方式。
    static func rewriteForUSB(_ announcement: ViewScopeHostAnnouncement, device: ViewScopeUSBDevice, port: UInt16) -> ViewScopeHostAnnouncement {
        var rewritten = announcement
        rewritten.identifier = "\(device.serial)|\(announcement.identifier)"
        rewritten.port = port
        rewritten.transport = ViewScopeHostTransport(
            kind: .usbmux,
            deviceID: device.deviceID,
            deviceSerial: device.serial,
            connectionType: device.connectionType
        )
        return rewritten
    }

    // MARK: - 发布

    /// 记录一条 announcement（测试与通知来源共用）。
    func record(_ announcement: ViewScopeHostAnnouncement, at date: Date) {
        if registry.record(announcement, at: date) {
            publishAnnouncements()
        }
    }

    private func publishAnnouncements() {
        let sorted = registry.sortedAnnouncements
        if sorted != announcements {
            announcements = sorted
        }
    }

    private func publishUSBDevices() {
        let devices = devicesByID.values.map { device -> ViewScopeUSBDevice in
            var resolved = device
            if resolved.name == nil || resolved.name?.isEmpty == true {
                resolved.name = deviceNamesBySerial[device.serial]
            }
            return resolved
        }
        .sorted { left, right in
            let nameOrder = left.displayName.localizedCaseInsensitiveCompare(right.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            if left.serial != right.serial {
                return left.serial < right.serial
            }
            return left.deviceID < right.deviceID
        }
        if devices != usbDevices {
            usbDevices = devices
        }
    }

    private nonisolated static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(interval, 0) * 1_000_000_000)
    }
}
