import Foundation
import ViewScopeServer

struct InspectorPanelModel: Equatable {
    var title: String
    var subtitle: String?
    var sections: [InspectorSectionModel]
    var placeholder: String?
    /// 可编辑项实际作用的节点：只有 detail 属于当前选中节点时才有值。
    var editableNodeID: String? = nil
}

struct InspectorSectionModel: Equatable {
    var title: String
    var rows: [InspectorRowModel]
}

enum InspectorRowModel: Equatable {
    case text(InspectorEditableTextModel)
    case toggle(InspectorEditableToggleModel)
    case number(InspectorEditableNumberModel)
    case enumeration(InspectorEditableEnumModel)
    case quad(InspectorEditableQuadModel)
    case color(InspectorEditableColorModel)
    case readOnly(title: String, value: String)
    case list(title: String, values: [String])
}

struct InspectorEditableTextModel: Equatable {
    var title: String
    var property: ViewScopeEditableProperty
    var value: String
}

struct InspectorEditableToggleModel: Equatable {
    var title: String
    var property: ViewScopeEditableProperty
    var isOn: Bool
}

struct InspectorEditableNumberModel: Equatable {
    var title: String
    var property: ViewScopeEditableProperty
    var value: String
}

/// 带候选项的枚举属性（服务端 v3 下发 `options`），使用下拉框编辑。
struct InspectorEditableEnumModel: Equatable {
    var title: String
    var property: ViewScopeEditableProperty
    var options: [ViewScopeEditableOption]

    /// 当前值对应的候选项下标；当前值不在候选项中时为 nil。
    var selectedIndex: Int? {
        guard let value = property.numberValue else {
            return nil
        }
        return options.firstIndex(where: { $0.value == value })
    }
}

struct InspectorEditableColorModel: Equatable {
    var title: String
    var property: ViewScopeEditableProperty
    var value: String
}

struct InspectorEditableQuadModel: Equatable {
    struct Field: Equatable {
        var label: String
        var property: ViewScopeEditableProperty
        var value: String
        /// 用于修改记录的完整标题，例如 “Frame X”。
        var title: String = ""
    }

    var title: String
    var fields: [Field]
}

struct InspectorPanelModelBuilder {
    /// 多分量属性的分组方式：按 key 的公共前缀（base）与后缀识别。
    private struct GroupPattern {
        let suffixes: [String]
        let labels: [String]
    }

    /// 矩形四元组（frame / bounds 等），必须先于两元组匹配。
    private static let rectPattern = GroupPattern(suffixes: ["x", "y", "width", "height"], labels: ["X", "Y", "W", "H"])
    /// 边距四元组（contentInsets / layoutMargins / edgeInsets 等）。
    private static let edgePattern = GroupPattern(suffixes: ["top", "left", "bottom", "right"], labels: ["T", "L", "B", "R"])
    /// 点（contentOffset 等）。
    private static let pointPattern = GroupPattern(suffixes: ["x", "y"], labels: ["X", "Y"])
    /// 尺寸（contentSize / intercellSpacing / textContainerInset(AppKit) 等）。
    private static let sizePattern = GroupPattern(suffixes: ["width", "height"], labels: ["W", "H"])

    private static let groupPatterns = [rectPattern, edgePattern, pointPattern, sizePattern]

    func makeModel(capture: ViewScopeCapturePayload?, node: ViewScopeHierarchyNode?, detail: ViewScopeNodeDetailPayload?) -> InspectorPanelModel {
        guard let node else {
            return InspectorPanelModel(
                title: L10n.inspector,
                subtitle: nil,
                sections: [],
                placeholder: capture == nil ? L10n.previewDisconnectedPlaceholder : L10n.pickNodePlaceholder
            )
        }

        // detail 可能还是上一个节点的（新 detail 请求在途），此时只显示只读的兜底信息，
        // 避免把 A 节点的属性写到 B 节点上
        let matchingDetail = detail?.nodeID == node.id ? detail : nil
        let sections = matchingDetail.map(makeSections(from:)) ?? fallbackSections(for: node)
        return InspectorPanelModel(
            title: node.title,
            subtitle: ViewScopeClassNameFormatter.displayName(for: node.className),
            sections: sections,
            placeholder: nil,
            editableNodeID: matchingDetail?.nodeID
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
        if let rootViewControllerClassName = node.rootViewControllerClassName, !rootViewControllerClassName.isEmpty {
            rows.append(
                .readOnly(
                    title: L10n.serverItemTitle("view_controller"),
                    value: ViewScopeClassNameFormatter.displayName(for: rootViewControllerClassName)
                )
            )
        }

        var sections = [
            InspectorSectionModel(title: L10n.serverSectionTitle("identity"), rows: rows)
        ]

        var controlRows: [InspectorRowModel] = []
        if let targetClassName = node.controlTargetClassName, !targetClassName.isEmpty {
            controlRows.append(
                .readOnly(
                    title: L10n.serverItemTitle("target"),
                    value: ViewScopeClassNameFormatter.displayName(for: targetClassName)
                )
            )
        } else if let actionName = node.controlActionName, !actionName.isEmpty {
            controlRows.append(
                .readOnly(
                    title: L10n.serverItemTitle("target"),
                    value: L10n.serverFirstResponder
                )
            )
        }
        if let actionName = node.controlActionName, !actionName.isEmpty {
            controlRows.append(.readOnly(title: L10n.serverItemTitle("action"), value: actionName))
        }
        if !controlRows.isEmpty {
            sections.append(InspectorSectionModel(title: L10n.serverSectionTitle("control"), rows: controlRows))
        }

        return sections
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
        let groups = makeGroupedRows(in: section)
        var groupByFirstKey: [String: InspectorEditableQuadModel] = [:]
        var consumedKeys = Set<String>()
        for group in groups {
            if let firstKey = group.fields.first?.property.key {
                groupByFirstKey[firstKey] = group
            }
            group.fields.forEach { consumedKeys.insert($0.property.key) }
        }

        // 分组行放在其第一个分量原来的位置，保持服务端给出的顺序
        var rows: [InspectorRowModel] = []
        for item in section.items {
            if let editable = item.editable, consumedKeys.contains(editable.key) {
                if let group = groupByFirstKey[editable.key] {
                    rows.append(.quad(group))
                }
                continue
            }
            rows.append(makeRow(for: item))
        }
        return rows
    }

    /// 识别 section 中可以合并显示的多分量数值属性。
    private func makeGroupedRows(in section: ViewScopePropertySection) -> [InspectorEditableQuadModel] {
        var numberItemsByKey: [String: ViewScopePropertyItem] = [:]
        var orderedKeys: [String] = []
        for item in section.items {
            guard let editable = item.editable, editable.kind == .number, editable.options == nil else {
                continue
            }
            numberItemsByKey[editable.key] = item
            orderedKeys.append(editable.key)
        }

        var consumed = Set<String>()
        var groups: [InspectorEditableQuadModel] = []
        for key in orderedKeys where consumed.contains(key) == false {
            guard let dotIndex = key.lastIndex(of: ".") else {
                continue
            }
            let base = String(key[..<dotIndex])
            for pattern in Self.groupPatterns {
                let keys = pattern.suffixes.map { "\(base).\($0)" }
                guard keys.allSatisfy({ numberItemsByKey[$0] != nil && consumed.contains($0) == false }) else {
                    continue
                }
                let groupTitle = Self.groupTitle(forBase: base)
                let fields = zip(pattern.labels, keys).compactMap { label, fieldKey -> InspectorEditableQuadModel.Field? in
                    guard let item = numberItemsByKey[fieldKey], let property = item.editable else {
                        return nil
                    }
                    return InspectorEditableQuadModel.Field(
                        label: label,
                        property: property,
                        value: item.value,
                        title: "\(groupTitle) \(label)"
                    )
                }
                keys.forEach { consumed.insert($0) }
                groups.append(InspectorEditableQuadModel(title: groupTitle, fields: fields))
                break
            }
        }
        return groups
    }

    /// 分组标题：已知 key 族使用本地化文案，其余由 key 推导（`edgeInsets` → “Edge Insets”）。
    static func groupTitle(forBase base: String) -> String {
        let lastComponent = base.split(separator: ".").last.map(String.init) ?? base
        switch lastComponent {
        case "frame":
            return L10n.serverItemTitle("frame")
        case "bounds":
            return L10n.serverItemTitle("bounds")
        case "contentInsets":
            return L10n.serverItemTitle("content_insets")
        case "contentInset":
            return L10n.inspectorGroupContentInset
        case "layoutMargins":
            return L10n.inspectorGroupLayoutMargins
        case "edgeInsets":
            return L10n.inspectorGroupEdgeInsets
        case "textContainerInset":
            return L10n.inspectorGroupTextContainerInset
        case "sectionInset":
            return L10n.inspectorGroupSectionInset
        case "contentEdgeInsets":
            return L10n.inspectorGroupContentEdgeInsets
        case "contentOffset":
            return L10n.inspectorGroupContentOffset
        case "contentSize":
            return L10n.inspectorGroupContentSize
        case "intercellSpacing":
            return L10n.inspectorGroupIntercellSpacing
        default:
            return humanized(lastComponent)
        }
    }

    /// `edgeInsets` → `Edge Insets`。
    static func humanized(_ identifier: String) -> String {
        var words: [String] = []
        var current = ""
        for character in identifier {
            if character.isUppercase, current.isEmpty == false {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if current.isEmpty == false {
            words.append(current)
        }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
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
            if let options = property.options, options.isEmpty == false {
                return .enumeration(
                    InspectorEditableEnumModel(
                        title: item.title,
                        property: property,
                        options: options
                    )
                )
            }
            return .number(
                InspectorEditableNumberModel(
                    title: item.title,
                    property: property,
                    value: item.value
                )
            )
        case .text:
            // 颜色 key 统一用 color row：backgroundColor 以及所有包含 "Color" 的 key
            let isColorKey = property.key == "backgroundColor" ||
                property.key.lowercased().hasSuffix("color") ||
                (property.textValue.map { $0.hasPrefix("#") && ($0.count == 7 || $0.count == 9) } ?? false)
            if isColorKey {
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
