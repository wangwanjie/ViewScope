import Foundation
import ViewScopeServer

/// 把修改记录导出为 Swift 代码片段。
///
/// - macOS 宿主生成 AppKit 写法（`alphaValue`、`layer?.`、`NSColor`）；
/// - iOS 等 UIKit 宿主生成 UIKit 写法（`alpha`、`layer.`、`UIColor`）；
/// - 按对象分组，同一对象同一 key 只保留最终值；
/// - 无法映射的 key 以注释形式输出，提示用户手动处理。
enum WorkspaceModificationCodeGenerator {
    enum Flavor: Equatable {
        case appKit
        case uiKit
    }

    /// 修改目标对象的类型，决定生成代码时使用的变量名与属性写法。
    enum ObjectKind: Equatable {
        case view
        case layer
        case window
    }

    static func flavor(for platform: ViewScopePlatform) -> Flavor {
        switch platform {
        case .macOS:
            return .appKit
        case .iOS, .iPadOS, .macCatalyst, .tvOS, .visionOS:
            return .uiKit
        }
    }

    static func generate(records: [WorkspaceModificationRecord]) -> String {
        let appliedRecords = records.filter { $0.state == .applied }
        guard appliedRecords.isEmpty == false else {
            return "// ViewScope: no modifications to export.\n"
        }

        // 先按宿主分组，再按对象分组，保持首次出现的顺序
        var hostOrder: [String] = []
        var groupsByHost: [String: [ObjectGroup]] = [:]
        for record in appliedRecords {
            if groupsByHost[record.hostIdentifier] == nil {
                hostOrder.append(record.hostIdentifier)
                groupsByHost[record.hostIdentifier] = []
            }
            var groups = groupsByHost[record.hostIdentifier] ?? []
            let objectKey = record.nodeAddress ?? record.nodeID
            if let index = groups.firstIndex(where: { $0.objectKey == objectKey }) {
                groups[index].apply(record)
            } else {
                var group = ObjectGroup(objectKey: objectKey, firstRecord: record)
                group.apply(record)
                groups.append(group)
            }
            groupsByHost[record.hostIdentifier] = groups
        }

        var lines: [String] = []
        for hostIdentifier in hostOrder {
            guard let groups = groupsByHost[hostIdentifier], let firstGroup = groups.first else {
                continue
            }
            let flavor = flavor(for: firstGroup.platform)
            let flavorName = flavor == .appKit ? "AppKit" : "UIKit"
            lines.append("// MARK: - \(firstGroup.hostDisplayName) (\(flavorName))")
            lines.append("")
            for group in groups {
                lines.append(contentsOf: group.makeLines(flavor: flavor))
                lines.append("")
            }
        }
        while lines.last == "" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 生成单条赋值语句；无法映射时返回 nil。
    static func statement(
        key: String,
        property: ViewScopeEditableProperty,
        objectKind: ObjectKind,
        className: String,
        flavor: Flavor
    ) -> String? {
        let object = variableName(for: objectKind)

        switch key {
        case "hidden":
            return "\(object).isHidden = \(boolLiteral(property))"
        case "alpha":
            switch objectKind {
            case .layer:
                return "\(object).opacity = \(numberLiteral(property))"
            case .view, .window:
                return "\(object).\(flavor == .appKit ? "alphaValue" : "alpha") = \(numberLiteral(property))"
            }
        case "enabled":
            return "\(object).isEnabled = \(boolLiteral(property))"
        case "toolTip":
            guard flavor == .appKit else {
                return nil
            }
            return "\(object).toolTip = \(valueLiteral(key: key, property: property, flavor: flavor))"
        case "backgroundColor":
            guard let color = colorLiteral(property, flavor: flavor) else {
                return nil
            }
            switch objectKind {
            case .layer:
                return "\(object).backgroundColor = \(color).cgColor"
            case .window:
                return "\(object).backgroundColor = \(color)"
            case .view:
                if flavor == .uiKit || appKitClassHasBackgroundColor(className) {
                    return "\(object).backgroundColor = \(color)"
                }
                return "\(object).wantsLayer = true\n\(object).layer?.backgroundColor = \(color).cgColor"
            }
        default:
            break
        }

        if let geometryStatement = geometryStatement(key: key, property: property, object: object) {
            return geometryStatement
        }

        if key.hasPrefix("layer.") {
            let path = String(key.dropFirst("layer.".count))
            guard isPropertyPath(path) else {
                return nil
            }
            let layerAccess: String
            switch objectKind {
            case .layer:
                layerAccess = object
            case .view, .window:
                layerAccess = flavor == .appKit ? "\(object).layer?" : "\(object).layer"
            }
            if path.lowercased().hasSuffix("color") {
                guard let color = colorLiteral(property, flavor: flavor) else {
                    return nil
                }
                return "\(layerAccess).\(path) = \(color).cgColor"
            }
            return "\(layerAccess).\(path) = \(valueLiteral(key: key, property: property, flavor: flavor))"
        }

        return controlStatement(key: key, property: property, object: object, flavor: flavor)
    }

    // MARK: - 私有实现

    private struct ObjectGroup {
        let objectKey: String
        let hostDisplayName: String
        let platform: ViewScopePlatform
        let className: String
        let hostViewClassName: String?
        let nodeKind: ViewScopeHierarchyNode.Kind?
        let address: String?
        let ivarName: String?
        private(set) var keyOrder: [String] = []
        private(set) var finalValues: [String: ViewScopeEditableProperty] = [:]

        init(objectKey: String, firstRecord: WorkspaceModificationRecord) {
            self.objectKey = objectKey
            self.hostDisplayName = firstRecord.hostDisplayName
            self.platform = firstRecord.platform
            self.className = firstRecord.className
            self.hostViewClassName = firstRecord.hostViewClassName
            self.nodeKind = firstRecord.nodeKind
            self.address = firstRecord.nodeAddress
            self.ivarName = firstRecord.ivarName
        }

        mutating func apply(_ record: WorkspaceModificationRecord) {
            if finalValues[record.key] == nil {
                keyOrder.append(record.key)
            }
            finalValues[record.key] = record.newValue
        }

        var objectKind: ObjectKind {
            switch nodeKind {
            case .window:
                return .window
            case .layer:
                // 带宿主视图的 layer 节点，视图级 key 作用于宿主视图
                return hostViewClassName == nil ? .layer : .view
            case .view, .none:
                return .view
            }
        }

        func makeLines(flavor: Flavor) -> [String] {
            let displayClassName = ViewScopeClassNameFormatter.displayName(for: hostViewClassName ?? className)
            var header = "// <\(displayClassName)"
            if let address, address.isEmpty == false {
                header += " \(address)"
            }
            header += ">"
            if let ivarName, ivarName.isEmpty == false {
                header += "  (\(ivarName))"
            }

            var lines = [header]
            for key in keyOrder {
                guard let property = finalValues[key] else {
                    continue
                }
                if let statement = WorkspaceModificationCodeGenerator.statement(
                    key: key,
                    property: property,
                    objectKind: objectKind,
                    className: hostViewClassName ?? className,
                    flavor: flavor
                ) {
                    lines.append(contentsOf: statement.components(separatedBy: "\n"))
                } else {
                    let value = WorkspaceModificationValueFormatter.displayString(for: property)
                    lines.append("// TODO: \(key) = \(value)")
                }
            }
            return lines
        }
    }

    /// 已知控件前缀：服务端 key 形如 `button.title`、`stack.spacing`，去掉前缀即为属性名。
    private static let controlPrefixes = [
        "button.", "textField.", "textView.", "control.", "stack.", "imageView.", "visualEffect.",
        "label.", "scrollView.", "tableView.", "collectionView.", "slider.", "switch.",
        "segmentedControl.", "progressView.", "datePicker.", "stepper.", "pageControl.",
        "activityIndicator.", "textInput.", "collection.", "scroll.", "image.", "table."
    ]

    private static func variableName(for objectKind: ObjectKind) -> String {
        switch objectKind {
        case .view:
            return "view"
        case .layer:
            return "layer"
        case .window:
            return "window"
        }
    }

    private static func geometryStatement(key: String, property: ViewScopeEditableProperty, object: String) -> String? {
        let mapping: [String: String] = [
            "frame.x": "frame.origin.x",
            "frame.y": "frame.origin.y",
            "frame.width": "frame.size.width",
            "frame.height": "frame.size.height",
            "bounds.x": "bounds.origin.x",
            "bounds.y": "bounds.origin.y",
            "bounds.width": "bounds.size.width",
            "bounds.height": "bounds.size.height"
        ]
        guard let path = mapping[key] else {
            return nil
        }
        return "\(object).\(path) = \(numberLiteral(property))"
    }

    private static func controlStatement(
        key: String,
        property: ViewScopeEditableProperty,
        object: String,
        flavor: Flavor
    ) -> String? {
        var path = key
        if let prefix = controlPrefixes.first(where: { key.hasPrefix($0) }) {
            path = String(key.dropFirst(prefix.count))
        }
        guard isPropertyPath(path), isKnownPropertyShape(path) else {
            return nil
        }

        // 少量需要特殊写法的属性
        switch (flavor, path) {
        case (_, "fontSize"):
            return "\(object).font = .systemFont(ofSize: \(numberLiteral(property))) // 近似：原字体族可能不同"
        case (.appKit, "value"):
            if property.kind == .number {
                return "\(object).doubleValue = \(numberLiteral(property))"
            }
            return "\(object).stringValue = \(stringLiteral(property.textValue ?? ""))"
        case (.uiKit, "value") where property.kind == .number:
            return "\(object).value = \(numberLiteral(property))"
        case (.uiKit, "title") where key.hasPrefix("button."):
            return "\(object).setTitle(\(stringLiteral(property.textValue ?? "")), for: .normal)"
        case (.uiKit, "titleColor") where key.hasPrefix("button."):
            guard let color = colorLiteral(property, flavor: flavor) else {
                return nil
            }
            return "\(object).setTitleColor(\(color), for: .normal)"
        case (.appKit, _) where path.hasPrefix("contentOffset."):
            // NSScrollView 没有 contentOffset，需要通过 contentView.scroll(to:) 实现
            return nil
        case (.uiKit, _) where path.hasPrefix("sectionInset."):
            return "(\(object).collectionViewLayout as? UICollectionViewFlowLayout)?.\(path) = \(numberLiteral(property))"
        default:
            break
        }

        if let options = property.options, options.isEmpty == false, property.kind == .number {
            let rawValue = Int(property.numberValue ?? 0)
            let title = WorkspaceModificationValueFormatter.displayString(for: property)
            return "\(object).\(path) = .init(rawValue: \(rawValue))! // \(title)"
        }
        return "\(object).\(path) = \(valueLiteral(key: key, property: property, flavor: flavor))"
    }

    private static func valueLiteral(key: String, property: ViewScopeEditableProperty, flavor: Flavor) -> String {
        switch property.kind {
        case .toggle:
            return boolLiteral(property)
        case .number:
            return numberLiteral(property)
        case .text:
            if key.lowercased().hasSuffix("color"), let color = colorLiteral(property, flavor: flavor) {
                return color
            }
            return stringLiteral(property.textValue ?? "")
        }
    }

    private static func boolLiteral(_ property: ViewScopeEditableProperty) -> String {
        (property.boolValue ?? false) ? "true" : "false"
    }

    private static func numberLiteral(_ property: ViewScopeEditableProperty) -> String {
        WorkspaceModificationValueFormatter.compactNumber(property.numberValue ?? 0)
    }

    private static func stringLiteral(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// `#RRGGBB` / `#RRGGBBAA` → `NSColor(red:green:blue:alpha:)` / `UIColor(...)`。
    static func colorLiteral(_ property: ViewScopeEditableProperty, flavor: Flavor) -> String? {
        guard let text = property.textValue, let components = rgbaComponents(fromHex: text) else {
            return nil
        }
        let typeName = flavor == .appKit ? "NSColor" : "UIColor"
        let red = colorComponent(components.red)
        let green = colorComponent(components.green)
        let blue = colorComponent(components.blue)
        let alpha = colorComponent(components.alpha)
        return "\(typeName)(red: \(red), green: \(green), blue: \(blue), alpha: \(alpha))"
    }

    static func rgbaComponents(fromHex string: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        var hex = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6 || hex.count == 8, let rawValue = UInt64(hex, radix: 16) else {
            return nil
        }
        if hex.count == 8 {
            return (
                Double((rawValue >> 24) & 0xFF) / 255,
                Double((rawValue >> 16) & 0xFF) / 255,
                Double((rawValue >> 8) & 0xFF) / 255,
                Double(rawValue & 0xFF) / 255
            )
        }
        return (
            Double((rawValue >> 16) & 0xFF) / 255,
            Double((rawValue >> 8) & 0xFF) / 255,
            Double(rawValue & 0xFF) / 255,
            1
        )
    }

    private static func colorComponent(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return WorkspaceModificationValueFormatter.compactNumber(rounded)
    }

    private static func appKitClassHasBackgroundColor(_ className: String) -> Bool {
        let markers = ["TextField", "TableView", "OutlineView", "TextView", "ScrollView", "ClipView", "CollectionView", "Window"]
        return markers.contains(where: { className.contains($0) })
    }

    /// 结构体类属性（边距、尺寸、点）及其分量，可以直接按 `view.a.b = v` 生成。
    private static let structPropertyNames: Set<String> = [
        "contentInsets", "contentInset", "layoutMargins", "edgeInsets", "textContainerInset",
        "contentEdgeInsets", "titleEdgeInsets", "imageEdgeInsets", "sectionInset", "separatorInset",
        "contentOffset", "contentSize", "intercellSpacing", "maxSize", "minSize", "shadowOffset"
    ]
    private static let structComponentNames: Set<String> = ["top", "left", "bottom", "right", "x", "y", "width", "height"]

    /// 只为“单个属性名”或“已知结构体属性的分量”生成代码，其余未知的多级 key 输出为注释。
    private static func isKnownPropertyShape(_ path: String) -> Bool {
        let segments = path.split(separator: ".").map(String.init)
        switch segments.count {
        case 1:
            return true
        case 2:
            return structPropertyNames.contains(segments[0]) && structComponentNames.contains(segments[1])
        default:
            return false
        }
    }

    /// 合法的 Swift 属性访问路径：`a`、`a.b.c`。
    private static func isPropertyPath(_ path: String) -> Bool {
        guard path.isEmpty == false else {
            return false
        }
        for segment in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard let first = segment.first, first.isLetter || first == "_" else {
                return false
            }
            guard segment.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                return false
            }
        }
        return true
    }
}
