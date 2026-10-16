import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

/// Store 层：自动刷新防重叠、选中保持、断线只读、修改记录与撤销。
@Suite(.serialized)
@MainActor
struct WorkspaceStoreRefreshAndUndoTests {
    @Test func olderCaptureResponseDoesNotOverwriteNewerOne() async throws {
        let host = makeHost(id: "host-seq")
        let session = ScriptedWorkspaceSession(announcement: host)
        session.enqueueCapture(.immediate(makeCapture(host: host, captureID: "initial", nodeIDs: ["root"])))
        session.enqueueCapture(.pending)
        session.enqueueCapture(.immediate(makeCapture(host: host, captureID: "newer", nodeIDs: ["root"])))
        session.detailHandler = { nodeID in
            makeDetail(nodeID: nodeID, host: host)
        }
        let store = try makeStore(session: session)
        defer {
            store.shutdown()
        }

        await store.connect(to: host)
        #expect(store.capture?.captureID == "initial")

        // 第一个刷新挂起，第二个刷新先返回
        let slowRefresh = Task {
            await store.refreshCapture()
        }
        try await waitUntil {
            session.captureRequestCount == 2
        }
        await store.refreshCapture()
        #expect(store.capture?.captureID == "newer")

        // 迟到的旧结果被丢弃
        session.resolvePendingCapture(with: makeCapture(host: host, captureID: "older", nodeIDs: ["root"]))
        await slowRefresh.value
        #expect(store.capture?.captureID == "newer")
    }

    @Test func refreshKeepsSelectionChangedDuringRequestAndDoesNotReselectRoot() async throws {
        let host = makeHost(id: "host-selection")
        let session = ScriptedWorkspaceSession(announcement: host)
        session.enqueueCapture(.immediate(makeCapture(host: host, captureID: "c1", nodeIDs: ["root", "child"])))
        session.enqueueCapture(.pending)
        session.enqueueCapture(.immediate(makeCapture(host: host, captureID: "c3", nodeIDs: ["root", "child"])))
        session.detailHandler = { nodeID in
            makeDetail(nodeID: nodeID, host: host)
        }
        let store = try makeStore(session: session)
        defer {
            store.shutdown()
        }

        await store.connect(to: host)
        // 首次抓取默认选中根节点
        #expect(store.selectedNodeID == "root")

        let refresh = Task {
            await store.refreshCapture()
        }
        try await waitUntil {
            session.captureRequestCount == 2
        }
        // 请求期间用户改选子节点
        await store.selectNode(withID: "child", highlightInHost: false)
        session.resolvePendingCapture(with: makeCapture(host: host, captureID: "c2", nodeIDs: ["root", "child"]))
        await refresh.value
        #expect(store.selectedNodeID == "child")

        // 用户清空选中后，后续刷新不应自动选回根节点
        await store.selectNode(withID: nil, highlightInHost: false)
        await store.refreshCapture()
        #expect(store.capture?.captureID == "c3")
        #expect(store.selectedNodeID == nil)
    }

    @Test func serverErrorDuringRefreshKeepsConnection() async throws {
        let host = makeHost(id: "host-server-error")
        let session = ScriptedWorkspaceSession(announcement: host)
        session.enqueueCapture(.immediate(makeCapture(host: host, captureID: "c1", nodeIDs: ["root"])))
        session.enqueueCapture(.failure(ViewScopeClientSession.SessionError.server("boom")))
        session.detailHandler = { nodeID in
            makeDetail(nodeID: nodeID, host: host)
        }
        let store = try makeStore(session: session)
        defer {
            store.shutdown()
        }

        await store.connect(to: host)
        await store.refreshCapture()

        #expect(store.connectionState == .connected(host))
        #expect(store.errorMessage == "boom")
        #expect(store.capture?.captureID == "c1")
        #expect(session.disconnectCount == 0)
    }

    @Test func unexpectedDisconnectKeepsLastCaptureReadOnly() async throws {
        let host = makeHost(id: "host-lost")
        let session = ScriptedWorkspaceSession(announcement: host)
        session.enqueueCapture(.immediate(makeCapture(host: host, captureID: "c1", nodeIDs: ["root"])))
        session.detailHandler = { nodeID in
            makeDetail(nodeID: nodeID, host: host)
        }
        let store = try makeStore(session: session)
        defer {
            store.shutdown()
        }

        await store.connect(to: host)
        store.inspectionTools.hoveredNodeID = "root"
        session.simulateUnexpectedDisconnect()

        #expect(store.connectionState == .lost(host))
        #expect(store.errorMessage == L10n.connectedHostDisappeared)
        #expect(store.capture?.captureID == "c1")
        #expect(store.selectedNodeID == "root")
        #expect(store.canRefreshCapture == false)
        #expect(store.inspectionTools.hoveredNodeID == nil)
        #expect(store.connectionState.supportsConsole == false)
    }

    @Test func mutationIsRecordedAndCanBeUndoneAndRedone() async throws {
        let host = makeHost(id: "host-undo")
        let session = ScriptedWorkspaceSession(announcement: host)
        session.defaultCapture = makeCapture(host: host, captureID: "c", nodeIDs: ["root"])
        session.detailHandler = { nodeID in
            makeDetail(nodeID: nodeID, host: host)
        }
        let store = try makeStore(session: session)
        defer {
            store.shutdown()
        }

        await store.connect(to: host)
        let options = [ViewScopeEditableOption(title: "A", value: 0), ViewScopeEditableOption(title: "B", value: 1)]
        let success = await store.applyMutation(
            nodeID: "root",
            property: .enumeration(key: "stack.alignment", value: 1, options: options),
            previousProperty: .enumeration(key: "stack.alignment", value: 0, options: options),
            title: "Alignment"
        )

        #expect(success)
        // 发送给宿主的只包含值，不含 options
        #expect(session.mutations.last?.property == .number(key: "stack.alignment", value: 1))
        let record = try #require(store.modificationLog.records.last)
        #expect(record.title == "Alignment")
        #expect(record.oldValue?.numberValue == 0)
        #expect(record.newValue.options == options)
        #expect(record.nodeAddress == "0xroot")
        #expect(store.canUndoModification)

        await store.undoLastModification()
        #expect(session.mutations.last?.property == .number(key: "stack.alignment", value: 0))
        #expect(store.modificationLog.records.last?.state == .undone)
        #expect(store.modificationLog.records.count == 1)
        #expect(store.canRedoModification)

        await store.redoLastModification()
        #expect(session.mutations.last?.property == .number(key: "stack.alignment", value: 1))
        #expect(store.modificationLog.records.last?.state == .applied)

        // 逐条还原：作为一次新的修改写回旧值
        let reverted = await store.revertModification(id: record.id)
        #expect(reverted)
        #expect(session.mutations.last?.property == .number(key: "stack.alignment", value: 0))
        #expect(store.modificationLog.records.count == 2)

        // 断开后撤销栈失效，但记录保留
        store.disconnect()
        #expect(store.canUndoModification == false)
        #expect(store.modificationLog.records.count == 2)
    }

    @Test func diffBaselineComparesAgainstCurrentCapture() async throws {
        let host = makeHost(id: "host-diff")
        let session = ScriptedWorkspaceSession(announcement: host)
        session.enqueueCapture(.immediate(makeCapture(host: host, captureID: "c1", nodeIDs: ["root"])))
        session.enqueueCapture(.immediate(makeCapture(host: host, captureID: "c2", nodeIDs: ["root", "extra"])))
        session.detailHandler = { nodeID in
            makeDetail(nodeID: nodeID, host: host)
        }
        let store = try makeStore(session: session)
        defer {
            store.shutdown()
        }

        await store.connect(to: host)
        #expect(store.makeCaptureDiff() == nil)
        #expect(store.setCurrentCaptureAsDiffBaseline())
        await store.refreshCapture()

        let diff = try #require(store.makeCaptureDiff())
        #expect(diff.entries(in: .added).map(\.currentNodeID) == ["extra"])

        await store.revealNode("extra")
        #expect(store.selectedNodeID == "extra")
    }

    @Test func consoleRejectsExtendedSyntaxOnlyForLegacyHosts() async throws {
        let host = makeHost(id: "host-console")
        let session = ScriptedWorkspaceSession(announcement: host)
        session.negotiatedProtocolVersion = 2
        session.defaultCapture = makeCapture(host: host, captureID: "c", nodeIDs: ["root"])
        session.detailHandler = { nodeID in
            makeDetail(nodeID: nodeID, host: host)
        }
        let store = try makeStore(session: session)
        defer {
            store.shutdown()
        }

        await store.connect(to: host)
        await store.submitConsole(expression: "setHidden:YES")
        #expect(store.consoleRows.last?.title == L10n.consoleErrorArgumentsRequireNewerHost)
        #expect(session.consoleExpressions.isEmpty)

        session.negotiatedProtocolVersion = 3
        await store.submitConsole(expression: "layer.cornerRadius")
        #expect(session.consoleExpressions == ["layer.cornerRadius"])
        #expect(store.previousConsoleHistoryEntry(currentInput: "") == "layer.cornerRadius")
    }

    @Test func v3CaptureRefreshKeepsConsoleTargetUsable() async throws {
        let host = makeHost(id: "host-console-rebase")
        let session = ScriptedWorkspaceSession(announcement: host)
        session.enqueueCapture(.immediate(makeCapture(host: host, captureID: "c1", nodeIDs: ["root"])))
        session.enqueueCapture(.immediate(makeCapture(host: host, captureID: "c2", nodeIDs: ["root"])))
        session.detailHandler = { nodeID in
            makeDetail(nodeID: nodeID, host: host, captureID: "c1")
        }
        let store = try makeStore(session: session)
        defer {
            store.shutdown()
        }

        await store.connect(to: host)
        #expect(store.consoleCurrentTarget?.reference.captureID == "c1")
        let detailRequests = session.detailRequestCount

        await store.refreshCapture()

        // 节点未变化：不重新拉取 detail，但 console 目标改写到最新抓取，仍可提交
        #expect(session.detailRequestCount == detailRequests)
        #expect(store.consoleCurrentTarget?.reference.captureID == "c2")
        #expect(store.consoleIsLoadingTarget == false)
    }

    // MARK: - 辅助

    private func makeStore(session: ScriptedWorkspaceSession) throws -> WorkspaceStore {
        let defaults = try #require(UserDefaults(suiteName: "WorkspaceStoreRefreshAndUndoTests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, environment: ["VIEWSCOPE_DISABLE_UPDATES": "1"])
        return try WorkspaceStore(
            settings: settings,
            updateManager: UpdateManager(settings: settings),
            sessionFactory: { _ in session }
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while condition() == false {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                throw ScriptedSessionError.timeout
            }
            await Task.yield()
        }
    }
}

// MARK: - 测试数据

@MainActor
private func makeHost(id: String) -> ViewScopeHostAnnouncement {
    ViewScopeHostAnnouncement(
        identifier: id,
        authToken: "token",
        displayName: "Host \(id)",
        bundleIdentifier: "cn.vanjay.\(id)",
        version: "1.0",
        build: "1",
        processIdentifier: 7,
        port: 47300,
        updatedAt: Date(),
        supportsHighlighting: true,
        protocolVersion: viewScopeCurrentProtocolVersion,
        runtimeVersion: viewScopeServerRuntimeVersion
    )
}

@MainActor
private func makeHostInfo(_ host: ViewScopeHostAnnouncement) -> ViewScopeHostInfo {
    ViewScopeHostInfo(
        displayName: host.displayName,
        bundleIdentifier: host.bundleIdentifier,
        version: host.version,
        build: host.build,
        processIdentifier: host.processIdentifier,
        runtimeVersion: host.runtimeVersion,
        supportsHighlighting: true
    )
}

/// 第一个节点为根，其余节点都是根的子节点。
@MainActor
private func makeCapture(host: ViewScopeHostAnnouncement, captureID: String, nodeIDs: [String]) -> ViewScopeCapturePayload {
    var nodes: [String: ViewScopeHierarchyNode] = [:]
    let rootID = nodeIDs[0]
    for (index, nodeID) in nodeIDs.enumerated() {
        nodes[nodeID] = ViewScopeHierarchyNode(
            id: nodeID,
            parentID: index == 0 ? nil : rootID,
            kind: .view,
            className: "NSView",
            title: nodeID,
            subtitle: nil,
            address: "0x\(nodeID)",
            frame: .zero,
            bounds: .zero,
            childIDs: index == 0 ? Array(nodeIDs.dropFirst()) : [],
            isHidden: false,
            alphaValue: 1,
            wantsLayer: true,
            isFlipped: true,
            clippingEnabled: false,
            depth: index == 0 ? 0 : 1
        )
    }
    return ViewScopeCapturePayload(
        host: makeHostInfo(host),
        capturedAt: Date(),
        summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
        rootNodeIDs: [rootID],
        nodes: nodes,
        captureID: captureID
    )
}

@MainActor
private func makeDetail(nodeID: String, host: ViewScopeHostAnnouncement, captureID: String = "c") -> ViewScopeNodeDetailPayload {
    ViewScopeNodeDetailPayload(
        nodeID: nodeID,
        host: makeHostInfo(host),
        sections: [],
        constraints: [],
        ancestry: [nodeID],
        screenshotPNGBase64: nil,
        screenshotSize: .zero,
        highlightedRect: .zero,
        consoleTargets: [
            ViewScopeConsoleTargetDescriptor(
                reference: ViewScopeRemoteObjectReference(
                    captureID: captureID,
                    objectID: "0x\(nodeID)",
                    kind: .view,
                    className: "NSView",
                    address: "0x\(nodeID)",
                    sourceNodeID: nodeID
                ),
                title: "<NSView: 0x\(nodeID)>"
            )
        ]
    )
}

private enum ScriptedSessionError: Error {
    case timeout
    case missingCapture
}

/// 可编排响应的会话：抓取可以立即返回、失败或挂起到手动放行。
@MainActor
private final class ScriptedWorkspaceSession: WorkspaceSessionProtocol {
    enum CaptureStep {
        case immediate(ViewScopeCapturePayload)
        case failure(Error)
        case pending
    }

    struct Mutation {
        let nodeID: String
        let property: ViewScopeEditableProperty
    }

    let announcement: ViewScopeHostAnnouncement
    var negotiatedProtocolVersion: Int = 3
    var defaultCapture: ViewScopeCapturePayload?
    var detailHandler: (String) -> ViewScopeNodeDetailPayload = { _ in
        fatalError("detailHandler not configured")
    }
    private(set) var captureRequestCount = 0
    private(set) var detailRequestCount = 0
    private(set) var disconnectCount = 0
    private(set) var mutations: [Mutation] = []
    private(set) var consoleExpressions: [String] = []
    private var captureSteps: [CaptureStep] = []
    private var pendingCaptureContinuations: [CheckedContinuation<ViewScopeCapturePayload, Error>] = []
    private var unexpectedDisconnectHandler: (@MainActor (Error) -> Void)?

    init(announcement: ViewScopeHostAnnouncement) {
        self.announcement = announcement
    }

    func enqueueCapture(_ step: CaptureStep) {
        captureSteps.append(step)
    }

    func resolvePendingCapture(with capture: ViewScopeCapturePayload) {
        guard pendingCaptureContinuations.isEmpty == false else {
            return
        }
        pendingCaptureContinuations.removeFirst().resume(returning: capture)
    }

    func simulateUnexpectedDisconnect() {
        unexpectedDisconnectHandler?(ViewScopeClientSession.SessionError.disconnected)
    }

    func open() async throws -> ViewScopeServerHelloPayload {
        ViewScopeServerHelloPayload(host: makeHostInfo(announcement), protocolVersion: negotiatedProtocolVersion)
    }

    func requestCapture() async throws -> ViewScopeCapturePayload {
        captureRequestCount += 1
        guard captureSteps.isEmpty == false else {
            if let defaultCapture {
                return defaultCapture
            }
            throw ScriptedSessionError.missingCapture
        }
        switch captureSteps.removeFirst() {
        case .immediate(let capture):
            return capture
        case .failure(let error):
            throw error
        case .pending:
            return try await withCheckedThrowingContinuation { continuation in
                pendingCaptureContinuations.append(continuation)
            }
        }
    }

    func requestNodeDetail(nodeID: String) async throws -> ViewScopeNodeDetailPayload {
        detailRequestCount += 1
        return detailHandler(nodeID)
    }

    func highlight(nodeID: String, duration: TimeInterval) async throws {}

    func applyMutation(nodeID: String, property: ViewScopeEditableProperty) async throws {
        mutations.append(Mutation(nodeID: nodeID, property: property))
    }

    func invokeConsole(
        target: ViewScopeRemoteObjectReference,
        expression: String
    ) async throws -> ViewScopeConsoleInvokeResponsePayload {
        consoleExpressions.append(expression)
        return ViewScopeConsoleInvokeResponsePayload(submittedExpression: expression, target: target, resultDescription: "ok")
    }

    func disconnect() {
        disconnectCount += 1
        let continuations = pendingCaptureContinuations
        pendingCaptureContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: ViewScopeClientSession.SessionError.disconnected)
        }
    }

    func setUnexpectedDisconnectHandler(_ handler: (@MainActor (Error) -> Void)?) {
        unexpectedDisconnectHandler = handler
    }
}
