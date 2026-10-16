import Foundation
import ViewScopeServer
@testable import ViewScope

/// 连接相关测试的公共构造器。
enum ConnectionTestFixtures {
    static func announcement(
        identifier: String = "host-1",
        displayName: String = "Host",
        port: UInt16 = 47300,
        protocolVersion: Int = 3,
        platform: ViewScopePlatform? = nil,
        deviceName: String? = nil,
        processIdentifier: Int32 = 100,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000),
        transport: ViewScopeHostTransport? = nil
    ) -> ViewScopeHostAnnouncement {
        ViewScopeHostAnnouncement(
            identifier: identifier,
            authToken: "token",
            displayName: displayName,
            bundleIdentifier: "cn.vanjay.\(identifier)",
            version: "1.0",
            build: "1",
            processIdentifier: processIdentifier,
            port: port,
            updatedAt: updatedAt,
            supportsHighlighting: true,
            protocolVersion: protocolVersion,
            runtimeVersion: "1.3.0",
            platform: platform,
            deviceName: deviceName,
            transport: transport
        )
    }

    static func hostInfo(protocolVersion: Int?) -> ViewScopeHostInfo {
        ViewScopeHostInfo(
            displayName: "Host",
            bundleIdentifier: "cn.vanjay.host",
            version: "1.0",
            build: "1",
            processIdentifier: 100,
            runtimeVersion: "1.3.0",
            supportsHighlighting: true,
            protocolVersion: protocolVersion
        )
    }

    static func detail(nodeID: String) -> ViewScopeNodeDetailPayload {
        ViewScopeNodeDetailPayload(
            nodeID: nodeID,
            host: hostInfo(protocolVersion: 3),
            sections: [],
            constraints: [],
            ancestry: [],
            screenshotPNGBase64: nil,
            screenshotSize: .zero,
            highlightedRect: .zero
        )
    }

    static func target() -> ViewScopeRemoteObjectReference {
        ViewScopeRemoteObjectReference(captureID: "capture", objectID: "view-0x1", kind: .view, className: "NSView")
    }
}

/// 可编程的假 transport：记录发出的消息，并允许测试注入任意事件。
final class FakeByteTransport: ViewScopeByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var eventHandler: (@Sendable (ViewScopeTransportEvent) -> Void)?
    private var sent: [ViewScopeMessage] = []
    private var cancelled = 0
    private let autoReady: Bool
    /// 每发出一条消息时调用（在调用 send 的线程上）。
    var responder: (@Sendable (ViewScopeMessage, FakeByteTransport) -> Void)?

    init(autoReady: Bool = true) {
        self.autoReady = autoReady
    }

    var sentMessages: [ViewScopeMessage] {
        lock.withLock {
            sent
        }
    }

    var cancelCount: Int {
        lock.withLock {
            cancelled
        }
    }

    func start(eventHandler: @escaping @Sendable (ViewScopeTransportEvent) -> Void) {
        lock.withLock {
            self.eventHandler = eventHandler
        }
        if autoReady {
            eventHandler(.ready)
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        var line = data
        if line.last == 0x0A {
            line.removeLast()
        }
        let decoder = ViewScopeConnectionCoding.makeDecoder()
        guard let message = try? decoder.decode(ViewScopeMessage.self, from: line) else {
            completion(ViewScopeTransportError.notConnected)
            return
        }
        lock.withLock {
            sent.append(message)
        }
        completion(nil)
        responder?(message, self)
    }

    func cancel() {
        lock.withLock {
            cancelled += 1
            eventHandler = nil
        }
    }

    // MARK: - 注入事件

    func emit(_ event: ViewScopeTransportEvent) {
        let handler = lock.withLock {
            eventHandler
        }
        handler?(event)
    }

    func deliver(_ message: ViewScopeMessage) {
        let encoder = ViewScopeConnectionCoding.makeEncoder()
        guard let data = try? ViewScopeConnectionCoding.encodeLine(message, encoder: encoder) else {
            return
        }
        emit(.data(data))
    }

    func deliverRaw(_ string: String) {
        emit(.data(Data(string.utf8)))
    }
}

/// 轮询等待条件成立（让出主线程，使 DispatchQueue.main 上的回调得以执行）。
@MainActor
func connectionTestWait(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
