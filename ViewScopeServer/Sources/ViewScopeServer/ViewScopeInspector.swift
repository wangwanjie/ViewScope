import AppKit
import Foundation
import Network
import Security

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

@_cdecl("ViewScopeInspectorPerformAutomaticStart")
func ViewScopeInspectorPerformAutomaticStart() {
    Task { @MainActor in
        ViewScopeInspector.performAutomaticStartIfNeededForBootstrap()
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
        guard automaticStartEnabled else { return }
        automaticStartEnabled = false
        startHandler(.init())
    }

    static func reset() {
        automaticStartEnabled = true
        startHandler = defaultStartHandler
    }
}

@MainActor
/// Manages the listener, active connection, discovery announcements, and live mutations.
private final class Inspector {
    static let shared = Inspector()

    private var configuration = ViewScopeInspector.Configuration()
    private var listener: NWListener?
    private var activeConnection: ViewScopeServerConnection?
    private var overlayController: ViewScopeOverlayController?
    private var heartbeatTimer: Timer?
    private var announcement: ViewScopeHostAnnouncement?
    private var lastReferenceContext = ViewScopeSnapshotBuilder.ReferenceContext(nodeReferences: [:], rootNodeIDs: [])
    private var clientInterfaceLanguage = ViewScopeInterfaceLanguage.english
    private var discoveryRequestObserver: NSObjectProtocol?

    private init() {}

    func start(configuration: ViewScopeInspector.Configuration) {
        guard shouldStartServer(allowInReleaseBuilds: configuration.allowInReleaseBuilds) else { return }
        guard listener == nil else { return }
        self.configuration = configuration

        if isSandboxedHost() {
            NSLog("ViewScopeServer warning: this host is sandboxed. The current discovery flow uses DistributedNotificationCenter only, so disable App Sandbox for the Debug configuration if you want it to appear in Live Hosts.")
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection: connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handle(listenerState: state, listener: listener)
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            discoveryRequestObserver = DistributedNotificationCenter.default().addObserver(
                forName: viewScopeDiscoveryRequestNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let announcement = self.announcement else { return }
                    self.publish(announcement: announcement)
                }
            }
        } catch {
            NSLog("ViewScopeServer failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
        overlayController?.hide()
        overlayController = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if let discoveryRequestObserver {
            DistributedNotificationCenter.default().removeObserver(discoveryRequestObserver)
            self.discoveryRequestObserver = nil
        }
        if let identifier = announcement?.identifier {
            DistributedNotificationCenter.default().postNotificationName(
                viewScopeDiscoveryTerminationNotification,
                object: nil,
                userInfo: ["identifier": identifier],
                options: [.deliverImmediately]
            )
        }
        announcement = nil
        lastReferenceContext = .init(nodeReferences: [:], rootNodeIDs: [])
        clientInterfaceLanguage = .english
    }

    private func shouldStartServer(allowInReleaseBuilds: Bool) -> Bool {
        #if DEBUG
        return true
        #else
        return allowInReleaseBuilds || ProcessInfo.processInfo.environment["VIEWSCOPE_SERVER_ENABLE_IN_RELEASE"] == "1"
        #endif
    }

    private func isSandboxedHost() -> Bool {
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

    private func handle(listenerState state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            guard let port = listener.port else { return }
            let announcement = makeAnnouncement(port: port)
            self.announcement = announcement
            publish(announcement: announcement)
            startHeartbeat()
        case .failed(let error):
            NSLog("ViewScopeServer listener failed: \(error.localizedDescription)")
            stop()
        default:
            break
        }
    }

    private func makeAnnouncement(port: NWEndpoint.Port) -> ViewScopeHostAnnouncement {
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
            port: port.rawValue,
            updatedAt: Date(),
            supportsHighlighting: true,
            protocolVersion: viewScopeCurrentProtocolVersion,
            runtimeVersion: viewScopeServerRuntimeVersion
        )
    }

    private func publish(announcement: ViewScopeHostAnnouncement) {
        guard let data = try? JSONEncoder.viewScope.encode(announcement),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            viewScopeDiscoveryAnnouncementNotification,
            object: nil,
            userInfo: ["payload": json],
            options: [.deliverImmediately]
        )
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: configuration.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, var announcement = self.announcement else { return }
                announcement.updatedAt = Date()
                self.announcement = announcement
                self.publish(announcement: announcement)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func accept(connection: NWConnection) {
        activeConnection?.cancel()
        let wrapped = ViewScopeServerConnection(
            connection: connection,
            onMessage: { [weak self] message in
                self?.handle(message: message)
            },
            onDisconnect: { [weak self] in
                self?.activeConnection = nil
            }
        )
        activeConnection = wrapped
        wrapped.start()
    }

    private func handle(message: ViewScopeMessage) {
        switch message.kind {
        case .clientHello:
            handleClientHello(message)
        case .captureRequest:
            handleCaptureRequest(message)
        case .nodeDetailRequest:
            handleNodeDetailRequest(message)
        case .highlightRequest:
            handleHighlightRequest(message)
        case .mutationRequest:
            handleMutationRequest(message)
        default:
            break
        }
    }

    private func handleClientHello(_ message: ViewScopeMessage) {
        guard let hello = message.clientHello,
              let announcement,
              hello.authToken == announcement.authToken,
              hello.protocolVersion == viewScopeCurrentProtocolVersion else {
            activeConnection?.send(
                ViewScopeMessage(
                    kind: .error,
                    requestID: message.requestID,
                    error: ViewScopeErrorPayload(message: "Handshake rejected.")
                )
            )
            activeConnection?.cancel()
            activeConnection = nil
            return
        }

        clientInterfaceLanguage = ViewScopeInterfaceLanguage(identifier: hello.preferredLanguage)

        activeConnection?.send(
            ViewScopeMessage(
                kind: .serverHello,
                requestID: message.requestID,
                serverHello: ViewScopeServerHelloPayload(
                    host: hostInfo(from: announcement),
                    protocolVersion: viewScopeCurrentProtocolVersion
                )
            )
        )
    }

    private func handleCaptureRequest(_ message: ViewScopeMessage) {
        guard let announcement else { return }
        let builder = ViewScopeSnapshotBuilder(hostInfo: hostInfo(from: announcement), interfaceLanguage: clientInterfaceLanguage)
        let (capture, context) = builder.makeCapture()
        lastReferenceContext = context
        activeConnection?.send(
            ViewScopeMessage(kind: .captureResponse, requestID: message.requestID, capture: capture)
        )
    }

    private func handleNodeDetailRequest(_ message: ViewScopeMessage) {
        guard let announcement,
              let request = message.nodeRequest else { return }
        let builder = ViewScopeSnapshotBuilder(hostInfo: hostInfo(from: announcement), interfaceLanguage: clientInterfaceLanguage)
        guard let detail = builder.makeDetail(for: request.nodeID, in: lastReferenceContext) else {
            activeConnection?.send(
                ViewScopeMessage(
                    kind: .error,
                    requestID: message.requestID,
                    error: ViewScopeErrorPayload(message: clientInterfaceLanguage.text("server.error.selected_node_gone"))
                )
            )
            return
        }
        activeConnection?.send(
            ViewScopeMessage(kind: .nodeDetailResponse, requestID: message.requestID, nodeDetail: detail)
        )
    }

    private func handleHighlightRequest(_ message: ViewScopeMessage) {
        guard let request = message.highlightRequest,
              let reference = lastReferenceContext.nodeReferences[request.nodeID] else {
            activeConnection?.send(ViewScopeMessage(kind: .ack, requestID: message.requestID, ack: ViewScopeAckPayload()))
            return
        }

        if overlayController == nil {
            overlayController = ViewScopeOverlayController()
        }

        switch reference {
        case .window(let window):
            if let contentView = window.contentView {
                overlayController?.show(highlight: contentView.bounds, in: window, duration: request.duration)
            }
        case .view(let view):
            if let window = view.window {
                let rect = view.convert(view.bounds, to: nil)
                overlayController?.show(highlight: rect, in: window, duration: request.duration)
            }
        }

        activeConnection?.send(ViewScopeMessage(kind: .ack, requestID: message.requestID, ack: ViewScopeAckPayload()))
    }

    private func handleMutationRequest(_ message: ViewScopeMessage) {
        guard let request = message.mutationRequest,
              let reference = lastReferenceContext.nodeReferences[request.nodeID] else {
            activeConnection?.send(
                ViewScopeMessage(
                    kind: .error,
                    requestID: message.requestID,
                    error: ViewScopeErrorPayload(message: clientInterfaceLanguage.text("server.error.selected_node_gone"))
                )
            )
            return
        }

        do {
            try applyMutation(request.property, to: reference)
            activeConnection?.send(
                ViewScopeMessage(kind: .ack, requestID: message.requestID, ack: ViewScopeAckPayload())
            )
        } catch let error as MutationError {
            activeConnection?.send(
                ViewScopeMessage(
                    kind: .error,
                    requestID: message.requestID,
                    error: ViewScopeErrorPayload(message: error.message(in: clientInterfaceLanguage))
                )
            )
        } catch {
            activeConnection?.send(
                ViewScopeMessage(
                    kind: .error,
                    requestID: message.requestID,
                    error: ViewScopeErrorPayload(message: error.localizedDescription)
                )
            )
        }
    }

    private func applyMutation(_ property: ViewScopeEditableProperty, to reference: ViewScopeInspectableReference) throws {
        switch reference {
        case .window(let window):
            try applyMutation(property, to: window)
        case .view(let view):
            try applyMutation(property, to: view)
        }
    }

    private func applyMutation(_ property: ViewScopeEditableProperty, to window: NSWindow) throws {
        switch property.key {
        case "title":
            guard let value = property.textValue else {
                throw MutationError.invalidValue
            }
            window.title = value
        case "alpha":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            window.alphaValue = CGFloat(max(0, min(1, value)))
        case "frame.x":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateWindowFrame(window, x: value)
        case "frame.y":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateWindowFrame(window, y: value)
        case "frame.width":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateWindowFrame(window, width: value)
        case "frame.height":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateWindowFrame(window, height: value)
        default:
            throw MutationError.unsupportedProperty
        }
    }

    private func applyMutation(_ property: ViewScopeEditableProperty, to view: NSView) throws {
        switch property.key {
        case "hidden":
            guard let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            view.isHidden = value
        case "alpha":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            view.alphaValue = CGFloat(max(0, min(1, value)))
        case "frame.x":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateViewFrame(view, x: value)
        case "frame.y":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateViewFrame(view, y: value)
        case "frame.width":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateViewFrame(view, width: value)
        case "frame.height":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateViewFrame(view, height: value)
        case "bounds.x":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateViewBounds(view, x: value)
        case "bounds.y":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateViewBounds(view, y: value)
        case "bounds.width":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateViewBounds(view, width: value)
        case "bounds.height":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateViewBounds(view, height: value)
        case "contentInsets.top":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateScrollViewInsets(view, top: value)
        case "contentInsets.left":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateScrollViewInsets(view, left: value)
        case "contentInsets.bottom":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateScrollViewInsets(view, bottom: value)
        case "contentInsets.right":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateScrollViewInsets(view, right: value)
        case "backgroundColor":
            guard let value = property.textValue else {
                throw MutationError.invalidValue
            }
            try mutateBackgroundColor(view, hexString: value)
        case "control.value":
            guard let value = property.textValue else {
                throw MutationError.invalidValue
            }
            try applyControlValue(value, to: view)
        default:
            throw MutationError.unsupportedProperty
        }
    }

    private func mutateWindowFrame(
        _ window: NSWindow,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) throws {
        var frame = window.frame
        if let x {
            frame.origin.x = CGFloat(x)
        }
        if let y {
            frame.origin.y = CGFloat(y)
        }
        if let width {
            frame.size.width = CGFloat(max(0, width))
        }
        if let height {
            frame.size.height = CGFloat(max(0, height))
        }
        guard frame.width >= 0, frame.height >= 0 else {
            throw MutationError.invalidValue
        }
        window.setFrame(frame, display: true)
    }

    private func mutateViewFrame(
        _ view: NSView,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) throws {
        var frame = view.frame
        if let x {
            frame.origin.x = CGFloat(x)
        }
        if let y {
            frame.origin.y = CGFloat(y)
        }
        if let width {
            frame.size.width = CGFloat(max(0, width))
        }
        if let height {
            frame.size.height = CGFloat(max(0, height))
        }
        guard frame.width >= 0, frame.height >= 0 else {
            throw MutationError.invalidValue
        }
        view.frame = frame
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.superview?.needsLayout = true
        view.superview?.layoutSubtreeIfNeeded()
    }

    private func mutateViewBounds(
        _ view: NSView,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) throws {
        var bounds = view.bounds
        if let x {
            bounds.origin.x = CGFloat(x)
        }
        if let y {
            bounds.origin.y = CGFloat(y)
        }
        if let width {
            bounds.size.width = CGFloat(max(0, width))
        }
        if let height {
            bounds.size.height = CGFloat(max(0, height))
        }
        guard bounds.width >= 0, bounds.height >= 0 else {
            throw MutationError.invalidValue
        }
        view.bounds = bounds
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private func mutateScrollViewInsets(
        _ view: NSView,
        top: Double? = nil,
        left: Double? = nil,
        bottom: Double? = nil,
        right: Double? = nil
    ) throws {
        guard let scrollView = view as? NSScrollView else {
            throw MutationError.unsupportedProperty
        }
        var insets = scrollView.contentInsets
        if let top {
            insets.top = CGFloat(top)
        }
        if let left {
            insets.left = CGFloat(left)
        }
        if let bottom {
            insets.bottom = CGFloat(bottom)
        }
        if let right {
            insets.right = CGFloat(right)
        }
        scrollView.contentInsets = insets
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()
    }

    private func mutateBackgroundColor(_ view: NSView, hexString: String) throws {
        guard let color = NSColor(viewScopeHexString: hexString) else {
            throw MutationError.invalidValue
        }
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.needsDisplay = true
    }

    private func applyControlValue(_ value: String, to view: NSView) throws {
        if let button = view as? NSButton {
            button.title = value
            return
        }
        if let textField = view as? NSTextField {
            textField.stringValue = value
            return
        }
        if let control = view as? NSControl {
            control.stringValue = value
            return
        }
        throw MutationError.unsupportedProperty
    }

    private func hostInfo(from announcement: ViewScopeHostAnnouncement) -> ViewScopeHostInfo {
        ViewScopeHostInfo(
            displayName: announcement.displayName,
            bundleIdentifier: announcement.bundleIdentifier,
            version: announcement.version,
            build: announcement.build,
            processIdentifier: announcement.processIdentifier,
            runtimeVersion: announcement.runtimeVersion,
            supportsHighlighting: announcement.supportsHighlighting
        )
    }
}

private enum MutationError: Error {
    case unsupportedProperty
    case invalidValue

    func message(in language: ViewScopeInterfaceLanguage) -> String {
        switch self {
        case .unsupportedProperty:
            return language.text("server.error.unsupported_mutation")
        case .invalidValue:
            return language.text("server.error.invalid_mutation_value")
        }
    }
}

private extension JSONEncoder {
    static var viewScope: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension NSColor {
    convenience init?(viewScopeHexString: String) {
        let sanitized = viewScopeHexString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6 || sanitized.count == 8,
              let rawValue = UInt64(sanitized, radix: 16) else {
            return nil
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        if sanitized.count == 8 {
            red = CGFloat((rawValue & 0xFF000000) >> 24) / 255
            green = CGFloat((rawValue & 0x00FF0000) >> 16) / 255
            blue = CGFloat((rawValue & 0x0000FF00) >> 8) / 255
            alpha = CGFloat(rawValue & 0x000000FF) / 255
        } else {
            red = CGFloat((rawValue & 0xFF0000) >> 16) / 255
            green = CGFloat((rawValue & 0x00FF00) >> 8) / 255
            blue = CGFloat(rawValue & 0x0000FF) / 255
            alpha = 1
        }

        self.init(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }
}
