import Combine
import CoreGraphics
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
    @Published private(set) var previewLayerSpacing: CGFloat = 22
    @Published private(set) var previewShowsLayerBorders: Bool = true
    @Published private(set) var expandedNodeIDs = Set<String>()
    @Published private(set) var captureInsight: CaptureHistoryInsight = .empty
    @Published private(set) var errorMessage: String?
    @Published private(set) var showsSystemWrapperViews: Bool
    @Published private(set) var consoleCurrentTarget: ViewScopeConsoleTargetDescriptor?
    @Published private(set) var consoleCandidateTargets: [ViewScopeConsoleTargetDescriptor] = []
    @Published private(set) var consoleRecentTargets: [ViewScopeConsoleTargetDescriptor] = []
    @Published private(set) var consoleRows: [ConsoleRowModel] = []
    @Published private(set) var consoleAutoSyncEnabled = true
    @Published private(set) var consoleIsLoadingTarget = false

    let settings: AppSettings
    let updateManager: UpdateManager

    private let database: AppDatabase
    private let sessionFactory: SessionFactory
    private let discoveryCenter = DiscoveryCenter()
    private let consoleController = WorkspaceConsoleController()
    private let previewState = WorkspacePreviewState()
    private let selectionController = WorkspaceSelectionController()
    private let captureCoordinator = WorkspaceCaptureCoordinator()
    private let connectionCoordinator = WorkspaceConnectionCoordinator()
    private var cancellables = Set<AnyCancellable>()
    private let previewFixtureEnabled: Bool

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
        self.previewFixtureEnabled = settings.environment["VIEWSCOPE_PREVIEW_FIXTURE"] == "1"
        self.showsSystemWrapperViews = settings.showsSystemWrapperViews
        self.previewLayerSpacing = CGFloat(settings.previewLayerSpacing)
        self.previewShowsLayerBorders = settings.previewShowsLayerBorders

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
            applyPreviewFixtureSelection(nodeID: "window-0-view-1-2")
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
            applyPreviewFixtureSelection(nodeID: "window-0-view-1-2")
            return
        }

        let generation = connectionCoordinator.beginNewGeneration()
        prepareForHostSwitch()
        connectionState = .connecting(host.displayName)
        let session = sessionFactory(host)
        connectionCoordinator.activate(session: session)

        do {
            _ = try await session.open()
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                session.disconnect()
                return
            }
            connectionState = .connected(host)
            try database.recordConnection(host: host)
            reloadRecentHosts()
            startAutoRefreshTimerIfNeeded()
            await refreshCapture()
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            connectionCoordinator.disconnectCurrentSession()
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
        _ = connectionCoordinator.beginNewGeneration()
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

    func refreshCapture(
        forceReloadSelectionDetail: Bool = false,
        clearingVisibleState: Bool = false
    ) async {
        let generation = connectionCoordinator.generation
        guard case .connected(let host) = connectionState else { return }
        let selectionSnapshot = captureCoordinator.snapshotSelection(
            selectedNodeID: selectedNodeID,
            focusedNodeID: focusedNodeID
        )

        if clearingVisibleState {
            clearVisibleWorkspaceState()
        }

        if previewFixtureEnabled {
            capture = SampleFixture.capture()
            reconcileConsoleStateForLatestCapture()
            await normalizeSelectionAfterCaptureUpdate(
                preferredNodeID: selectionSnapshot.selectedNodeID,
                preferredFocusedNodeID: selectionSnapshot.focusedNodeID,
                forceReloadDetail: forceReloadSelectionDetail
            )
            return
        }

        guard let session = connectionCoordinator.session else { return }

        do {
            let capture = try await captureCoordinator.requestCapture(using: session)
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            self.capture = capture
            reconcileConsoleStateForLatestCapture()
            errorMessage = nil
            try database.recordCapture(for: host, summary: capture.summary)
            captureInsight = try database.captureInsight(for: host.bundleIdentifier)
            await normalizeSelectionAfterCaptureUpdate(
                preferredNodeID: selectionSnapshot.selectedNodeID,
                preferredFocusedNodeID: selectionSnapshot.focusedNodeID,
                forceReloadDetail: forceReloadSelectionDetail
            )
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            errorMessage = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
            connectionCoordinator.disconnectCurrentSession()
        }
    }

    func selectNode(withID nodeID: String?, highlightInHost: Bool = true) async {
        let generation = connectionCoordinator.generation
        selectedNodeID = nodeID
        guard let nodeID else {
            selectedNodeDetail = nil
            consoleCandidateTargets = []
            consoleIsLoadingTarget = false
            if consoleAutoSyncEnabled {
                consoleCurrentTarget = nil
            }
            return
        }

        if previewFixtureEnabled {
            selectedNodeDetail = SampleFixture.detail(for: nodeID)
            updateConsoleTargets(from: selectedNodeDetail)
            return
        }

        guard let session = connectionCoordinator.session else {
            if selectedNodeDetail?.nodeID != nodeID {
                selectedNodeDetail = nil
            }
            updateConsoleTargets(from: selectedNodeDetail)
            return
        }
        if consoleAutoSyncEnabled {
            consoleIsLoadingTarget = true
        }
        do {
            let detail = try await session.requestNodeDetail(nodeID: nodeID)
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session),
                  selectedNodeID == nodeID else {
                return
            }
            selectedNodeDetail = detail
            updateConsoleTargets(from: detail)
            errorMessage = nil
            if highlightInHost, settings.autoHighlightSelection {
                try await session.highlight(nodeID: nodeID, duration: 1.25)
            }
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            errorMessage = error.localizedDescription
            if let capture, consoleCurrentTarget?.reference.captureID != capture.captureID {
                consoleCurrentTarget = nil
            }
            consoleCandidateTargets = []
            consoleIsLoadingTarget = false
        }
    }

    func highlightCurrentSelection() async {
        let generation = connectionCoordinator.generation
        guard let selectedNodeID else { return }
        if previewFixtureEnabled { return }
        guard let session = connectionCoordinator.session else { return }
        do {
            try await session.highlight(nodeID: selectedNodeID, duration: 1.25)
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func applyMutation(nodeID: String, property: ViewScopeEditableProperty) async -> Bool {
        let generation = connectionCoordinator.generation
        guard previewFixtureEnabled == false else { return false }
        guard let session = connectionCoordinator.session else { return false }

        selectedNodeID = nodeID

        do {
            try await session.applyMutation(nodeID: nodeID, property: property)
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return false
            }
            await refreshCapture(forceReloadSelectionDetail: true)
            guard generation == connectionCoordinator.generation else {
                return false
            }
            return true
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
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
        focusedNodeID = selectionController.focusedNodeID(for: nodeID, capture: capture)
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
        previewScale = previewState.clampedScale(value)
    }

    func setPreviewDisplayMode(_ mode: WorkspacePreviewDisplayMode) {
        previewDisplayMode = mode
    }

    func setPreviewLayerSpacing(_ value: CGFloat) {
        previewLayerSpacing = previewState.clampedLayerSpacing(value)
        settings.previewLayerSpacing = Double(previewLayerSpacing)
    }

    func setPreviewShowsLayerBorders(_ showsLayerBorders: Bool) {
        previewShowsLayerBorders = showsLayerBorders
        settings.previewShowsLayerBorders = showsLayerBorders
    }

    func loadPreviewExport(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let export = try WorkspaceArchiveCodec.decode(data)
        loadPreviewExport(export, sourceName: url.deletingPathExtension().lastPathComponent)
    }

    /// 生成一个包含 capture + 当前预览上下文的可移植快照。
    ///
    /// 这样导入到另一台机器后，预览面板仍能尽量恢复当时的 2D/3D 状态。
    func makeRawPreviewExport() -> WorkspaceRawPreviewExport? {
        guard let capture else { return nil }

        let geometry = ViewHierarchyGeometry()
        let previewRootNodeID = resolvedPreviewRootNodeID(capture: capture, detail: selectedNodeDetail)
        let geometryMode = PreviewPanelRenderDecisions.geometryMode(
            capture: capture,
            selectedNodeID: selectedNodeID,
            detail: selectedNodeDetail,
            previewRootNodeID: previewRootNodeID,
            geometry: geometry
        ) ?? .directGlobalCanvasRect
        let previewBitmap = resolvedPreviewBitmap(
            capture: capture,
            previewRootNodeID: previewRootNodeID,
            detail: selectedNodeDetail
        )

        let previewContext = previewState.makePreviewContext(
            selectedNodeID: selectedNodeID,
            focusedNodeID: focusedNodeID,
            previewRootNodeID: previewRootNodeID,
            geometryMode: geometryMode == .directGlobalCanvasRect ? "directGlobalCanvasRect" : "legacyLocalFrames",
            previewScale: previewScale,
            previewDisplayMode: previewDisplayMode,
            previewLayerSpacing: previewLayerSpacing,
            previewShowsLayerBorders: previewShowsLayerBorders,
            expandedNodeIDs: expandedNodeIDs
        )

        return captureCoordinator.makePreviewExport(
            capture: capture,
            selectedNodeDetail: selectedNodeDetail,
            previewBitmap: previewBitmap,
            previewContext: previewContext
        )
    }

    func isNodeExpanded(_ nodeID: String) -> Bool {
        guard let capture else { return false }
        return capture.rootNodeIDs.contains(nodeID) || expandedNodeIDs.contains(nodeID)
    }

    func setNodeExpanded(_ nodeID: String, isExpanded: Bool) {
        let update = selectionController.setNodeExpanded(
            nodeID: nodeID,
            isExpanded: isExpanded,
            capture: capture,
            expandedNodeIDs: expandedNodeIDs,
            selectedNodeID: selectedNodeID,
            focusedNodeID: focusedNodeID,
            showsSystemWrapperViews: showsSystemWrapperViews
        )
        expandedNodeIDs = update.expandedNodeIDs
        if focusedNodeID != update.focusedNodeID {
            // 展开/折叠节点时，焦点经常保持不变。
            // 这里如果把相同值再次写回 @Published，会让层级面板误以为状态变了，
            // 从而在恢复展开状态期间整棵树重复重建，最终形成 UI 死循环。
            focusedNodeID = update.focusedNodeID
        }

        guard update.selectedNodeID != selectedNodeID else { return }
        selectedNodeID = update.selectedNodeID
        if previewFixtureEnabled {
            applyPreviewFixtureSelection(nodeID: update.selectedNodeID)
            return
        }
        if connectionCoordinator.session == nil {
            selectedNodeDetail = selectedNodeDetail?.nodeID == update.selectedNodeID
                ? selectedNodeDetail
                : nil
            updateConsoleTargets(from: selectedNodeDetail)
            return
        }
        Task { [weak self] in
            await self?.selectNode(withID: update.selectedNodeID, highlightInHost: false)
        }
    }

    func expandAncestors(of nodeID: String) {
        expandedNodeIDs = selectionController.expandedNodeIDsAfterExpandingAncestors(
            of: nodeID,
            capture: capture,
            expandedNodeIDs: expandedNodeIDs
        )
    }

    func setShowsSystemWrapperViews(_ showsSystemWrapperViews: Bool) {
        guard self.showsSystemWrapperViews != showsSystemWrapperViews else { return }
        self.showsSystemWrapperViews = showsSystemWrapperViews
        settings.showsSystemWrapperViews = showsSystemWrapperViews
        Task { await refreshCapture(forceReloadSelectionDetail: true, clearingVisibleState: false) }
    }

    func setConsoleAutoSyncEnabled(_ enabled: Bool) {
        consoleAutoSyncEnabled = enabled
        let update = consoleController.autoSyncUpdate(
            enabled: enabled,
            candidateTargets: consoleCandidateTargets,
            currentTarget: consoleCurrentTarget,
            captureID: capture?.captureID
        )
        consoleCurrentTarget = update.currentTarget
    }

    func selectConsoleTarget(objectID: String) {
        guard let descriptor = consoleController.selectedTarget(
            objectID: objectID,
            currentTarget: consoleCurrentTarget,
            candidateTargets: consoleCandidateTargets,
            recentTargets: consoleRecentTargets,
            rows: consoleRows,
            autoSyncEnabled: consoleAutoSyncEnabled,
            isLoadingTarget: consoleIsLoadingTarget,
            captureID: capture?.captureID
        ) else { return }
        consoleCurrentTarget = descriptor
        if consoleAutoSyncEnabled {
            consoleAutoSyncEnabled = false
        }
    }

    func clearConsoleHistory() {
        consoleRows = []
    }

    func submitConsole(expression rawExpression: String) async {
        let expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else {
            consoleRows.append(ConsoleRowFactory.makeErrorRow(message: L10n.consoleErrorEmptyInput))
            return
        }
        if expression.contains(":") {
            consoleRows.append(ConsoleRowFactory.makeErrorRow(message: L10n.consoleErrorArgumentsUnsupported))
            return
        }
        if expression.contains(".") {
            consoleRows.append(ConsoleRowFactory.makeErrorRow(message: L10n.consoleErrorSyntaxUnsupported))
            return
        }
        guard let target = consoleCurrentTarget else {
            consoleRows.append(ConsoleRowFactory.makeErrorRow(message: L10n.consoleStatusNoTarget))
            return
        }
        guard let capture, target.reference.captureID == capture.captureID else {
            consoleRows.append(ConsoleRowFactory.makeErrorRow(message: L10n.consoleStatusStaleTarget))
            return
        }
        guard let session = connectionCoordinator.session else {
            consoleRows.append(ConsoleRowFactory.makeErrorRow(message: L10n.consoleStatusDisconnected))
            return
        }

        consoleRows.append(ConsoleRowFactory.makeSubmitRow(target: target, expression: expression))
        do {
            let response = try await session.invokeConsole(target: target.reference, expression: expression)
            if let row = ConsoleRowFactory.makeResponseRow(response: response) {
                consoleRows.append(row)
            }
            if let errorMessage = response.errorMessage, !errorMessage.isEmpty {
                consoleRows.append(ConsoleRowFactory.makeErrorRow(message: errorMessage))
            }
            if let returnedObject = response.returnedObject {
                consoleRecentTargets = consoleController.upsertRecentTarget(
                    returnedObject,
                    recentTargets: consoleRecentTargets
                )
            }
        } catch {
            consoleRows.append(ConsoleRowFactory.makeErrorRow(message: error.localizedDescription))
        }
    }

    private func normalizeSelectionAfterCaptureUpdate(
        preferredNodeID: String?,
        preferredFocusedNodeID: String?,
        forceReloadDetail: Bool = false
    ) async {
        let result = selectionController.normalizeAfterCaptureUpdate(
            capture: capture,
            preferredNodeID: preferredNodeID,
            preferredFocusedNodeID: preferredFocusedNodeID,
            currentSelectedNodeID: selectedNodeID,
            currentFocusedNodeID: focusedNodeID,
            selectedNodeDetailNodeID: selectedNodeDetail?.nodeID,
            expandedNodeIDs: expandedNodeIDs,
            showsSystemWrapperViews: showsSystemWrapperViews,
            forceReloadDetail: forceReloadDetail
        )

        expandedNodeIDs = result.expandedNodeIDs
        selectedNodeID = result.selectedNodeID
        focusedNodeID = result.focusedNodeID

        guard capture != nil else {
            selectedNodeID = nil
            selectedNodeDetail = nil
            focusedNodeID = nil
            return
        }

        guard result.shouldReloadDetail else {
            return
        }
        await selectNode(withID: result.targetNodeID, highlightInHost: false)
    }

    private func reconcileConsoleStateForLatestCapture() {
        let update = consoleController.reconcileForLatestCapture(
            capture: capture,
            selectedNodeID: selectedNodeID,
            currentTarget: consoleCurrentTarget,
            recentTargets: consoleRecentTargets,
            autoSyncEnabled: consoleAutoSyncEnabled
        )
        consoleCurrentTarget = update.currentTarget
        consoleRecentTargets = update.recentTargets
        consoleIsLoadingTarget = update.isLoadingTarget
        if capture == nil {
            consoleCandidateTargets = []
        }
    }

    private func updateConsoleTargets(from detail: ViewScopeNodeDetailPayload?) {
        let update = consoleController.updateTargets(
            from: detail,
            capture: capture,
            currentTarget: consoleCurrentTarget,
            autoSyncEnabled: consoleAutoSyncEnabled
        )
        consoleCurrentTarget = update.currentTarget
        consoleCandidateTargets = update.candidateTargets
        consoleIsLoadingTarget = update.isLoadingTarget
    }

    private func clearConsoleConnectionState() {
        let clearedState = consoleController.clearConnectionState()
        consoleCurrentTarget = clearedState.currentTarget
        consoleCandidateTargets = clearedState.candidateTargets
        consoleRecentTargets = clearedState.recentTargets
        consoleIsLoadingTarget = clearedState.isLoadingTarget
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
                    self.connectionCoordinator.disconnectCurrentSession()
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

        settings.$showsSystemWrapperViews
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.showsSystemWrapperViews = value
            }
            .store(in: &cancellables)

        settings.$previewLayerSpacing
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.previewLayerSpacing = self?.previewState.clampedLayerSpacing(CGFloat(value)) ?? CGFloat(value)
            }
            .store(in: &cancellables)

        settings.$previewShowsLayerBorders
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.previewShowsLayerBorders = value
            }
            .store(in: &cancellables)
    }

    private func reloadRecentHosts() {
        recentHosts = (try? database.recentHosts()) ?? []
    }

    private func startAutoRefreshTimerIfNeeded() {
        connectionCoordinator.configureAutoRefreshTimer(
            isEnabled: settings.autoRefreshEnabled && previewFixtureEnabled == false,
            isConnected: {
                guard case .connected = connectionState else { return false }
                return true
            }()
        ) { [weak self] in
            await self?.refreshCapture(clearingVisibleState: false)
        }
    }

    private func prepareForHostSwitch() {
        connectionCoordinator.disconnectCurrentSession()
        clearVisibleWorkspaceState()
        clearConsoleConnectionState()
        errorMessage = nil
    }

    private func loadPreviewExport(_ export: WorkspaceRawPreviewExport, sourceName: String?) {
        // 导入归档等价于切换到一个新的只读“离线连接”。
        _ = connectionCoordinator.beginNewGeneration()
        prepareForHostSwitch()
        captureInsight = .empty

        let importedState = captureCoordinator.importedState(from: export)
        let importedPreviewState = previewState.importedState(from: export.previewContext)

        capture = importedState.capture
        selectedNodeDetail = importedState.selectedNodeDetail
        selectedNodeID = importedState.selectedNodeID
        focusedNodeID = importedState.focusedNodeID
        previewScale = importedPreviewState.scale
        previewDisplayMode = importedPreviewState.displayMode
        previewLayerSpacing = importedPreviewState.layerSpacing
        previewShowsLayerBorders = importedPreviewState.showsLayerBorders
        expandedNodeIDs = importedState.expandedNodeIDs
        connectionState = .imported(sourceName ?? export.capture.host.displayName)
        errorMessage = nil
    }

    private func clearVisibleWorkspaceState() {
        capture = nil
        selectedNodeID = nil
        selectedNodeDetail = nil
        focusedNodeID = nil
        expandedNodeIDs = []
    }

    private func applyPreviewFixtureSelection(nodeID: String?) {
        selectedNodeID = nodeID
        selectedNodeDetail = nodeID.flatMap(SampleFixture.detail(for:))
        updateConsoleTargets(from: selectedNodeDetail)
    }

    private func resolvedPreviewRootNodeID(
        capture: ViewScopeCapturePayload,
        detail: ViewScopeNodeDetailPayload?
    ) -> String? {
        let anchorNodeID = focusedNodeID ?? selectedNodeID ?? capture.rootNodeIDs.first
        _ = detail
        return PreviewPanelRenderDecisions.previewRootNodeID(
            capture: capture,
            anchorNodeID: anchorNodeID
        )
    }

    private func resolvedPreviewBitmap(
        capture: ViewScopeCapturePayload,
        previewRootNodeID: String?,
        detail: ViewScopeNodeDetailPayload?
    ) -> ViewScopePreviewBitmap? {
        if let previewRootNodeID,
           let bitmap = capture.previewBitmaps.first(where: { $0.rootNodeID == previewRootNodeID }) {
            return bitmap
        }

        guard let detail,
              let pngBase64 = detail.screenshotPNGBase64,
              pngBase64.isEmpty == false else {
            return nil
        }

        let rootNodeID = previewRootNodeID ?? detail.screenshotRootNodeID ?? detail.nodeID
        return ViewScopePreviewBitmap(
            rootNodeID: rootNodeID,
            pngBase64: pngBase64,
            size: detail.screenshotSize,
            capturedAt: capture.capturedAt
        )
    }

}
