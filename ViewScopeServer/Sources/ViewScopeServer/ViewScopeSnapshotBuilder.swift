import AppKit
import Foundation

@MainActor
/// Builds hierarchy captures, detail payloads, and live object references for an inspected host.
final class ViewScopeSnapshotBuilder {
    struct ReferenceContext {
        var nodeReferences: [String: ViewScopeInspectableReference]
        var rootNodeIDs: [String]
    }

    private let hostInfo: ViewScopeHostInfo
    private let interfaceLanguage: ViewScopeInterfaceLanguage

    init(hostInfo: ViewScopeHostInfo, interfaceLanguage: ViewScopeInterfaceLanguage = .english) {
        self.hostInfo = hostInfo
        self.interfaceLanguage = interfaceLanguage
    }

    func makeCapture() -> (ViewScopeCapturePayload, ReferenceContext) {
        let start = Date()
        let windows = NSApp.windows
            .filter { window in
                guard !(window is NSPanel && NSStringFromClass(type(of: window)).contains("ViewScope")) else {
                    return false
                }
                return window.contentView != nil
            }
            .sorted { left, right in
                if left.isVisible == right.isVisible {
                    return left.windowNumber < right.windowNumber
                }
                return left.isVisible && !right.isVisible
            }

        var nodes: [String: ViewScopeHierarchyNode] = [:]
        var references: [String: ViewScopeInspectableReference] = [:]
        var rootNodeIDs: [String] = []

        for (index, window) in windows.enumerated() {
            let windowID = "window-\(index)"
            let contentBounds = window.contentView?.bounds ?? .zero
            let contentIsFlipped = window.contentView?.isFlipped ?? false
            nodes[windowID] = ViewScopeHierarchyNode(
                id: windowID,
                parentID: nil,
                kind: .window,
                className: NSStringFromClass(type(of: window)),
                title: sanitizedDisplayText(window.title) ?? interfaceLanguage.text("server.value.window_fallback"),
                subtitle: "#\(window.windowNumber)",
                address: window.viewScopeAddress,
                frame: contentBounds.viewScopeRect,
                bounds: contentBounds.viewScopeRect,
                childIDs: [],
                isHidden: !window.isVisible,
                alphaValue: Double(window.alphaValue),
                wantsLayer: true,
                isFlipped: contentIsFlipped,
                clippingEnabled: true,
                depth: 0
            )
            references[windowID] = .window(window)
            rootNodeIDs.append(windowID)

            if let contentView = window.contentView {
                let childIDs = buildNodes(
                    from: contentView,
                    parentID: windowID,
                    prefix: "\(windowID)-view",
                    depth: 1,
                    nodes: &nodes,
                    references: &references
                )
                nodes[windowID]?.childIDs = childIDs
            }
        }

        let summary = ViewScopeCaptureSummary(
            nodeCount: nodes.count,
            windowCount: windows.count,
            visibleWindowCount: windows.filter(\.isVisible).count,
            captureDurationMilliseconds: Int(Date().timeIntervalSince(start) * 1000)
        )

        return (
            ViewScopeCapturePayload(
                host: hostInfo,
                capturedAt: Date(),
                summary: summary,
                rootNodeIDs: rootNodeIDs,
                nodes: nodes
            ),
            ReferenceContext(nodeReferences: references, rootNodeIDs: rootNodeIDs)
        )
    }

    func makeDetail(for nodeID: String, in context: ReferenceContext) -> ViewScopeNodeDetailPayload? {
        guard let reference = context.nodeReferences[nodeID] else {
            return nil
        }

        switch reference {
        case .window(let window):
            let image = makeWindowScreenshot(window: window)
            return ViewScopeNodeDetailPayload(
                nodeID: nodeID,
                host: hostInfo,
                sections: windowSections(for: window),
                constraints: [],
                ancestry: [window.title.isEmpty ? interfaceLanguage.text("server.value.window_fallback") : window.title],
                screenshotPNGBase64: image.flatMap(ViewScopeImageEncoder().base64PNG),
                screenshotSize: image?.size.viewScopeSize ?? .zero,
                highlightedRect: window.contentView?.bounds.viewScopeRect ?? .zero
            )
        case .view(let view):
            let rootView = view.window?.contentView
            let image = rootView.flatMap(makeViewScreenshot)
            let highlightRect = rootView.map { root in
                normalizedCanvasRect(for: view, in: root).viewScopeRect
            } ?? .zero
            return ViewScopeNodeDetailPayload(
                nodeID: nodeID,
                host: hostInfo,
                sections: viewSections(for: view),
                constraints: constraintDescriptions(for: view),
                ancestry: ancestry(for: view),
                screenshotPNGBase64: image.flatMap(ViewScopeImageEncoder().base64PNG),
                screenshotSize: image?.size.viewScopeSize ?? .zero,
                highlightedRect: highlightRect
            )
        }
    }

    private func buildNodes(
        from view: NSView,
        parentID: String,
        prefix: String,
        depth: Int,
        nodes: inout [String: ViewScopeHierarchyNode],
        references: inout [String: ViewScopeInspectableReference]
    ) -> [String] {
        var childIDs: [String] = []

        for (index, child) in view.subviews.enumerated() {
            let nodeID = "\(prefix)-\(index)"
            let title = sanitizedDisplayText(child.viewScopeTitle(interfaceLanguage: interfaceLanguage))
                ?? NSStringFromClass(type(of: child)).components(separatedBy: ".").last
                ?? NSStringFromClass(type(of: child))
            nodes[nodeID] = ViewScopeHierarchyNode(
                id: nodeID,
                parentID: parentID,
                kind: .view,
                className: NSStringFromClass(type(of: child)),
                title: title,
                subtitle: sanitizedDisplayText(child.viewScopeSubtitle(interfaceLanguage: interfaceLanguage)),
                identifier: sanitizedDisplayText(child.identifier?.rawValue),
                address: child.viewScopeAddress,
                frame: child.frame.viewScopeRect,
                bounds: child.bounds.viewScopeRect,
                childIDs: [],
                isHidden: child.isHidden,
                alphaValue: Double(child.alphaValue),
                wantsLayer: child.wantsLayer,
                isFlipped: child.isFlipped,
                clippingEnabled: child.layer?.masksToBounds ?? false,
                depth: depth
            )
            references[nodeID] = .view(child)
            let nestedIDs = buildNodes(
                from: child,
                parentID: nodeID,
                prefix: nodeID,
                depth: depth + 1,
                nodes: &nodes,
                references: &references
            )
            nodes[nodeID]?.childIDs = nestedIDs
            childIDs.append(nodeID)
        }

        return childIDs
    }

    private func makeViewScreenshot(view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makeWindowScreenshot(window: NSWindow) -> NSImage? {
        guard let contentView = window.contentView else {
            return nil
        }
        return makeViewScreenshot(view: contentView)
    }

    private func normalizedCanvasRect(for view: NSView, in rootView: NSView) -> NSRect {
        let rect = view.convert(view.bounds, to: rootView)
        guard rootView.isFlipped == false else {
            return rect
        }

        return NSRect(
            x: rect.origin.x,
            y: rootView.bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func text(_ key: String, _ arguments: CVarArg...) -> String {
        interfaceLanguage.text(key, arguments: arguments)
    }

    private func sanitizedDisplayText(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = value.viewScopeSanitizedSingleLine
        return sanitized.isEmpty ? nil : sanitized
    }

    private func formattedNumber(_ value: Double, decimals: Int) -> String {
        let format = "%.\(decimals)f"
        return String(format: format, locale: interfaceLanguage.locale, value)
    }

    private func editableToggleItem(title: String, key: String, value: Bool) -> ViewScopePropertyItem {
        ViewScopePropertyItem(
            title: title,
            value: value.viewScopeBoolText(interfaceLanguage: interfaceLanguage),
            editable: .toggle(key: key, value: value)
        )
    }

    private func editableNumberItem(title: String, key: String, value: Double, decimals: Int) -> ViewScopePropertyItem {
        ViewScopePropertyItem(
            title: title,
            value: formattedNumber(value, decimals: decimals),
            editable: .number(key: key, value: value)
        )
    }

    private func editableTextItem(title: String, key: String, value: String) -> ViewScopePropertyItem {
        ViewScopePropertyItem(
            title: title,
            value: value,
            editable: .text(key: key, value: value)
        )
    }

    private func windowSections(for window: NSWindow) -> [ViewScopePropertySection] {
        [
            ViewScopePropertySection(
                title: text("server.section.identity"),
                items: [
                    ViewScopePropertyItem(title: text("server.item.class"), value: NSStringFromClass(type(of: window))),
                    editableTextItem(
                        title: text("server.item.title"),
                        key: "title",
                        value: sanitizedDisplayText(window.title) ?? ""
                    ),
                    ViewScopePropertyItem(title: text("server.item.window_number"), value: String(window.windowNumber)),
                    ViewScopePropertyItem(title: text("server.item.address"), value: window.viewScopeAddress)
                ]
            ),
            ViewScopePropertySection(
                title: text("server.section.state"),
                items: [
                    ViewScopePropertyItem(title: text("server.item.visible"), value: window.isVisible.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
                    ViewScopePropertyItem(title: text("server.item.key"), value: window.isKeyWindow.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
                    ViewScopePropertyItem(title: text("server.item.main"), value: window.isMainWindow.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
                    ViewScopePropertyItem(title: text("server.item.level"), value: String(window.level.rawValue)),
                    editableNumberItem(title: text("server.item.alpha"), key: "alpha", value: Double(window.alphaValue), decimals: 2)
                ]
            ),
            ViewScopePropertySection(
                title: text("server.section.geometry"),
                items: [
                    ViewScopePropertyItem(title: text("server.item.frame"), value: window.frame.viewScopeString),
                    editableNumberItem(title: text("server.item.x"), key: "frame.x", value: Double(window.frame.origin.x), decimals: 1),
                    editableNumberItem(title: text("server.item.y"), key: "frame.y", value: Double(window.frame.origin.y), decimals: 1),
                    editableNumberItem(title: text("server.item.width"), key: "frame.width", value: Double(window.frame.width), decimals: 1),
                    editableNumberItem(title: text("server.item.height"), key: "frame.height", value: Double(window.frame.height), decimals: 1),
                    ViewScopePropertyItem(title: text("server.item.content_layout"), value: window.contentLayoutRect.viewScopeString)
                ]
            )
        ]
    }

    private func viewSections(for view: NSView) -> [ViewScopePropertySection] {
        var identityItems = [
            ViewScopePropertyItem(title: text("server.item.class"), value: NSStringFromClass(type(of: view))),
            ViewScopePropertyItem(title: text("server.item.address"), value: view.viewScopeAddress)
        ]
        if let title = sanitizedDisplayText(view.viewScopeTitle(interfaceLanguage: interfaceLanguage)) {
            identityItems.append(ViewScopePropertyItem(title: text("server.item.title"), value: title))
        }
        if let identifier = view.identifier?.rawValue, !identifier.isEmpty {
            identityItems.append(ViewScopePropertyItem(title: text("server.item.identifier"), value: identifier))
        }
        if let tooltip = view.toolTip, !tooltip.isEmpty {
            identityItems.append(ViewScopePropertyItem(title: text("server.item.tooltip"), value: tooltip))
        }

        let layoutItems = [
            ViewScopePropertyItem(title: text("server.item.frame"), value: view.frame.viewScopeString),
            editableNumberItem(title: text("server.item.x"), key: "frame.x", value: Double(view.frame.origin.x), decimals: 1),
            editableNumberItem(title: text("server.item.y"), key: "frame.y", value: Double(view.frame.origin.y), decimals: 1),
            editableNumberItem(title: text("server.item.width"), key: "frame.width", value: Double(view.frame.width), decimals: 1),
            editableNumberItem(title: text("server.item.height"), key: "frame.height", value: Double(view.frame.height), decimals: 1),
            ViewScopePropertyItem(title: text("server.item.bounds"), value: view.bounds.viewScopeString),
            ViewScopePropertyItem(title: text("server.item.intrinsic_size"), value: view.intrinsicContentSize.viewScopeString(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: text("server.item.translates_mask"), value: view.translatesAutoresizingMaskIntoConstraints.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(
                title: text("server.item.hugging_h"),
                value: String(format: "%.1f", locale: interfaceLanguage.locale, view.contentHuggingPriority(for: .horizontal).rawValue)
            ),
            ViewScopePropertyItem(
                title: text("server.item.hugging_v"),
                value: String(format: "%.1f", locale: interfaceLanguage.locale, view.contentHuggingPriority(for: .vertical).rawValue)
            ),
            ViewScopePropertyItem(
                title: text("server.item.compression_h"),
                value: String(format: "%.1f", locale: interfaceLanguage.locale, view.contentCompressionResistancePriority(for: .horizontal).rawValue)
            ),
            ViewScopePropertyItem(
                title: text("server.item.compression_v"),
                value: String(format: "%.1f", locale: interfaceLanguage.locale, view.contentCompressionResistancePriority(for: .vertical).rawValue)
            )
        ]

        var renderingItems = [
            editableToggleItem(title: text("server.item.hidden"), key: "hidden", value: view.isHidden),
            editableNumberItem(title: text("server.item.alpha"), key: "alpha", value: Double(view.alphaValue), decimals: 2),
            ViewScopePropertyItem(title: text("server.item.layer_backed"), value: view.wantsLayer.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: text("server.item.flipped"), value: view.isFlipped.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: text("server.item.subviews"), value: String(view.subviews.count))
        ]
        if let background = view.layer?.backgroundColor?.viewScopeDescription {
            renderingItems.append(ViewScopePropertyItem(title: text("server.item.background"), value: background))
        }

        var sections = [
            ViewScopePropertySection(title: text("server.section.identity"), items: identityItems),
            ViewScopePropertySection(title: text("server.section.layout"), items: layoutItems),
            ViewScopePropertySection(title: text("server.section.rendering"), items: renderingItems)
        ]

        if let control = view as? NSControl {
            let editableControlValue: ViewScopeEditableProperty? = {
                if control is NSButton || control is NSTextField || control is NSSegmentedControl {
                    return .text(key: "control.value", value: control.viewScopeControlValue)
                }
                return .text(key: "control.value", value: control.stringValue)
            }()
            sections.append(
                ViewScopePropertySection(
                    title: text("server.section.control"),
                    items: [
                        ViewScopePropertyItem(title: text("server.item.enabled"), value: control.isEnabled.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
                        ViewScopePropertyItem(title: text("server.item.value"), value: control.viewScopeControlValue, editable: editableControlValue)
                    ]
                )
            )
        }

        return sections
    }

    private func ancestry(for view: NSView) -> [String] {
        var chain: [String] = []
        var cursor: NSView? = view
        while let current = cursor {
            chain.append(current.viewScopeTitle(interfaceLanguage: interfaceLanguage))
            cursor = current.superview
        }
        if let title = sanitizedDisplayText(view.window?.title), !title.isEmpty {
            chain.append(title)
        }
        return chain.reversed()
    }

    private func constraintDescriptions(for view: NSView) -> [String] {
        var allConstraints = view.constraints
        if let superview = view.superview {
            allConstraints.append(contentsOf: superview.constraints.filter { constraint in
                (constraint.firstItem as AnyObject?) === view || (constraint.secondItem as AnyObject?) === view
            })
        }

        let descriptions = allConstraints.map { constraint -> String in
            let first = (constraint.firstItem as? NSObject).map { NSStringFromClass(type(of: $0)) } ?? "nil"
            let second = (constraint.secondItem as? NSObject).map { NSStringFromClass(type(of: $0)) } ?? "nil"
            let relation = constraint.relation.viewScopeSymbol
            let multiplier = String(format: "%.2f", locale: interfaceLanguage.locale, constraint.multiplier)
            let constant = String(format: "%.2f", locale: interfaceLanguage.locale, constraint.constant)
            return "\(first).\(constraint.firstAttribute.rawValue) \(relation) \(second).\(constraint.secondAttribute.rawValue) * \(multiplier) + \(constant)"
        }

        return descriptions.isEmpty ? [text("server.value.no_active_constraints")] : descriptions
    }
}

enum ViewScopeInspectableReference {
    case window(NSWindow)
    case view(NSView)
}

private extension NSView {
    func viewScopeTitle(interfaceLanguage: ViewScopeInterfaceLanguage) -> String {
        if let tabView = self as? NSTabView,
           let selectedItem = tabView.selectedTabViewItem,
           !selectedItem.label.isEmpty {
            return selectedItem.label.viewScopeSanitizedSingleLine
        }
        if self is NSOutlineView {
            return identifier?.rawValue ?? interfaceLanguage.text("server.value.outline_view")
        }
        if self is NSTableView {
            return identifier?.rawValue ?? interfaceLanguage.text("server.value.table_view")
        }
        if let rowView = self as? NSTableRowView,
           let tableView = rowView.viewScopeEnclosingTableView {
            let row = tableView.row(for: rowView)
            if row >= 0 {
                return interfaceLanguage.text("server.value.row_format", row)
            }
        }
        if let cellView = self as? NSTableCellView,
           let text = cellView.textField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text.viewScopeSanitizedSingleLine
        }
        if let button = self as? NSButton, !button.title.isEmpty {
            return button.title.viewScopeSanitizedSingleLine
        }
        if let textField = self as? NSTextField, !textField.stringValue.isEmpty {
            return textField.stringValue.viewScopeSanitizedSingleLine
        }
        if let segmented = self as? NSSegmentedControl, segmented.segmentCount > 0 {
            return segmented.label(forSegment: max(segmented.selectedSegment, 0))?.viewScopeSanitizedSingleLine
                ?? NSStringFromClass(type(of: self))
        }
        if let identifier = identifier?.rawValue, !identifier.isEmpty {
            return identifier.viewScopeSanitizedSingleLine
        }
        return NSStringFromClass(type(of: self)).components(separatedBy: ".").last ?? NSStringFromClass(type(of: self))
    }

    func viewScopeSubtitle(interfaceLanguage: ViewScopeInterfaceLanguage) -> String? {
        if let outlineView = self as? NSOutlineView {
            return interfaceLanguage.text("server.subtitle.visible_rows", outlineView.numberOfRows)
        }
        if let tableView = self as? NSTableView {
            return interfaceLanguage.text("server.subtitle.rows_cols", tableView.numberOfRows, tableView.numberOfColumns)
        }
        if let tabView = self as? NSTabView {
            return interfaceLanguage.text("server.subtitle.tabs", tabView.numberOfTabViewItems)
        }
        if let imageView = self as? NSImageView, imageView.image != nil {
            return interfaceLanguage.text("server.value.image")
        }
        if let stack = self as? NSStackView {
            return interfaceLanguage.text("server.subtitle.arranged", stack.arrangedSubviews.count)
        }
        if let scroll = self as? NSScrollView, scroll.hasVerticalScroller || scroll.hasHorizontalScroller {
            return interfaceLanguage.text("server.value.scrollable")
        }
        return nil
    }

    var viewScopeAddress: String {
        String(describing: Unmanaged.passUnretained(self).toOpaque())
    }

    var viewScopeEnclosingTableView: NSTableView? {
        var candidate = superview
        while let current = candidate {
            if let tableView = current as? NSTableView {
                return tableView
            }
            candidate = current.superview
        }
        return nil
    }
}

private extension NSWindow {
    var viewScopeAddress: String {
        String(describing: Unmanaged.passUnretained(self).toOpaque())
    }
}

private extension NSControl {
    var viewScopeControlValue: String {
        switch self {
        case let button as NSButton:
            return button.title
        case let field as NSTextField:
            return field.stringValue
        default:
            return stringValue
        }
    }
}

private extension NSRect {
    var viewScopeRect: ViewScopeRect {
        ViewScopeRect(x: Double(origin.x), y: Double(origin.y), width: Double(size.width), height: Double(size.height))
    }

    var viewScopeString: String {
        String(format: "x %.1f y %.1f w %.1f h %.1f", origin.x, origin.y, size.width, size.height)
    }
}

private extension NSSize {
    var viewScopeSize: ViewScopeSize {
        ViewScopeSize(width: Double(width), height: Double(height))
    }

    func viewScopeString(interfaceLanguage: ViewScopeInterfaceLanguage) -> String {
        let noIntrinsicMetric = CGFloat(-1)
        if width == noIntrinsicMetric || height == noIntrinsicMetric {
            return interfaceLanguage.text("server.value.no_intrinsic_size")
        }
        return String(format: "w %.1f h %.1f", width, height)
    }
}

private extension Bool {
    func viewScopeBoolText(interfaceLanguage: ViewScopeInterfaceLanguage) -> String {
        self ? interfaceLanguage.text("server.value.yes") : interfaceLanguage.text("server.value.no")
    }
}

private extension NSLayoutConstraint.Relation {
    var viewScopeSymbol: String {
        switch self {
        case .equal:
            return "="
        case .greaterThanOrEqual:
            return ">="
        case .lessThanOrEqual:
            return "<="
        @unknown default:
            return "?"
        }
    }
}

private extension CGColor {
    var viewScopeDescription: String {
        guard let components else {
            return "CGColor"
        }
        let values = components.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        return "[\(values)]"
    }
}

private extension String {
    var viewScopeSanitizedSingleLine: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
