import Darwin
import Foundation

/// 设备监听事件。
nonisolated enum ViewScopeUSBDeviceMonitorEvent: Sendable {
    /// ListDevices 返回的完整设备列表（每次（重新）连接 usbmuxd 时发送）。
    case deviceList([ViewScopeUSBDevice])
    case attached(ViewScopeUSBDevice)
    case detached(deviceID: Int)
    /// 与 usbmuxd 的监听连接断开，调用方应清空设备列表；监听器会自动重试。
    case connectionLost
}

/// 设备监听抽象，便于测试时注入假实现。
nonisolated protocol ViewScopeUSBDeviceMonitoring: AnyObject, Sendable {
    /// 事件在监听器内部串行队列上回调。
    func start(eventHandler: @escaping @Sendable (ViewScopeUSBDeviceMonitorEvent) -> Void)
    func stop()
}

/// 通过 usbmuxd `Listen` 持久连接监听设备接入/拔出；失败时每隔 retryInterval 重试。
nonisolated final class ViewScopeUSBMuxDeviceMonitor: ViewScopeUSBDeviceMonitoring, @unchecked Sendable {
    private static let readLength = 64 * 1024

    private let socketPath: String
    private let retryInterval: TimeInterval
    private let requestTimeout: TimeInterval
    private let queue = DispatchQueue(label: "cn.vanjay.ViewScope.usbmux-monitor", qos: .utility)

    /// 以下状态只在 queue 上访问。
    private var eventHandler: (@Sendable (ViewScopeUSBDeviceMonitorEvent) -> Void)?
    private var isRunning = false
    /// 每次 stop / 重连递增，用于丢弃过期的重试。
    private var generation: UInt64 = 0
    private var readSource: (any DispatchSourceRead)?
    private var listenDescriptor: Int32 = -1
    private var framer = ViewScopeUSBMuxPacketFramer()

    init(
        socketPath: String = ViewScopeUSBMuxPacket.defaultSocketPath,
        retryInterval: TimeInterval = 5,
        requestTimeout: TimeInterval = 5
    ) {
        self.socketPath = socketPath
        self.retryInterval = retryInterval
        self.requestTimeout = requestTimeout
    }

    func start(eventHandler: @escaping @Sendable (ViewScopeUSBDeviceMonitorEvent) -> Void) {
        queue.async { [self] in
            guard isRunning == false else {
                return
            }
            isRunning = true
            generation &+= 1
            self.eventHandler = eventHandler
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            isRunning = false
            generation &+= 1
            eventHandler = nil
            tearDownListenConnection()
        }
    }

    // MARK: - 私有

    private func connect() {
        guard isRunning else {
            return
        }
        do {
            // 先取一次完整列表，再建立 Listen 长连接
            let devices = try ViewScopeUSBMuxSocket.listDevices(path: socketPath, timeout: requestTimeout)
            eventHandler?(.deviceList(devices))

            let descriptor = try ViewScopeUSBMuxSocket.open(path: socketPath, timeout: requestTimeout)
            do {
                try ViewScopeUSBMuxSocket.performResultRequest(
                    fd: descriptor,
                    payload: ViewScopeUSBMuxPacket.listenPayload(),
                    tag: 1
                )
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            ViewScopeUSBMuxSocket.setTimeout(fd: descriptor, timeout: 0)
            ViewScopeUSBMuxSocket.setNonBlocking(fd: descriptor)

            framer = ViewScopeUSBMuxPacketFramer()
            listenDescriptor = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in
                self?.readAvailableBytes()
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            readSource = source
            source.resume()
        } catch {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        let expectedGeneration = generation
        queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
            guard let self else {
                return
            }
            guard self.isRunning, self.generation == expectedGeneration else {
                return
            }
            self.connect()
        }
    }

    private func readAvailableBytes() {
        guard listenDescriptor >= 0 else {
            return
        }
        var buffer = Data(count: Self.readLength)
        let descriptor = listenDescriptor
        let result = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else {
                return 0
            }
            return Darwin.read(descriptor, base, Self.readLength)
        }
        if result < 0 {
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK || code == EINTR {
                return
            }
            handleConnectionLost()
            return
        }
        if result == 0 {
            handleConnectionLost()
            return
        }
        buffer.count = result
        do {
            let packets = try framer.append(buffer)
            for packet in packets {
                handle(payload: packet.payload)
            }
        } catch {
            handleConnectionLost()
        }
    }

    private func handle(payload: [String: Any]) {
        guard let messageType = payload["MessageType"] as? String else {
            return
        }
        switch messageType {
        case "Attached":
            if let device = ViewScopeUSBMuxPacket.device(from: payload) {
                eventHandler?(.attached(device))
            }
        case "Detached":
            if let deviceID = ViewScopeUSBMuxPacket.detachedDeviceID(from: payload) {
                eventHandler?(.detached(deviceID: deviceID))
            }
        default:
            // Paired 等其他消息忽略
            break
        }
    }

    private func handleConnectionLost() {
        tearDownListenConnection()
        eventHandler?(.connectionLost)
        generation &+= 1
        scheduleRetry()
    }

    private func tearDownListenConnection() {
        listenDescriptor = -1
        if let source = readSource {
            readSource = nil
            // cancel handler 负责关闭 fd
            source.cancel()
        }
    }
}
