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
    case number(InspectorEditableNumberModel)
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

struct InspectorEditableNumberModel {
    var title: String
    var property: ViewScopeEditableProperty
    var value: String
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
    private struct QuadGroup {
        let title: String
        let labels: [String]
        let keys: [String]
    }

    private let quadGroups: [QuadGroup] = [
        QuadGroup(
            title: L10n.serverItemTitle("frame"),
            labels: ["X", "Y", "W", "H"],
            keys: ["frame.x", "frame.y", "frame.width", "frame.height"]
        ),
        QuadGroup(
            title: L10n.serverItemTitle("bounds"),
            labels: ["X", "Y", "W", "H"],
            keys: ["bounds.x", "bounds.y", "bounds.width", "bounds.height"]
        ),
        QuadGroup(
            title: L10n.serverItemTitle("content_insets"),
            labels: ["T", "L", "B", "R"],
            keys: ["contentInsets.top", "contentInsets.left", "contentInsets.bottom", "contentInsets.right"]
        )
    ]

    func makeModel(capture: ViewScopeCapturePayload?, node: ViewScopeHierarchyNode?, detail: ViewScopeNodeDetailPayload?) -> InspectorPanelModel {
        guard let node else {
            return InspectorPanelModel(
                title: L10n.inspector,
                subtitle: nil,
                sections: [],
                placeholder: capture == nil ? L10n.previewDisconnectedPlaceholder : L10n.pickNodePlaceholder
            )
        }

        let sections = detail.map(makeSections(from:)) ?? fallbackSections(for: node)
        return InspectorPanelModel(
            title: node.title,
            subtitle: ViewScopeClassNameFormatter.displayName(for: node.className),
            sections: sections,
            placeholder: nil
        )
    }

    private func fallbackSections(for node: ViewScopeHierarchyNode) -> [InspectorSectionModel] {
        var rows: [InspectorRowModel] = [
            .readOnly(title: L10n.serverItemTitle("class"), value: ViewScopeClassNameFormatter.displayName(for: node.className)),
            .readOnly(title: L10n.serverItemTitle("title"), value: node.title)
        ]
        if let identifier = node.identifier, !identifier.isEmpty {
            rows.append(.readOnly(title: L10n.serverItemTitle("identifier"), value: identifier))
        }
        if let address = node.address, !address.isEmpty {
            rows.append(.readOnly(title: L10n.serverItemTitle("address"), value: address))
        }
        return [
            InspectorSectionModel(title: L10n.serverSectionTitle("identity"), rows: rows)
        ]
    }

    private func makeSections(from detail: ViewScopeNodeDetailPayload) -> [InspectorSectionModel] {
        var sections = detail.sections.compactMap { section -> InspectorSectionModel? in
            let rows = makeRows(for: section)
            guard !rows.isEmpty else { return nil }
            return InspectorSectionModel(title: section.title, rows: rows)
        }

        if !detail.ancestry.isEmpty {
            sections.append(.init(title: L10n.ancestry, rows: [.list(title: L10n.ancestry, values: detail.ancestry)]))
        }
        if !detail.constraints.isEmpty {
            sections.append(.init(title: L10n.constraints, rows: [.list(title: L10n.constraints, values: detail.constraints)]))
        }

        return sections
    }

    private func makeRows(for section: ViewScopePropertySection) -> [InspectorRowModel] {
        let quadRows = quadGroups.compactMap { makeQuadRow(group: $0, in: section) }
        let consumedQuadKeys = Set(quadRows.flatMap { quadRow in
            quadRow.fields.map(\.property.key)
        })

        var rows = quadRows.map(InspectorRowModel.quad)
        for item in section.items {
            if let editable = item.editable, consumedQuadKeys.contains(editable.key) {
                continue
            }
            rows.append(makeRow(for: item))
        }
        return rows
    }

    private func makeQuadRow(group: QuadGroup, in section: ViewScopePropertySection) -> InspectorEditableQuadModel? {
        let fields = zip(group.labels, group.keys).compactMap { label, key -> InspectorEditableQuadModel.Field? in
            guard let item = section.items.first(where: { $0.editable?.key == key }),
                  let property = item.editable,
                  property.kind == .number else {
                return nil
            }

            return InspectorEditableQuadModel.Field(
                label: label,
                property: property,
                value: item.value
            )
        }

        guard fields.count == group.keys.count else { return nil }
        return InspectorEditableQuadModel(title: group.title, fields: fields)
    }

    private func makeRow(for item: ViewScopePropertyItem) -> InspectorRowModel {
        guard let property = item.editable else {
            return .readOnly(title: item.title, value: item.value)
        }

        switch property.kind {
        case .toggle:
            return .toggle(
                InspectorEditableToggleModel(
                    title: item.title,
                    property: property,
                    isOn: property.boolValue ?? false
                )
            )
        case .number:
            return .number(
                InspectorEditableNumberModel(
                    title: item.title,
                    property: property,
                    value: item.value
                )
            )
        case .text:
            if property.key == "backgroundColor" {
                return .color(
                    InspectorEditableColorModel(
                        title: item.title,
                        property: property,
                        value: property.textValue ?? item.value
                    )
                )
            }
            return .text(
                InspectorEditableTextModel(
                    title: item.title,
                    property: property,
                    value: property.textValue ?? item.value
                )
            )
        }
    }
}
