import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct WorkspaceStoreConnectionLifecycleTests {
    // Pins extracted Task 2 collaborators so the refactor keeps real module boundaries.
    @Test func workspaceCoordinatorTypesAreVisibleToLifecycleCoverage() {
        _ = WorkspaceConnectionCoordinator.self
        _ = WorkspaceCaptureCoordinator.self
        _ = WorkspaceConsoleController.self
    }

    @Test func switchingHostsClearsVisibleStateBeforeNewCaptureArrives() async throws {
        let hostA = makeHost(id: "host-a", bundleID: "cn.vanjay.hostA", name: "Host A", port: 7101)
        let hostB = makeHost(id: "host-b", bundleID: "cn.vanjay.hostB", name: "Host B", port: 7102)

        let sessionA = FakeWorkspaceSession(
            announcement: hostA,
            openResponses: [.resolved(.success(makeHello(for: hostA)))],
            captureResponses: [.resolved(.success(makeCapture(nodeID: "old-node", host: hostA)))],
            nodeDetailResponses: ["old-node": [.resolved(.success(makeDetail(nodeID: "old-node", host: hostA)))]]
        )
        let sessionB = FakeWorkspaceSession(
            announcement: hostB,
            openResponses: [.resolved(.success(makeHello(for: hostB)))],
            captureResponses: [.pending],
            nodeDetailResponses: ["new-node": [.resolved(.success(makeDetail(nodeID: "new-node", host: hostB)))]]
        )

        let store = try makeStore(sessions: [hostA.identifier: sessionA, hostB.identifier: sessionB])
        defer { store.shutdown() }

        await store.connect(to: hostA)
        await store.selectNode(withID: "old-node", highlightInHost: false)

        #expect(store.capture?.rootNodeIDs == ["old-node"])
        #expect(store.selectedNodeID == "old-node")
        #expect(store.selectedNodeDetail?.nodeID == "old-node")

        let switchTask = Task { await store.connect(to: hostB) }
        try await waitUntil { await sessionB.captureRequestCount == 1 }

        #expect(store.isLoadingWorkspace)
        #expect(store.capture == nil)
        #expect(store.selectedNodeID == nil)
        #expect(store.selectedNodeDetail == nil)
        #expect(store.focusedNodeID == nil)
        #expect(store.errorMessage == nil)

        await sessionB.resolveNextCapture(with: .success(makeCapture(nodeID: "new-node", host: hostB)))
        await switchTask.value
        #expect(store.isLoadingWorkspace == false)
    }

    @Test func staleCaptureResponseFromPreviousHostIsIgnored() async throws {
        let hostA = makeHost(id: "host-a", bundleID: "cn.vanjay.hostA", name: "Host A", port: 7103)
        let hostB = makeHost(id: "host-b", bundleID: "cn.vanjay.hostB", name: "Host B", port: 7104)

        let sessionA = FakeWorkspaceSession(
            announcement: hostA,
            openResponses: [.resolved(.success(makeHello(for: hostA)))],
            captureResponses: [
                .resolved(.success(makeCapture(nodeID: "old-node", host: hostA))),
                .pending
            ],
            nodeDetailResponses: ["old-node": [.resolved(.success(makeDetail(nodeID: "old-node", host: hostA)))]]
        )
        let sessionB = FakeWorkspaceSession(
            announcement: hostB,
            openResponses: [.resolved(.success(makeHello(for: hostB)))],
            captureResponses: [.pending],
            nodeDetailResponses: ["new-node": [.resolved(.success(makeDetail(nodeID: "new-node", host: hostB)))]]
        )

        let store = try makeStore(sessions: [hostA.identifier: sessionA, hostB.identifier: sessionB])
        defer { store.shutdown() }

        await store.connect(to: hostA)
        await store.selectNode(withID: "old-node", highlightInHost: false)

        let staleCaptureTask = Task { await store.refreshCapture() }
        try await Task.sleep(nanoseconds: 50_000_000)

        let switchTask = Task { await store.connect(to: hostB) }
        try await waitUntil { await sessionB.captureRequestCount == 1 }

        #expect(store.capture == nil)
        #expect(store.selectedNodeID == nil)
        #expect(store.selectedNodeDetail == nil)

        await sessionA.resolveNextCapture(with: .success(makeCapture(nodeID: "stale-node", host: hostA)))
        await staleCaptureTask.value
        #expect(store.capture == nil)

        let expectedCapture = makeCapture(nodeID: "new-node", host: hostB)
        await sessionB.resolveNextCapture(with: .success(expectedCapture))
        await switchTask.value

        #expect(store.capture?.rootNodeIDs == expectedCapture.rootNodeIDs)
        #expect(store.capture?.host.bundleIdentifier == hostB.bundleIdentifier)
    }

    @Test func staleDetailResponseAfterHostSwitchIsIgnored() async throws {
        let hostA = makeHost(id: "host-a", bundleID: "cn.vanjay.hostA", name: "Host A", port: 7105)
        let hostB = makeHost(id: "host-b", bundleID: "cn.vanjay.hostB", name: "Host B", port: 7106)

        let sessionA = FakeWorkspaceSession(
            announcement: hostA,
            openResponses: [.resolved(.success(makeHello(for: hostA)))],
            captureResponses: [.resolved(.success(makeCapture(nodeID: "old-node", host: hostA)))],
            nodeDetailResponses: [
                "old-node": [
                    .resolved(.success(makeDetail(nodeID: "old-node", host: hostA))),
                    .pending
                ]
            ]
        )
        let sessionB = FakeWorkspaceSession(
            announcement: hostB,
            openResponses: [.resolved(.success(makeHello(for: hostB)))],
            captureResponses: [.pending],
            nodeDetailResponses: ["new-node": [.resolved(.success(makeDetail(nodeID: "new-node", host: hostB)))]]
        )

        let store = try makeStore(sessions: [hostA.identifier: sessionA, hostB.identifier: sessionB])
        defer { store.shutdown() }

        await store.connect(to: hostA)
        await store.selectNode(withID: "old-node", highlightInHost: false)

        let staleDetailTask = Task { await store.selectNode(withID: "old-node", highlightInHost: false) }
        try await waitUntil { await sessionA.detailRequestCount(for: "old-node") == 2 }

        let switchTask = Task { await store.connect(to: hostB) }
        try await waitUntil { await sessionB.captureRequestCount == 1 }

        #expect(store.capture == nil)
        #expect(store.selectedNodeID == nil)
        #expect(store.selectedNodeDetail == nil)

        await sessionA.resolveNextDetail(nodeID: "old-node", with: .success(makeDetail(nodeID: "old-node", host: hostA)))
        await staleDetailTask.value
        #expect(store.selectedNodeDetail == nil)
        #expect(store.selectedNodeID == nil)

        await sessionB.resolveNextCapture(with: .success(makeCapture(nodeID: "new-node", host: hostB)))
        await switchTask.value
        #expect(store.selectedNodeDetail?.nodeID == "new-node")
    }

    @Test func successfulMutationReloadsSelectedNodeDetailForSameSelection() async throws {
        let host = makeHost(id: "host-a", bundleID: "cn.vanjay.hostA", name: "Host A", port: 7107)
        let session = FakeWorkspaceSession(
            announcement: host,
            openResponses: [.resolved(.success(makeHello(for: host)))],
            captureResponses: [
                .resolved(.success(makeCapture(nodeID: "node-1", host: host))),
                .resolved(.success(makeCapture(nodeID: "node-1", host: host)))
            ],
            nodeDetailResponses: [
                "node-1": [
                    .resolved(.success(makeDetail(nodeID: "node-1", host: host, alphaValue: "0.80"))),
                    .resolved(.success(makeDetail(nodeID: "node-1", host: host, alphaValue: "0.35")))
                ]
            ]
        )

        let store = try makeStore(sessions: [host.identifier: session])
        defer { store.shutdown() }

        await store.connect(to: host)

        #expect(alphaValue(in: store.selectedNodeDetail) == "0.80")
        #expect(await session.detailRequestCount(for: "node-1") == 1)

        let success = await store.applyMutation(nodeID: "node-1", property: .number(key: "alpha", value: 0.35))

        #expect(success)
        #expect(await session.captureRequestCount == 2)
        #expect(await session.detailRequestCount(for: "node-1") == 2)
        #expect(alphaValue(in: store.selectedNodeDetail) == "0.35")
    }

    @Test func manualRefreshClearsVisibleStateBeforeFreshCaptureArrives() async throws {
        let host = makeHost(id: "host-a", bundleID: "cn.vanjay.hostA", name: "Host A", port: 7108)
        let session = FakeWorkspaceSession(
            announcement: host,
            openResponses: [.resolved(.success(makeHello(for: host)))],
            captureResponses: [
                .resolved(.success(makeCapture(nodeID: "node-1", host: host))),
                .pending
            ],
            nodeDetailResponses: [
                "node-1": [
                    .resolved(.success(makeDetail(nodeID: "node-1", host: host))),
                    .resolved(.success(makeDetail(nodeID: "node-1", host: host)))
                ]
            ]
        )

        let store = try makeStore(sessions: [host.identifier: session])
        defer { store.shutdown() }

        await store.connect(to: host)
        store.setFocusedNode("node-1")

        #expect(store.capture?.rootNodeIDs == ["node-1"])
        #expect(store.selectedNodeID == "node-1")
        #expect(store.selectedNodeDetail?.nodeID == "node-1")
        #expect(store.focusedNodeID == "node-1")

        var observedRefreshRequest = false
        var observedLoadingState = false
        var observedClearedCapture = false
        var observedClearedSelection = false
        var observedClearedDetail = false
        var observedClearedFocus = false
        session.onCaptureRequest = {
            observedRefreshRequest = true
            observedLoadingState = store.isLoadingWorkspace
            observedClearedCapture = store.capture == nil
            observedClearedSelection = store.selectedNodeID == nil
            observedClearedDetail = store.selectedNodeDetail == nil
            observedClearedFocus = store.focusedNodeID == nil
        }

        await session.resolveNextCapture(with: .success(makeCapture(nodeID: "node-1", host: host)))
        await store.refreshCapture(
            forceReloadSelectionDetail: true,
            clearingVisibleState: true
        )
        #expect(observedRefreshRequest)
        #expect(observedLoadingState)
        #expect(observedClearedCapture)
        #expect(observedClearedSelection)
        #expect(observedClearedDetail)
        #expect(observedClearedFocus)
        #expect(store.isLoadingWorkspace == false)

        #expect(store.capture?.rootNodeIDs == ["node-1"])
        #expect(store.selectedNodeID == "node-1")
        #expect(store.selectedNodeDetail?.nodeID == "node-1")
        #expect(store.focusedNodeID == "node-1")
    }

    @Test func disconnectClearsConnectionOwnedStateButKeepsSettingsBackedPreviewDefaults() async throws {
        let host = makeHost(id: "host-a", bundleID: "cn.vanjay.hostA", name: "Host A", port: 7109)
        let session = FakeWorkspaceSession(
            announcement: host,
            openResponses: [.resolved(.success(makeHello(for: host)))],
            captureResponses: [.resolved(.success(makeCapture(nodeID: "node-1", host: host, captureID: "capture-before-disconnect")))],
            nodeDetailResponses: [
                "node-1": [
                    .resolved(.success(makeDetail(nodeID: "node-1", host: host, captureID: "capture-before-disconnect")))
                ]
            ]
        )

        let defaults = try #require(UserDefaults(suiteName: "WorkspaceStoreLifecycleTests.disconnect.\(UUID().uuidString)"))
        defaults.set(48.0, forKey: "ViewScope.previewLayerSpacing")
        defaults.set(false, forKey: "ViewScope.previewShowsLayerBorders")
        let settings = AppSettings(defaults: defaults, environment: [:])
        let store = try WorkspaceStore(
            settings: settings,
            updateManager: UpdateManager(settings: settings),
            sessionFactory: { _ in session }
        )
        defer { store.shutdown() }

        await store.connect(to: host)
        store.setFocusedNode("node-1")
        store.setPreviewScale(2.4)
        store.setPreviewDisplayMode(.layered)

        #expect(store.consoleCandidateTargets.isEmpty == false)
        #expect(store.consoleCurrentTarget != nil)
        #expect(store.previewLayerSpacing == 48)
        #expect(store.previewShowsLayerBorders == false)

        store.disconnect()

        #expect(store.connectionState == .idle)
        #expect(store.capture == nil)
        #expect(store.selectedNodeID == nil)
        #expect(store.selectedNodeDetail == nil)
        #expect(store.focusedNodeID == nil)
        #expect(store.errorMessage == nil)
        #expect(store.consoleCandidateTargets.isEmpty)
        #expect(store.consoleCurrentTarget == nil)
        #expect(store.consoleRecentTargets.isEmpty)
        #expect(store.consoleIsLoadingTarget == false)
        #expect(store.previewScale == 1)
        #expect(store.previewDisplayMode == .flat)
        #expect(store.previewLayerSpacing == 48)
        #expect(store.previewShowsLayerBorders == false)
    }

    @Test func refreshCaptureRebuildsSelectionAndConsoleStateThroughCoordinator() async throws {
        let host = makeHost(id: "host-a", bundleID: "cn.vanjay.hostA", name: "Host A", port: 7110)
        let firstCapture = makeCapture(nodeID: "node-1", host: host, captureID: "capture-before-refresh")
        let refreshedCapture = makeCapture(nodeID: "node-1", host: host, captureID: "capture-after-refresh")
        let session = FakeWorkspaceSession(
            announcement: host,
            openResponses: [.resolved(.success(makeHello(for: host)))],
            captureResponses: [
                .resolved(.success(firstCapture)),
                .resolved(.success(refreshedCapture))
            ],
            nodeDetailResponses: [
                "node-1": [
                    .resolved(.success(makeDetail(nodeID: "node-1", host: host, captureID: "capture-before-refresh"))),
                    .resolved(.success(makeDetail(nodeID: "node-1", host: host, captureID: "capture-after-refresh", alphaValue: "0.35")))
                ]
            ]
        )

        let store = try makeStore(sessions: [host.identifier: session])
        defer { store.shutdown() }

        await store.connect(to: host)
        store.setFocusedNode("node-1")

        #expect(store.selectedNodeID == "node-1")
        #expect(store.focusedNodeID == "node-1")
        #expect(store.consoleCurrentTarget?.reference.captureID == "capture-before-refresh")
        #expect(alphaValue(in: store.selectedNodeDetail) == nil)

        await store.refreshCapture(forceReloadSelectionDetail: true)

        #expect(store.capture?.captureID == "capture-after-refresh")
        #expect(store.selectedNodeID == "node-1")
        #expect(store.focusedNodeID == "node-1")
        #expect(store.selectedNodeDetail?.nodeID == "node-1")
        #expect(alphaValue(in: store.selectedNodeDetail) == "0.35")
        #expect(store.consoleCandidateTargets.allSatisfy { $0.reference.captureID == "capture-after-refresh" })
        #expect(store.consoleCurrentTarget?.reference.captureID == "capture-after-refresh")
    }

    @Test func discoveryDropDoesNotDisconnectHealthyConnectedSession() async throws {
        let host = makeHost(id: "host-discovery-flap", bundleID: "cn.vanjay.MachOKnife", name: "MachOKnife", port: 7111)
        let initialCapture = makeCapture(nodeID: "node-1", host: host, captureID: "capture-before-discovery-drop")
        let refreshedCapture = makeCapture(nodeID: "node-1", host: host, captureID: "capture-after-discovery-drop")
        let session = FakeWorkspaceSession(
            announcement: host,
            openResponses: [.resolved(.success(makeHello(for: host)))],
            captureResponses: [
                .resolved(.success(initialCapture)),
                .resolved(.success(refreshedCapture))
            ],
            nodeDetailResponses: [
                "node-1": [
                    .resolved(.success(makeDetail(nodeID: "node-1", host: host, captureID: initialCapture.captureID))),
                    .resolved(.success(makeDetail(nodeID: "node-1", host: host, captureID: refreshedCapture.captureID)))
                ]
            ]
        )

        let store = try makeStore(sessions: [host.identifier: session])
        defer { store.shutdown() }

        store.start()
        publishAnnouncement(host)
        try await waitUntil {
            store.discoveredHosts.contains(where: { $0.identifier == host.identifier })
        }

        await store.connect(to: host)
        #expect(store.connectionState == .connected(host))
        #expect(await session.captureRequestCount == 1)

        publishTermination(identifier: host.identifier)
        try await waitUntil {
            store.discoveredHosts.contains(where: { $0.identifier == host.identifier }) == false
        }

        #expect(store.connectionState == .connected(host))
        #expect(store.errorMessage == nil)

        await store.refreshCapture(forceReloadSelectionDetail: true)

        #expect(store.connectionState == .connected(host))
        #expect(await session.captureRequestCount == 2)
        #expect(store.capture?.captureID == refreshedCapture.captureID)
        #expect(store.selectedNodeDetail?.host.bundleIdentifier == host.bundleIdentifier)
    }

    private func makeStore(sessions: [String: FakeWorkspaceSession]) throws -> WorkspaceStore {
        let defaults = try #require(UserDefaults(suiteName: "WorkspaceStoreLifecycleTests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, environment: [:])
        let updateManager = UpdateManager(settings: settings)
        return try WorkspaceStore(
            settings: settings,
            updateManager: updateManager,
            sessionFactory: { host in
                sessions[host.identifier] ?? FakeWorkspaceSession(
                    announcement: host,
                    openResponses: [.resolved(.failure(FakeTestError.missingSession(host.identifier)))],
                    captureResponses: [],
                    nodeDetailResponses: [:]
                )
            }
        )
    }

    private func makeHost(id: String, bundleID: String, name: String, port: UInt16) -> ViewScopeHostAnnouncement {
        ViewScopeHostAnnouncement(
            identifier: id,
            authToken: "token-\(id)",
            displayName: name,
            bundleIdentifier: bundleID,
            version: "1.0.0",
            build: "1",
            processIdentifier: 101,
            port: port,
            updatedAt: Date(),
            supportsHighlighting: true,
            protocolVersion: viewScopeCurrentProtocolVersion,
            runtimeVersion: viewScopeServerRuntimeVersion
        )
    }

    private func makeHostInfo(from host: ViewScopeHostAnnouncement) -> ViewScopeHostInfo {
        ViewScopeHostInfo(
            displayName: host.displayName,
            bundleIdentifier: host.bundleIdentifier,
            version: host.version,
            build: host.build,
            processIdentifier: host.processIdentifier,
            runtimeVersion: host.runtimeVersion,
            supportsHighlighting: host.supportsHighlighting
        )
    }

    private func makeHello(for host: ViewScopeHostAnnouncement) -> ViewScopeServerHelloPayload {
        ViewScopeServerHelloPayload(host: makeHostInfo(from: host), protocolVersion: viewScopeCurrentProtocolVersion)
    }

    private func makeCapture(
        nodeID: String,
        host: ViewScopeHostAnnouncement,
        captureID: String = UUID().uuidString
    ) -> ViewScopeCapturePayload {
        let node = ViewScopeHierarchyNode(
            id: nodeID,
            parentID: nil,
            kind: .view,
            className: "NSView",
            title: nodeID,
            subtitle: nil,
            frame: .zero,
            bounds: .zero,
            childIDs: [],
            isHidden: false,
            alphaValue: 1,
            wantsLayer: true,
            isFlipped: true,
            clippingEnabled: false,
            depth: 0
        )
        return ViewScopeCapturePayload(
            host: makeHostInfo(from: host),
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(nodeCount: 1, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 10),
            rootNodeIDs: [nodeID],
            nodes: [nodeID: node],
            captureID: captureID
        )
    }

    private func makeDetail(
        nodeID: String,
        host: ViewScopeHostAnnouncement,
        captureID: String = UUID().uuidString,
        alphaValue: String? = nil
    ) -> ViewScopeNodeDetailPayload {
        ViewScopeNodeDetailPayload(
            nodeID: nodeID,
            host: makeHostInfo(from: host),
            sections: alphaValue.map {
                [
                    ViewScopePropertySection(
                        title: "Rendering",
                        items: [ViewScopePropertyItem(title: "Alpha", value: $0, editable: .number(key: "alpha", value: 0))]
                    )
                ]
            } ?? [],
            constraints: [],
            ancestry: [host.displayName, nodeID],
            screenshotPNGBase64: nil,
            screenshotSize: .zero,
            highlightedRect: .zero,
            consoleTargets: [
                ViewScopeConsoleTargetDescriptor(
                    reference: ViewScopeRemoteObjectReference(
                        captureID: captureID,
                        objectID: "view-\(nodeID)-\(captureID)",
                        kind: .view,
                        className: "NSView",
                        address: "0x\(nodeID)",
                        sourceNodeID: nodeID
                    ),
                    title: "<NSView: 0x\(nodeID)>",
                    subtitle: nodeID
                )
            ]
        )
    }

    private func alphaValue(in detail: ViewScopeNodeDetailPayload?) -> String? {
        detail?.sections
            .flatMap(\.items)
            .first(where: { $0.title == "Alpha" })?
            .value
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while await condition() == false {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                throw FakeTestError.timeout
            }
            await Task.yield()
        }
    }

    private func publishAnnouncement(_ host: ViewScopeHostAnnouncement) {
        guard let data = try? JSONEncoder.viewScope.encode(host),
              let payload = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to encode host announcement for test setup.")
            return
        }

        DistributedNotificationCenter.default().postNotificationName(
            viewScopeDiscoveryAnnouncementNotification,
            object: nil,
            userInfo: ["payload": payload],
            options: [.deliverImmediately]
        )
    }

    private func publishTermination(identifier: String) {
        DistributedNotificationCenter.default().postNotificationName(
            viewScopeDiscoveryTerminationNotification,
            object: nil,
            userInfo: ["identifier": identifier],
            options: [.deliverImmediately]
        )
    }
}

private enum FakeTestError: Error, Sendable {
    case timeout
    case disconnected
    case missingSession(String)
    case missingResponse
}

@MainActor
private final class FakeWorkspaceSession: WorkspaceSessionProtocol {
    enum Response<Value: Sendable> {
        case resolved(Result<Value, FakeTestError>)
        case pending
    }

    let announcement: ViewScopeHostAnnouncement

    private var openQueue: [ControlledResponse<ViewScopeServerHelloPayload>]
    private var captureQueue: [ControlledResponse<ViewScopeCapturePayload>]
    private var nodeDetailQueues: [String: [ControlledResponse<ViewScopeNodeDetailPayload>]]
    private var inFlightCaptures: [ControlledResponse<ViewScopeCapturePayload>] = []
    private var inFlightDetails: [String: [ControlledResponse<ViewScopeNodeDetailPayload>]] = [:]
    private(set) var captureRequestCount = 0
    private var detailRequestCounts: [String: Int] = [:]
    private var isDisconnected = false
    var onCaptureRequest: (() -> Void)?

    init(
        announcement: ViewScopeHostAnnouncement,
        openResponses: [Response<ViewScopeServerHelloPayload>],
        captureResponses: [Response<ViewScopeCapturePayload>],
        nodeDetailResponses: [String: [Response<ViewScopeNodeDetailPayload>]]
    ) {
        self.announcement = announcement
        self.openQueue = openResponses.map(ControlledResponse.init)
        self.captureQueue = captureResponses.map(ControlledResponse.init)
        self.nodeDetailQueues = nodeDetailResponses.mapValues { $0.map(ControlledResponse.init) }
    }

    func open() async throws -> ViewScopeServerHelloPayload {
        guard !isDisconnected else { throw FakeTestError.disconnected }
        guard !openQueue.isEmpty else { throw FakeTestError.missingResponse }
        return try await openQueue.removeFirst().wait()
    }

    func requestCapture() async throws -> ViewScopeCapturePayload {
        guard !isDisconnected else { throw FakeTestError.disconnected }
        captureRequestCount += 1
        guard !captureQueue.isEmpty else { throw FakeTestError.missingResponse }
        let response = captureQueue.removeFirst()
        if response.hasResolved == false {
            inFlightCaptures.append(response)
        }
        onCaptureRequest?()
        return try await response.wait()
    }

    func requestNodeDetail(nodeID: String) async throws -> ViewScopeNodeDetailPayload {
        guard !isDisconnected else { throw FakeTestError.disconnected }
        detailRequestCounts[nodeID, default: 0] += 1
        guard var queue = nodeDetailQueues[nodeID], !queue.isEmpty else { throw FakeTestError.missingResponse }
        let response = queue.removeFirst()
        nodeDetailQueues[nodeID] = queue
        if response.hasResolved == false {
            inFlightDetails[nodeID, default: []].append(response)
        }
        return try await response.wait()
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
            resultDescription: "<\(target.className): \(target.address ?? "0x0")>"
        )
    }

    func disconnect() {
        guard !isDisconnected else { return }
        isDisconnected = true
        for response in inFlightCaptures where response.hasResolved == false {
            response.resolve(with: .failure(.disconnected))
        }
        for queue in inFlightDetails.values {
            for response in queue where response.hasResolved == false {
                response.resolve(with: .failure(.disconnected))
            }
        }
    }

    func detailRequestCount(for nodeID: String) -> Int {
        detailRequestCounts[nodeID, default: 0]
    }

    func resolveNextCapture(with result: Result<ViewScopeCapturePayload, FakeTestError>) {
        if let response = inFlightCaptures.first(where: { $0.hasResolved == false }) {
            response.resolve(with: result)
            return
        }
        guard let response = captureQueue.first(where: { $0.hasResolved == false }) else { return }
        response.resolve(with: result)
    }

    func resolveNextDetail(nodeID: String, with result: Result<ViewScopeNodeDetailPayload, FakeTestError>) {
        if let queue = inFlightDetails[nodeID],
           let response = queue.first(where: { $0.hasResolved == false }) {
            response.resolve(with: result)
            return
        }
        guard let queue = nodeDetailQueues[nodeID],
              let response = queue.first(where: { $0.hasResolved == false }) else { return }
        response.resolve(with: result)
    }
}

@MainActor
private final class ControlledResponse<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, FakeTestError>?
    private(set) var hasResolved = false

    init(_ response: FakeWorkspaceSession.Response<Value>) {
        switch response {
        case .resolved(let result):
            self.result = result
            self.hasResolved = true
        case .pending:
            self.result = nil
            self.hasResolved = false
        }
    }

    func wait() async throws -> Value {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(with result: Result<Value, FakeTestError>) {
        hasResolved = true
        if let continuation {
            self.continuation = nil
            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
            return
        }
        self.result = result
    }
}

private extension JSONEncoder {
    static var viewScope: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
