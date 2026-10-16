import ViewScopeServer

struct WorkspaceConsoleConnectionState {
    let currentTarget: ViewScopeConsoleTargetDescriptor?
    let candidateTargets: [ViewScopeConsoleTargetDescriptor]
    let recentTargets: [ViewScopeConsoleTargetDescriptor]
    let isLoadingTarget: Bool
}

struct WorkspaceConsoleCaptureState {
    let currentTarget: ViewScopeConsoleTargetDescriptor?
    let recentTargets: [ViewScopeConsoleTargetDescriptor]
    let isLoadingTarget: Bool
}

struct WorkspaceConsoleTargetUpdate {
    let currentTarget: ViewScopeConsoleTargetDescriptor?
    let candidateTargets: [ViewScopeConsoleTargetDescriptor]
    let isLoadingTarget: Bool
}

struct WorkspaceConsoleRebaseState {
    let currentTarget: ViewScopeConsoleTargetDescriptor?
    let candidateTargets: [ViewScopeConsoleTargetDescriptor]
    let recentTargets: [ViewScopeConsoleTargetDescriptor]
}

struct WorkspaceConsoleAutoSyncUpdate {
    let currentTarget: ViewScopeConsoleTargetDescriptor?
}

@MainActor
final class WorkspaceConsoleController {
    private let maximumRecentTargets: Int

    init(maximumRecentTargets: Int = 10) {
        self.maximumRecentTargets = maximumRecentTargets
    }

    func clearConnectionState() -> WorkspaceConsoleConnectionState {
        WorkspaceConsoleConnectionState(
            currentTarget: nil,
            candidateTargets: [],
            recentTargets: [],
            isLoadingTarget: false
        )
    }

    func reconcileForLatestCapture(
        capture: ViewScopeCapturePayload?,
        selectedNodeID: String?,
        currentTarget: ViewScopeConsoleTargetDescriptor?,
        recentTargets: [ViewScopeConsoleTargetDescriptor],
        autoSyncEnabled: Bool
    ) -> WorkspaceConsoleCaptureState {
        guard let capture else {
            return WorkspaceConsoleCaptureState(
                currentTarget: nil,
                recentTargets: [],
                isLoadingTarget: false
            )
        }

        let nextRecentTargets = recentTargets.filter { $0.reference.captureID == capture.captureID }
        let nextCurrentTarget: ViewScopeConsoleTargetDescriptor?
        if let currentTarget, currentTarget.reference.captureID == capture.captureID {
            nextCurrentTarget = currentTarget
        } else {
            nextCurrentTarget = nil
        }

        return WorkspaceConsoleCaptureState(
            currentTarget: nextCurrentTarget,
            recentTargets: nextRecentTargets,
            isLoadingTarget: autoSyncEnabled ? selectedNodeID != nil : false
        )
    }

    /// v3 宿主节点 ID 跨抓取稳定：把仍然存在的目标改写到最新 captureID，
    /// 这样自动刷新不会让控制台目标失效（返回对象由服务端缓存，也一并保留）。
    func rebaseForLatestCapture(
        capture: ViewScopeCapturePayload,
        currentTarget: ViewScopeConsoleTargetDescriptor?,
        candidateTargets: [ViewScopeConsoleTargetDescriptor],
        recentTargets: [ViewScopeConsoleTargetDescriptor],
        autoSyncEnabled: Bool
    ) -> WorkspaceConsoleRebaseState {
        let nextCandidates = candidateTargets.compactMap { rebased($0, to: capture) }
        let nextRecents = recentTargets.compactMap { rebased($0, to: capture) }
        var nextCurrent = currentTarget.flatMap { rebased($0, to: capture) }
        if nextCurrent == nil, autoSyncEnabled {
            nextCurrent = ConsoleModelBuilder.preferredTarget(from: nextCandidates)
        }
        return WorkspaceConsoleRebaseState(
            currentTarget: nextCurrent,
            candidateTargets: nextCandidates,
            recentTargets: nextRecents
        )
    }

    func rebased(
        _ descriptor: ViewScopeConsoleTargetDescriptor,
        to capture: ViewScopeCapturePayload
    ) -> ViewScopeConsoleTargetDescriptor? {
        if descriptor.reference.captureID == capture.captureID {
            return descriptor
        }
        if descriptor.reference.kind != .returnedObject {
            // 节点类目标要求源节点在新抓取中仍然存在
            guard let sourceNodeID = descriptor.reference.sourceNodeID,
                  capture.nodes[sourceNodeID] != nil else {
                return nil
            }
        }
        var next = descriptor
        next.reference.captureID = capture.captureID
        return next
    }

    func updateTargets(
        from detail: ViewScopeNodeDetailPayload?,
        capture: ViewScopeCapturePayload?,
        currentTarget: ViewScopeConsoleTargetDescriptor?,
        autoSyncEnabled: Bool
    ) -> WorkspaceConsoleTargetUpdate {
        let candidateTargets = detail?.consoleTargets ?? []
        if autoSyncEnabled {
            return WorkspaceConsoleTargetUpdate(
                currentTarget: ConsoleModelBuilder.preferredTarget(from: candidateTargets),
                candidateTargets: candidateTargets,
                isLoadingTarget: false
            )
        }

        guard let capture else {
            return WorkspaceConsoleTargetUpdate(
                currentTarget: nil,
                candidateTargets: candidateTargets,
                isLoadingTarget: false
            )
        }

        let nextCurrentTarget: ViewScopeConsoleTargetDescriptor?
        if let currentTarget, currentTarget.reference.captureID == capture.captureID {
            nextCurrentTarget = currentTarget
        } else {
            nextCurrentTarget = nil
        }
        return WorkspaceConsoleTargetUpdate(
            currentTarget: nextCurrentTarget,
            candidateTargets: candidateTargets,
            isLoadingTarget: false
        )
    }

    func autoSyncUpdate(
        enabled: Bool,
        candidateTargets: [ViewScopeConsoleTargetDescriptor],
        currentTarget: ViewScopeConsoleTargetDescriptor?,
        captureID: String?
    ) -> WorkspaceConsoleAutoSyncUpdate {
        guard enabled else {
            return WorkspaceConsoleAutoSyncUpdate(currentTarget: currentTarget)
        }

        if let preferredTarget = ConsoleModelBuilder.preferredTarget(from: candidateTargets) {
            return WorkspaceConsoleAutoSyncUpdate(currentTarget: preferredTarget)
        }
        if let currentTarget, currentTarget.reference.captureID == captureID {
            return WorkspaceConsoleAutoSyncUpdate(currentTarget: currentTarget)
        }
        return WorkspaceConsoleAutoSyncUpdate(currentTarget: nil)
    }

    func selectedTarget(
        objectID: String,
        currentTarget: ViewScopeConsoleTargetDescriptor?,
        candidateTargets: [ViewScopeConsoleTargetDescriptor],
        recentTargets: [ViewScopeConsoleTargetDescriptor],
        rows: [ConsoleRowModel],
        autoSyncEnabled: Bool,
        isLoadingTarget: Bool,
        captureID: String?
    ) -> ViewScopeConsoleTargetDescriptor? {
        let options = ConsoleModelBuilder.make(
            currentTarget: currentTarget,
            candidateTargets: candidateTargets,
            recentTargets: recentTargets,
            rows: rows,
            autoSyncEnabled: autoSyncEnabled,
            isLoading: isLoadingTarget,
            captureID: captureID
        ).targetOptions

        return options.first(where: { $0.id == objectID })?.descriptor
    }

    func upsertRecentTarget(
        _ descriptor: ViewScopeConsoleTargetDescriptor,
        recentTargets: [ViewScopeConsoleTargetDescriptor]
    ) -> [ViewScopeConsoleTargetDescriptor] {
        var nextRecentTargets = recentTargets
        nextRecentTargets.removeAll { $0.reference.objectID == descriptor.reference.objectID }
        nextRecentTargets.insert(descriptor, at: 0)
        if nextRecentTargets.count > maximumRecentTargets {
            nextRecentTargets = Array(nextRecentTargets.prefix(maximumRecentTargets))
        }
        return nextRecentTargets
    }
}
