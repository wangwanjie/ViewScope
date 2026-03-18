import AppKit
import Foundation

@MainActor
final class ViewScopeSnapshotBuilder {
    struct ReferenceContext {
        var nodeReferences: [String: ViewScopeInspectableReference]
        var rootNodeIDs: [String]
    }

    private let hostInfo: ViewScopeHostInfo

    init(hostInfo: ViewScopeHostInfo) {
        self.hostInfo = hostInfo
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
            let contentFrame = window.contentView?.frame ?? .zero
            nodes[windowID] = ViewScopeHierarchyNode(
                id: windowID,
                parentID: nil,
                kind: .window,
                className: NSStringFromClass(type(of: window)),
                title: window.title.isEmpty ? "Untitled Window" : window.title,
                subtitle: "#\(window.windowNumber)",
                frame: contentFrame.viewScopeRect,
                bounds: contentFrame.viewScopeRect,
                childIDs: [],
                isHidden: !window.isVisible,
                alphaValue: Double(window.alphaValue),
                wantsLayer: true,
                isFlipped: false,
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
                ancestry: [window.title.isEmpty ? "Window" : window.title],
                screenshotPNGBase64: image.flatMap(ViewScopeImageEncoder().base64PNG),
                screenshotSize: image?.size.viewScopeSize ?? .zero,
                highlightedRect: window.contentView?.bounds.viewScopeRect ?? .zero
            )
        case .view(let view):
            let rootView = view.window?.contentView
            let image = rootView.flatMap(makeViewScreenshot)
            let highlightRect = rootView.map { root in
                view.convert(view.bounds, to: root).viewScopeRect
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
            nodes[nodeID] = ViewScopeHierarchyNode(
                id: nodeID,
                parentID: parentID,
                kind: .view,
                className: NSStringFromClass(type(of: child)),
                title: child.viewScopeTitle,
                subtitle: child.viewScopeSubtitle,
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

    private func windowSections(for window: NSWindow) -> [ViewScopePropertySection] {
        [
            ViewScopePropertySection(
                title: "Identity",
                items: [
                    ViewScopePropertyItem(title: "Class", value: NSStringFromClass(type(of: window))),
                    ViewScopePropertyItem(title: "Title", value: window.title),
                    ViewScopePropertyItem(title: "Window Number", value: String(window.windowNumber)),
                    ViewScopePropertyItem(title: "Address", value: window.viewScopeAddress)
                ]
            ),
            ViewScopePropertySection(
                title: "State",
                items: [
                    ViewScopePropertyItem(title: "Visible", value: window.isVisible.viewScopeBoolText),
                    ViewScopePropertyItem(title: "Key", value: window.isKeyWindow.viewScopeBoolText),
                    ViewScopePropertyItem(title: "Main", value: window.isMainWindow.viewScopeBoolText),
                    ViewScopePropertyItem(title: "Level", value: String(window.level.rawValue))
                ]
            ),
            ViewScopePropertySection(
                title: "Geometry",
                items: [
                    ViewScopePropertyItem(title: "Frame", value: window.frame.viewScopeString),
                    ViewScopePropertyItem(title: "Content Layout", value: window.contentLayoutRect.viewScopeString)
                ]
            )
        ]
    }

    private func viewSections(for view: NSView) -> [ViewScopePropertySection] {
        var identityItems = [
            ViewScopePropertyItem(title: "Class", value: NSStringFromClass(type(of: view))),
            ViewScopePropertyItem(title: "Address", value: view.viewScopeAddress)
        ]
        if let identifier = view.identifier?.rawValue, !identifier.isEmpty {
            identityItems.append(ViewScopePropertyItem(title: "Identifier", value: identifier))
        }
        if let tooltip = view.toolTip, !tooltip.isEmpty {
            identityItems.append(ViewScopePropertyItem(title: "Tool Tip", value: tooltip))
        }

        let layoutItems = [
            ViewScopePropertyItem(title: "Frame", value: view.frame.viewScopeString),
            ViewScopePropertyItem(title: "Bounds", value: view.bounds.viewScopeString),
            ViewScopePropertyItem(title: "Intrinsic Size", value: view.intrinsicContentSize.viewScopeString),
            ViewScopePropertyItem(title: "Translates Mask", value: view.translatesAutoresizingMaskIntoConstraints.viewScopeBoolText),
            ViewScopePropertyItem(
                title: "Hugging H",
                value: String(format: "%.1f", view.contentHuggingPriority(for: .horizontal).rawValue)
            ),
            ViewScopePropertyItem(
                title: "Hugging V",
                value: String(format: "%.1f", view.contentHuggingPriority(for: .vertical).rawValue)
            ),
            ViewScopePropertyItem(
                title: "Compression H",
                value: String(format: "%.1f", view.contentCompressionResistancePriority(for: .horizontal).rawValue)
            ),
            ViewScopePropertyItem(
                title: "Compression V",
                value: String(format: "%.1f", view.contentCompressionResistancePriority(for: .vertical).rawValue)
            )
        ]

        var renderingItems = [
            ViewScopePropertyItem(title: "Hidden", value: view.isHidden.viewScopeBoolText),
            ViewScopePropertyItem(title: "Alpha", value: String(format: "%.2f", view.alphaValue)),
            ViewScopePropertyItem(title: "Layer Backed", value: view.wantsLayer.viewScopeBoolText),
            ViewScopePropertyItem(title: "Flipped", value: view.isFlipped.viewScopeBoolText),
            ViewScopePropertyItem(title: "Subviews", value: String(view.subviews.count))
        ]
        if let background = view.layer?.backgroundColor?.viewScopeDescription {
            renderingItems.append(ViewScopePropertyItem(title: "Background", value: background))
        }

        var sections = [
            ViewScopePropertySection(title: "Identity", items: identityItems),
            ViewScopePropertySection(title: "Layout", items: layoutItems),
            ViewScopePropertySection(title: "Rendering", items: renderingItems)
        ]

        if let control = view as? NSControl {
            sections.append(
                ViewScopePropertySection(
                    title: "Control",
                    items: [
                        ViewScopePropertyItem(title: "Enabled", value: control.isEnabled.viewScopeBoolText),
                        ViewScopePropertyItem(title: "Value", value: control.viewScopeControlValue)
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
            chain.append(current.viewScopeTitle)
            cursor = current.superview
        }
        if let title = view.window?.title, !title.isEmpty {
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
            let multiplier = String(format: "%.2f", constraint.multiplier)
            let constant = String(format: "%.2f", constraint.constant)
            return "\(first).\(constraint.firstAttribute.rawValue) \(relation) \(second).\(constraint.secondAttribute.rawValue) * \(multiplier) + \(constant)"
        }

        return descriptions.isEmpty ? ["No active constraints on the selected node."] : descriptions
    }
}

enum ViewScopeInspectableReference {
    case window(NSWindow)
    case view(NSView)
}

private extension NSView {
    var viewScopeTitle: String {
        if let tabView = self as? NSTabView,
           let selectedItem = tabView.selectedTabViewItem,
           !selectedItem.label.isEmpty {
            return selectedItem.label
        }
        if let outlineView = self as? NSOutlineView {
            return identifier?.rawValue ?? "OutlineView"
        }
        if let tableView = self as? NSTableView {
            return identifier?.rawValue ?? "TableView"
        }
        if let rowView = self as? NSTableRowView,
           let tableView = rowView.viewScopeEnclosingTableView {
            let row = tableView.row(for: rowView)
            if row >= 0 {
                return "Row \(row)"
            }
        }
        if let cellView = self as? NSTableCellView,
           let text = cellView.textField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let button = self as? NSButton, !button.title.isEmpty {
            return button.title
        }
        if let textField = self as? NSTextField, !textField.stringValue.isEmpty {
            return textField.stringValue
        }
        if let segmented = self as? NSSegmentedControl, segmented.segmentCount > 0 {
            return segmented.label(forSegment: max(segmented.selectedSegment, 0)) ?? NSStringFromClass(type(of: self))
        }
        if let identifier = identifier?.rawValue, !identifier.isEmpty {
            return identifier
        }
        return NSStringFromClass(type(of: self)).components(separatedBy: ".").last ?? NSStringFromClass(type(of: self))
    }

    var viewScopeSubtitle: String? {
        if let outlineView = self as? NSOutlineView {
            return "\(outlineView.numberOfRows) visible rows"
        }
        if let tableView = self as? NSTableView {
            return "\(tableView.numberOfRows) rows • \(tableView.numberOfColumns) cols"
        }
        if let tabView = self as? NSTabView {
            return "\(tabView.numberOfTabViewItems) tabs"
        }
        if let imageView = self as? NSImageView, imageView.image != nil {
            return "Image"
        }
        if let stack = self as? NSStackView {
            return "\(stack.arrangedSubviews.count) arranged"
        }
        if let scroll = self as? NSScrollView, scroll.hasVerticalScroller || scroll.hasHorizontalScroller {
            return "Scrollable"
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

    var viewScopeString: String {
        let noIntrinsicMetric = CGFloat(-1)
        if width == noIntrinsicMetric || height == noIntrinsicMetric {
            return "No intrinsic size"
        }
        return String(format: "w %.1f h %.1f", width, height)
    }
}

private extension Bool {
    var viewScopeBoolText: String {
        self ? "Yes" : "No"
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
