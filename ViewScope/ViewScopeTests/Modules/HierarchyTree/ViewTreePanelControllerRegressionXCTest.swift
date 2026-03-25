import AppKit
import Combine
import Foundation
import ObjectiveC.runtime
import XCTest
@testable import ViewScope
@testable import ViewScopeServer

@MainActor
final class ViewTreePanelControllerRegressionXCTest: XCTestCase {
    func testExpandingRootNodeDoesNotRepublishUnchangedFocusState() async throws {
        let (store, host) = try makeConnectedStoreWithHandlers()
        defer { store.shutdown() }
        await store.connect(to: host)

        var focusEvents: [String?] = []
        let cancellable = store.$focusedNodeID
            .dropFirst()
            .sink { focusEvents.append($0) }
        defer { cancellable.cancel() }

        store.setNodeExpanded("window-0", isExpanded: true)
        pumpRunLoop(for: 0.05)

        XCTAssertEqual(
            focusEvents.count,
            0,
            "展开根节点不会改变焦点；如果这里重新发布 focusedNodeID，树面板会在恢复展开状态时被无意义地整棵重建。"
        )
    }

    func testTreePanelDoesNotForceSynchronousCellLayoutWhenCaptureArrives() async throws {
        let (store, host) = try makeConnectedStoreWithHandlers()
        defer { store.shutdown() }

        let controller = ViewTreePanelController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }

        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()

        let tracker = ViewTreePanelLayoutTracker()
        try tracker.install()
        defer { tracker.uninstall() }

        await store.connect(to: host)
        pumpRunLoop(for: 0.2)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            tracker.callsFromTreeCellMetricsUpdate,
            0,
            "树节点 cell 在构建期不应同步触发布局，否则会在展开节点时递归回到 NSOutlineView 的行构建流程。"
        )
    }

    private func pumpRunLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private func makeConnectedStoreWithHandlers() throws -> (WorkspaceStore, ViewScopeHostAnnouncement) {
        let suiteName = "ViewTreePanelControllerRegressionXCTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw RegressionTestError.missingDefaults
        }

        let settings = AppSettings(defaults: defaults, environment: ["VIEWSCOPE_DISABLE_UPDATES": "1"])
        let host = ViewScopeHostAnnouncement(
            identifier: "tests.host.handlers",
            authToken: "tests-token",
            displayName: "Handlers Host",
            bundleIdentifier: "cn.vanjay.handlers-host",
            version: "1.0",
            build: "1",
            processIdentifier: 100,
            port: 0,
            updatedAt: Date(),
            supportsHighlighting: true,
            protocolVersion: viewScopeCurrentProtocolVersion,
            runtimeVersion: viewScopeServerRuntimeVersion
        )
        let captureHost = ViewScopeHostInfo(
            displayName: host.displayName,
            bundleIdentifier: host.bundleIdentifier,
            version: host.version,
            build: host.build,
            processIdentifier: host.processIdentifier,
            runtimeVersion: host.runtimeVersion,
            supportsHighlighting: host.supportsHighlighting
        )
        let capture = ViewScopeCapturePayload(
            host: captureHost,
            capturedAt: Date(),
            summary: .init(nodeCount: 2, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["window-0"],
            nodes: [
                "window-0": ViewScopeHierarchyNode(
                    id: "window-0",
                    parentID: nil,
                    kind: .window,
                    className: "NSWindow",
                    title: "Host Window",
                    subtitle: nil,
                    frame: .zero,
                    bounds: .zero,
                    childIDs: ["button-0"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: true,
                    depth: 0
                ),
                "button-0": ViewScopeHierarchyNode(
                    id: "button-0",
                    parentID: "window-0",
                    kind: .view,
                    className: "NSButton",
                    title: "Connect",
                    subtitle: nil,
                    frame: .zero,
                    bounds: .zero,
                    childIDs: [],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: false,
                    isFlipped: true,
                    clippingEnabled: false,
                    depth: 1,
                    controlTargetClassName: "Demo.ConnectCoordinator",
                    controlActionName: "connect:"
                )
            ],
            captureID: "capture-with-handlers",
            previewBitmaps: []
        )
        let detail = ViewScopeNodeDetailPayload(
            nodeID: "window-0",
            host: capture.host,
            sections: [],
            constraints: [],
            ancestry: [],
            screenshotPNGBase64: nil,
            screenshotSize: .init(width: 1, height: 1),
            highlightedRect: .init(x: 0, y: 0, width: 1, height: 1),
            consoleTargets: []
        )
        let session = ViewTreePanelRegressionSession(
            announcement: host,
            hello: ViewScopeServerHelloPayload(host: capture.host, protocolVersion: viewScopeCurrentProtocolVersion),
            capture: capture,
            detail: detail
        )

        let store = try WorkspaceStore(
            settings: settings,
            updateManager: UpdateManager(settings: settings),
            sessionFactory: { _ in session }
        )
        store.start()
        return (store, host)
    }
}

private enum RegressionTestError: Error {
    case missingDefaults
    case missingMethod
}

@MainActor
private final class ViewTreePanelLayoutTracker {
    private var originalMethod: Method?
    private var replacementMethod: Method?
    private(set) var callsFromTreeCellMetricsUpdate = 0

    func install() throws {
        ViewTreePanelLayoutTracker.shared = self
        guard let originalMethod = class_getInstanceMethod(NSView.self, #selector(NSView.layoutSubtreeIfNeeded)),
              let replacementMethod = class_getInstanceMethod(NSView.self, #selector(NSView.vs_regression_track_layoutSubtreeIfNeeded)) else {
            throw RegressionTestError.missingMethod
        }
        self.originalMethod = originalMethod
        self.replacementMethod = replacementMethod
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    func uninstall() {
        if let originalMethod, let replacementMethod {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
        originalMethod = nil
        replacementMethod = nil
        ViewTreePanelLayoutTracker.shared = nil
    }

    fileprivate static weak var shared: ViewTreePanelLayoutTracker?

    fileprivate func recordIfNeeded(view: NSView, symbols: [String]) {
        guard NSStringFromClass(type(of: view)).contains("ViewTreeNodeCellView") else { return }
        guard symbols.contains(where: { $0.contains("updateHandlersButtonMetrics") }) else { return }
        callsFromTreeCellMetricsUpdate += 1
    }
}

private extension NSView {
    @objc dynamic func vs_regression_track_layoutSubtreeIfNeeded() {
        ViewTreePanelLayoutTracker.shared?.recordIfNeeded(view: self, symbols: Thread.callStackSymbols)
        vs_regression_track_layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class ViewTreePanelRegressionSession: WorkspaceSessionProtocol {
    let announcement: ViewScopeHostAnnouncement

    private let hello: ViewScopeServerHelloPayload
    private let capture: ViewScopeCapturePayload
    private let detail: ViewScopeNodeDetailPayload

    init(
        announcement: ViewScopeHostAnnouncement,
        hello: ViewScopeServerHelloPayload,
        capture: ViewScopeCapturePayload,
        detail: ViewScopeNodeDetailPayload
    ) {
        self.announcement = announcement
        self.hello = hello
        self.capture = capture
        self.detail = detail
    }

    func open() async throws -> ViewScopeServerHelloPayload {
        hello
    }

    func requestCapture() async throws -> ViewScopeCapturePayload {
        capture
    }

    func requestNodeDetail(nodeID: String) async throws -> ViewScopeNodeDetailPayload {
        detail
    }

    func highlight(nodeID: String, duration: TimeInterval) async throws {}

    func applyMutation(nodeID: String, property: ViewScopeEditableProperty) async throws {}

    func invokeConsole(
        target: ViewScopeRemoteObjectReference,
        expression: String
    ) async throws -> ViewScopeConsoleInvokeResponsePayload {
        ViewScopeConsoleInvokeResponsePayload(
            submittedExpression: expression,
            target: target,
            resultDescription: expression
        )
    }

    func disconnect() {}
}
