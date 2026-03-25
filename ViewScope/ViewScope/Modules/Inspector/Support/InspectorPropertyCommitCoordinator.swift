import AppKit
import Foundation
import ViewScopeServer

@MainActor
final class InspectorPropertyCommitCoordinator {
    typealias MutationApplier = @MainActor (String, ViewScopeEditableProperty) async -> Bool

    private let localeProvider: @MainActor () -> Locale
    private let beep: @MainActor () -> Void
    private let colorParser: @MainActor (String) -> NSColor?
    private let applyMutation: MutationApplier

    convenience init(store: WorkspaceStore) {
        self.init(
            applyMutation: { [weak store] nodeID, property in
                guard let store else { return false }
                return await store.applyMutation(nodeID: nodeID, property: property)
            }
        )
    }

    init(
        locale: Locale? = nil,
        beep: @escaping @MainActor () -> Void = { NSSound.beep() },
        colorParser: @escaping @MainActor (String) -> NSColor? = { NSColor(viewScopeHexString: $0) },
        applyMutation: @escaping MutationApplier
    ) {
        self.localeProvider = { locale ?? AppLocalization.shared.locale }
        self.beep = beep
        self.colorParser = colorParser
        self.applyMutation = applyMutation
    }

    func commitText(
        _ value: String,
        property: ViewScopeEditableProperty,
        rowView: InspectorCommitCapable,
        nodeID: String?
    ) async {
        await commitProperty(.text(key: property.key, value: value), rowView: rowView, nodeID: nodeID)
    }

    func commitToggle(
        _ isOn: Bool,
        property: ViewScopeEditableProperty,
        rowView: InspectorCommitCapable,
        nodeID: String?
    ) async {
        await commitProperty(.toggle(key: property.key, value: isOn), rowView: rowView, nodeID: nodeID)
    }

    func commitNumber(
        _ value: String,
        property: ViewScopeEditableProperty,
        rowView: InspectorCommitCapable,
        nodeID: String?
    ) async {
        guard let number = parseNumber(value) else {
            beep()
            rowView.resetDisplayedValue()
            return
        }

        await commitProperty(.number(key: property.key, value: number), rowView: rowView, nodeID: nodeID)
    }

    func commitColor(
        _ value: String,
        property: ViewScopeEditableProperty,
        rowView: InspectorCommitCapable,
        nodeID: String?
    ) async {
        guard colorParser(value) != nil else {
            beep()
            rowView.resetDisplayedValue()
            return
        }

        await commitProperty(
            .text(key: property.key, value: value.uppercased()),
            rowView: rowView,
            nodeID: nodeID
        )
    }

    private func commitProperty(
        _ property: ViewScopeEditableProperty,
        rowView: InspectorCommitCapable,
        nodeID: String?
    ) async {
        guard let nodeID else { return }

        rowView.setEditingEnabled(false)
        let success = await applyMutation(nodeID, property)
        rowView.setEditingEnabled(true)
        if success == false {
            rowView.resetDisplayedValue()
        }
    }

    private func parseNumber(_ value: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = localeProvider()
        formatter.numberStyle = .decimal

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if let number = formatter.number(from: trimmed) {
            return number.doubleValue
        }
        return Double(trimmed)
    }
}
