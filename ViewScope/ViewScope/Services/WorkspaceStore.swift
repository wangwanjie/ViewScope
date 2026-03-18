import Combine
import Foundation
import ViewScopeServer

@MainActor
final class WorkspaceStore: NSObject {
    @Published private(set) var discoveredHosts: [ViewScopeHostAnnouncement] = []
    @Published private(set) var recentHosts: [RecentHostRecord] = []
    @Published private(set) var connectionState: WorkspaceConnectionState = .idle
    @Published private(set) var capture: ViewScopeCapturePayload?
    @Published private(set) var selectedNodeDetail: ViewScopeNodeDetailPayload?
    @Published private(set) var selectedNodeID: String?
    @Published private(set) var captureInsight: CaptureHistoryInsight = .empty
    @Published private(set) var errorMessage: String?

    let settings: AppSettings
    let updateManager: UpdateManager

    private let database: AppDatabase
    private let discoveryCenter = DiscoveryCenter()
    private var session: ViewScopeClientSession?
    private var cancellables = Set<AnyCancellable>()
    private var autoRefreshTimer: Timer?
    private let previewFixtureEnabled: Bool

    init(settings: AppSettings = .shared, updateManager: UpdateManager? = nil) throws {
        self.settings = settings
        self.updateManager = updateManager ?? UpdateManager(settings: settings)
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

    func start() {
        reloadRecentHosts()
        if previewFixtureEnabled {
            let previewAnnouncement = SampleFixture.announcement()
            discoveredHosts = [previewAnnouncement]
            connectionState = .connected(previewAnnouncement)
            capture = SampleFixture.capture()
            captureInsight = CaptureHistoryInsight(totalCaptures: 12, averageDurationMilliseconds: 203, mostRecentDurationMilliseconds: 184)
            Task { await selectNode(withID: "window-0-view-1-2") }
            return
        }
        discoveryCenter.start()
    }

    func connect(to host: ViewScopeHostAnnouncement) async {
        if previewFixtureEnabled {
            connectionState = .connected(host)
            capture = SampleFixture.capture()
            await selectNode(withID: "window-0-view-1-2")
            return
        }

        errorMessage = nil
        connectionState = .connecting(host.displayName)
        let session = ViewScopeClientSession(announcement: host)
        self.session = session

        do {
            _ = try await session.open()
            connectionState = .connected(host)
            try database.recordConnection(host: host)
            reloadRecentHosts()
            startAutoRefreshTimerIfNeeded()
            await refreshCapture()
        } catch {
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
        session?.disconnect()
        session = nil
        capture = nil
        selectedNodeID = nil
        selectedNodeDetail = nil
        captureInsight = .empty
        connectionState = .idle
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    func shutdown() {
        disconnect()
        discoveryCenter.stop()
    }

    func refreshCapture() async {
        guard case .connected(let host) = connectionState else { return }
        if previewFixtureEnabled {
            capture = SampleFixture.capture()
            if let selectedNodeID {
                await selectNode(withID: selectedNodeID)
            }
            return
        }
        guard let session else { return }

        do {
            let capture = try await session.requestCapture()
            self.capture = capture
            try database.recordCapture(for: host, summary: capture.summary)
            captureInsight = try database.captureInsight(for: host.bundleIdentifier)
            if let selectedNodeID, capture.nodes[selectedNodeID] != nil {
                await selectNode(withID: selectedNodeID)
            } else {
                selectedNodeID = nil
                selectedNodeDetail = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
            self.session = nil
        }
    }

    func selectNode(withID nodeID: String?) async {
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
            selectedNodeDetail = detail
            if settings.autoHighlightSelection {
                try await session.highlight(nodeID: nodeID, duration: 1.25)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func highlightCurrentSelection() async {
        guard let selectedNodeID else { return }
        if previewFixtureEnabled { return }
        do {
            try await session?.highlight(nodeID: selectedNodeID, duration: 1.25)
        } catch {
            errorMessage = error.localizedDescription
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
}
