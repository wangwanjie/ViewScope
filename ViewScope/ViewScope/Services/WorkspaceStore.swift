import AppKit
import Combine
import Foundation
import ViewScopeServer

@MainActor
/// Coordinates discovery, connections, captures, selection, and preview-specific workspace state.
final class WorkspaceStore: NSObject {
    typealias SessionFactory = @MainActor (ViewScopeHostAnnouncement) -> any WorkspaceSessionProtocol

    @Published private(set) var discoveredHosts: [ViewScopeHostAnnouncement] = []
    @Published private(set) var recentHosts: [RecentHostRecord] = []
    @Published private(set) var connectionState: WorkspaceConnectionState = .idle
    @Published private(set) var capture: ViewScopeCapturePayload?
    @Published private(set) var selectedNodeDetail: ViewScopeNodeDetailPayload?
    @Published private(set) var selectedNodeID: String?
    @Published private(set) var focusedNodeID: String?
    @Published private(set) var previewScale: CGFloat = 1
    @Published private(set) var previewDisplayMode: WorkspacePreviewDisplayMode = .flat
    @Published private(set) var captureInsight: CaptureHistoryInsight = .empty
    @Published private(set) var errorMessage: String?

    let settings: AppSettings
    let updateManager: UpdateManager

    private let database: AppDatabase
    private let sessionFactory: SessionFactory
    private let discoveryCenter = DiscoveryCenter()
    private var session: (any WorkspaceSessionProtocol)?
    private var cancellables = Set<AnyCancellable>()
    private var autoRefreshTimer: Timer?
    private let previewFixtureEnabled: Bool
    private var connectionGeneration: UInt64 = 0

    init(
        settings: AppSettings = .shared,
        updateManager: UpdateManager? = nil,
        sessionFactory: @escaping SessionFactory = { announcement in
            ViewScopeClientSession(announcement: announcement)
        }
    ) throws {
        self.settings = settings
        self.updateManager = updateManager ?? UpdateManager(settings: settings)
        self.sessionFactory = sessionFactory
        self.previewFixtureEnabled = ProcessInfo.processInfo.environment["VIEWSCOPE_PREVIEW_FIXTURE"] == "1"

        let appSupportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ViewScope", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        self.database = try AppDatabase(databaseURL: appSupportDirectory.appendingPathComponent("workspace.sqlite"))
        super.init()
        bindDiscovery()
        bindSettings()
    }

    var selectedNode: ViewScopeHierarchyNode? {
        node(withID: selectedNodeID)
    }

    var focusedNode: ViewScopeHierarchyNode? {
        node(withID: focusedNodeID)
    }

    func start() {
        reloadRecentHosts()
        if previewFixtureEnabled {
            let previewAnnouncement = SampleFixture.announcement()
            discoveredHosts = [previewAnnouncement]
            connectionState = .connected(previewAnnouncement)
            capture = SampleFixture.capture()
            captureInsight = CaptureHistoryInsight(totalCaptures: 12, averageDurationMilliseconds: 203, mostRecentDurationMilliseconds: 184)
            Task { await selectNode(withID: "window-0-view-1-2", highlightInHost: false) }
            return
        }
        discoveryCenter.start()
    }

    func node(withID nodeID: String?) -> ViewScopeHierarchyNode? {
        guard let nodeID else { return nil }
        return capture?.nodes[nodeID]
    }

    func connect(to host: ViewScopeHostAnnouncement) async {
        if previewFixtureEnabled {
            connectionState = .connected(host)
            capture = SampleFixture.capture()
            await selectNode(withID: "window-0-view-1-2", highlightInHost: false)
            return
        }

        let generation = beginNewConnectionGeneration()
        prepareForHostSwitch()
        connectionState = .connecting(host.displayName)
        let session = sessionFactory(host)
        self.session = session

        do {
            _ = try await session.open()
            guard isActiveConnection(generation: generation, session: session) else {
                session.disconnect()
                return
            }
            connectionState = .connected(host)
            try database.recordConnection(host: host)
            reloadRecentHosts()
            startAutoRefreshTimerIfNeeded()
            await refreshCapture()
        } catch {
            guard isActiveConnection(generation: generation, session: session) else {
                return
            }
            self.session = nil
            connectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func connect(using record: RecentHostRecord) async {
        guard let host = discoveredHosts.first(where: { $0.bundleIdentifier == record.bundleIdentifier }) else {
            connectionState = .failed(L10n.recentHostNotRunning)
            return
        }
        await connect(to: host)
    }

    func disconnect() {
        _ = beginNewConnectionGeneration()
        prepareForHostSwitch()
        captureInsight = .empty
        previewScale = 1
        previewDisplayMode = .flat
        connectionState = .idle
    }

    func shutdown() {
        disconnect()
        discoveryCenter.stop()
    }

    func refreshCapture() async {
        let generation = connectionGeneration
        guard case .connected(let host) = connectionState else { return }

        if previewFixtureEnabled {
            capture = SampleFixture.capture()
            await normalizeSelectionAfterCaptureUpdate(preferredNodeID: selectedNodeID)
            return
        }

        guard let session else { return }

        do {
            let capture = try await session.requestCapture()
            guard isActiveConnection(generation: generation, session: session) else {
                return
            }
            self.capture = capture
            errorMessage = nil
            try database.recordCapture(for: host, summary: capture.summary)
            captureInsight = try database.captureInsight(for: host.bundleIdentifier)
            await normalizeSelectionAfterCaptureUpdate(preferredNodeID: selectedNodeID)
        } catch {
            guard isActiveConnection(generation: generation, session: session) else {
                return
            }
            errorMessage = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
            self.session = nil
        }
    }

    func selectNode(withID nodeID: String?, highlightInHost: Bool = true) async {
        let generation = connectionGeneration
        selectedNodeID = nodeID
        guard let nodeID else {
            selectedNodeDetail = nil
            return
        }

        if previewFixtureEnabled {
            selectedNodeDetail = SampleFixture.detail(for: nodeID)
            return
        }

        guard let session else { return }
        do {
            let detail = try await session.requestNodeDetail(nodeID: nodeID)
            guard isActiveConnection(generation: generation, session: session),
                  selectedNodeID == nodeID else {
                return
            }
            selectedNodeDetail = detail
            errorMessage = nil
            if highlightInHost, settings.autoHighlightSelection {
                try await session.highlight(nodeID: nodeID, duration: 1.25)
            }
        } catch {
            guard isActiveConnection(generation: generation, session: session) else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func highlightCurrentSelection() async {
        let generation = connectionGeneration
        guard let selectedNodeID else { return }
        if previewFixtureEnabled { return }
        guard let session else { return }
        do {
            try await session.highlight(nodeID: selectedNodeID, duration: 1.25)
        } catch {
            guard isActiveConnection(generation: generation, session: session) else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func applyMutation(nodeID: String, property: ViewScopeEditableProperty) async -> Bool {
        let generation = connectionGeneration
        guard previewFixtureEnabled == false else { return false }
        guard let session else { return false }

        selectedNodeID = nodeID

        do {
            try await session.applyMutation(nodeID: nodeID, property: property)
            guard isActiveConnection(generation: generation, session: session) else {
                return false
            }
            await refreshCapture()
            guard generation == connectionGeneration else {
                return false
            }
            return true
        } catch {
            guard isActiveConnection(generation: generation, session: session) else {
                return false
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggleVisibility(for nodeID: String) async -> Bool {
        guard let node = node(withID: nodeID), node.kind == .view else { return false }
        return await applyMutation(nodeID: nodeID, property: .toggle(key: "hidden", value: !node.isHidden))
    }

    func setFocusedNode(_ nodeID: String?) {
        guard let nodeID else {
            focusedNodeID = nil
            return
        }
        guard capture?.nodes[nodeID] != nil else { return }
        focusedNodeID = nodeID
    }

    func focusSelectedNode() {
        setFocusedNode(selectedNodeID)
    }

    func clearFocus() {
        focusedNodeID = nil
    }

    func zoomInPreview() {
        setPreviewScale(previewScale * 1.2)
    }

    func zoomOutPreview() {
        setPreviewScale(previewScale / 1.2)
    }

    func resetPreviewZoom() {
        setPreviewScale(1)
    }

    func setPreviewScale(_ value: CGFloat) {
        previewScale = clampedPreviewScale(value)
    }

    func setPreviewDisplayMode(_ mode: WorkspacePreviewDisplayMode) {
        previewDisplayMode = mode
    }

    private func clampedPreviewScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.35), 4)
    }

    private func normalizeSelectionAfterCaptureUpdate(preferredNodeID: String?) async {
        guard let capture else {
            selectedNodeID = nil
            selectedNodeDetail = nil
            focusedNodeID = nil
            return
        }

        if let focusedNodeID, capture.nodes[focusedNodeID] == nil {
            self.focusedNodeID = nil
        }

        let targetNodeID: String?
        if let preferredNodeID, capture.nodes[preferredNodeID] != nil {
            targetNodeID = preferredNodeID
        } else {
            targetNodeID = capture.rootNodeIDs.first
        }

        if selectedNodeID != targetNodeID || selectedNodeDetail == nil {
            await selectNode(withID: targetNodeID, highlightInHost: false)
        }
    }

    private func bindDiscovery() {
        discoveryCenter.$announcements
            .receive(on: RunLoop.main)
            .sink { [weak self] announcements in
                guard let self else { return }
                guard !self.previewFixtureEnabled else { return }

                self.discoveredHosts = announcements
                if case .connected(let host) = self.connectionState,
                   announcements.contains(where: { $0.identifier == host.identifier }) == false {
                    self.connectionState = .failed(L10n.connectedHostDisappeared)
                    self.session = nil
                }
            }
            .store(in: &cancellables)
    }

    private func bindSettings() {
        settings.$autoRefreshEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.startAutoRefreshTimerIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func reloadRecentHosts() {
        recentHosts = (try? database.recentHosts()) ?? []
    }

    private func startAutoRefreshTimerIfNeeded() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        guard settings.autoRefreshEnabled, previewFixtureEnabled == false else { return }
        guard case .connected = connectionState else { return }

        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshCapture()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoRefreshTimer = timer
    }

    private func beginNewConnectionGeneration() -> UInt64 {
        connectionGeneration &+= 1
        return connectionGeneration
    }

    private func isActiveConnection(generation: UInt64, session: any WorkspaceSessionProtocol) -> Bool {
        generation == connectionGeneration && self.session === session
    }

    private func prepareForHostSwitch() {
        session?.disconnect()
        session = nil
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        capture = nil
        selectedNodeID = nil
        selectedNodeDetail = nil
        focusedNodeID = nil
        errorMessage = nil
    }
}
