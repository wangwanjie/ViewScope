import AppKit
import Foundation
import ViewScopeServer

/// Inspector 发起的一次属性修改。
struct InspectorMutationRequest: Equatable {
    let nodeID: String
    /// 新值（只含值，不含 options）。
    let property: ViewScopeEditableProperty
    /// 编辑时行上的可编辑属性（旧值），用于修改记录、还原与撤销。
    let previousProperty: ViewScopeEditableProperty?
    /// 属性展示标题。
    let title: String
}

@MainActor
final class InspectorPropertyCommitCoordinator {
    typealias MutationApplier = @MainActor (InspectorMutationRequest) async -> Bool

    private let localeProvider: @MainActor () -> Locale
    private let beep: @MainActor () -> Void
    private let colorParser: @MainActor (String) -> NSColor?
    private let applyMutation: MutationApplier

    convenience init(store: WorkspaceStore) {
        self.init(
            applyMutation: { [weak store] request in
                guard let store else {
                    return false
                }
                return await store.applyMutation(
                    nodeID: request.nodeID,
                    property: request.property,
                    previousProperty: request.previousProperty,
                    title: request.title
                )
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
        nodeID: String?,
        title: String? = nil
    ) async {
        // 值未变化（例如只是失焦）不发送修改
        guard value != property.textValue else {
            return
        }
        await commitProperty(.text(key: property.key, value: value), previous: property, title: title, rowView: rowView, nodeID: nodeID)
    }

    func commitToggle(
        _ isOn: Bool,
        property: ViewScopeEditableProperty,
        rowView: InspectorCommitCapable,
        nodeID: String?,
        title: String? = nil
    ) async {
        guard isOn != property.boolValue else {
            return
        }
        await commitProperty(.toggle(key: property.key, value: isOn), previous: property, title: title, rowView: rowView, nodeID: nodeID)
    }

    func commitNumber(
        _ value: String,
        property: ViewScopeEditableProperty,
        rowView: InspectorCommitCapable,
        nodeID: String?,
        title: String? = nil
    ) async {
        guard let number = parseNumber(value), number.isFinite else {
            beep()
            rowView.resetDisplayedValue()
            return
        }
        guard number != property.numberValue else {
            return
        }

        await commitProperty(.number(key: property.key, value: number), previous: property, title: title, rowView: rowView, nodeID: nodeID)
    }

    /// 枚举下拉框选择了新值。
    func commitEnumeration(
        _ value: Double,
        property: ViewScopeEditableProperty,
        rowView: InspectorCommitCapable,
        nodeID: String?,
        title: String? = nil
    ) async {
        guard value != property.numberValue else {
            return
        }
        await commitProperty(.number(key: property.key, value: value), previous: property, title: title, rowView: rowView, nodeID: nodeID)
    }

    func commitColor(
        _ value: String,
        property: ViewScopeEditableProperty,
        rowView: InspectorCommitCapable,
        nodeID: String?,
        title: String? = nil
    ) async {
        guard colorParser(value) != nil else {
            beep()
            rowView.resetDisplayedValue()
            return
        }
        let normalized = value.uppercased()
        guard normalized != property.textValue?.uppercased() else {
            return
        }

        await commitProperty(
            .text(key: property.key, value: normalized),
            previous: property,
            title: title,
            rowView: rowView,
            nodeID: nodeID
        )
    }

    private func commitProperty(
        _ property: ViewScopeEditableProperty,
        previous: ViewScopeEditableProperty,
        title: String?,
        rowView: InspectorCommitCapable,
        nodeID: String?
    ) async {
        guard let nodeID else {
            return
        }

        rowView.setEditingEnabled(false)
        let request = InspectorMutationRequest(
            nodeID: nodeID,
            property: property,
            previousProperty: previous,
            title: title ?? property.key
        )
        let success = await applyMutation(request)
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
        guard trimmed.isEmpty == false else {
            return nil
        }
        if let number = formatter.number(from: trimmed) {
            return number.doubleValue
        }
        return Double(trimmed)
    }
}
