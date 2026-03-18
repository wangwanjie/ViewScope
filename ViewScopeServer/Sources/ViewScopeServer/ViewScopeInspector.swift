import AppKit
import Foundation
import Network

public enum ViewScopeInspector {
    @MainActor
    public static func start(configuration: Configuration = .init()) {
        Inspector.shared.start(configuration: configuration)
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
}

@MainActor
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

private extension JSONEncoder {
    static var viewScope: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
