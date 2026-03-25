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

struct WorkspaceConsoleAutoSyncUpdate {
    let currentTarget: ViewScopeConsoleTargetDescriptor?
}

@MainActor
final class WorkspaceConsoleController {
    private let maximumRecentTargets: Int

    init(maximumRecentTargets: Int = 5) {
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
