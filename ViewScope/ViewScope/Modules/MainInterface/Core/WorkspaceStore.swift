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
    /// 已连接但未必运行宿主的 iOS 设备（USB / Wi‑Fi），用于“设备已连接但未发现宿主”提示。
    @Published private(set) var connectedDevices: [WorkspaceConnectedDevice] = []
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
    @Published private(set) var isLoadingWorkspace = false
    @Published private(set) var showsSystemWrapperViews: Bool
    @Published private(set) var consoleCurrentTarget: ViewScopeConsoleTargetDescriptor?
    @Published private(set) var consoleCandidateTargets: [ViewScopeConsoleTargetDescriptor] = []
    @Published private(set) var consoleRecentTargets: [ViewScopeConsoleTargetDescriptor] = []
    @Published private(set) var consoleRows: [ConsoleRowModel] = []
    @Published private(set) var consoleAutoSyncEnabled = true
    @Published private(set) var consoleIsLoadingTarget = false
    /// 抓取对比的基线。
    @Published private(set) var diffBaseline: WorkspaceDiffBaseline?
    /// 正在执行撤销/重做/还原时为 true，期间禁用同类操作，避免并发修改。
    @Published private(set) var isApplyingModificationHistory = false

    let settings: AppSettings
    let updateManager: UpdateManager
    /// 预览检查工具（悬停联动、测量、诊断）的共享状态。
    let inspectionTools = WorkspaceInspectionToolsState()
    /// 实时修改记录与撤销栈。
    let modificationLog = WorkspaceModificationLog()
    /// 请求打开辅助面板（修改记录、抓取对比），由 AppDelegate 持有的面板协调器订阅。
    let panelRequests = PassthroughSubject<WorkspacePanelRequest, Never>()

    /// Console 行数上限，超出后丢弃最早的行。
    static let maximumConsoleRows = 500
    /// 自动刷新写入抓取历史的最小间隔（秒），避免每 2.5 秒插入一条数据库记录。
    static let automaticCaptureHistoryInterval: TimeInterval = 30

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
    private var loadingGeneration: UInt64?
    private var hasStarted = false

    /// 抓取请求序号：同一连接内可能有多个抓取同时在途，只应用比已应用结果更新的响应。
    private var captureRequestSequence: UInt64 = 0
    private var lastAppliedCaptureSequence: UInt64 = 0
    /// 各 generation 正在进行中的抓取数量；自动刷新在本连接有抓取在途时直接跳过。
    /// 按 generation 计数，避免旧连接遗留的请求影响新连接。
    private var refreshInFlightCounts: [UInt64: Int] = [:]
    /// 当前连接是否已经收到过抓取结果（首次抓取允许默认选中根节点）。
    private var hasReceivedCaptureForConnection = false
    /// 每个宿主最近一次写入抓取历史的时间。
    private var lastCaptureHistoryRecordDates: [String: Date] = [:]

    /// Console 输入历史（仅内存）。
    private(set) var consoleHistory = ConsoleInputHistory(capacity: 100)

    /// 自动重连：已经尝试过的 announcement（identifier + pid），每个只尝试一次。
    private var autoReconnectAttemptedKeys = Set<String>()
    /// 断开的宿主是否已经从发现列表中消失过；消失后再出现才认为它真正重新上线。
    private var lostHostHasLeftDiscovery = false

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

    /// 当前会话协商出的协议版本；未连接时按最低版本处理。
    var negotiatedProtocolVersion: Int {
        connectionCoordinator.session?.negotiatedProtocolVersion ?? viewScopeMinimumSupportedProtocolVersion
    }

    /// 是否可以刷新：仅在线连接可刷新。
    var canRefreshCapture: Bool {
        connectionState.activeHost != nil
    }

    /// 是否有可断开/关闭的工作区（在线、只读断开、导入文件或失败状态）。
    var canDisconnect: Bool {
        switch connectionState {
        case .idle:
            return false
        case .connecting, .connected, .imported, .failed, .lost:
            return true
        }
    }

    func start() {
        // 发现服务由 AppDelegate 在启动时开启；重复调用保持幂等
        guard hasStarted == false else {
            return
        }
        hasStarted = true
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
        guard let nodeID else {
            return nil
        }
        return capture?.nodes[nodeID]
    }

    // MARK: - 连接生命周期

    func connect(to host: ViewScopeHostAnnouncement) async {
        if previewFixtureEnabled {
            clearWorkspaceLoadingState()
            connectionState = .connected(host)
            capture = SampleFixture.capture()
            applyPreviewFixtureSelection(nodeID: "window-0-view-1-2")
            return
        }

        let generation = connectionCoordinator.beginNewGeneration()
        prepareForHostSwitch()
        beginWorkspaceLoading(for: generation)
        connectionState = .connecting(host.displayName)
        let session = sessionFactory(host)
        connectionCoordinator.activate(session: session)
        session.setUnexpectedDisconnectHandler { [weak self, weak session] error in
            guard let self, let session else {
                return
            }
            self.handleConnectionLost(session: session, generation: generation, error: error)
        }

        do {
            _ = try await session.open()
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            connectionCoordinator.disconnectCurrentSession()
            connectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            endWorkspaceLoading(for: generation)
            return
        }

        guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
            session.disconnect()
            return
        }
        connectionState = .connected(host)
        // 记录最近连接只是辅助信息，写入失败不能影响已经握手成功的连接
        recordConnectionInBackground(host: host)
        await performRefresh(forceReloadSelectionDetail: false, clearingVisibleState: false, isAutomatic: false)
        // 首次抓取完成后再启动自动刷新，避免与首次抓取重叠
        startAutoRefreshTimerIfNeeded()
        endWorkspaceLoading(for: generation)
    }

    func connect(using record: RecentHostRecord) async {
        guard let host = discoveredHosts.first(where: { $0.bundleIdentifier == record.bundleIdentifier }) else {
            // 只提示，不影响当前连接
            errorMessage = L10n.recentHostNotRunning
            return
        }
        await connect(to: host)
    }

    func disconnect() {
        _ = connectionCoordinator.beginNewGeneration()
        prepareForHostSwitch()
        autoReconnectAttemptedKeys.removeAll()
        lostHostHasLeftDiscovery = false
        captureInsight = .empty
        previewScale = 1
        previewDisplayMode = .flat
        connectionState = .idle
    }

    /// 关闭导入的抓取文件，回到空闲状态。
    func closeImportedCapture() {
        guard connectionState.importedCaptureName != nil else {
            return
        }
        disconnect()
    }

    func shutdown() {
        disconnect()
        discoveryCenter.stop()
    }

    // MARK: - 抓取

    func refreshCapture(
        forceReloadSelectionDetail: Bool = false,
        clearingVisibleState: Bool = false
    ) async {
        await performRefresh(
            forceReloadSelectionDetail: forceReloadSelectionDetail,
            clearingVisibleState: clearingVisibleState,
            isAutomatic: false
        )
    }

    /// 执行一次抓取。
    ///
    /// - Returns: 抓取结果是否已应用到工作区。
    @discardableResult
    private func performRefresh(
        forceReloadSelectionDetail: Bool,
        clearingVisibleState: Bool,
        isAutomatic: Bool
    ) async -> Bool {
        let generation = connectionCoordinator.generation
        guard case .connected(let host) = connectionState else {
            return false
        }
        // 自动刷新不与其他抓取重叠
        if isAutomatic, refreshInFlightCounts[generation, default: 0] > 0 {
            return false
        }
        if clearingVisibleState {
            beginWorkspaceLoading(for: generation)
        }
        let selectionSnapshot = captureCoordinator.snapshotSelection(
            selectedNodeID: selectedNodeID,
            focusedNodeID: focusedNodeID
        )

        // v3 宿主的节点 ID 跨抓取稳定，手动刷新时保留展开状态（审计 20），刷新后再按新抓取恢复
        let preservedExpandedNodeIDs = expandedNodeIDs
        let canPreserveExpansion = (connectionCoordinator.session?.negotiatedProtocolVersion ?? 0) >= 3
        if clearingVisibleState {
            clearVisibleWorkspaceState()
        }

        if previewFixtureEnabled {
            capture = SampleFixture.capture()
            reconcileConsoleStateForLatestCapture()
            await normalizeSelectionAfterCaptureUpdate(
                preferredNodeID: selectionSnapshot.selectedNodeID,
                preferredFocusedNodeID: selectionSnapshot.focusedNodeID,
                forceReloadDetail: forceReloadSelectionDetail,
                allowsDefaultRootSelection: true
            )
            if clearingVisibleState {
                endWorkspaceLoading(for: generation)
            }
            return true
        }

        guard let session = connectionCoordinator.session else {
            if clearingVisibleState {
                endWorkspaceLoading(for: generation)
            }
            return false
        }

        captureRequestSequence &+= 1
        let sequence = captureRequestSequence
        beginRefreshRequest(generation: generation)
        let newCapture: ViewScopeCapturePayload
        do {
            newCapture = try await captureCoordinator.requestCapture(using: session)
            endRefreshRequest(generation: generation)
        } catch {
            endRefreshRequest(generation: generation)
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return false
            }
            if clearingVisibleState {
                endWorkspaceLoading(for: generation)
            }
            if Self.isTransportError(error) {
                // 只有传输层错误才视为连接断开；服务端业务错误只提示
                handleConnectionLost(session: session, generation: generation, error: error)
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }

        guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
            return false
        }
        guard sequence > lastAppliedCaptureSequence else {
            // 更新的抓取结果已经应用，丢弃这份过期结果
            if clearingVisibleState {
                endWorkspaceLoading(for: generation)
            }
            return false
        }
        lastAppliedCaptureSequence = sequence

        let previousCapture = capture
        let isFirstCapture = hasReceivedCaptureForConnection == false
        hasReceivedCaptureForConnection = true
        if clearingVisibleState, canPreserveExpansion {
            // 只保留在新抓取里仍然存在的节点
            expandedNodeIDs = preservedExpandedNodeIDs.filter { newCapture.nodes[$0] != nil }
        }
        capture = newCapture
        let supportsStableNodeIDs = session.negotiatedProtocolVersion >= 3
        if supportsStableNodeIDs {
            rebaseConsoleStateForLatestCapture(newCapture)
        } else {
            reconcileConsoleStateForLatestCapture()
        }
        errorMessage = nil
        recordCaptureHistory(for: host, summary: newCapture.summary, isAutomatic: isAutomatic, generation: generation)

        // 清空可见状态的刷新需要用刷新前的快照恢复选中；
        // 其余情况以“当前”选中为准，避免请求期间用户换了选中又被改回去。
        let preferredNodeID = clearingVisibleState ? selectionSnapshot.selectedNodeID : selectedNodeID
        let preferredFocusedNodeID = clearingVisibleState ? selectionSnapshot.focusedNodeID : focusedNodeID
        let selectedNodeChanged: Bool
        if let preferredNodeID {
            selectedNodeChanged = previousCapture?.nodes[preferredNodeID] != newCapture.nodes[preferredNodeID]
        } else {
            selectedNodeChanged = false
        }
        // 旧协议节点 ID 不稳定，console 目标必须靠重新拉取 detail 来刷新
        let mustReloadDetail = forceReloadSelectionDetail || selectedNodeChanged || supportsStableNodeIDs == false

        await normalizeSelectionAfterCaptureUpdate(
            preferredNodeID: preferredNodeID,
            preferredFocusedNodeID: preferredFocusedNodeID,
            forceReloadDetail: mustReloadDetail,
            allowsDefaultRootSelection: isFirstCapture
        )
        if clearingVisibleState {
            endWorkspaceLoading(for: generation)
        }
        return true
    }

    // MARK: - 选中

    func selectNode(withID nodeID: String?, highlightInHost: Bool = true) async {
        let generation = connectionCoordinator.generation
        if selectedNodeID != nodeID {
            selectedNodeID = nodeID
        }
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

        let detail: ViewScopeNodeDetailPayload
        do {
            detail = try await session.requestNodeDetail(nodeID: nodeID)
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            if Self.isTransportError(error) {
                handleConnectionLost(session: session, generation: generation, error: error)
                return
            }
            // 期间用户已经换了选中：交给新的请求处理
            guard selectedNodeID == nodeID else {
                return
            }
            errorMessage = error.localizedDescription
            if selectedNodeDetail?.nodeID != nodeID {
                selectedNodeDetail = nil
            }
            if consoleAutoSyncEnabled {
                consoleCurrentTarget = nil
            }
            consoleCandidateTargets = []
            consoleIsLoadingTarget = false
            return
        }

        guard connectionCoordinator.isActiveConnection(generation: generation, session: session),
              selectedNodeID == nodeID else {
            return
        }
        selectedNodeDetail = detail
        updateConsoleTargets(from: detail)
        errorMessage = nil

        guard highlightInHost, settings.autoHighlightSelection else {
            return
        }
        // 高亮失败不影响 detail 与 console 状态
        do {
            try await session.highlight(nodeID: nodeID, duration: 1.25)
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            if Self.isTransportError(error) {
                handleConnectionLost(session: session, generation: generation, error: error)
            }
        }
    }

    /// 选中并展开到指定节点（用于对比面板、修改记录跳转）。
    func revealNode(_ nodeID: String) async {
        guard capture?.nodes[nodeID] != nil else {
            return
        }
        expandAncestors(of: nodeID)
        await selectNode(withID: nodeID, highlightInHost: false)
    }

    func highlightCurrentSelection() async {
        let generation = connectionCoordinator.generation
        guard let selectedNodeID else {
            return
        }
        if previewFixtureEnabled {
            return
        }
        guard let session = connectionCoordinator.session else {
            return
        }
        do {
            try await session.highlight(nodeID: selectedNodeID, duration: 1.25)
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            if Self.isTransportError(error) {
                handleConnectionLost(session: session, generation: generation, error: error)
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 实时修改

    /// 发送一次属性修改。
    ///
    /// - Parameters:
    ///   - previousProperty: 编辑时的旧值（Inspector 行上的可编辑属性），用于修改记录、还原与撤销。
    ///   - title: 属性的展示标题。
    @discardableResult
    func applyMutation(
        nodeID: String,
        property: ViewScopeEditableProperty,
        previousProperty: ViewScopeEditableProperty? = nil,
        title: String? = nil
    ) async -> Bool {
        await performMutation(
            nodeID: nodeID,
            property: property,
            previousProperty: previousProperty,
            title: title,
            recordsModification: true
        )
    }

    func toggleVisibility(for nodeID: String) async -> Bool {
        guard let node = node(withID: nodeID), node.kind != .window else {
            return false
        }
        return await applyMutation(
            nodeID: nodeID,
            property: .toggle(key: "hidden", value: !node.isHidden),
            previousProperty: .toggle(key: "hidden", value: node.isHidden),
            title: L10n.serverItemTitle("hidden")
        )
    }

    var canUndoModification: Bool {
        guard isApplyingModificationHistory == false,
              let record = modificationLog.nextUndoRecord,
              record.oldValue != nil else {
            return false
        }
        return isModificationApplicableToCurrentHost(record)
    }

    var canRedoModification: Bool {
        guard isApplyingModificationHistory == false, let record = modificationLog.nextRedoRecord else {
            return false
        }
        return isModificationApplicableToCurrentHost(record)
    }

    /// 撤销最近一次修改：把旧值写回宿主。
    func undoLastModification() async {
        guard canUndoModification,
              let record = modificationLog.nextUndoRecord,
              let oldValue = record.oldValue else {
            return
        }
        isApplyingModificationHistory = true
        let success = await performMutation(
            nodeID: record.nodeID,
            property: oldValue,
            previousProperty: record.newValue,
            title: record.title,
            recordsModification: false
        )
        isApplyingModificationHistory = false
        if success {
            modificationLog.markUndone(record.id)
        }
    }

    /// 重做最近一次撤销的修改。
    func redoLastModification() async {
        guard canRedoModification, let record = modificationLog.nextRedoRecord else {
            return
        }
        isApplyingModificationHistory = true
        let success = await performMutation(
            nodeID: record.nodeID,
            property: record.newValue,
            previousProperty: record.oldValue,
            title: record.title,
            recordsModification: false
        )
        isApplyingModificationHistory = false
        if success {
            modificationLog.markRedone(record.id)
        }
    }

    /// 某条修改记录能否“还原”：需要旧值、同一宿主仍在线且节点仍存在。
    func canRevertModification(_ record: WorkspaceModificationRecord) -> Bool {
        record.oldValue != nil &&
            isApplyingModificationHistory == false &&
            isModificationApplicableToCurrentHost(record)
    }

    /// 还原单条修改：把旧值作为一次新的修改写回（可被撤销）。
    @discardableResult
    func revertModification(id: UUID) async -> Bool {
        guard let record = modificationLog.record(withID: id),
              canRevertModification(record),
              let oldValue = record.oldValue else {
            return false
        }
        isApplyingModificationHistory = true
        let success = await performMutation(
            nodeID: record.nodeID,
            property: oldValue,
            previousProperty: record.newValue,
            title: record.title,
            recordsModification: true
        )
        isApplyingModificationHistory = false
        return success
    }

    func clearModificationLog() {
        modificationLog.clear()
    }

    func makeModificationCode() -> String {
        WorkspaceModificationCodeGenerator.generate(records: modificationLog.records)
    }

    func requestPanel(_ request: WorkspacePanelRequest) {
        panelRequests.send(request)
    }

    private func isModificationApplicableToCurrentHost(_ record: WorkspaceModificationRecord) -> Bool {
        guard let activeHost = connectionState.activeHost,
              activeHost.identifier == record.hostIdentifier else {
            return false
        }
        return capture?.nodes[record.nodeID] != nil
    }

    private func performMutation(
        nodeID: String,
        property: ViewScopeEditableProperty,
        previousProperty: ViewScopeEditableProperty?,
        title: String?,
        recordsModification: Bool
    ) async -> Bool {
        let generation = connectionCoordinator.generation
        guard previewFixtureEnabled == false else {
            return false
        }
        guard let session = connectionCoordinator.session, case .connected(let host) = connectionState else {
            return false
        }
        let nodeSnapshot = capture?.nodes[nodeID]

        do {
            // options 只用于展示，发送时去掉
            try await session.applyMutation(nodeID: nodeID, property: property.valueOnly)
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return false
            }
            if Self.isTransportError(error) {
                handleConnectionLost(session: session, generation: generation, error: error)
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
        guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
            return false
        }

        if recordsModification {
            var recordedValue = property.valueOnly
            // 枚举属性保留候选项，便于在记录与导出代码中显示选项标题
            recordedValue.options = previousProperty?.options ?? property.options
            modificationLog.append(
                WorkspaceModificationRecord(
                    hostIdentifier: host.identifier,
                    hostDisplayName: host.displayName,
                    platform: capture?.host.resolvedPlatform ?? host.resolvedPlatform,
                    nodeID: nodeID,
                    nodeKind: nodeSnapshot?.kind,
                    nodeAddress: nodeSnapshot?.address,
                    className: nodeSnapshot?.className ?? "",
                    hostViewClassName: nodeSnapshot?.hostViewClassName,
                    ivarName: nodeSnapshot?.ivarName ?? nodeSnapshot?.ivarTraces.first?.ivarName,
                    key: property.key,
                    title: title ?? property.key,
                    oldValue: previousProperty,
                    newValue: recordedValue
                )
            )
        }

        await performRefresh(forceReloadSelectionDetail: true, clearingVisibleState: false, isAutomatic: false)
        // 刷新期间若连接已断开（generation 已递增），视为失败，让 Inspector 恢复显示
        return generation == connectionCoordinator.generation
    }

    // MARK: - 抓取对比

    /// 把当前抓取设为对比基线。
    @discardableResult
    func setCurrentCaptureAsDiffBaseline() -> Bool {
        guard let capture else {
            return false
        }
        let name = connectionState.activeHost?.displayName
            ?? connectionState.importedCaptureName
            ?? connectionState.lostHost?.displayName
            ?? capture.host.displayName
        diffBaseline = WorkspaceDiffBaseline(capture: capture, name: name, createdAt: Date())
        return true
    }

    /// 从 .viewscope 文件导入对比基线。
    func loadDiffBaseline(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let export = try WorkspaceArchiveCodec.decode(data)
        diffBaseline = WorkspaceDiffBaseline(
            capture: export.capture,
            name: url.deletingPathExtension().lastPathComponent,
            createdAt: export.exportedAt
        )
    }

    func clearDiffBaseline() {
        diffBaseline = nil
    }

    /// 计算当前抓取与基线的差异；缺少任一方时返回 nil。
    func makeCaptureDiff() -> CaptureDiffResult? {
        guard let diffBaseline, let capture else {
            return nil
        }
        return CaptureDiffEngine.diff(baseline: diffBaseline.capture, current: capture)
    }

    // MARK: - 预览与层级

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
        guard let capture else {
            return nil
        }

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
        guard let capture else {
            return false
        }
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

        guard update.selectedNodeID != selectedNodeID else {
            return
        }
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
        let nextExpandedNodeIDs = selectionController.expandedNodeIDsAfterExpandingAncestors(
            of: nodeID,
            capture: capture,
            expandedNodeIDs: expandedNodeIDs
        )
        // 值未变化时不重新发布，避免层级树与预览无意义地重建
        guard nextExpandedNodeIDs != expandedNodeIDs else {
            return
        }
        expandedNodeIDs = nextExpandedNodeIDs
    }

    /// 批量展开多个节点（含各自的祖先），只发布一次 `expandedNodeIDs`。
    func expandNodes(_ nodeIDs: [String]) {
        guard let capture else {
            return
        }
        var nextExpandedNodeIDs = expandedNodeIDs
        for nodeID in nodeIDs {
            nextExpandedNodeIDs = selectionController.expandedNodeIDsAfterExpandingAncestors(
                of: nodeID,
                capture: capture,
                expandedNodeIDs: nextExpandedNodeIDs
            )
            if capture.rootNodeIDs.contains(nodeID) == false, capture.nodes[nodeID] != nil {
                nextExpandedNodeIDs.insert(nodeID)
            }
        }
        guard nextExpandedNodeIDs != expandedNodeIDs else {
            return
        }
        expandedNodeIDs = nextExpandedNodeIDs
    }

    func setShowsSystemWrapperViews(_ showsSystemWrapperViews: Bool) {
        guard self.showsSystemWrapperViews != showsSystemWrapperViews else {
            return
        }
        settings.showsSystemWrapperViews = showsSystemWrapperViews
        applyShowsSystemWrapperViews(showsSystemWrapperViews)
    }

    // MARK: - Console

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
        ) else {
            return
        }
        consoleCurrentTarget = descriptor
        if consoleAutoSyncEnabled {
            consoleAutoSyncEnabled = false
        }
    }

    func clearConsoleHistory() {
        consoleRows = []
    }

    /// ↑：取上一条历史命令。
    func previousConsoleHistoryEntry(currentInput: String) -> String? {
        consoleHistory.previous(currentInput: currentInput)
    }

    /// ↓：取下一条历史命令（越过最新一条时返回草稿）。
    func nextConsoleHistoryEntry() -> String? {
        consoleHistory.next()
    }

    /// 宿主是否支持 v3 表达式语法（带参数方法、key path、对象引用）。
    var supportsExtendedConsoleSyntax: Bool {
        negotiatedProtocolVersion >= 3
    }

    /// 请求当前 console 目标的补全列表；旧宿主或无目标时返回空数组。
    func requestConsoleCompletions(prefix: String?) async -> [ViewScopeConsoleCompletion] {
        let generation = connectionCoordinator.generation
        guard supportsExtendedConsoleSyntax,
              let target = consoleCurrentTarget,
              let session = connectionCoordinator.session else {
            return []
        }
        do {
            let completions = try await session.requestConsoleCompletions(target: target.reference, prefix: prefix)
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return []
            }
            return completions
        } catch {
            return []
        }
    }

    func submitConsole(expression rawExpression: String) async {
        let generation = connectionCoordinator.generation
        let expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else {
            appendConsoleRow(ConsoleRowFactory.makeErrorRow(message: L10n.consoleErrorEmptyInput))
            return
        }
        consoleHistory.record(expression)
        // v3 宿主由服务端解析表达式；旧宿主只支持无参 selector
        if supportsExtendedConsoleSyntax == false {
            if expression.contains(":") {
                appendConsoleRow(ConsoleRowFactory.makeErrorRow(message: L10n.consoleErrorArgumentsRequireNewerHost))
                return
            }
            if expression.contains(".") {
                appendConsoleRow(ConsoleRowFactory.makeErrorRow(message: L10n.consoleErrorKeyPathRequireNewerHost))
                return
            }
        }
        guard let target = consoleCurrentTarget else {
            appendConsoleRow(ConsoleRowFactory.makeErrorRow(message: L10n.consoleStatusNoTarget))
            return
        }
        guard let capture, target.reference.captureID == capture.captureID else {
            appendConsoleRow(ConsoleRowFactory.makeErrorRow(message: L10n.consoleStatusStaleTarget))
            return
        }
        guard let session = connectionCoordinator.session else {
            appendConsoleRow(ConsoleRowFactory.makeErrorRow(message: L10n.consoleStatusDisconnected))
            return
        }

        appendConsoleRow(ConsoleRowFactory.makeSubmitRow(target: target, expression: expression))
        do {
            let response = try await session.invokeConsole(target: target.reference, expression: expression)
            // 切换宿主后到达的迟到响应直接丢弃
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            if let row = ConsoleRowFactory.makeResponseRow(response: response) {
                appendConsoleRow(row)
            }
            if let errorMessage = response.errorMessage, !errorMessage.isEmpty {
                appendConsoleRow(ConsoleRowFactory.makeErrorRow(message: errorMessage))
            }
            if let returnedObject = response.returnedObject {
                consoleRecentTargets = consoleController.upsertRecentTarget(
                    returnedObject,
                    recentTargets: consoleRecentTargets
                )
            }
        } catch {
            guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
                return
            }
            appendConsoleRow(ConsoleRowFactory.makeErrorRow(message: error.localizedDescription))
            if Self.isTransportError(error) {
                handleConnectionLost(session: session, generation: generation, error: error)
            }
        }
    }

    private func appendConsoleRow(_ row: ConsoleRowModel) {
        var rows = consoleRows
        rows.append(row)
        if rows.count > Self.maximumConsoleRows {
            rows.removeFirst(rows.count - Self.maximumConsoleRows)
        }
        consoleRows = rows
    }

    // MARK: - 私有：选中整理

    private func normalizeSelectionAfterCaptureUpdate(
        preferredNodeID: String?,
        preferredFocusedNodeID: String?,
        forceReloadDetail: Bool = false,
        allowsDefaultRootSelection: Bool
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
            forceReloadDetail: forceReloadDetail,
            allowsDefaultRootSelection: allowsDefaultRootSelection
        )

        if expandedNodeIDs != result.expandedNodeIDs {
            expandedNodeIDs = result.expandedNodeIDs
        }
        if selectedNodeID != result.selectedNodeID {
            selectedNodeID = result.selectedNodeID
        }
        if focusedNodeID != result.focusedNodeID {
            focusedNodeID = result.focusedNodeID
        }

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

    /// 切换“显示系统包装视图”只影响展示，不需要重新抓取，只整理选中与展开状态。
    private func applyShowsSystemWrapperViews(_ value: Bool) {
        guard showsSystemWrapperViews != value else {
            return
        }
        showsSystemWrapperViews = value
        guard capture != nil else {
            return
        }
        let preferredNodeID = selectedNodeID
        let preferredFocusedNodeID = focusedNodeID
        Task { [weak self] in
            await self?.normalizeSelectionAfterCaptureUpdate(
                preferredNodeID: preferredNodeID,
                preferredFocusedNodeID: preferredFocusedNodeID,
                forceReloadDetail: false,
                allowsDefaultRootSelection: false
            )
        }
    }

    // MARK: - 私有：Console 状态

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

    private func rebaseConsoleStateForLatestCapture(_ capture: ViewScopeCapturePayload) {
        let update = consoleController.rebaseForLatestCapture(
            capture: capture,
            currentTarget: consoleCurrentTarget,
            candidateTargets: consoleCandidateTargets,
            recentTargets: consoleRecentTargets,
            autoSyncEnabled: consoleAutoSyncEnabled
        )
        if consoleCurrentTarget != update.currentTarget {
            consoleCurrentTarget = update.currentTarget
        }
        if consoleCandidateTargets != update.candidateTargets {
            consoleCandidateTargets = update.candidateTargets
        }
        if consoleRecentTargets != update.recentTargets {
            consoleRecentTargets = update.recentTargets
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

    // MARK: - 私有：断线与自动重连

    /// 传输层错误（连接断开、建连失败）才需要断开会话；服务端返回的业务错误只做提示。
    static func isTransportError(_ error: Error) -> Bool {
        if let sessionError = error as? ViewScopeClientSession.SessionError {
            if case .disconnected = sessionError {
                return true
            }
            if case .connectionFailed = sessionError {
                return true
            }
            if case .connectTimedOut = sessionError {
                return true
            }
            // 请求超时、服务端业务错误等不代表连接已断开
            return false
        }
        if error is URLError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
    }

    /// 已连接的宿主意外断开：保留最后一次抓取为只读，等待宿主重新出现。
    private func handleConnectionLost(
        session: any WorkspaceSessionProtocol,
        generation: UInt64,
        error: Error
    ) {
        _ = error
        guard connectionCoordinator.isActiveConnection(generation: generation, session: session) else {
            return
        }
        guard case .connected(let host) = connectionState else {
            return
        }
        // 递增 generation，让所有在途请求的结果都被丢弃
        _ = connectionCoordinator.beginNewGeneration()
        connectionCoordinator.disconnectCurrentSession()
        clearWorkspaceLoadingState()
        inspectionTools.reset()
        modificationLog.invalidateUndoHistory()
        consoleCurrentTarget = nil
        consoleCandidateTargets = []
        consoleIsLoadingTarget = false
        connectionState = .lost(host)
        errorMessage = L10n.connectedHostDisappeared
        lostHostHasLeftDiscovery = discoveredHosts.contains(where: { $0.identifier == host.identifier }) == false
        attemptAutoReconnectIfNeeded()
    }

    private func attemptAutoReconnectIfNeeded() {
        guard settings.autoReconnectEnabled, case .lost(let lostHost) = connectionState else {
            return
        }
        if discoveredHosts.contains(where: { $0.identifier == lostHost.identifier }) == false {
            lostHostHasLeftDiscovery = true
        }
        let candidate = discoveredHosts.first { host in
            guard WorkspaceHostPresentation.isSameApplication(host, lostHost) else {
                return false
            }
            guard autoReconnectAttemptedKeys.contains(Self.autoReconnectKey(for: host)) == false else {
                return false
            }
            // 同一个 announcement 仍在宽限期内时它很可能已经不可用，必须先消失再出现才重连
            if host.identifier == lostHost.identifier, host.processIdentifier == lostHost.processIdentifier {
                return lostHostHasLeftDiscovery
            }
            return true
        }
        guard let candidate else {
            return
        }
        autoReconnectAttemptedKeys.insert(Self.autoReconnectKey(for: candidate))
        Task { [weak self] in
            await self?.connect(to: candidate)
        }
    }

    private static func autoReconnectKey(for host: ViewScopeHostAnnouncement) -> String {
        "\(host.identifier)|\(host.processIdentifier)|\(host.updatedAt.timeIntervalSince1970)"
    }

    // MARK: - 私有：绑定

    private func bindDiscovery() {
        discoveryCenter.$announcements
            .receive(on: RunLoop.main)
            .sink { [weak self] announcements in
                guard let self else {
                    return
                }
                guard !self.previewFixtureEnabled else {
                    return
                }

                self.discoveredHosts = announcements
                self.attemptAutoReconnectIfNeeded()
            }
            .store(in: &cancellables)
        bindConnectedDevices()
    }

    /// USB 设备列表由 C-conn 的 DiscoveryCenter 提供（`@Published usbDevices`）。
    private func bindConnectedDevices() {
        discoveryCenter.$usbDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                let nextDevices = devices.map {
                    WorkspaceConnectedDevice(serial: $0.serial, name: $0.displayName, connectionType: $0.connectionType)
                }
                if self?.connectedDevices != nextDevices {
                    self?.connectedDevices = nextDevices
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
                self?.applyShowsSystemWrapperViews(value)
            }
            .store(in: &cancellables)

        settings.$autoReconnectEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.attemptAutoReconnectIfNeeded()
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

    // MARK: - 私有：数据库

    private func reloadRecentHosts() {
        recentHosts = (try? database.recentHosts()) ?? []
    }

    private func recordConnectionInBackground(host: ViewScopeHostAnnouncement) {
        let database = self.database
        Task.detached(priority: .utility) { [weak self] in
            try? database.recordConnection(host: host)
            let hosts = (try? database.recentHosts()) ?? []
            await MainActor.run {
                self?.recentHosts = hosts
            }
        }
    }

    /// 抓取历史写入放到后台；自动刷新每个宿主最多 30 秒写一次。
    private func recordCaptureHistory(
        for host: ViewScopeHostAnnouncement,
        summary: ViewScopeCaptureSummary,
        isAutomatic: Bool,
        generation: UInt64
    ) {
        let now = Date()
        if isAutomatic,
           let lastDate = lastCaptureHistoryRecordDates[host.bundleIdentifier],
           now.timeIntervalSince(lastDate) < Self.automaticCaptureHistoryInterval {
            return
        }
        lastCaptureHistoryRecordDates[host.bundleIdentifier] = now
        let database = self.database
        let bundleIdentifier = host.bundleIdentifier
        Task.detached(priority: .utility) { [weak self] in
            try? database.recordCapture(for: host, summary: summary)
            let insight = (try? database.captureInsight(for: bundleIdentifier)) ?? .empty
            await MainActor.run {
                guard let self, self.connectionCoordinator.generation == generation else {
                    return
                }
                self.captureInsight = insight
            }
        }
    }

    private func startAutoRefreshTimerIfNeeded() {
        connectionCoordinator.configureAutoRefreshTimer(
            isEnabled: settings.autoRefreshEnabled && previewFixtureEnabled == false,
            isConnected: {
                guard case .connected = connectionState else {
                    return false
                }
                // 首次抓取完成前不启动定时器
                return hasReceivedCaptureForConnection
            }()
        ) { [weak self] in
            await self?.performRefresh(forceReloadSelectionDetail: false, clearingVisibleState: false, isAutomatic: true)
        }
    }

    private func prepareForHostSwitch() {
        connectionCoordinator.disconnectCurrentSession()
        clearWorkspaceLoadingState()
        clearVisibleWorkspaceState()
        clearConsoleConnectionState()
        inspectionTools.reset()
        modificationLog.invalidateUndoHistory()
        hasReceivedCaptureForConnection = false
        errorMessage = nil
    }

    private func beginRefreshRequest(generation: UInt64) {
        refreshInFlightCounts[generation, default: 0] += 1
    }

    private func endRefreshRequest(generation: UInt64) {
        let remaining = refreshInFlightCounts[generation, default: 0] - 1
        if remaining > 0 {
            refreshInFlightCounts[generation] = remaining
        } else {
            refreshInFlightCounts.removeValue(forKey: generation)
        }
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

    private func beginWorkspaceLoading(for generation: UInt64) {
        loadingGeneration = generation
        isLoadingWorkspace = true
    }

    private func endWorkspaceLoading(for generation: UInt64) {
        guard loadingGeneration == generation else {
            return
        }
        clearWorkspaceLoadingState()
    }

    private func clearWorkspaceLoadingState() {
        loadingGeneration = nil
        isLoadingWorkspace = false
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
