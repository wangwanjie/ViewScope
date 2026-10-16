import AppKit
import Combine
import Foundation
import XCTest
@testable import ViewScope
@testable import ViewScopeServer

/// 层级树与 store 的选中 / 展开同步回归测试（审计 15–18、21）。
@MainActor
final class ViewTreeSyncRegressionTests: XCTestCase {
    private typealias F = DiagnosticsTestFixtures

    // MARK: - 纯逻辑

    func testDeselectingInsideSyncIsTreatedAsProgrammatic() {
        let synchronizer = ViewTreeSelectionSynchronizer()
        let outlineView = RecordingOutlineView()
        outlineView.onDeselect = {
            outlineView.recordedChange = synchronizer.userSelectionChange(selectedRow: -1, itemAtRow: { _ in nil })
        }
        synchronizer.syncSelection(selectedNodeID: "missing", item: nil, outlineView: outlineView) { _ in }
        XCTAssertEqual(outlineView.recordedChange, .ignored, "取消选中必须包在程序化选中里，否则会把 store 的选中清空。")
    }

    func testNestedProgrammaticSelectionKeepsOuterFlag() {
        let synchronizer = ViewTreeSelectionSynchronizer()
        synchronizer.withProgrammaticSelection {
            synchronizer.withProgrammaticSelection {
            }
            XCTAssertEqual(synchronizer.userSelectionChange(selectedRow: -1, itemAtRow: { _ in nil }), .ignored)
        }
        XCTAssertEqual(synchronizer.userSelectionChange(selectedRow: -1, itemAtRow: { _ in nil }), .update(nil))
    }

    func testFilteringKeepsMatchedContainerChildrenAndMarksPaths() throws {
        let capture = makeCapture()
        let roots = ViewTreePresentationBuilder().buildRoots(
            capture: capture,
            focusedNodeID: nil,
            showsSystemWrappers: true,
            query: "node-a"
        )
        let root = try XCTUnwrap(roots.first)
        XCTAssertTrue(root.isOnFilterPath)
        XCTAssertFalse(root.isFilterMatch)
        let matched = try XCTUnwrap(root.children.first { $0.node.id == "a" })
        XCTAssertTrue(matched.isFilterMatch)
        // 命中节点保留完整子树，便于继续展开查看。
        XCTAssertEqual(matched.children.map(\.node.id), ["b"])
        XCTAssertEqual(matched.children.first?.children.map(\.node.id), ["c"])
    }

    func testIssueFilterOnlyKeepsNodesWithIssuesAndTheirAncestors() throws {
        let capture = makeCapture()
        let roots = ViewTreePresentationBuilder().buildRoots(
            capture: capture,
            focusedNodeID: nil,
            showsSystemWrappers: true,
            query: "",
            nodeFilter: { $0.id == "c" }
        )
        let root = try XCTUnwrap(roots.first)
        XCTAssertEqual(root.children.map(\.node.id), ["a"])
        XCTAssertEqual(root.children.first?.children.first?.children.first?.node.id, "c")
        XCTAssertTrue(root.children.first?.children.first?.children.first?.isFilterMatch == true)
    }

    func testHiddenNodesStayVisibleForSelectionNormalization() {
        let capture = makeCapture()
        let visible = ViewHierarchyPresentation.visiblePresentedNodeIDs(
            rootNodeIDs: capture.rootNodeIDs,
            nodes: capture.nodes,
            expandedNodeIDs: [],
            showsSystemWrappers: true
        )
        XCTAssertTrue(visible.contains("hidden"))
    }

    // MARK: - 控制器集成

    func testTreeFollowsStoreCollapseOfDescendants() async throws {
        let (store, host) = try makeStore()
        defer {
            store.shutdown()
        }
        let (controller, window) = makeController(store: store)
        defer {
            window.close()
        }
        await store.connect(to: host)
        pumpRunLoop()

        store.setNodeExpanded("a", isExpanded: true)
        store.setNodeExpanded("b", isExpanded: true)
        pumpRunLoop()
        let outlineView = try outline(of: controller)
        XCTAssertTrue(outlineView.isItemExpanded(try item("b", in: outlineView)))

        // store 折叠 a 时会一并清除 b 的展开态；树必须跟随，重新展开 a 时 b 保持折叠。
        store.setNodeExpanded("a", isExpanded: false)
        pumpRunLoop()
        XCTAssertFalse(store.expandedNodeIDs.contains("b"))
        store.setNodeExpanded("a", isExpanded: true)
        pumpRunLoop()
        XCTAssertTrue(outlineView.isItemExpanded(try item("a", in: outlineView)))
        XCTAssertFalse(outlineView.isItemExpanded(try item("b", in: outlineView)))
    }

    func testSelectingDeepNodeExpandsAncestorsAtomically() async throws {
        let (store, host) = try makeStore()
        defer {
            store.shutdown()
        }
        let (controller, window) = makeController(store: store)
        defer {
            window.close()
        }
        await store.connect(to: host)
        pumpRunLoop()

        await store.selectNode(withID: "c", highlightInHost: false)
        pumpRunLoop()
        XCTAssertEqual(store.selectedNodeID, "c")
        XCTAssertTrue(store.expandedNodeIDs.isSuperset(of: ["a", "b"]))
        let outlineView = try outline(of: controller)
        XCTAssertEqual(outlineView.selectedRow, outlineView.row(forItem: try item("c", in: outlineView)))
    }

    func testHiddenSelectionSurvivesExpansionChanges() async throws {
        let (store, host) = try makeStore()
        defer {
            store.shutdown()
        }
        let (_, window) = makeController(store: store)
        defer {
            window.close()
        }
        await store.connect(to: host)
        pumpRunLoop()

        await store.selectNode(withID: "hidden", highlightInHost: false)
        store.setNodeExpanded("a", isExpanded: true)
        pumpRunLoop()
        XCTAssertEqual(store.selectedNodeID, "hidden")
    }

    func testSearchThatHidesSelectionDoesNotClearStoreSelection() async throws {
        let (store, host) = try makeStore()
        defer {
            store.shutdown()
        }
        let (controller, window) = makeController(store: store)
        defer {
            window.close()
        }
        await store.connect(to: host)
        pumpRunLoop()
        await store.selectNode(withID: "c", highlightInHost: false)
        pumpRunLoop()

        let searchField = try XCTUnwrap(Mirror(reflecting: controller).descendant("searchField") as? NSSearchField)
        searchField.stringValue = "hidden"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        pumpRunLoop(for: 0.4)

        XCTAssertEqual(store.selectedNodeID, "c")
        let matchLabel = try XCTUnwrap(Mirror(reflecting: controller).descendant("searchMatchLabel") as? NSTextField)
        XCTAssertFalse(matchLabel.stringValue.isEmpty)
    }

    // MARK: - 工具

    private func pumpRunLoop(for duration: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private func outline(of controller: ViewTreePanelController) throws -> NSOutlineView {
        try XCTUnwrap(Mirror(reflecting: controller).descendant("outlineView") as? NSOutlineView)
    }

    private func item(_ nodeID: String, in outlineView: NSOutlineView) throws -> ViewTreeNodeItem {
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? ViewTreeNodeItem, item.node.id == nodeID {
                return item
            }
        }
        throw XCTSkip("节点 \(nodeID) 不在可见行中")
    }

    private func makeController(store: WorkspaceStore) -> (ViewTreePanelController, NSWindow) {
        let controller = ViewTreePanelController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // 代码创建的 NSWindow 默认 isReleasedWhenClosed = true，close() 会额外 release 一次，导致后续自动释放池过度释放崩溃。
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private func makeCapture() -> ViewScopeCapturePayload {
        F.capture(
            nodes: [
                F.node("root", parent: nil, children: ["a", "hidden"], frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
                F.node("a", parent: "root", children: ["b"], frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
                F.node("b", parent: "a", children: ["c"], frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
                F.node("c", parent: "b", frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                F.node("hidden", parent: "root", frame: CGRect(x: 0, y: 0, width: 50, height: 50), isHidden: true)
            ].map { node in
                var node = node
                node.title = "node-\(node.id)"
                return node
            },
            rootNodeIDs: ["root"],
            platform: .macOS,
            screenScale: 2,
            captureID: "tree-sync-fixture"
        )
    }

    private func makeStore() throws -> (WorkspaceStore, ViewScopeHostAnnouncement) {
        let suiteName = "ViewTreeSyncRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults, environment: ["VIEWSCOPE_DISABLE_UPDATES": "1"])
        let host = ViewScopeHostAnnouncement(
            identifier: "tests.host.tree-sync",
            authToken: "tests-token",
            displayName: "Tree Sync Host",
            bundleIdentifier: "cn.vanjay.tree-sync-host",
            version: "1.0",
            build: "1",
            processIdentifier: 101,
            port: 0,
            updatedAt: Date(),
            supportsHighlighting: true,
            protocolVersion: viewScopeCurrentProtocolVersion,
            runtimeVersion: viewScopeServerRuntimeVersion
        )
        let capture = makeCapture()
        let session = TreeSyncSession(announcement: host, capture: capture)
        let store = try WorkspaceStore(
            settings: settings,
            updateManager: UpdateManager(settings: settings),
            sessionFactory: { _ in session }
        )
        store.start()
        return (store, host)
    }
}

private final class RecordingOutlineView: NSOutlineView {
    var onDeselect: (() -> Void)?
    var recordedChange: ViewTreeUserSelectionChange?

    override func deselectAll(_ sender: Any?) {
        onDeselect?()
        super.deselectAll(sender)
    }
}

@MainActor
private final class TreeSyncSession: WorkspaceSessionProtocol {
    let announcement: ViewScopeHostAnnouncement
    private let capture: ViewScopeCapturePayload

    init(announcement: ViewScopeHostAnnouncement, capture: ViewScopeCapturePayload) {
        self.announcement = announcement
        self.capture = capture
    }

    func open() async throws -> ViewScopeServerHelloPayload {
        ViewScopeServerHelloPayload(host: capture.host, protocolVersion: viewScopeCurrentProtocolVersion)
    }

    func requestCapture() async throws -> ViewScopeCapturePayload {
        capture
    }

    func requestNodeDetail(nodeID: String) async throws -> ViewScopeNodeDetailPayload {
        ViewScopeNodeDetailPayload(
            nodeID: nodeID,
            host: capture.host,
            sections: [],
            constraints: [],
            ancestry: [],
            screenshotPNGBase64: nil,
            screenshotSize: .init(width: 1, height: 1),
            highlightedRect: .init(x: 0, y: 0, width: 1, height: 1),
            consoleTargets: []
        )
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
