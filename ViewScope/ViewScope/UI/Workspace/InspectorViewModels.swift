import Foundation
import ViewScopeServer

struct InspectorPanelModel {
    var title: String
    var subtitle: String?
    var sections: [InspectorSectionModel]
    var placeholder: String?
}

struct InspectorSectionModel {
    var title: String
    var rows: [InspectorRowModel]
}

enum InspectorRowModel {
    case text(InspectorEditableTextModel)
    case toggle(InspectorEditableToggleModel)
    case quad(InspectorEditableQuadModel)
    case color(InspectorEditableColorModel)
    case readOnly(title: String, value: String)
    case list(title: String, values: [String])
}

struct InspectorEditableTextModel {
    var title: String
    var property: ViewScopeEditableProperty
    var value: String
}

struct InspectorEditableToggleModel {
    var title: String
    var property: ViewScopeEditableProperty
    var isOn: Bool
}

struct InspectorEditableColorModel {
    var title: String
    var property: ViewScopeEditableProperty
    var value: String
}

struct InspectorEditableQuadModel {
    struct Field {
        var label: String
        var property: ViewScopeEditableProperty
        var value: String
    }

    var title: String
    var fields: [Field]
}

struct InspectorPanelModelBuilder {
    func makeModel(capture: ViewScopeCapturePayload?, node: ViewScopeHierarchyNode?, detail: ViewScopeNodeDetailPayload?) -> InspectorPanelModel {
        guard let node else {
            return InspectorPanelModel(
                title: L10n.inspector,
                subtitle: nil,
                sections: [],
                placeholder: L10n.pickNodePlaceholder
            )
        }

        let propertyIndex = DetailPropertyIndex(detail: detail)
        var sections: [InspectorSectionModel] = []

        var identityRows: [InspectorRowModel] = [
            .readOnly(title: L10n.serverItemTitle("node_id"), value: node.id),
            .readOnly(title: L10n.serverItemTitle("class"), value: ViewScopeClassNameFormatter.displayName(for: node.className))
        ]
        if let editableTitle = propertyIndex.textProperty(forKey: "title") {
            identityRows.append(.text(.init(title: L10n.serverItemTitle("title"), property: editableTitle, value: editableTitle.textValue ?? "")))
        } else {
            identityRows.append(.readOnly(title: L10n.serverItemTitle("title"), value: node.title))
        }
        if let identifier = node.identifier, !identifier.isEmpty {
            identityRows.append(.readOnly(title: L10n.serverItemTitle("identifier"), value: identifier))
        }
        if let address = node.address, !address.isEmpty {
            identityRows.append(.readOnly(title: L10n.serverItemTitle("address"), value: address))
        }
        sections.append(.init(title: L10n.serverSectionTitle("identity"), rows: identityRows))

        var contentRows: [InspectorRowModel] = []
        if let controlValue = propertyIndex.textProperty(forKey: "control.value") {
            contentRows.append(.text(.init(title: L10n.serverItemTitle("value"), property: controlValue, value: controlValue.textValue ?? "")))
        }
        if !contentRows.isEmpty {
            sections.append(.init(title: L10n.serverSectionTitle("control"), rows: contentRows))
        }

        var geometryRows: [InspectorRowModel] = []
        if let frameRow = quadRow(title: L10n.serverItemTitle("frame"), propertyIndex: propertyIndex, keys: ["frame.x", "frame.y", "frame.width", "frame.height"]) {
            geometryRows.append(.quad(frameRow))
        }
        if let boundsRow = quadRow(title: L10n.serverItemTitle("bounds"), propertyIndex: propertyIndex, keys: ["bounds.x", "bounds.y", "bounds.width", "bounds.height"]) {
            geometryRows.append(.quad(boundsRow))
        }
        if let insetRow = quadRow(title: L10n.serverItemTitle("content_insets"), propertyIndex: propertyIndex, keys: ["contentInsets.top", "contentInsets.left", "contentInsets.bottom", "contentInsets.right"], labels: ["T", "L", "B", "R"]) {
            geometryRows.append(.quad(insetRow))
        }
        if !geometryRows.isEmpty {
            sections.append(.init(title: L10n.serverSectionTitle("geometry"), rows: geometryRows))
        }

        var appearanceRows: [InspectorRowModel] = []
        if let hiddenProperty = propertyIndex.toggleProperty(forKey: "hidden") {
            appearanceRows.append(.toggle(.init(title: L10n.serverItemTitle("hidden"), property: hiddenProperty, isOn: hiddenProperty.boolValue ?? false)))
        }
        if let alphaValue = propertyIndex.displayValue(forKey: "alpha") {
            appearanceRows.append(.readOnly(title: L10n.serverItemTitle("alpha"), value: alphaValue))
        }
        if let backgroundProperty = propertyIndex.textProperty(forKey: "backgroundColor") {
            appearanceRows.append(.color(.init(title: L10n.serverItemTitle("background"), property: backgroundProperty, value: backgroundProperty.textValue ?? backgroundProperty.valueDescription)))
        }
        if !appearanceRows.isEmpty {
            sections.append(.init(title: L10n.serverSectionTitle("rendering"), rows: appearanceRows))
        }

        if let detail {
            sections.append(.init(title: L10n.ancestry, rows: [.list(title: L10n.ancestry, values: detail.ancestry)]))
            sections.append(.init(title: L10n.constraints, rows: [.list(title: L10n.constraints, values: detail.constraints)]))
        }

        return InspectorPanelModel(
            title: node.title,
            subtitle: ViewScopeClassNameFormatter.displayName(for: node.className),
            sections: sections,
            placeholder: nil
        )
    }

    private func quadRow(
        title: String,
        propertyIndex: DetailPropertyIndex,
        keys: [String],
        labels: [String] = ["X", "Y", "W", "H"]
    ) -> InspectorEditableQuadModel? {
        guard keys.count == labels.count else { return nil }

        let fields = zip(labels, keys).compactMap { label, key -> InspectorEditableQuadModel.Field? in
            guard let property = propertyIndex.numberProperty(forKey: key) else { return nil }
            return InspectorEditableQuadModel.Field(
                label: label,
                property: property,
                value: propertyIndex.displayValue(forKey: key) ?? property.valueDescription
            )
        }
        guard fields.count == keys.count else { return nil }
        return InspectorEditableQuadModel(title: title, fields: fields)
    }

}

private struct DetailPropertyIndex {
    private let editablePropertiesByKey: [String: ViewScopeEditableProperty]
    private let itemValuesByKey: [String: String]

    init(detail: ViewScopeNodeDetailPayload?) {
        var editablePropertiesByKey: [String: ViewScopeEditableProperty] = [:]
        var itemValuesByKey: [String: String] = [:]

        detail?.sections.forEach { section in
            section.items.forEach { item in
                if let editable = item.editable {
                    editablePropertiesByKey[editable.key] = editable
                    itemValuesByKey[editable.key] = item.value
                }
            }
        }

        self.editablePropertiesByKey = editablePropertiesByKey
        self.itemValuesByKey = itemValuesByKey
    }

    func numberProperty(forKey key: String) -> ViewScopeEditableProperty? {
        guard let property = editablePropertiesByKey[key], property.kind == .number else { return nil }
        return property
    }

    func textProperty(forKey key: String) -> ViewScopeEditableProperty? {
        guard let property = editablePropertiesByKey[key], property.kind == .text else { return nil }
        return property
    }

    func toggleProperty(forKey key: String) -> ViewScopeEditableProperty? {
        guard let property = editablePropertiesByKey[key], property.kind == .toggle else { return nil }
        return property
    }

    func displayValue(forKey key: String) -> String? {
        itemValuesByKey[key]
    }
}

private extension ViewScopeEditableProperty {
    var valueDescription: String {
        if let textValue {
            return textValue
        }
        if let boolValue {
            return boolValue ? L10n.serverYes : L10n.serverNo
        }
        if let numberValue {
            return String(numberValue)
        }
        return ""
    }
}
