import Foundation
import ViewScopeServer

struct ConsoleRowModel: Identifiable, Equatable {
    enum Kind: Equatable {
        case submit
        case response
        case error
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?

    init(
        id: String = UUID().uuidString,
        kind: Kind,
        title: String,
        subtitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }
}

struct ConsoleTargetOption: Identifiable, Equatable {
    enum Source: Equatable {
        case selection
        case recent
    }

    let descriptor: ViewScopeConsoleTargetDescriptor
    let source: Source

    var id: String { descriptor.reference.objectID }
}

struct ConsolePanelModel: Equatable {
    let currentTarget: ViewScopeConsoleTargetDescriptor?
    let targetOptions: [ConsoleTargetOption]
    let rows: [ConsoleRowModel]
    let autoSyncEnabled: Bool
    let isLoading: Bool
    let isSubmitEnabled: Bool
    let statusText: String?
}

enum ConsoleModelBuilder {
    static func make(
        currentTarget: ViewScopeConsoleTargetDescriptor?,
        candidateTargets: [ViewScopeConsoleTargetDescriptor],
        recentTargets: [ViewScopeConsoleTargetDescriptor],
        rows: [ConsoleRowModel],
        autoSyncEnabled: Bool,
        isLoading: Bool,
        captureID: String?
    ) -> ConsolePanelModel {
        let targetOptions = deduplicatedOptions(
            candidateTargets: candidateTargets,
            recentTargets: recentTargets
        )
        let targetIsFresh = currentTarget.map { target in
            guard let captureID else { return false }
            return target.reference.captureID == captureID
        } ?? false
        let isSubmitEnabled = currentTarget != nil && targetIsFresh && !isLoading

        return ConsolePanelModel(
            currentTarget: currentTarget,
            targetOptions: targetOptions,
            rows: rows,
            autoSyncEnabled: autoSyncEnabled,
            isLoading: isLoading,
            isSubmitEnabled: isSubmitEnabled,
            statusText: statusText(
                currentTarget: currentTarget,
                captureID: captureID,
                isLoading: isLoading,
                isSubmitEnabled: isSubmitEnabled
            )
        )
    }

    static func preferredTarget(from descriptors: [ViewScopeConsoleTargetDescriptor]) -> ViewScopeConsoleTargetDescriptor? {
        descriptors.first(where: { $0.reference.kind == .view })
            ?? descriptors.first(where: { $0.reference.kind == .layer })
            ?? descriptors.first
    }

    private static func deduplicatedOptions(
        candidateTargets: [ViewScopeConsoleTargetDescriptor],
        recentTargets: [ViewScopeConsoleTargetDescriptor]
    ) -> [ConsoleTargetOption] {
        var seen = Set<String>()
        var options: [ConsoleTargetOption] = []

        for descriptor in candidateTargets where seen.insert(descriptor.reference.objectID).inserted {
            options.append(ConsoleTargetOption(descriptor: descriptor, source: .selection))
        }
        for descriptor in recentTargets where seen.insert(descriptor.reference.objectID).inserted {
            options.append(ConsoleTargetOption(descriptor: descriptor, source: .recent))
        }

        return options
    }

    private static func statusText(
        currentTarget: ViewScopeConsoleTargetDescriptor?,
        captureID: String?,
        isLoading: Bool,
        isSubmitEnabled: Bool
    ) -> String? {
        if isLoading {
            return L10n.consoleStatusLoading
        }
        guard let currentTarget else {
            return L10n.consoleStatusNoTarget
        }
        guard let captureID else {
            return L10n.consoleStatusDisconnected
        }
        guard currentTarget.reference.captureID == captureID else {
            return L10n.consoleStatusStaleTarget
        }
        return isSubmitEnabled ? nil : L10n.consoleStatusUnavailable
    }
}

enum ConsoleRowFactory {
    static func makeSubmitRow(
        target: ViewScopeConsoleTargetDescriptor,
        expression: String
    ) -> ConsoleRowModel {
        ConsoleRowModel(
            kind: .submit,
            title: expression,
            subtitle: target.title
        )
    }

    static func makeResponseRow(
        response: ViewScopeConsoleInvokeResponsePayload
    ) -> ConsoleRowModel? {
        guard let description = response.resultDescription, !description.isEmpty else {
            return nil
        }
        return ConsoleRowModel(kind: .response, title: description)
    }

    static func makeErrorRow(message: String) -> ConsoleRowModel {
        ConsoleRowModel(kind: .error, title: message)
    }
}
