import AppKit
import Foundation
import ObjectiveC.runtime

enum ViewScopeRuntimeIvarReader {
    static func storedObjectPointer(in object: AnyObject, ivarNamed name: String) -> UnsafeRawPointer? {
        var currentClass: AnyClass? = type(of: object)

        while let targetClass = currentClass {
            if let ivar = class_getInstanceVariable(targetClass, name) {
                return storedObjectPointer(in: object, ivar: ivar)
            }
            currentClass = class_getSuperclass(targetClass)
        }

        return nil
    }

    static func storedObjectPointer(in object: AnyObject, ivar: Ivar) -> UnsafeRawPointer? {
        guard mayStoreObjectReference(ivar) else {
            return nil
        }

        let basePointer = UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
        let slotPointer = basePointer
            .advanced(by: ivar_getOffset(ivar))
            .assumingMemoryBound(to: Optional<UnsafeRawPointer>.self)
        return slotPointer.pointee
    }

    static func mayStoreObjectReference(_ ivar: Ivar) -> Bool {
        guard let encodingPointer = ivar_getTypeEncoding(ivar) else {
            return true
        }

        let encoding = String(cString: encodingPointer)
        return encoding.isEmpty || encoding.hasPrefix("@")
    }
}

enum ViewScopeCompositeCapturePolicy {
    /// 只有少数系统特效视图在 `cacheDisplay` 时会丢失/错误合成后代内容，
    /// 才需要走“基底截图 + 子视图递归叠绘”的 composite 路径。
    ///
    /// 这里故意不用 `"SplitView" / "Wrapper"` 这类字符串关键字：
    /// 自定义类名非常容易误命中，反而会把普通视图错误送进 composite，
    /// 导致父层底图与子层再次叠绘，最终出现重影或翻转。
    @MainActor
    static func prefersDescendantCompositeCapture(for view: NSView) -> Bool {
        guard view.subviews.isEmpty == false else {
            return false
        }

        if view is NSVisualEffectView {
            return true
        }
        if #available(macOS 26.0, *), view is NSGlassEffectView {
            return true
        }
        return false
    }
}

@MainActor
/// 抓取端总入口：负责把宿主 AppKit 视图树转换成 ViewScope 可传输的数据模型。
///
/// 预览相关的关键职责有三件：
/// 1. 产出 capture：节点树、frame、bounds、isFlipped 等基础几何信息。
/// 2. 产出 detail：截图、高亮 rect、属性面板内容。
/// 3. 维持统一的“左上角原点”画布语义，给客户端 2D / 3D 共用。
final class ViewScopeSnapshotBuilder {
    struct ReferenceContext {
        var nodeReferences: [String: ViewScopeInspectableReference]
        var rootNodeIDs: [String]
        var captureID: String
    }

    private let hostInfo: ViewScopeHostInfo
    private let interfaceLanguage: ViewScopeInterfaceLanguage

    init(hostInfo: ViewScopeHostInfo, interfaceLanguage: ViewScopeInterfaceLanguage = .english) {
        self.hostInfo = hostInfo
        self.interfaceLanguage = interfaceLanguage
    }

    /// 抓取当前应用所有窗口，构造完整 capture。
    ///
    /// 这里写入到 `node.frame` 的值，优先就是客户端可直接消费的统一画布坐标。
    func makeCapture() -> (ViewScopeCapturePayload, ReferenceContext) {
        let start = Date()
        let captureID = UUID().uuidString
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
                let contentViewNodeID = "\(windowID)-view-root"
                let title = sanitizedDisplayText(contentView.viewScopeTitle(interfaceLanguage: interfaceLanguage))
                    ?? ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: contentView)))
                nodes[contentViewNodeID] = ViewScopeHierarchyNode(
                    id: contentViewNodeID,
                    parentID: windowID,
                    kind: .view,
                    className: NSStringFromClass(type(of: contentView)),
                    title: title,
                    subtitle: sanitizedDisplayText(contentView.viewScopeSubtitle(interfaceLanguage: interfaceLanguage)),
                    identifier: sanitizedDisplayText(contentView.identifier?.rawValue),
                    address: contentView.viewScopeAddress,
                    frame: contentBounds.viewScopeRect,
                    bounds: contentView.bounds.viewScopeRect,
                    childIDs: [],
                    isHidden: contentView.isHidden,
                    alphaValue: Double(contentView.alphaValue),
                    wantsLayer: contentView.wantsLayer,
                    isFlipped: contentView.isFlipped,
                    clippingEnabled: contentView.layer?.masksToBounds ?? false,
                    depth: 1,
                    ivarName: nil,
                    ivarTraces: [],
                    rootViewControllerClassName: contentView.viewScopeExactRootViewControllerClassName,
                    controlTargetClassName: nil,
                    controlActionName: nil,
                    eventHandlers: contentView.viewScopeEventHandlers(interfaceLanguage: interfaceLanguage).nonEmpty
                )
                references[contentViewNodeID] = .view(contentView)

                let childIDs = buildNodes(
                    from: contentView,
                    rootView: contentView,
                    parentID: contentViewNodeID,
                    prefix: "\(windowID)-view",
                    depth: 2,
                    nodes: &nodes,
                    references: &references
                )
                nodes[contentViewNodeID]?.childIDs = childIDs
                nodes[windowID]?.childIDs = [contentViewNodeID]
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
                nodes: nodes,
                captureID: captureID,
                previewBitmaps: []
            ),
            ReferenceContext(nodeReferences: references, rootNodeIDs: rootNodeIDs, captureID: captureID)
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
                screenshotRootNodeID: nodeID,
                screenshotPNGBase64: image.flatMap(ViewScopeImageEncoder().base64PNG),
                screenshotSize: image?.size.viewScopeSize ?? .zero,
                highlightedRect: window.contentView?.bounds.viewScopeRect ?? .zero,
                consoleTargets: makeConsoleTargets(for: .window(window), nodeID: nodeID, context: context)
            )
        case .view(let view):
            let screenshotRootView = screenshotRootView(for: view)
            let image = screenshotRootView.flatMap { root in
                makeViewScreenshot(view: root)
            }
            let highlightRect = screenshotRootView.map { root in
                normalizedCanvasRect(for: view, in: root).viewScopeRect
            } ?? .zero
            return ViewScopeNodeDetailPayload(
                nodeID: nodeID,
                host: hostInfo,
                sections: viewSections(for: view),
                constraints: constraintDescriptions(for: view),
                ancestry: ancestry(for: view),
                screenshotRootNodeID: screenshotRootView.flatMap { screenshotRootNodeID(for: $0, in: context) },
                screenshotPNGBase64: image.flatMap(ViewScopeImageEncoder().base64PNG),
                screenshotSize: image?.size.viewScopeSize ?? .zero,
                highlightedRect: highlightRect,
                consoleTargets: makeConsoleTargets(for: .view(view), nodeID: nodeID, context: context)
            )
        case .viewController(let controller):
            return ViewScopeNodeDetailPayload(
                nodeID: nodeID,
                host: hostInfo,
                sections: [
                    ViewScopePropertySection(
                        title: text("server.section.identity"),
                        items: [
                            ViewScopePropertyItem(
                                title: text("server.item.class"),
                                value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: controller)))
                            )
                        ]
                    )
                ],
                constraints: [],
                ancestry: [],
                screenshotRootNodeID: nil,
                screenshotPNGBase64: nil,
                screenshotSize: .zero,
                highlightedRect: .zero,
                consoleTargets: makeConsoleTargets(for: .viewController(controller), nodeID: nodeID, context: context)
            )
        case .object(let object):
            return ViewScopeNodeDetailPayload(
                nodeID: nodeID,
                host: hostInfo,
                sections: [
                    ViewScopePropertySection(
                        title: text("server.section.identity"),
                        items: [
                            ViewScopePropertyItem(
                                title: text("server.item.class"),
                                value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: object)))
                            )
                        ]
                    )
                ],
                constraints: [],
                ancestry: [],
                screenshotRootNodeID: nil,
                screenshotPNGBase64: nil,
                screenshotSize: .zero,
                highlightedRect: .zero,
                consoleTargets: makeConsoleTargets(for: .object(object), nodeID: nodeID, context: context)
            )
        }
    }

    private func buildNodes(
        from view: NSView,
        rootView: NSView,
        parentID: String,
        prefix: String,
        depth: Int,
        nodes: inout [String: ViewScopeHierarchyNode],
        references: inout [String: ViewScopeInspectableReference]
    ) -> [String] {
        // 递归构建子树时，child.frame 会立即被归一成相对 rootView 的统一画布坐标。
        var childIDs: [String] = []
        let ivarTracesBySubview = directSubviewIvarTraces(in: view)

        for (index, child) in capturedChildViews(of: view).enumerated() {
            let nodeID = "\(prefix)-\(index)"
            let title = sanitizedDisplayText(child.viewScopeTitle(interfaceLanguage: interfaceLanguage))
                ?? ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: child)))
            let ivarTraces = ivarTracesBySubview[ObjectIdentifier(child)] ?? []
            let childFrame = normalizedCanvasRect(for: child, in: rootView)
            nodes[nodeID] = ViewScopeHierarchyNode(
                id: nodeID,
                parentID: parentID,
                kind: .view,
                className: NSStringFromClass(type(of: child)),
                title: title,
                subtitle: sanitizedDisplayText(child.viewScopeSubtitle(interfaceLanguage: interfaceLanguage)),
                identifier: sanitizedDisplayText(child.identifier?.rawValue),
                address: child.viewScopeAddress,
                frame: childFrame.viewScopeRect,
                bounds: child.bounds.viewScopeRect,
                childIDs: [],
                isHidden: child.isHidden,
                alphaValue: Double(child.alphaValue),
                wantsLayer: child.wantsLayer,
                isFlipped: child.isFlipped,
                clippingEnabled: child.layer?.masksToBounds ?? false,
                depth: depth,
                ivarName: ivarTraces.first?.ivarName,
                ivarTraces: ivarTraces,
                rootViewControllerClassName: child.viewScopeExactRootViewControllerClassName,
                controlTargetClassName: (child as? NSControl)?.viewScopeTargetClassName,
                controlActionName: (child as? NSControl)?.viewScopeActionName,
                eventHandlers: child.viewScopeEventHandlers(interfaceLanguage: interfaceLanguage).nonEmpty
            )
            references[nodeID] = .view(child)
            let nestedIDs = buildNodes(
                from: child,
                rootView: rootView,
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

    private func capturedChildViews(of view: NSView) -> [NSView] {
        // `buildNodes` 本身是递归的；
        // 这里做的是“补齐当前节点的一层直接孩子”。
        //
        // AppKit 有一些容器会把逻辑子节点藏在普通 `subviews` 之外，
        // 或者由复用/虚拟化机制托管，因此这里只补充那些 `subviews` 不稳定覆盖的系统容器：
        // - `NSTableView` 当前可见 row/header
        //
        // 真正的整棵树递归仍由 `buildNodes(from:)` 完成。
        var orderedChildren: [NSView] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ child: NSView?) {
            guard let child else { return }
            let identifier = ObjectIdentifier(child)
            guard seen.insert(identifier).inserted else { return }
            orderedChildren.append(child)
        }

        view.subviews.forEach(append)

        if let tableView = view as? NSTableView {
            append(tableView.headerView)

            let visibleRows = tableView.rows(in: tableView.visibleRect)
            if visibleRows.length > 0 {
                for row in visibleRows.location ..< NSMaxRange(visibleRows) {
                    append(tableView.rowView(atRow: row, makeIfNecessary: false))
                }
            }
        }

        return orderedChildren
    }

    private func directSubviewIvarTraces(in hostView: NSView) -> [ObjectIdentifier: [ViewScopeIvarTrace]] {
        var tracesBySubview: [ObjectIdentifier: Set<ViewScopeIvarTrace>] = [:]
        let subviewsByAddress = Dictionary(uniqueKeysWithValues: hostView.subviews.map { subview in
            (UInt(bitPattern: Unmanaged.passUnretained(subview).toOpaque()), subview)
        })
        var currentClass: AnyClass? = type(of: hostView)

        while let targetClass = currentClass,
              targetClass != NSView.self,
              targetClass != NSResponder.self,
              targetClass != NSObject.self {
            var count: UInt32 = 0
            guard let ivars = class_copyIvarList(targetClass, &count) else {
                currentClass = class_getSuperclass(targetClass)
                continue
            }

            defer { free(ivars) }

            for index in 0 ..< Int(count) {
                let ivar = ivars[index]
                guard let rawObjectPointer = ViewScopeRuntimeIvarReader.storedObjectPointer(in: hostView, ivar: ivar),
                      let subview = subviewsByAddress[UInt(bitPattern: rawObjectPointer)],
                      let namePointer = ivar_getName(ivar) else {
                    continue
                }

                let trace = ViewScopeIvarTrace(
                    relation: "superview",
                    hostClassName: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(targetClass)),
                    ivarName: String(cString: namePointer)
                )
                tracesBySubview[ObjectIdentifier(subview), default: []].insert(trace)
            }

            currentClass = class_getSuperclass(targetClass)
        }

        return tracesBySubview.mapValues { traces in
            traces.sorted {
                if $0.hostClassName == $1.hostClassName {
                    return $0.ivarName < $1.ivarName
                }
                return $0.hostClassName < $1.hostClassName
            }
        }
    }

    private func screenshotRootView(for view: NSView) -> NSView? {
        if let contentView = view.window?.contentView,
           contentView.bounds.width > 0,
           contentView.bounds.height > 0 {
            return contentView
        }

        var current: NSView = view
        while let parent = current.superview {
            current = parent
        }
        return current.bounds.width > 0 && current.bounds.height > 0 ? current : nil
    }

    private func screenshotRootNodeID(for view: NSView, in context: ReferenceContext) -> String? {
        context.nodeReferences.first { _, reference in
            guard case .view(let capturedView) = reference else { return false }
            return capturedView === view
        }?.key
    }

    private func makeViewScreenshot(
        view: NSView,
        inheritsCompositeCapture: Bool = false
    ) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }

        let prefersCompositeCapture = ViewScopeCompositeCapturePolicy.prefersDescendantCompositeCapture(for: view) ||
            (inheritsCompositeCapture && view.subviews.isEmpty == false)
        if prefersCompositeCapture {
            return makeCompositeScreenshot(
                view: view,
                inheritsCompositeCapture: prefersCompositeCapture
            )
        }

        guard let image = makeDirectViewScreenshot(view: view) else {
            return nil
        }
        return normalizedScreenshot(image, for: view)
    }

    private func makeDirectViewScreenshot(view: NSView) -> NSImage? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makeCompositeScreenshot(
        view: NSView,
        inheritsCompositeCapture: Bool
    ) -> NSImage? {
        // composite 路径会先铺一层当前 view 的直接截图，再把后代节点逐个叠回去；
        // 因此它只能用于“直接截图缺后代内容”的少数系统特效视图。
        // 如果把普通容器误送进来，就会出现父层底图和子层重复绘制。
        let image = NSImage(size: view.bounds.size)
        image.lockFocusFlipped(true)
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: view.bounds.size).fill()

        if !shouldSkipDirectCompositeBase(for: view, inheritsCompositeCapture: inheritsCompositeCapture),
           let baseImage = makeDirectViewScreenshot(view: view) {
            normalizedScreenshot(baseImage, for: view).draw(
                in: CGRect(origin: .zero, size: view.bounds.size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }

        for child in capturedChildViews(of: view) where child.isHidden == false {
            guard let childImage = makeViewScreenshot(
                view: child,
                inheritsCompositeCapture: inheritsCompositeCapture
            ) else {
                continue
            }
            let childRect = normalizedCanvasRect(for: child, in: view)
            childImage.draw(
                in: childRect,
                from: .zero,
                operation: .sourceOver,
                fraction: CGFloat(child.alphaValue),
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }

        image.unlockFocus()
        return image
    }

    private func shouldSkipDirectCompositeBase(
        for view: NSView,
        inheritsCompositeCapture: Bool
    ) -> Bool {
        if inheritsCompositeCapture,
           type(of: view) == NSView.self,
           view.wantsLayer == false,
           view.layer == nil {
            return true
        }
        return false
    }

    private func makeWindowScreenshot(window: NSWindow) -> NSImage? {
        guard let contentView = window.contentView else {
            return nil
        }
        return makeViewScreenshot(view: contentView)
    }

    private func normalizedScreenshot(_ image: NSImage, for view: NSView) -> NSImage {
        // 当前观察到 `cacheDisplay` 产出的截图已经与统一画布坐标保持一致，
        // 因此这里不再额外做垂直翻转，避免客户端再出现重复翻转。
        _ = view
        return image
    }

    private func normalizedCanvasRect(for view: NSView, in rootView: NSView) -> NSRect {
        // 把 AppKit 的实际 view 坐标统一成“左上角原点”的画布坐标：
        // - 如果截图根本身就是 flipped，`convert(_:to:)` 的结果可直接使用
        // - 如果截图根不是 flipped，则在这里翻一次 y
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

    private func editableColorItem(title: String, key: String, value: String) -> ViewScopePropertyItem {
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
                    ViewScopePropertyItem(title: text("server.item.class"), value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: window)))),
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
            ViewScopePropertyItem(title: text("server.item.class"), value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: view)))),
            ViewScopePropertyItem(title: text("server.item.address"), value: view.viewScopeAddress)
        ]
        if let title = sanitizedDisplayText(view.viewScopeTitle(interfaceLanguage: interfaceLanguage)) {
            identityItems.append(ViewScopePropertyItem(title: text("server.item.title"), value: title))
        }
        if let identifier = view.identifier?.rawValue, !identifier.isEmpty {
            identityItems.append(ViewScopePropertyItem(title: text("server.item.identifier"), value: identifier))
        }
        if let rootViewControllerClassName = view.viewScopeExactRootViewControllerClassName {
            identityItems.append(
                ViewScopePropertyItem(
                    title: text("server.item.view_controller"),
                    value: ViewScopeClassNameFormatter.displayName(for: rootViewControllerClassName)
                )
            )
        }
        identityItems.append(
            editableTextItem(
                title: text("server.item.tooltip"),
                key: "toolTip",
                value: view.toolTip ?? ""
            )
        )

        let layoutItems = [
            ViewScopePropertyItem(title: text("server.item.frame"), value: view.frame.viewScopeString),
            editableNumberItem(title: text("server.item.x"), key: "frame.x", value: Double(view.frame.origin.x), decimals: 1),
            editableNumberItem(title: text("server.item.y"), key: "frame.y", value: Double(view.frame.origin.y), decimals: 1),
            editableNumberItem(title: text("server.item.width"), key: "frame.width", value: Double(view.frame.width), decimals: 1),
            editableNumberItem(title: text("server.item.height"), key: "frame.height", value: Double(view.frame.height), decimals: 1),
            ViewScopePropertyItem(title: text("server.item.bounds"), value: view.bounds.viewScopeString),
            editableNumberItem(title: text("server.item.bounds_x"), key: "bounds.x", value: Double(view.bounds.origin.x), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_y"), key: "bounds.y", value: Double(view.bounds.origin.y), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_width"), key: "bounds.width", value: Double(view.bounds.width), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_height"), key: "bounds.height", value: Double(view.bounds.height), decimals: 1),
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
        if let background = view.layer?.backgroundColor?.viewScopeHexString {
            renderingItems.append(editableColorItem(title: text("server.item.background"), key: "backgroundColor", value: background))
        }
        if view.layer != nil || view.wantsLayer {
            let cornerRadius = Double(view.layer?.cornerRadius ?? 0)
            let borderWidth = Double(view.layer?.borderWidth ?? 0)
            renderingItems.append(
                editableNumberItem(
                    title: text("server.item.corner_radius"),
                    key: "layer.cornerRadius",
                    value: cornerRadius,
                    decimals: 1
                )
            )
            renderingItems.append(
                editableNumberItem(
                    title: text("server.item.border_width"),
                    key: "layer.borderWidth",
                    value: borderWidth,
                    decimals: 1
                )
            )
        }

        var sections = [
            ViewScopePropertySection(title: text("server.section.identity"), items: identityItems),
            ViewScopePropertySection(title: text("server.section.layout"), items: layoutItems),
            ViewScopePropertySection(title: text("server.section.rendering"), items: renderingItems)
        ]

        if let scrollView = view as? NSScrollView {
            let insets = scrollView.contentInsets
            sections.append(
                ViewScopePropertySection(
                    title: text("server.section.geometry"),
                    items: [
                        ViewScopePropertyItem(title: text("server.item.content_insets"), value: insets.viewScopeString),
                        editableNumberItem(title: text("server.item.inset_top"), key: "contentInsets.top", value: Double(insets.top), decimals: 1),
                        editableNumberItem(title: text("server.item.inset_left"), key: "contentInsets.left", value: Double(insets.left), decimals: 1),
                        editableNumberItem(title: text("server.item.inset_bottom"), key: "contentInsets.bottom", value: Double(insets.bottom), decimals: 1),
                        editableNumberItem(title: text("server.item.inset_right"), key: "contentInsets.right", value: Double(insets.right), decimals: 1)
                    ]
                )
            )
        }

        if let control = view as? NSControl {
            let editableControlValue: ViewScopeEditableProperty = {
                if control is NSButton || control is NSTextField || control is NSSegmentedControl {
                    return .text(key: "control.value", value: control.viewScopeControlValue)
                }
                return .text(key: "control.value", value: control.stringValue)
            }()
            var controlItems: [ViewScopePropertyItem] = [
                editableToggleItem(title: text("server.item.enabled"), key: "enabled", value: control.isEnabled),
                ViewScopePropertyItem(title: text("server.item.value"), value: control.viewScopeControlValue, editable: editableControlValue)
            ]

            if let button = control as? NSButton, button.allowsMixedState == false {
                controlItems.append(
                    editableToggleItem(
                        title: text("server.item.button_state"),
                        key: "button.state",
                        value: button.state == .on
                    )
                )
            }

            if let textField = control as? NSTextField {
                controlItems.append(
                    editableTextItem(
                        title: text("server.item.placeholder"),
                        key: "textField.placeholderString",
                        value: textField.placeholderString ?? ""
                    )
                )
            }

            if let targetClassName = control.viewScopeTargetClassName {
                controlItems.append(
                    ViewScopePropertyItem(
                        title: text("server.item.target"),
                        value: ViewScopeClassNameFormatter.displayName(for: targetClassName)
                    )
                )
            } else if control.viewScopeActionName != nil {
                controlItems.append(
                    ViewScopePropertyItem(
                        title: text("server.item.target"),
                        value: text("server.value.first_responder")
                    )
                )
            }

            if let actionName = control.viewScopeActionName {
                controlItems.append(
                    ViewScopePropertyItem(
                        title: text("server.item.action"),
                        value: actionName
                    )
                )
            }

            sections.append(
                ViewScopePropertySection(
                    title: text("server.section.control"),
                    items: controlItems
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
            let first = formattedConstraintItem(
                constraint.firstItem as? NSObject,
                attribute: constraint.firstAttribute
            )
            let relation = constraint.relation.viewScopeSymbol
            let constant = String(format: "%.2f", locale: interfaceLanguage.locale, constraint.constant)
            guard constraint.secondAttribute != .notAnAttribute,
                  let secondItem = constraint.secondItem as? NSObject else {
                return "\(first) \(relation) \(constant)"
            }

            let second = formattedConstraintItem(secondItem, attribute: constraint.secondAttribute)
            let multiplier = String(format: "%.2f", locale: interfaceLanguage.locale, constraint.multiplier)
            return "\(first) \(relation) \(second) * \(multiplier) + \(constant)"
        }

        return descriptions.isEmpty ? [text("server.value.no_active_constraints")] : descriptions
    }

    private func formattedConstraintItem(_ item: NSObject?, attribute: NSLayoutConstraint.Attribute) -> String {
        let className = item.map { ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: $0))) } ?? "nil"
        let attributeName = attribute.viewScopeName
        return "\(className).\(attributeName)"
    }

    private func makeConsoleTargets(
        for reference: ViewScopeInspectableReference,
        nodeID: String,
        context: ReferenceContext
    ) -> [ViewScopeConsoleTargetDescriptor] {
        switch reference {
        case .window(let window):
            return [
                makeConsoleTargetDescriptor(
                    reference: .window(window),
                    sourceNodeID: nodeID,
                    captureID: context.captureID,
                    subtitle: interfaceLanguage.text("server.value.window_fallback")
                )
            ].compactMap { $0 }
        case .view(let view):
            var targets: [ViewScopeConsoleTargetDescriptor] = []
            if let descriptor = makeConsoleTargetDescriptor(
                reference: .view(view),
                sourceNodeID: nodeID,
                captureID: context.captureID,
                subtitle: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: view)))
            ) {
                targets.append(descriptor)
            }
            if let controller = view.viewScopeExactRootOwningViewController,
               let descriptor = makeConsoleTargetDescriptor(
                reference: .viewController(controller),
                sourceNodeID: nodeID,
                captureID: context.captureID,
                subtitle: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: controller)))
               ) {
                targets.append(descriptor)
            }
            return targets
        case .viewController(let controller):
            return [
                makeConsoleTargetDescriptor(
                    reference: .viewController(controller),
                    sourceNodeID: nodeID,
                    captureID: context.captureID,
                    subtitle: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: controller)))
                )
            ].compactMap { $0 }
        case .object:
            return []
        }
    }

    private func makeConsoleTargetDescriptor(
        reference: ViewScopeInspectableReference,
        sourceNodeID: String?,
        captureID: String,
        subtitle: String?
    ) -> ViewScopeConsoleTargetDescriptor? {
        let object: AnyObject
        let kind: ViewScopeRemoteObjectReference.Kind
        switch reference {
        case .window(let window):
            object = window
            kind = .window
        case .view(let view):
            object = view
            kind = .view
        case .viewController(let controller):
            object = controller
            kind = .viewController
        case .object(let anyObject):
            object = anyObject
            kind = .returnedObject
        }
        let className = NSStringFromClass(type(of: object))
        let address = String(describing: Unmanaged.passUnretained(object).toOpaque())
        let referencePayload = ViewScopeRemoteObjectReference(
            captureID: captureID,
            objectID: address,
            kind: kind,
            className: className,
            address: address,
            sourceNodeID: sourceNodeID
        )
        let title = "<\(ViewScopeClassNameFormatter.displayName(for: className)): \(address)>"
        return ViewScopeConsoleTargetDescriptor(reference: referencePayload, title: title, subtitle: subtitle)
    }
}

enum ViewScopeInspectableReference {
    case window(NSWindow)
    case view(NSView)
    case viewController(NSViewController)
    case object(AnyObject)
}

private extension NSView {
    var viewScopeOwningViewController: NSViewController? {
        guard let windowController = window?.contentViewController else {
            return nil
        }
        return windowController.viewScopeOwningController(containing: self)
    }

    var viewScopeExactRootViewControllerClassName: String? {
        viewScopeExactRootOwningViewController.map { NSStringFromClass(type(of: $0)) }
    }

    var viewScopeExactRootOwningViewController: NSViewController? {
        if let windowController = window?.contentViewController,
           let controller = windowController.viewScopeOwningController(containing: self),
           controller.view === self {
            return controller
        }
        return nil
    }

    func viewScopeEventHandlers(interfaceLanguage: ViewScopeInterfaceLanguage) -> [ViewScopeEventHandler] {
        var handlers: [ViewScopeEventHandler] = []

        if let controlHandler = (self as? NSControl)?.viewScopeControlEventHandler(interfaceLanguage: interfaceLanguage) {
            handlers.append(controlHandler)
        }

        handlers.append(contentsOf: gestureRecognizers.map {
            $0.viewScopeEventHandler(interfaceLanguage: interfaceLanguage)
        })

        return handlers
    }

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
                ?? ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: self)))
        }
        if let identifier = identifier?.rawValue, !identifier.isEmpty {
            return identifier.viewScopeSanitizedSingleLine
        }
        return ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: self)))
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

private extension NSViewController {
    func viewScopeOwningController(containing view: NSView) -> NSViewController? {
        guard isViewLoaded else {
            return nil
        }

        for child in children {
            if let controller = child.viewScopeOwningController(containing: view) {
                return controller
            }
        }

        if self.view === view || view.isDescendant(of: self.view) {
            return self
        }

        return nil
    }
}

private extension NSLayoutConstraint.Attribute {
    var viewScopeName: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        case .leading: return "leading"
        case .trailing: return "trailing"
        case .width: return "width"
        case .height: return "height"
        case .centerX: return "centerX"
        case .centerY: return "centerY"
        case .lastBaseline: return "lastBaseline"
        case .firstBaseline: return "firstBaseline"
        case .notAnAttribute: return "notAnAttribute"
        @unknown default: return String(rawValue)
        }
    }
}

private extension NSWindow {
    var viewScopeAddress: String {
        String(describing: Unmanaged.passUnretained(self).toOpaque())
    }
}

private extension NSControl {
    var viewScopeTargetClassName: String? {
        guard let target else { return nil }
        return NSStringFromClass(type(of: target))
    }

    var viewScopeActionName: String? {
        guard let action else { return nil }
        return NSStringFromSelector(action)
    }

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

    func viewScopeControlEventHandler(interfaceLanguage: ViewScopeInterfaceLanguage) -> ViewScopeEventHandler? {
        let targetAction = ViewScopeEventTargetAction(
            targetClassName: viewScopeTargetClassName,
            actionName: viewScopeActionName
        )
        guard targetAction.targetClassName != nil || targetAction.actionName != nil else {
            return nil
        }

        return ViewScopeEventHandler(
            kind: .controlAction,
            title: targetAction.actionName ?? interfaceLanguage.text("server.item.action"),
            targetActions: [targetAction]
        )
    }
}

private extension NSGestureRecognizer {
    func viewScopeEventHandler(interfaceLanguage _: ViewScopeInterfaceLanguage) -> ViewScopeEventHandler {
        let title = ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: self)))
        let targetAction = ViewScopeEventTargetAction(
            targetClassName: target.map { NSStringFromClass(type(of: $0)) },
            actionName: action.map(NSStringFromSelector)
        )
        let delegateClassName = delegate.map { NSStringFromClass(type(of: $0 as AnyObject)) }

        return ViewScopeEventHandler(
            kind: .gesture,
            title: title,
            targetActions: (targetAction.targetClassName != nil || targetAction.actionName != nil) ? [targetAction] : [],
            isEnabled: isEnabled,
            delegateClassName: delegateClassName
        )
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
    var viewScopeHexString: String? {
        guard let color = NSColor(cgColor: self)?.usingColorSpace(.deviceRGB) else {
            return nil
        }
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        let alpha = Int(round(color.alphaComponent * 255))
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }
}

private extension NSEdgeInsets {
    var viewScopeString: String {
        String(format: "t %.1f l %.1f b %.1f r %.1f", top, left, bottom, right)
    }
}

private extension String {
    var viewScopeSanitizedSingleLine: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private extension Array {
    var nonEmpty: Self? {
        isEmpty ? nil : self
    }
}
