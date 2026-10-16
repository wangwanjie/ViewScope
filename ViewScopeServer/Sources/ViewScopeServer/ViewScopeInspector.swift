import Foundation
import Network

/// Starts and stops the embedded inspection server inside a debug host app.
public enum ViewScopeInspector {
    @MainActor
    public static func start(configuration: Configuration = .init()) {
        ViewScopeInspectorLifecycle.startManually(configuration: configuration)
    }

    @MainActor
    public static func disableAutomaticStart() {
        ViewScopeInspectorLifecycle.disableAutomaticStart()
    }

    @MainActor
    public static func stop() {
        Inspector.shared.stop()
    }

    public struct Configuration: Sendable {
        public var displayName: String?
        public var allowInReleaseBuilds: Bool
        public var heartbeatInterval: TimeInterval
        public var highlightDuration: TimeInterval

        public init(
            displayName: String? = nil,
            allowInReleaseBuilds: Bool = false,
            heartbeatInterval: TimeInterval = 2,
            highlightDuration: TimeInterval = 1.25
        ) {
            self.displayName = displayName
            self.allowInReleaseBuilds = allowInReleaseBuilds
            self.heartbeatInterval = heartbeatInterval
            self.highlightDuration = highlightDuration
        }
    }

    @MainActor
    static func performAutomaticStartIfNeededForBootstrap() {
        ViewScopeInspectorLifecycle.performAutomaticStartIfNeeded()
    }

    @MainActor
    static var isAutomaticStartEnabledForTesting: Bool {
        ViewScopeInspectorLifecycle.automaticStartEnabled
    }

    @MainActor
    static func performAutomaticStartIfNeededForTesting() {
        ViewScopeInspectorLifecycle.performAutomaticStartIfNeeded()
    }

    @MainActor
    static func setStartHandlerForTesting(_ handler: @escaping (Configuration) -> Void) {
        ViewScopeInspectorLifecycle.startHandler = handler
    }

    @MainActor
    static func resetLifecycleStateForTesting() {
        Inspector.shared.stop()
        ViewScopeInspectorLifecycle.reset()
    }
}

@objc(ViewScopeAutomaticStartBridge)
public final class ViewScopeAutomaticStartBridge: NSObject {
    @objc public static func performAutomaticStart() {
        Task { @MainActor in
            ViewScopeInspector.performAutomaticStartIfNeededForBootstrap()
        }
    }
}

@MainActor
private enum ViewScopeInspectorLifecycle {
    private static let defaultStartHandler: (ViewScopeInspector.Configuration) -> Void = { configuration in
        Inspector.shared.start(configuration: configuration)
    }

    static var automaticStartEnabled = true
    static var startHandler: (ViewScopeInspector.Configuration) -> Void = defaultStartHandler

    static func startManually(configuration: ViewScopeInspector.Configuration) {
        automaticStartEnabled = false
        startHandler(configuration)
    }

    static func disableAutomaticStart() {
        automaticStartEnabled = false
    }

    static func performAutomaticStartIfNeeded() {
        guard automaticStartEnabled else {
            return
        }
        automaticStartEnabled = false
        startHandler(.init())
    }

    static func reset() {
        automaticStartEnabled = true
        startHandler = defaultStartHandler
    }
}

/// 高亮浮层登记处：Inspector 创建浮层后登记，抓取时据此排除浮层窗口/视图（B5）。
///
/// 平台的 SnapshotBuilder 在遍历窗口/视图时调用 `isOverlayObject(_:)` 过滤。
@MainActor
enum ViewScopeOverlayRegistry {
    static weak var activeOverlay: ViewScopeHighlightOverlay?

    static func isOverlayObject(_ object: AnyObject) -> Bool {
        activeOverlay?.isOverlayObject(object) ?? false
    }
}

@MainActor
/// 管理监听、连接/认证、发现与消息分发。平台相关的工作全部委托给平台目录中的类型。
final class Inspector {
    static let shared = Inspector()

    private(set) var configuration = ViewScopeInspector.Configuration()
    private var portListener: ViewScopePortRangeListener?
    /// 所有存活连接（含未认证的探测连接）。
    private var connections: [ObjectIdentifier: ViewScopeServerConnection] = [:]
    /// 当前已认证会话。新连接只有在认证成功后才会替换它（§4.2）。
    private(set) weak var activeSession: (any ViewScopeMessageChannel)?
    private var overlay: ViewScopeHighlightOverlay?
    private var heartbeatTimer: Timer?
    private(set) var announcement: ViewScopeHostAnnouncement?
    private(set) var lastReferenceContext = ViewScopeSnapshotBuilder.ReferenceContext(nodeReferences: [:], rootNodeIDs: [], captureID: "")
    let consoleEvaluator = ViewScopeConsoleEvaluator()
    #if os(macOS)
    private var discoveryRequestObserver: NSObjectProtocol?
    #endif

    init() {}

    // MARK: - 生命周期

    func start(configuration: ViewScopeInspector.Configuration) {
        guard shouldStartServer(allowInReleaseBuilds: configuration.allowInReleaseBuilds) else {
            return
        }
        guard portListener == nil else {
            return
        }
        self.configuration = configuration

        if ViewScopePlatformRuntime.isSandboxed() {
            NSLog("ViewScopeServer warning: this host is sandboxed. Enable the com.apple.security.network.server entitlement for the Debug configuration so ViewScope can discover it by port scanning; DistributedNotificationCenter discovery is blocked by the sandbox.")
        }

        let listener = ViewScopePortRangeListener(
            ports: viewScopeHostPortRange,
            fallback: ViewScopePlatformRuntime.supportsDistributedDiscovery ? .anyLoopbackPort : .none,
            newConnectionHandler: { [weak self] connection in
                self?.accept(connection: connection)
            },
            onReady: { [weak self] port in
                self?.listenerDidBecomeReady(port: port)
            },
            onFailure: { [weak self] in
                self?.stop()
            }
        )
        portListener = listener
        listener.start()

        #if os(macOS)
        if ViewScopePlatformRuntime.supportsDistributedDiscovery {
            discoveryRequestObserver = DistributedNotificationCenter.default().addObserver(
                forName: viewScopeDiscoveryRequestNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let announcement = self.announcement else {
                        return
                    }
                    self.publish(announcement: announcement)
                }
            }
        }
        #endif
    }

    func stop() {
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        activeSession = nil
        portListener?.cancel()
        portListener = nil
        overlay?.hide()
        overlay = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        #if os(macOS)
        if let discoveryRequestObserver {
            DistributedNotificationCenter.default().removeObserver(discoveryRequestObserver)
            self.discoveryRequestObserver = nil
        }
        if let identifier = announcement?.identifier, ViewScopePlatformRuntime.supportsDistributedDiscovery {
            DistributedNotificationCenter.default().postNotificationName(
                viewScopeDiscoveryTerminationNotification,
                object: nil,
                userInfo: ["identifier": identifier],
                options: [.deliverImmediately]
            )
        }
        #endif
        announcement = nil
        lastReferenceContext = .init(nodeReferences: [:], rootNodeIDs: [], captureID: "")
        consoleEvaluator.reset()
    }

    private func shouldStartServer(allowInReleaseBuilds: Bool) -> Bool {
        #if DEBUG
        return true
        #else
        return allowInReleaseBuilds || ProcessInfo.processInfo.environment["VIEWSCOPE_SERVER_ENABLE_IN_RELEASE"] == "1"
        #endif
    }

    private func listenerDidBecomeReady(port: UInt16) {
        let announcement = makeAnnouncement(port: port)
        self.announcement = announcement
        publish(announcement: announcement)
        startHeartbeat()
    }

    /// 测试用：直接注入 announcement，跳过监听。
    func configureForTesting(announcement: ViewScopeHostAnnouncement) {
        self.announcement = announcement
    }

    /// 测试用：注入抓取上下文。
    func setReferenceContextForTesting(_ context: ViewScopeSnapshotBuilder.ReferenceContext) {
        lastReferenceContext = context
    }

    func makeAnnouncement(port: UInt16) -> ViewScopeHostAnnouncement {
        let bundle = Bundle.main
        let displayName = configuration.displayName
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        let bundleIdentifier = bundle.bundleIdentifier ?? "unknown.bundle"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let identifier = "\(bundleIdentifier)-\(ProcessInfo.processInfo.processIdentifier)"
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return ViewScopeHostAnnouncement(
            identifier: identifier,
            authToken: token,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            port: port,
            updatedAt: Date(),
            supportsHighlighting: true,
            protocolVersion: viewScopeCurrentProtocolVersion,
            runtimeVersion: viewScopeServerRuntimeVersion,
            platform: ViewScopePlatformRuntime.platform,
            osVersion: ViewScopePlatformRuntime.osVersion,
            deviceName: ViewScopePlatformRuntime.deviceName,
            deviceModel: ViewScopePlatformRuntime.deviceModel,
            isSimulator: ViewScopePlatformRuntime.isSimulator,
            screenScale: ViewScopePlatformRuntime.screenScale
        )
    }

    private func publish(announcement: ViewScopeHostAnnouncement) {
        #if os(macOS)
        guard ViewScopePlatformRuntime.supportsDistributedDiscovery else {
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(announcement),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            viewScopeDiscoveryAnnouncementNotification,
            object: nil,
            userInfo: ["payload": json],
            options: [.deliverImmediately]
        )
        #endif
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        // 只有支持分布式通知的平台需要定期广播；端口扫描发现不依赖心跳。
        guard ViewScopePlatformRuntime.supportsDistributedDiscovery else {
            return
        }
        let interval = configuration.heartbeatInterval.isFinite ? max(configuration.heartbeatInterval, 0.5) : 2
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, var announcement = self.announcement else {
                    return
                }
                announcement.updatedAt = Date()
                self.announcement = announcement
                self.publish(announcement: announcement)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    // MARK: - 连接

    private func accept(connection: NWConnection) {
        // 新连接不会踢掉已认证会话；它要么只是探测（discovery/ping），要么认证成功后再替换旧会话。
        let wrapped = ViewScopeServerConnection(
            connection: connection,
            onMessage: { [weak self] message, connection in
                self?.handle(message: message, from: connection)
            },
            onDisconnect: { [weak self] connection in
                self?.connectionDidDisconnect(connection)
            }
        )
        connections[ObjectIdentifier(wrapped)] = wrapped
        wrapped.start()
    }

    private func connectionDidDisconnect(_ connection: ViewScopeServerConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        // 只有断开的正是当前会话时才清空（A2）。
        if activeSession === connection {
            sessionDidEnd()
        }
    }

    private func sessionDidEnd() {
        activeSession = nil
        overlay?.hide()
        // 释放上一个会话 console 缓存里的强引用。
        consoleEvaluator.reset()
    }

    // MARK: - 消息分发

    /// 不需要认证即可处理的消息。
    private static let unauthenticatedKinds: Set<ViewScopeMessage.Kind> = [.clientHello, .discoveryRequest, .ping]

    /// 处理一条消息，并保证带 requestID 的请求恰好得到一条响应（§4.3）。
    func handle(message: ViewScopeMessage, from channel: any ViewScopeMessageChannel) {
        guard channel.isAuthenticated || Self.unauthenticatedKinds.contains(message.kind) else {
            channel.send(errorMessage(for: message, key: "server.error.not_authenticated", language: channel.interfaceLanguage))
            return
        }

        switch message.kind {
        case .clientHello:
            handleClientHello(message, from: channel)
        case .discoveryRequest:
            handleDiscoveryRequest(message, from: channel)
        case .ping:
            channel.send(ViewScopeMessage(kind: .ack, requestID: message.requestID, ack: ViewScopeAckPayload()))
        case .captureRequest:
            handleCaptureRequest(message, from: channel)
        case .nodeDetailRequest:
            handleNodeDetailRequest(message, from: channel)
        case .highlightRequest:
            handleHighlightRequest(message, from: channel)
        case .mutationRequest:
            handleMutationRequest(message, from: channel)
        case .consoleInvokeRequest:
            handleConsoleInvokeRequest(message, from: channel)
        case .consoleCompletionRequest:
            handleConsoleCompletionRequest(message, from: channel)
        case .serverHello, .captureResponse, .nodeDetailResponse, .consoleInvokeResponse,
             .ack, .error, .discoveryResponse, .consoleCompletionResponse:
            channel.send(errorMessage(for: message, key: "server.error.unsupported_request", language: channel.interfaceLanguage))
        }
    }

    private func errorMessage(for message: ViewScopeMessage, key: String, language: ViewScopeInterfaceLanguage) -> ViewScopeMessage {
        errorMessage(for: message, text: language.text(key))
    }

    private func errorMessage(for message: ViewScopeMessage, text: String) -> ViewScopeMessage {
        ViewScopeMessage(kind: .error, requestID: message.requestID, error: ViewScopeErrorPayload(message: text))
    }

    private func handleClientHello(_ message: ViewScopeMessage, from channel: any ViewScopeMessageChannel) {
        let language = ViewScopeInterfaceLanguage(identifier: message.clientHello?.preferredLanguage)
        guard let hello = message.clientHello,
              let announcement,
              hello.authToken == announcement.authToken,
              (viewScopeMinimumSupportedProtocolVersion ... viewScopeCurrentProtocolVersion).contains(hello.protocolVersion) else {
            channel.send(errorMessage(for: message, key: "server.error.handshake_rejected", language: language))
            // 只断开这个握手失败的连接，不影响已认证会话。
            channel.cancel()
            return
        }

        channel.isAuthenticated = true
        channel.interfaceLanguage = language
        channel.negotiatedProtocolVersion = min(hello.protocolVersion, viewScopeCurrentProtocolVersion)

        // 新会话认证成功后才替换旧会话。
        if let previous = activeSession, previous !== channel {
            previous.cancel()
            overlay?.hide()
            consoleEvaluator.reset()
        }
        activeSession = channel

        channel.send(
            ViewScopeMessage(
                kind: .serverHello,
                requestID: message.requestID,
                serverHello: ViewScopeServerHelloPayload(
                    host: hostInfo(for: channel),
                    protocolVersion: channel.negotiatedProtocolVersion
                )
            )
        )
    }

    private func handleDiscoveryRequest(_ message: ViewScopeMessage, from channel: any ViewScopeMessageChannel) {
        guard var announcement else {
            channel.send(errorMessage(for: message, key: "server.error.not_ready", language: channel.interfaceLanguage))
            return
        }
        announcement.updatedAt = Date()
        channel.send(ViewScopeMessage(kind: .discoveryResponse, requestID: message.requestID, announcement: announcement))
    }

    private func handleCaptureRequest(_ message: ViewScopeMessage, from channel: any ViewScopeMessageChannel) {
        guard announcement != nil else {
            channel.send(errorMessage(for: message, key: "server.error.not_ready", language: channel.interfaceLanguage))
            return
        }
        let builder = ViewScopeSnapshotBuilder(hostInfo: hostInfo(for: channel), interfaceLanguage: channel.interfaceLanguage)
        let (capture, context) = builder.makeCapture()
        lastReferenceContext = context
        channel.send(ViewScopeMessage(kind: .captureResponse, requestID: message.requestID, capture: capture))
    }

    private func handleNodeDetailRequest(_ message: ViewScopeMessage, from channel: any ViewScopeMessageChannel) {
        guard let request = message.nodeRequest else {
            channel.send(errorMessage(for: message, key: "server.error.invalid_request", language: channel.interfaceLanguage))
            return
        }
        let builder = ViewScopeSnapshotBuilder(hostInfo: hostInfo(for: channel), interfaceLanguage: channel.interfaceLanguage)
        guard let detail = builder.makeDetail(for: request.nodeID, in: lastReferenceContext) else {
            channel.send(errorMessage(for: message, key: "server.error.selected_node_gone", language: channel.interfaceLanguage))
            return
        }
        channel.send(ViewScopeMessage(kind: .nodeDetailResponse, requestID: message.requestID, nodeDetail: detail))
    }

    private func handleHighlightRequest(_ message: ViewScopeMessage, from channel: any ViewScopeMessageChannel) {
        guard let request = message.highlightRequest else {
            channel.send(errorMessage(for: message, key: "server.error.invalid_request", language: channel.interfaceLanguage))
            return
        }
        guard let reference = lastReferenceContext.nodeReferences[request.nodeID],
              reference.resolvedObject != nil else {
            channel.send(errorMessage(for: message, key: "server.error.selected_node_gone", language: channel.interfaceLanguage))
            return
        }

        if overlay == nil {
            let newOverlay = ViewScopeHighlightOverlay()
            overlay = newOverlay
            ViewScopeOverlayRegistry.activeOverlay = newOverlay
        }
        let duration = request.duration.isFinite && request.duration > 0 ? request.duration : configuration.highlightDuration
        overlay?.show(reference: reference, duration: duration)
        channel.send(ViewScopeMessage(kind: .ack, requestID: message.requestID, ack: ViewScopeAckPayload()))
    }

    private func handleMutationRequest(_ message: ViewScopeMessage, from channel: any ViewScopeMessageChannel) {
        guard let request = message.mutationRequest else {
            channel.send(errorMessage(for: message, key: "server.error.invalid_request", language: channel.interfaceLanguage))
            return
        }
        guard let reference = lastReferenceContext.nodeReferences[request.nodeID] else {
            channel.send(errorMessage(for: message, key: "server.error.selected_node_gone", language: channel.interfaceLanguage))
            return
        }

        do {
            try ViewScopeMutationApplier.apply(request.property.valueOnly, to: reference)
            channel.send(ViewScopeMessage(kind: .ack, requestID: message.requestID, ack: ViewScopeAckPayload()))
        } catch let error as ViewScopeMutationError {
            channel.send(errorMessage(for: message, text: error.message(in: channel.interfaceLanguage)))
        } catch {
            channel.send(errorMessage(for: message, text: error.localizedDescription))
        }
    }

    private func handleConsoleInvokeRequest(_ message: ViewScopeMessage, from channel: any ViewScopeMessageChannel) {
        guard let request = message.consoleInvokeRequest else {
            channel.send(errorMessage(for: message, key: "server.error.invalid_request", language: channel.interfaceLanguage))
            return
        }
        let response = consoleEvaluator.evaluate(request, context: lastReferenceContext, language: channel.interfaceLanguage)
        channel.send(ViewScopeMessage(kind: .consoleInvokeResponse, requestID: message.requestID, consoleInvokeResponse: response))
    }

    private func handleConsoleCompletionRequest(_ message: ViewScopeMessage, from channel: any ViewScopeMessageChannel) {
        guard let request = message.consoleCompletionRequest else {
            channel.send(errorMessage(for: message, key: "server.error.invalid_request", language: channel.interfaceLanguage))
            return
        }
        guard let target = consoleEvaluator.resolveTarget(request.target, in: lastReferenceContext) else {
            channel.send(errorMessage(for: message, key: "server.console.target_not_found", language: channel.interfaceLanguage))
            return
        }
        let completions = consoleEvaluator.completions(for: target, prefix: request.prefix)
        channel.send(
            ViewScopeMessage(
                kind: .consoleCompletionResponse,
                requestID: message.requestID,
                consoleCompletionResponse: ViewScopeConsoleCompletionResponsePayload(target: request.target, completions: completions)
            )
        )
    }

    // MARK: - 宿主信息

    func hostInfo(for channel: (any ViewScopeMessageChannel)?) -> ViewScopeHostInfo {
        let negotiatedVersion = channel?.negotiatedProtocolVersion ?? viewScopeCurrentProtocolVersion
        guard let announcement else {
            return ViewScopeHostInfo(
                displayName: ProcessInfo.processInfo.processName,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown.bundle",
                version: "0",
                build: "0",
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true,
                platform: ViewScopePlatformRuntime.platform,
                osVersion: ViewScopePlatformRuntime.osVersion,
                deviceName: ViewScopePlatformRuntime.deviceName,
                deviceModel: ViewScopePlatformRuntime.deviceModel,
                isSimulator: ViewScopePlatformRuntime.isSimulator,
                screenScale: ViewScopePlatformRuntime.screenScale,
                protocolVersion: negotiatedVersion
            )
        }
        return ViewScopeHostInfo(
            displayName: announcement.displayName,
            bundleIdentifier: announcement.bundleIdentifier,
            version: announcement.version,
            build: announcement.build,
            processIdentifier: announcement.processIdentifier,
            runtimeVersion: announcement.runtimeVersion,
            supportsHighlighting: announcement.supportsHighlighting,
            platform: announcement.platform ?? ViewScopePlatformRuntime.platform,
            osVersion: announcement.osVersion ?? ViewScopePlatformRuntime.osVersion,
            deviceName: announcement.deviceName ?? ViewScopePlatformRuntime.deviceName,
            deviceModel: announcement.deviceModel ?? ViewScopePlatformRuntime.deviceModel,
            isSimulator: announcement.isSimulator ?? ViewScopePlatformRuntime.isSimulator,
            screenScale: announcement.screenScale ?? ViewScopePlatformRuntime.screenScale,
            protocolVersion: negotiatedVersion
        )
    }
}
