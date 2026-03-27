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
    private var lastReferenceContext = ViewScopeSnapshotBuilder.ReferenceContext(nodeReferences: [:], rootNodeIDs: [], captureID: "")
    private var clientInterfaceLanguage = ViewScopeInterfaceLanguage.english
    /// 缓存控制台返回的对象，以便用作后续命令的 target。
    private var consoleObjectCache: [String: AnyObject] = [:]
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
        lastReferenceContext = .init(nodeReferences: [:], rootNodeIDs: [], captureID: "")
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
        case .consoleInvokeRequest:
            handleConsoleInvokeRequest(message)
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
        case .layer(let layer):
            if let window = layer.viewScopeWindow,
               let rect = layer.viewScopeFrameInWindow {
                overlayController?.show(highlight: rect, in: window, duration: request.duration)
            }
        case .viewController(let controller):
            if let window = controller.view.window {
                let rect = controller.view.convert(controller.view.bounds, to: nil)
                overlayController?.show(highlight: rect, in: window, duration: request.duration)
            }
        case .object:
            break
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

    private func handleConsoleInvokeRequest(_ message: ViewScopeMessage) {
        guard let request = message.consoleInvokeRequest else {
            activeConnection?.send(
                ViewScopeMessage(
                    kind: .error,
                    requestID: message.requestID,
                    error: ViewScopeErrorPayload(message: "Invalid console invoke request")
                )
            )
            return
        }

        let targetObject = resolveConsoleTarget(request.target)
        guard let targetObject else {
            activeConnection?.send(
                ViewScopeMessage(
                    kind: .consoleInvokeResponse,
                    requestID: message.requestID,
                    consoleInvokeResponse: .init(
                        submittedExpression: request.expression,
                        target: request.target,
                        errorMessage: "Target object not found"
                    )
                )
            )
            return
        }

        let expression = request.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsObject = targetObject as AnyObject

        guard nsObject.responds(to: Selector(expression)) else {
            activeConnection?.send(
                ViewScopeMessage(
                    kind: .consoleInvokeResponse,
                    requestID: message.requestID,
                    consoleInvokeResponse: .init(
                        submittedExpression: request.expression,
                        target: request.target,
                        errorMessage: "Object does not respond to '\(expression)'"
                    )
                )
            )
            return
        }

        // value(forKey:) 在 key 不存在时会抛出 NSException，
        // 但 responds(to:) 已经做了前置检查，这里安全使用。
        let value = nsObject.value(forKey: expression)

        let resultDescription = describeConsoleValue(value)
        var returnedObject: ViewScopeConsoleTargetDescriptor?
        if let obj = value as AnyObject?, !(value is NSNumber), !(value is NSString), !(value is NSValue) {
            let objectID = "\(ObjectIdentifier(obj).hashValue)"
            consoleObjectCache[objectID] = obj
            returnedObject = ViewScopeConsoleTargetDescriptor(
                reference: ViewScopeRemoteObjectReference(
                    captureID: lastReferenceContext.captureID,
                    objectID: objectID,
                    kind: .returnedObject,
                    className: NSStringFromClass(type(of: obj)),
                    address: String(format: "%p", unsafeBitCast(obj, to: Int.self))
                ),
                title: String(describing: obj)
            )
        }

        activeConnection?.send(
            ViewScopeMessage(
                kind: .consoleInvokeResponse,
                requestID: message.requestID,
                consoleInvokeResponse: .init(
                    submittedExpression: request.expression,
                    target: request.target,
                    resultDescription: resultDescription,
                    returnedObject: returnedObject
                )
            )
        )
    }

    private func resolveConsoleTarget(_ ref: ViewScopeRemoteObjectReference) -> AnyObject? {
        switch ref.kind {
        case .view, .layer, .viewController, .window:
            // objectID 是内存地址，nodeReferences 以 node tree ID 为 key。
            // 优先用 sourceNodeID 查找，再用 objectID 兜底。
            let lookupID = ref.sourceNodeID ?? ref.objectID
            guard let inspectable = lastReferenceContext.nodeReferences[lookupID] else {
                return nil
            }
            switch inspectable {
            case .window(let w): return w
            case .view(let v):
                // console target kind 可能是 .viewController，但 nodeReferences 存的是 .view。
                // 此时需要找到 view 的 owning VC。
                if ref.kind == .viewController,
                   let vc = sequence(first: v.nextResponder, next: { $0?.nextResponder })
                    .compactMap({ $0 as? NSViewController }).first {
                    return vc
                }
                return v
            case .layer(let layer):
                if ref.kind == .viewController,
                   let controller = layer.viewScopeHostView?.viewScopeExactRootOwningViewController {
                    return controller
                }
                if ref.kind == .view,
                   let hostView = layer.viewScopeHostView {
                    return hostView
                }
                return layer
            case .viewController(let vc): return vc
            case .object(let o): return o
            }
        case .returnedObject:
            return consoleObjectCache[ref.objectID]
        }
    }

    private func describeConsoleValue(_ value: Any?) -> String {
        switch value {
        case nil:
            return "nil"
        case let bool as Bool:
            return bool ? "true" : "false"
        case let num as NSNumber:
            return num.stringValue
        case let str as String:
            return "\"\(str)\""
        case let val as NSValue:
            let objCType = String(cString: val.objCType)
            if objCType == "{CGRect={CGPoint=dd}{CGSize=dd}}" {
                return NSStringFromRect(val.rectValue)
            } else if objCType == "{CGPoint=dd}" {
                return NSStringFromPoint(val.pointValue)
            } else if objCType == "{CGSize=dd}" {
                return NSStringFromSize(val.sizeValue)
            }
            return val.description
        default:
            return String(describing: value!)
        }
    }

    private func applyMutation(_ property: ViewScopeEditableProperty, to reference: ViewScopeInspectableReference) throws {
        try ViewScopeMutationApplier.apply(property, to: reference)
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

@MainActor
enum ViewScopeMutationApplier {
    static func apply(_ property: ViewScopeEditableProperty, to reference: ViewScopeInspectableReference) throws {
        switch reference {
        case .window(let window):
            try apply(property, to: window)
        case .view(let view):
            try apply(property, to: view)
        case .layer(let layer):
            try apply(property, to: layer)
        case .viewController, .object:
            throw MutationError.unsupportedProperty
        }
    }

    static func apply(_ property: ViewScopeEditableProperty, to window: NSWindow) throws {
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

    static func apply(_ property: ViewScopeEditableProperty, to view: NSView) throws {
        if try applyAppKitSpecificMutation(property, to: view) {
            return
        }
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
        case "toolTip":
            guard let value = property.textValue else {
                throw MutationError.invalidValue
            }
            view.toolTip = value
        case "enabled":
            guard let control = view as? NSControl,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            control.isEnabled = value
        case "button.state":
            guard let button = view as? NSButton,
                  button.allowsMixedState == false,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            button.state = value ? .on : .off
        case "textField.placeholderString":
            guard let textField = view as? NSTextField,
                  let value = property.textValue else {
                throw MutationError.invalidValue
            }
            textField.placeholderString = value
        case "layer.cornerRadius":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            mutateLayerValue(view, cornerRadius: value)
        case "layer.borderWidth":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            mutateLayerValue(view, borderWidth: value)
        default:
            throw MutationError.unsupportedProperty
        }
    }

    static func apply(_ property: ViewScopeEditableProperty, to layer: CALayer) throws {
        switch property.key {
        case "hidden":
            guard let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            layer.isHidden = value
        case "alpha":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            layer.opacity = Float(max(0, min(1, value)))
        case "frame.x":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateLayerFrame(layer, x: value)
        case "frame.y":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateLayerFrame(layer, y: value)
        case "frame.width":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateLayerFrame(layer, width: value)
        case "frame.height":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateLayerFrame(layer, height: value)
        case "bounds.x":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateLayerBounds(layer, x: value)
        case "bounds.y":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateLayerBounds(layer, y: value)
        case "bounds.width":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateLayerBounds(layer, width: value)
        case "bounds.height":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            try mutateLayerBounds(layer, height: value)
        case "backgroundColor":
            guard let value = property.textValue else {
                throw MutationError.invalidValue
            }
            try mutateBackgroundColor(layer, hexString: value)
        case "layer.cornerRadius":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            mutateLayerValue(layer, cornerRadius: value)
        case "layer.borderWidth":
            guard let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            mutateLayerValue(layer, borderWidth: value)
        default:
            throw MutationError.unsupportedProperty
        }
    }

    private static func applyAppKitSpecificMutation(_ property: ViewScopeEditableProperty, to view: NSView) throws -> Bool {
        switch property.key {
        case "imageView.imageScaling":
            guard let imageView = view as? NSImageView,
                  let value = property.numberValue,
                  let scaling = NSImageScaling(rawValue: UInt(Int(value))) else {
                throw MutationError.invalidValue
            }
            imageView.imageScaling = scaling
            return true
        case "imageView.imageAlignment":
            guard let imageView = view as? NSImageView,
                  let value = property.numberValue,
                  let alignment = NSImageAlignment(rawValue: UInt(value)) else {
                throw MutationError.invalidValue
            }
            imageView.imageAlignment = alignment
            return true
        case "imageView.animates":
            guard let imageView = view as? NSImageView,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            imageView.animates = value
            return true
        case "contentOffset.x":
            guard let scrollView = view as? NSScrollView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            var origin = scrollView.contentView.bounds.origin
            origin.x = CGFloat(value)
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return true
        case "contentOffset.y":
            guard let scrollView = view as? NSScrollView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            var origin = scrollView.contentView.bounds.origin
            origin.y = CGFloat(value)
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return true
        case "contentSize.width":
            guard let scrollView = view as? NSScrollView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            guard let documentView = scrollView.documentView else {
                throw MutationError.unsupportedProperty
            }
            var size = documentView.frame.size
            size.width = CGFloat(max(0, value))
            documentView.setFrameSize(size)
            return true
        case "contentSize.height":
            guard let scrollView = view as? NSScrollView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            guard let documentView = scrollView.documentView else {
                throw MutationError.unsupportedProperty
            }
            var size = documentView.frame.size
            size.height = CGFloat(max(0, value))
            documentView.setFrameSize(size)
            return true
        case "automaticallyAdjustsContentInsets":
            guard let scrollView = view as? NSScrollView,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            scrollView.automaticallyAdjustsContentInsets = value
            return true
        case "borderType":
            guard let scrollView = view as? NSScrollView,
                  let value = property.numberValue,
                  let borderType = NSBorderType(rawValue: UInt(value)) else {
                throw MutationError.invalidValue
            }
            scrollView.borderType = borderType
            return true
        case "hasHorizontalScroller":
            guard let scrollView = view as? NSScrollView,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            scrollView.hasHorizontalScroller = value
            return true
        case "hasVerticalScroller":
            guard let scrollView = view as? NSScrollView,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            scrollView.hasVerticalScroller = value
            return true
        case "autohidesScrollers":
            guard let scrollView = view as? NSScrollView,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            scrollView.autohidesScrollers = value
            return true
        case "scrollerStyle":
            guard let scrollView = view as? NSScrollView,
                  let value = property.numberValue,
                  let style = NSScroller.Style(rawValue: Int(value)) else {
                throw MutationError.invalidValue
            }
            scrollView.scrollerStyle = style
            return true
        case "scrollerKnobStyle":
            guard let scrollView = view as? NSScrollView,
                  let value = property.numberValue,
                  let style = NSScroller.KnobStyle(rawValue: Int(value)) else {
                throw MutationError.invalidValue
            }
            scrollView.scrollerKnobStyle = style
            return true
        case "scrollsDynamically":
            guard let scrollView = view as? NSScrollView,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            scrollView.scrollsDynamically = value
            return true
        case "usesPredominantAxisScrolling":
            guard let scrollView = view as? NSScrollView,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            scrollView.usesPredominantAxisScrolling = value
            return true
        case "allowsMagnification":
            guard let scrollView = view as? NSScrollView,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            scrollView.allowsMagnification = value
            return true
        case "magnification":
            guard let scrollView = view as? NSScrollView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            scrollView.setMagnification(CGFloat(value), centeredAt: .zero)
            return true
        case "maxMagnification":
            guard let scrollView = view as? NSScrollView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            scrollView.maxMagnification = CGFloat(value)
            return true
        case "minMagnification":
            guard let scrollView = view as? NSScrollView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            scrollView.minMagnification = CGFloat(value)
            return true
        case "rowHeight":
            guard let tableView = view as? NSTableView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            tableView.rowHeight = CGFloat(value)
            return true
        case "usesAutomaticRowHeights":
            guard let tableView = view as? NSTableView,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            tableView.usesAutomaticRowHeights = value
            return true
        case "intercellSpacing.width":
            guard let tableView = view as? NSTableView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            var spacing = tableView.intercellSpacing
            spacing.width = CGFloat(value)
            tableView.intercellSpacing = spacing
            return true
        case "intercellSpacing.height":
            guard let tableView = view as? NSTableView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            var spacing = tableView.intercellSpacing
            spacing.height = CGFloat(value)
            tableView.intercellSpacing = spacing
            return true
        case "style":
            guard let tableView = view as? NSTableView,
                  let value = property.numberValue,
                  let style = NSTableView.Style(rawValue: Int(value)) else {
                throw MutationError.invalidValue
            }
            tableView.style = style
            return true
        case "columnAutoresizingStyle":
            guard let tableView = view as? NSTableView,
                  let value = property.numberValue,
                  let style = NSTableView.ColumnAutoresizingStyle(rawValue: UInt(value)) else {
                throw MutationError.invalidValue
            }
            tableView.columnAutoresizingStyle = style
            return true
        case "gridStyleMask":
            guard let tableView = view as? NSTableView,
                  let value = property.numberValue else {
                throw MutationError.invalidValue
            }
            tableView.gridStyleMask = NSTableView.GridLineStyle(rawValue: UInt(value))
            return true
        case "selectionHighlightStyle":
            guard let tableView = view as? NSTableView,
                  let value = property.numberValue,
                  let style = NSTableView.SelectionHighlightStyle(rawValue: Int(value)) else {
                throw MutationError.invalidValue
            }
            tableView.selectionHighlightStyle = style
            return true
        case "gridColor":
            guard let tableView = view as? NSTableView,
                  let value = property.textValue,
                  let color = NSColor(viewScopeHexString: value) else {
                throw MutationError.invalidValue
            }
            tableView.gridColor = color
            return true
        case "rowSizeStyle":
            guard let tableView = view as? NSTableView,
                  let value = property.numberValue,
                  let style = NSTableView.RowSizeStyle(rawValue: Int(value)) else {
                throw MutationError.invalidValue
            }
            tableView.rowSizeStyle = style
            return true
        case "usesAlternatingRowBackgroundColors":
            guard let tableView = view as? NSTableView,
                  let value = property.boolValue else {
                throw MutationError.invalidValue
            }
            tableView.usesAlternatingRowBackgroundColors = value
            return true
        case "allowsColumnReordering":
            guard let tableView = view as? NSTableView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            tableView.allowsColumnReordering = value
            return true
        case "allowsColumnResizing":
            guard let tableView = view as? NSTableView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            tableView.allowsColumnResizing = value
            return true
        case "allowsMultipleSelection":
            guard let tableView = view as? NSTableView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            tableView.allowsMultipleSelection = value
            return true
        case "allowsEmptySelection":
            guard let tableView = view as? NSTableView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            tableView.allowsEmptySelection = value
            return true
        case "allowsColumnSelection":
            guard let tableView = view as? NSTableView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            tableView.allowsColumnSelection = value
            return true
        case "allowsTypeSelect":
            guard let tableView = view as? NSTableView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            tableView.allowsTypeSelect = value
            return true
        case "floatsGroupRows":
            guard let tableView = view as? NSTableView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            tableView.floatsGroupRows = value
            return true
        case "verticalMotionCanBeginDrag":
            guard let tableView = view as? NSTableView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            tableView.verticalMotionCanBeginDrag = value
            return true
        case "textView.string":
            guard let textView = view as? NSTextView,
                  let value = property.textValue else {
                throw MutationError.invalidValue
            }
            textView.string = value
            return true
        case "textView.fontSize":
            guard let textView = view as? NSTextView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            textView.font = font.withSize(CGFloat(value))
            return true
        case "textView.textColor":
            guard let textView = view as? NSTextView,
                  let value = property.textValue,
                  let color = NSColor(viewScopeHexString: value) else { throw MutationError.invalidValue }
            textView.textColor = color
            return true
        case "textView.alignment":
            guard let textView = view as? NSTextView,
                  let value = property.numberValue,
                  let alignment = NSTextAlignment(rawValue: Int(value)) else { throw MutationError.invalidValue }
            textView.alignment = alignment
            return true
        case "textView.textContainerInset.width":
            guard let textView = view as? NSTextView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            var inset = textView.textContainerInset
            inset.width = CGFloat(value)
            textView.textContainerInset = inset
            return true
        case "textView.textContainerInset.height":
            guard let textView = view as? NSTextView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            var inset = textView.textContainerInset
            inset.height = CGFloat(value)
            textView.textContainerInset = inset
            return true
        case "textView.maxSize.width":
            guard let textView = view as? NSTextView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            var size = textView.maxSize
            size.width = CGFloat(value)
            textView.maxSize = size
            return true
        case "textView.maxSize.height":
            guard let textView = view as? NSTextView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            var size = textView.maxSize
            size.height = CGFloat(value)
            textView.maxSize = size
            return true
        case "textView.minSize.width":
            guard let textView = view as? NSTextView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            var size = textView.minSize
            size.width = CGFloat(value)
            textView.minSize = size
            return true
        case "textView.minSize.height":
            guard let textView = view as? NSTextView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            var size = textView.minSize
            size.height = CGFloat(value)
            textView.minSize = size
            return true
        case "textView.isEditable":
            guard let textView = view as? NSTextView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textView.isEditable = value
            return true
        case "textView.isSelectable":
            guard let textView = view as? NSTextView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textView.isSelectable = value
            return true
        case "textView.isRichText":
            guard let textView = view as? NSTextView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textView.isRichText = value
            return true
        case "textView.importsGraphics":
            guard let textView = view as? NSTextView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textView.importsGraphics = value
            return true
        case "textView.isHorizontallyResizable":
            guard let textView = view as? NSTextView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textView.isHorizontallyResizable = value
            return true
        case "textView.isVerticallyResizable":
            guard let textView = view as? NSTextView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textView.isVerticallyResizable = value
            return true
        case "textField.isBordered":
            guard let textField = view as? NSTextField,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textField.isBordered = value
            return true
        case "textField.isBezeled":
            guard let textField = view as? NSTextField,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textField.isBezeled = value
            return true
        case "textField.bezelStyle":
            guard let textField = view as? NSTextField,
                  let value = property.numberValue,
                  let style = NSTextField.BezelStyle(rawValue: UInt(value)) else { throw MutationError.invalidValue }
            textField.bezelStyle = style
            return true
        case "textField.isEditable":
            guard let textField = view as? NSTextField,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textField.isEditable = value
            return true
        case "textField.isSelectable":
            guard let textField = view as? NSTextField,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textField.isSelectable = value
            return true
        case "textField.drawsBackground":
            guard let textField = view as? NSTextField,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textField.drawsBackground = value
            return true
        case "textField.preferredMaxLayoutWidth":
            guard let textField = view as? NSTextField,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            textField.preferredMaxLayoutWidth = CGFloat(value)
            return true
        case "textField.maximumNumberOfLines":
            guard let textField = view as? NSTextField,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            textField.maximumNumberOfLines = max(0, Int(value))
            return true
        case "textField.allowsDefaultTighteningForTruncation":
            guard let textField = view as? NSTextField,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            textField.allowsDefaultTighteningForTruncation = value
            return true
        case "textField.lineBreakStrategy":
            guard let textField = view as? NSTextField,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            textField.lineBreakStrategy = NSParagraphStyle.LineBreakStrategy(rawValue: UInt(value))
            return true
        case "textField.textColor":
            guard let textField = view as? NSTextField,
                  let value = property.textValue,
                  let color = NSColor(viewScopeHexString: value) else { throw MutationError.invalidValue }
            textField.textColor = color
            return true
        case "button.title":
            guard let button = view as? NSButton,
                  let value = property.textValue else { throw MutationError.invalidValue }
            button.title = value
            return true
        case "button.alternateTitle":
            guard let button = view as? NSButton,
                  let value = property.textValue else { throw MutationError.invalidValue }
            button.alternateTitle = value
            return true
        case "button.buttonType":
            guard let button = view as? NSButton,
                  let value = property.numberValue,
                  let buttonType = NSButton.ButtonType(rawValue: UInt(value)) else { throw MutationError.invalidValue }
            button.setButtonType(buttonType)
            return true
        case "button.bezelStyle":
            guard let button = view as? NSButton,
                  let value = property.numberValue,
                  let bezelStyle = NSButton.BezelStyle(rawValue: UInt(value)) else { throw MutationError.invalidValue }
            button.bezelStyle = bezelStyle
            return true
        case "button.isBordered":
            guard let button = view as? NSButton,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            button.isBordered = value
            return true
        case "button.isTransparent":
            guard let button = view as? NSButton,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            button.isTransparent = value
            return true
        case "button.bezelColor":
            guard let button = view as? NSButton,
                  let value = property.textValue,
                  let color = NSColor(viewScopeHexString: value) else { throw MutationError.invalidValue }
            button.bezelColor = color
            return true
        case "button.contentTintColor":
            guard let button = view as? NSButton,
                  let value = property.textValue,
                  let color = NSColor(viewScopeHexString: value) else { throw MutationError.invalidValue }
            button.contentTintColor = color
            return true
        case "button.showsBorderOnlyWhileMouseInside":
            guard let button = view as? NSButton,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            button.showsBorderOnlyWhileMouseInside = value
            return true
        case "button.isSpringLoaded":
            guard let button = view as? NSButton,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            button.isSpringLoaded = value
            return true
        case "control.controlSize":
            guard let control = view as? NSControl,
                  let value = property.numberValue,
                  let size = NSControl.ControlSize(rawValue: UInt(value)) else { throw MutationError.invalidValue }
            control.controlSize = size
            return true
        case "control.alignment":
            guard let control = view as? NSControl,
                  let value = property.numberValue,
                  let alignment = NSTextAlignment(rawValue: Int(value)) else { throw MutationError.invalidValue }
            control.alignment = alignment
            return true
        case "control.fontSize":
            guard let control = view as? NSControl,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            let font = control.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            control.font = font.withSize(CGFloat(value))
            return true
        case "visualEffect.material":
            guard let visualEffectView = view as? NSVisualEffectView,
                  let value = property.numberValue,
                  let material = NSVisualEffectView.Material(rawValue: Int(value)) else { throw MutationError.invalidValue }
            visualEffectView.material = material
            return true
        case "visualEffect.blendingMode":
            guard let visualEffectView = view as? NSVisualEffectView,
                  let value = property.numberValue,
                  let blendingMode = NSVisualEffectView.BlendingMode(rawValue: Int(value)) else { throw MutationError.invalidValue }
            visualEffectView.blendingMode = blendingMode
            return true
        case "visualEffect.state":
            guard let visualEffectView = view as? NSVisualEffectView,
                  let value = property.numberValue,
                  let state = NSVisualEffectView.State(rawValue: Int(value)) else { throw MutationError.invalidValue }
            visualEffectView.state = state
            return true
        case "visualEffect.isEmphasized":
            guard let visualEffectView = view as? NSVisualEffectView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            visualEffectView.isEmphasized = value
            return true
        case "stack.orientation":
            guard let stackView = view as? NSStackView,
                  let value = property.numberValue,
                  let orientation = NSUserInterfaceLayoutOrientation(rawValue: Int(value)) else { throw MutationError.invalidValue }
            stackView.orientation = orientation
            return true
        case "stack.edgeInsets.top":
            guard let stackView = view as? NSStackView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            var insets = stackView.edgeInsets
            insets.top = CGFloat(value)
            stackView.edgeInsets = insets
            return true
        case "stack.edgeInsets.left":
            guard let stackView = view as? NSStackView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            var insets = stackView.edgeInsets
            insets.left = CGFloat(value)
            stackView.edgeInsets = insets
            return true
        case "stack.edgeInsets.bottom":
            guard let stackView = view as? NSStackView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            var insets = stackView.edgeInsets
            insets.bottom = CGFloat(value)
            stackView.edgeInsets = insets
            return true
        case "stack.edgeInsets.right":
            guard let stackView = view as? NSStackView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            var insets = stackView.edgeInsets
            insets.right = CGFloat(value)
            stackView.edgeInsets = insets
            return true
        case "stack.detachesHiddenViews":
            guard let stackView = view as? NSStackView,
                  let value = property.boolValue else { throw MutationError.invalidValue }
            stackView.detachesHiddenViews = value
            return true
        case "stack.distribution":
            guard let stackView = view as? NSStackView,
                  let value = property.numberValue,
                  let distribution = NSStackView.Distribution(rawValue: Int(value)) else { throw MutationError.invalidValue }
            stackView.distribution = distribution
            return true
        case "stack.alignment":
            guard let stackView = view as? NSStackView,
                  let value = property.numberValue,
                  let alignment = NSLayoutConstraint.Attribute(rawValue: Int(value)) else { throw MutationError.invalidValue }
            stackView.alignment = alignment
            return true
        case "stack.spacing":
            guard let stackView = view as? NSStackView,
                  let value = property.numberValue else { throw MutationError.invalidValue }
            stackView.spacing = CGFloat(value)
            return true
        default:
            return false
        }
    }

    private static func mutateWindowFrame(
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

    private static func mutateViewFrame(
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

    private static func mutateViewBounds(
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

    private static func mutateLayerFrame(
        _ layer: CALayer,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) throws {
        var frame = layer.frame
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
        layer.frame = frame
        layer.setNeedsDisplay()
        layer.viewScopeHostView?.needsDisplay = true
    }

    private static func mutateLayerBounds(
        _ layer: CALayer,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) throws {
        var bounds = layer.bounds
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
        layer.bounds = bounds
        layer.setNeedsDisplay()
        layer.viewScopeHostView?.needsDisplay = true
    }

    private static func mutateScrollViewInsets(
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
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = insets
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()
    }

    private static func mutateBackgroundColor(_ view: NSView, hexString: String) throws {
        guard let color = NSColor(viewScopeHexString: hexString) else {
            throw MutationError.invalidValue
        }
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.needsDisplay = true
    }

    private static func mutateBackgroundColor(_ layer: CALayer, hexString: String) throws {
        guard let color = NSColor(viewScopeHexString: hexString) else {
            throw MutationError.invalidValue
        }
        layer.backgroundColor = color.cgColor
        layer.setNeedsDisplay()
        layer.viewScopeHostView?.needsDisplay = true
    }

    private static func mutateLayerValue(
        _ view: NSView,
        cornerRadius: Double? = nil,
        borderWidth: Double? = nil
    ) {
        view.wantsLayer = true
        if let cornerRadius {
            view.layer?.cornerRadius = CGFloat(max(0, cornerRadius))
        }
        if let borderWidth {
            view.layer?.borderWidth = CGFloat(max(0, borderWidth))
        }
        view.needsDisplay = true
    }

    private static func mutateLayerValue(
        _ layer: CALayer,
        cornerRadius: Double? = nil,
        borderWidth: Double? = nil
    ) {
        if let cornerRadius {
            layer.cornerRadius = CGFloat(max(0, cornerRadius))
        }
        if let borderWidth {
            layer.borderWidth = CGFloat(max(0, borderWidth))
        }
        layer.setNeedsDisplay()
        layer.viewScopeHostView?.needsDisplay = true
    }

    private static func applyControlValue(_ value: String, to view: NSView) throws {
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
