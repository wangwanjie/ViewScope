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

        ViewScopeTraceManager.reload(windows: windows)

        var nodes: [String: ViewScopeHierarchyNode] = [:]
        var references: [String: ViewScopeInspectableReference] = [:]
        var visitedViews = Set<ObjectIdentifier>()
        var visitedLayers = Set<ObjectIdentifier>()
        var rootNodeIDs: [String] = []
        for (index, window) in windows.enumerated() {
            let windowID = "window-\(index)"
            let rootView = window.viewScopeRootView
            let windowBounds = window.viewScopeBounds
            nodes[windowID] = ViewScopeHierarchyNode(
                id: windowID,
                parentID: nil,
                kind: .window,
                className: NSStringFromClass(type(of: window)),
                title: sanitizedDisplayText(window.title) ?? interfaceLanguage.text("server.value.window_fallback"),
                subtitle: "#\(window.windowNumber)",
                address: window.viewScopeAddress,
                frame: windowBounds.viewScopeRect,
                bounds: windowBounds.viewScopeRect,
                childIDs: [],
                isHidden: !window.isVisible,
                alphaValue: Double(window.alphaValue),
                wantsLayer: true,
                isFlipped: rootView?.isFlipped ?? false,
                clippingEnabled: true,
                depth: 0
            )
            references[windowID] = .window(window)
            rootNodeIDs.append(windowID)

            if let rootView, let rootLayer = rootView.layer {
                let rootLayerNodeID = "\(windowID)-layer-root"
                buildLayerNode(
                    layer: rootLayer,
                    rootView: rootView,
                    rootLayer: rootLayer,
                    nodeID: rootLayerNodeID,
                    parentID: windowID,
                    prefix: "\(windowID)-layer",
                    depth: 1,
                    nodes: &nodes,
                    references: &references,
                    visitedViews: &visitedViews,
                    visitedLayers: &visitedLayers
                )
                nodes[windowID]?.childIDs = [rootLayerNodeID]
            } else if let rootView {
                let rootViewNodeID = "\(windowID)-view-root"
                buildViewNode(
                    view: rootView,
                    rootView: rootView,
                    rootLayer: nil,
                    nodeID: rootViewNodeID,
                    parentID: windowID,
                    prefix: "\(windowID)-view",
                    depth: 1,
                    nodes: &nodes,
                    references: &references,
                    visitedViews: &visitedViews,
                    visitedLayers: &visitedLayers
                )
                nodes[windowID]?.childIDs = [rootViewNodeID]
            }
        }

        let summary = ViewScopeCaptureSummary(
            nodeCount: nodes.count,
            windowCount: windows.count,
            visibleWindowCount: windows.filter(\.isVisible).count,
            captureDurationMilliseconds: Int(Date().timeIntervalSince(start) * 1000)
        )
        let capturedAt = Date()
        let context = ReferenceContext(nodeReferences: references, rootNodeIDs: rootNodeIDs, captureID: captureID)
        let nodePreviewScreenshots = makeNodePreviewScreenshots(
            nodes: nodes,
            context: context,
            capturedAt: capturedAt
        )

        var previewBitmaps: [ViewScopePreviewBitmap] = []
        let bitmapEncoder = ViewScopeImageEncoder()
        for (index, window) in windows.enumerated() {
            guard window.isVisible,
                  let rootView = window.viewScopeRootView,
                  rootView.bounds.width > 0, rootView.bounds.height > 0 else { continue }
            let rootNodeID = rootView.layer == nil ? "window-\(index)-view-root" : "window-\(index)-layer-root"
            if let image = makeWindowScreenshot(window: window),
               let base64 = bitmapEncoder.base64PNG(for: image) {
                previewBitmaps.append(ViewScopePreviewBitmap(
                    rootNodeID: rootNodeID,
                    pngBase64: base64,
                    size: image.size.viewScopeSize,
                    capturedAt: capturedAt,
                    scale: Double(window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
                ))
            }
        }

        return (
            ViewScopeCapturePayload(
                host: hostInfo,
                capturedAt: capturedAt,
                summary: summary,
                rootNodeIDs: rootNodeIDs,
                nodes: nodes,
                captureID: captureID,
                previewBitmaps: previewBitmaps,
                nodePreviewScreenshots: nodePreviewScreenshots
            ),
            context
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
                highlightedRect: window.viewScopeBounds.viewScopeRect,
                consoleTargets: makeConsoleTargets(for: .window(window), nodeID: nodeID, context: context)
            )
        case .view(let view):
            let screenshotRootView = screenshotRootView(for: view)
            let image = screenshotRootView.flatMap { root in
                makeCanvasScreenshot(rootView: root)
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
        case .layer(let layer):
            let screenshotRootView = screenshotRootView(for: layer)
            let screenshotRootLayer = screenshotRootView?.layer
            let image = screenshotRootView.flatMap { root in
                makeCanvasScreenshot(rootView: root)
            }
            let highlightRect = screenshotRootView.map { rootView -> ViewScopeRect in
                if let hostView = layer.viewScopeHostView {
                    return normalizedCanvasRect(for: hostView, in: rootView).viewScopeRect
                } else if let rootLayer = screenshotRootLayer {
                    return normalizedCanvasRect(for: layer, in: rootLayer, rootView: rootView).viewScopeRect
                }
                return .zero
            } ?? .zero
            return ViewScopeNodeDetailPayload(
                nodeID: nodeID,
                host: hostInfo,
                sections: layerSections(for: layer),
                constraints: [],
                ancestry: ancestry(for: layer),
                screenshotRootNodeID: screenshotRootView.flatMap { screenshotRootNodeID(for: $0, in: context) },
                screenshotPNGBase64: image.flatMap(ViewScopeImageEncoder().base64PNG),
                screenshotSize: image?.size.viewScopeSize ?? .zero,
                highlightedRect: highlightRect,
                consoleTargets: makeConsoleTargets(for: .layer(layer), nodeID: nodeID, context: context)
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

    private func buildViewNode(
        view: NSView,
        rootView: NSView,
        rootLayer: CALayer?,
        nodeID: String,
        parentID: String,
        prefix: String,
        depth: Int,
        nodes: inout [String: ViewScopeHierarchyNode],
        references: inout [String: ViewScopeInspectableReference],
        visitedViews: inout Set<ObjectIdentifier>,
        visitedLayers: inout Set<ObjectIdentifier>
    ) {
        guard visitedViews.insert(ObjectIdentifier(view)).inserted else {
            return
        }
        let ivarTraces = view.viewScopeIvarTracesForNode
        let childIDs = buildChildNodeIDs(
            for: view,
            rootView: rootView,
            rootLayer: rootLayer,
            parentNodeID: nodeID,
            prefix: prefix,
            depth: depth + 1,
            nodes: &nodes,
            references: &references,
            visitedViews: &visitedViews,
            visitedLayers: &visitedLayers
        )

        nodes[nodeID] = ViewScopeHierarchyNode(
            id: nodeID,
            parentID: parentID,
            kind: .view,
            className: NSStringFromClass(type(of: view)),
            hostViewClassName: nil,
            title: sanitizedDisplayText(view.viewScopeTitle(interfaceLanguage: interfaceLanguage))
                ?? ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: view))),
            subtitle: sanitizedDisplayText(view.viewScopeStoredSpecialTrace)
                ?? sanitizedDisplayText(view.viewScopeSubtitle(interfaceLanguage: interfaceLanguage)),
            identifier: sanitizedDisplayText(view.identifier?.rawValue),
            address: view.viewScopeAddress,
            frame: normalizedCanvasRect(for: view, in: rootView).viewScopeRect,
            bounds: view.bounds.viewScopeRect,
            childIDs: childIDs,
            isHidden: view.isHidden,
            alphaValue: Double(view.alphaValue),
            wantsLayer: view.wantsLayer,
            isFlipped: view.isFlipped,
            clippingEnabled: view.layer?.masksToBounds ?? false,
            depth: depth,
            ivarName: ivarTraces.first?.ivarName,
            ivarTraces: ivarTraces,
            rootViewControllerClassName: view.viewScopeExactRootViewControllerClassName,
            controlTargetClassName: (view as? NSControl)?.viewScopeTargetClassName,
            controlActionName: (view as? NSControl)?.viewScopeActionName,
            eventHandlers: view.viewScopeEventHandlers(interfaceLanguage: interfaceLanguage).nonEmpty
        )
        references[nodeID] = .view(view)
    }

    private func buildLayerNode(
        layer: CALayer,
        rootView: NSView,
        rootLayer: CALayer,
        nodeID: String,
        parentID: String,
        prefix: String,
        depth: Int,
        nodes: inout [String: ViewScopeHierarchyNode],
        references: inout [String: ViewScopeInspectableReference],
        visitedViews: inout Set<ObjectIdentifier>,
        visitedLayers: inout Set<ObjectIdentifier>
    ) {
        guard visitedLayers.insert(ObjectIdentifier(layer)).inserted else {
            return
        }
        let ivarTraces = layer.viewScopeIvarTracesForNode
        let childIDs = buildChildNodeIDs(
            for: layer,
            rootView: rootView,
            rootLayer: rootLayer,
            parentNodeID: nodeID,
            prefix: prefix,
            depth: depth + 1,
            nodes: &nodes,
            references: &references,
            visitedViews: &visitedViews,
            visitedLayers: &visitedLayers
        )
        let layerClassName = NSStringFromClass(type(of: layer))

        nodes[nodeID] = ViewScopeHierarchyNode(
            id: nodeID,
            parentID: parentID,
            kind: .layer,
            className: layerClassName,
            hostViewClassName: layer.viewScopeHostView.map { NSStringFromClass(type(of: $0)) },
            title: sanitizedDisplayText(layer.viewScopeHostView?.viewScopeTitle(interfaceLanguage: interfaceLanguage))
                ?? ViewScopeClassNameFormatter.displayName(for: layerClassName),
            subtitle: sanitizedDisplayText(layer.viewScopeSpecialTraceForNode)
                ?? sanitizedDisplayText(layer.viewScopeHostView?.viewScopeSubtitle(interfaceLanguage: interfaceLanguage)),
            identifier: layer.viewScopeHostView.flatMap { sanitizedDisplayText($0.identifier?.rawValue) },
            address: layer.viewScopeAddress,
            frame: normalizedCanvasRect(for: layer, in: rootLayer, rootView: rootView).viewScopeRect,
            bounds: layer.bounds.viewScopeRect,
            childIDs: childIDs,
            isHidden: layer.isHidden,
            alphaValue: Double(layer.opacity),
            wantsLayer: true,
            isFlipped: layer.viewScopeHostView?.isFlipped ?? layer.isGeometryFlipped,
            clippingEnabled: layer.masksToBounds,
            depth: depth,
            ivarName: ivarTraces.first?.ivarName,
            ivarTraces: ivarTraces,
            rootViewControllerClassName: layer.viewScopeHostView?.viewScopeOwningViewController.map { NSStringFromClass(type(of: $0)) },
            controlTargetClassName: (layer.viewScopeHostView as? NSControl)?.viewScopeTargetClassName,
            controlActionName: (layer.viewScopeHostView as? NSControl)?.viewScopeActionName,
            eventHandlers: layer.viewScopeHostView?.viewScopeEventHandlers(interfaceLanguage: interfaceLanguage).nonEmpty
        )
        references[nodeID] = .layer(layer)
    }

    private func buildChildNodeIDs(
        for view: NSView,
        rootView: NSView,
        rootLayer: CALayer?,
        parentNodeID: String,
        prefix: String,
        depth: Int,
        nodes: inout [String: ViewScopeHierarchyNode],
        references: inout [String: ViewScopeInspectableReference],
        visitedViews: inout Set<ObjectIdentifier>,
        visitedLayers: inout Set<ObjectIdentifier>
    ) -> [String] {
        var childIDs: [String] = []
        let childViews = capturedChildViews(of: view)

        for child in childViews {
            let nodeID = "\(prefix)-\(childIDs.count)"
            if let childLayer = child.layer {
                buildLayerNode(
                    layer: childLayer,
                    rootView: rootView,
                    rootLayer: rootLayer ?? childLayer,
                    nodeID: nodeID,
                    parentID: parentNodeID,
                    prefix: nodeID,
                    depth: depth,
                    nodes: &nodes,
                    references: &references,
                    visitedViews: &visitedViews,
                    visitedLayers: &visitedLayers
                )
            } else {
                buildViewNode(
                    view: child,
                    rootView: rootView,
                    rootLayer: rootLayer,
                    nodeID: nodeID,
                    parentID: parentNodeID,
                    prefix: nodeID,
                    depth: depth,
                    nodes: &nodes,
                    references: &references,
                    visitedViews: &visitedViews,
                    visitedLayers: &visitedLayers
                )
            }
            if nodes[nodeID] != nil {
                childIDs.append(nodeID)
            }
        }

        return childIDs
    }

    private func buildChildNodeIDs(
        for layer: CALayer,
        rootView: NSView,
        rootLayer: CALayer,
        parentNodeID: String,
        prefix: String,
        depth: Int,
        nodes: inout [String: ViewScopeHierarchyNode],
        references: inout [String: ViewScopeInspectableReference],
        visitedViews: inout Set<ObjectIdentifier>,
        visitedLayers: inout Set<ObjectIdentifier>
    ) -> [String] {
        var childIDs: [String] = []
        var representedLayerIDs = Set<ObjectIdentifier>()

        if let hostView = layer.viewScopeHostView {
            for childView in capturedChildViews(of: hostView) {
                let nodeID = "\(prefix)-\(childIDs.count)"
                if let childLayer = childView.layer {
                    representedLayerIDs.insert(ObjectIdentifier(childLayer))
                    buildLayerNode(
                        layer: childLayer,
                        rootView: rootView,
                        rootLayer: rootLayer,
                        nodeID: nodeID,
                    parentID: parentNodeID,
                    prefix: nodeID,
                    depth: depth,
                    nodes: &nodes,
                    references: &references,
                    visitedViews: &visitedViews,
                    visitedLayers: &visitedLayers
                )
                } else {
                    buildViewNode(
                        view: childView,
                        rootView: rootView,
                        rootLayer: rootLayer,
                        nodeID: nodeID,
                        parentID: parentNodeID,
                        prefix: nodeID,
                        depth: depth,
                        nodes: &nodes,
                        references: &references,
                        visitedViews: &visitedViews,
                        visitedLayers: &visitedLayers
                    )
                }
                if nodes[nodeID] != nil {
                    childIDs.append(nodeID)
                }
            }
        }

        for sublayer in layer.sublayers ?? [] {
            let identifier = ObjectIdentifier(sublayer)
            guard representedLayerIDs.contains(identifier) == false else {
                continue
            }
            if let hostView = layer.viewScopeHostView,
               let sublayerHostView = sublayer.viewScopeHostView,
               (sublayerHostView === hostView || sublayerHostView.viewScopeIsDescendant(of: hostView)) {
                continue
            }

            let nodeID = "\(prefix)-\(childIDs.count)"
            buildLayerNode(
                layer: sublayer,
                rootView: rootView,
                rootLayer: rootLayer,
                nodeID: nodeID,
                parentID: parentNodeID,
                prefix: nodeID,
                depth: depth,
                nodes: &nodes,
                references: &references,
                visitedViews: &visitedViews,
                visitedLayers: &visitedLayers
            )
            if nodes[nodeID] != nil {
                childIDs.append(nodeID)
            }
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

        if let outlineView = view as? NSOutlineView {
            let visibleRows = outlineView.rows(in: outlineView.visibleRect)
            if visibleRows.length > 0 {
                for row in visibleRows.location ..< NSMaxRange(visibleRows) {
                    append(outlineView.rowView(atRow: row, makeIfNecessary: false))
                }
            }
        }

        if let collectionView = view as? NSCollectionView {
            for indexPath in collectionView.indexPathsForVisibleItems() {
                if let item = collectionView.item(at: indexPath) {
                    append(item.view)
                }
            }
        }

        if let tabView = view as? NSTabView,
           let selectedItem = tabView.selectedTabViewItem {
            append(selectedItem.view)
        }

        return orderedChildren
    }

    private func screenshotRootView(for view: NSView) -> NSView? {
        if let rootView = view.window?.viewScopeRootView,
           rootView.bounds.width > 0,
           rootView.bounds.height > 0 {
            return rootView
        }

        var current: NSView = view
        while let parent = current.superview {
            current = parent
        }
        return current.bounds.width > 0 && current.bounds.height > 0 ? current : nil
    }

    private func screenshotRootView(for layer: CALayer) -> NSView? {
        let window = layer.viewScopeWindow

        // If the layer's host view is the window's direct content view, use it as
        // the screenshot root to avoid including the title bar in the screenshot.
        if let hostView = layer.viewScopeHostView,
           hostView === window?.contentView,
           hostView.bounds.width > 0, hostView.bounds.height > 0 {
            return hostView
        }

        if let rootView = window?.viewScopeRootView,
           rootView.bounds.width > 0,
           rootView.bounds.height > 0 {
            return rootView
        }
        if let hostView = layer.viewScopeHostView {
            return screenshotRootView(for: hostView)
        }
        return nil
    }

    private func screenshotRootNodeID(for view: NSView, in context: ReferenceContext) -> String? {
        if let layer = view.layer,
           let key = context.nodeReferences.first(where: { entry in
               guard case .layer(let capturedLayer) = entry.value else { return false }
               return capturedLayer === layer
           })?.key {
            return key
        }
        return context.nodeReferences.first(where: { entry in
            guard case .view(let capturedView) = entry.value else { return false }
            return capturedView === view
        })?.key
    }

    private func makeNodePreviewScreenshots(
        nodes: [String: ViewScopeHierarchyNode],
        context: ReferenceContext,
        capturedAt: Date
    ) -> [ViewScopeNodePreviewScreenshotSet] {
        let encoder = ViewScopeImageEncoder()
        let debugNodePreview = ProcessInfo.processInfo.environment["VIEWSCOPE_DEBUG_NODE_PREVIEW"] == "1"

        return nodes.keys.sorted().compactMap { nodeID -> ViewScopeNodePreviewScreenshotSet? in
            guard let node = nodes[nodeID],
                  node.isHidden == false,
                  node.bounds.width > 0,
                  node.bounds.height > 0,
                  let reference = context.nodeReferences[nodeID] else {
                return nil
            }

            if debugNodePreview {
                fputs("node-preview \(nodeID) \(node.className)\n", stderr)
                fflush(stderr)
            }

            switch reference {
            case .window(let window):
                _ = window
                return nil

            case .view(let view):
                if view.window?.contentView === view || node.childIDs.isEmpty {
                    return nil
                }

                // Skip solo screenshots for very small or deep nodes to improve performance.
                guard node.bounds.width > 2, node.bounds.height > 2 else {
                    return nil
                }
                if node.depth > 4, node.childIDs.count <= 3 {
                    return nil
                }

                let soloImage = makeSoloViewScreenshot(view: view)
                let soloPNGBase64 = soloImage.flatMap(encoder.base64PNG)
                guard soloPNGBase64 != nil else {
                    return nil
                }

                return ViewScopeNodePreviewScreenshotSet(
                    nodeID: nodeID,
                    groupPNGBase64: nil,
                    soloPNGBase64: soloPNGBase64,
                    size: view.bounds.size.viewScopeSize,
                    capturedAt: capturedAt,
                    scale: Double(view.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
                )

            case .layer(let layer):
                guard let hostView = layer.viewScopeHostView else { return nil }
                if hostView.window?.contentView === hostView || node.childIDs.isEmpty {
                    return nil
                }

                guard node.bounds.width > 2, node.bounds.height > 2 else {
                    return nil
                }
                if node.depth > 4, node.childIDs.count <= 3 {
                    return nil
                }

                let soloImage = makeSoloLayerScreenshot(layer: layer)
                let soloPNGBase64 = soloImage.flatMap(encoder.base64PNG)
                guard soloPNGBase64 != nil else {
                    return nil
                }

                return ViewScopeNodePreviewScreenshotSet(
                    nodeID: nodeID,
                    groupPNGBase64: nil,
                    soloPNGBase64: soloPNGBase64,
                    size: layer.bounds.size.viewScopeSize,
                    capturedAt: capturedAt,
                    scale: Double(hostView.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
                )

            case .viewController, .object:
                return nil
            }
        }
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

    private func makeSoloViewScreenshot(view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }

        if view.window?.contentView === view {
            return makeTransparentImage(size: view.bounds.size)
        }

        if let layerImage = makeOwnLayerScreenshot(for: view) {
            return normalizedScreenshot(layerImage, for: view)
        }
        return makeTransparentImage(size: view.bounds.size)
    }

    /// Returns true for layers that use (or are nested inside) a compositor-backed view such as
    /// NSVisualEffectView or NSGlassEffectView, and therefore cannot safely be rendered via
    /// CALayer.render(in:) in an off-screen context (the compositor must own the render pass).
    private func isCompositorRenderedLayer(_ layer: CALayer) -> Bool {
        var current: CALayer? = layer
        while let l = current {
            if let hostView = l.viewScopeHostView {
                if hostView is NSVisualEffectView { return true }
                if #available(macOS 26.0, *), hostView is NSGlassEffectView { return true }
                // Found a concrete, non-compositor host view — safe to render below this level.
                return false
            }
            current = l.superlayer
        }
        return false
    }

    private func makeLayerScreenshot(layer: CALayer) -> NSImage? {
        guard layer.bounds.width > 0, layer.bounds.height > 0 else {
            return nil
        }
        if isCompositorRenderedLayer(layer) {
            return nil
        }

        if let hostView = layer.viewScopeHostView,
           let image = makeDirectViewScreenshot(view: hostView) {
            return normalizedScreenshot(image, for: hostView)
        }

        let image = NSImage(size: layer.bounds.size)
        image.lockFocusFlipped(layer.isGeometryFlipped)
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }
        layer.render(in: context)
        image.unlockFocus()
        return image
    }

    private func makeSoloLayerScreenshot(layer: CALayer) -> NSImage? {
        guard layer.bounds.width > 0, layer.bounds.height > 0 else {
            return nil
        }
        guard (layer.sublayers?.isEmpty == false) || layer.viewScopeHostView != nil else {
            return nil
        }
        if isCompositorRenderedLayer(layer) {
            return nil
        }

        let hiddenStates = (layer.sublayers ?? []).map { sublayer in
            (layer: sublayer, isHidden: sublayer.isHidden)
        }
        for (sublayer, isHidden) in hiddenStates where isHidden == false {
            sublayer.isHidden = true
        }
        defer {
            for (sublayer, isHidden) in hiddenStates {
                sublayer.isHidden = isHidden
            }
        }

        if let hostView = layer.viewScopeHostView,
           let image = makeDirectViewScreenshot(view: hostView) {
            return normalizedScreenshot(image, for: hostView)
        }

        let image = NSImage(size: layer.bounds.size)
        image.lockFocusFlipped(layer.isGeometryFlipped)
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }
        layer.render(in: context)
        image.unlockFocus()
        return image
    }

    private func makeDirectViewScreenshot(view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }

        // Use layer.render for explicitly layer-backed views so that CALayer properties
        // (e.g. backgroundColor) are captured. Implicit system layer-backing (wantsLayer=false)
        // uses cacheDisplay to avoid unsafe rendering of system-private layer delegates.
        //
        // NSVisualEffectView and NSGlassEffectView (macOS 26+) use compositor rendering
        // that is incompatible with off-screen layer.render calls — calling render on their
        // layers crashes once the window compositor is active. Fall through to cacheDisplay.
        if view.wantsLayer, let layer = view.layer {
            var usesCompositorRendering = view is NSVisualEffectView
            if !usesCompositorRendering, #available(macOS 26.0, *) {
                usesCompositorRendering = view is NSGlassEffectView
            }
            if !usesCompositorRendering {
                let image = NSImage(size: view.bounds.size)
                image.lockFocusFlipped(!layer.isGeometryFlipped)
                defer { image.unlockFocus() }
                guard let context = NSGraphicsContext.current?.cgContext else { return nil }
                layer.render(in: context)
                return image
            }
        }

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

    private func makeOwnLayerScreenshot(for view: NSView) -> NSImage? {
        guard let sourceLayer = view.layer else {
            return nil
        }

        let image = NSImage(size: view.bounds.size)
        image.lockFocusFlipped(true)
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        NSColor.clear.setFill()
        bounds.fill()

        let cornerRadius = max(sourceLayer.cornerRadius, 0)
        let borderWidth = max(sourceLayer.borderWidth, 0)
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: borderWidth * 0.5, dy: borderWidth * 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )

        if let backgroundColor = sourceLayer.backgroundColor.flatMap(NSColor.init(cgColor:)) {
            backgroundColor.setFill()
            path.fill()
        }

        if borderWidth > 0,
           let borderColor = sourceLayer.borderColor.flatMap(NSColor.init(cgColor:)) {
            borderColor.setStroke()
            path.lineWidth = borderWidth
            path.stroke()
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

    /// Returns a canvas-level screenshot for a given root view in `makeDetail`.
    ///
    /// When the root view is the window's frame root (NSThemeFrame), the window compositor
    /// snapshot (CGWindowListCreateImage) is preferred so that compositor-backed content
    /// such as NSGlassEffectView and NSVisualEffectView renders correctly. A regular
    /// view screenshot is used as a fallback, and for content-view-only canvas roots.
    private func makeCanvasScreenshot(rootView: NSView) -> NSImage? {
        if let window = rootView.window,
           window.viewScopeRootView === rootView {
            return makeWindowScreenshot(window: window)
        }
        return makeViewScreenshot(view: rootView)
    }

    private func makeWindowScreenshot(window: NSWindow) -> NSImage? {
        if let snapshot = window.viewScopeSnapshotImage {
            return snapshot
        }
        guard let rootView = window.viewScopeRootView else {
            return nil
        }
        return makeViewScreenshot(view: rootView)
    }

    private func makeTransparentImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func normalizedScreenshot(_ image: NSImage, for view: NSView) -> NSImage {
        // layer.render(in:) always produces a y-down (screen-coords) bitmap regardless of
        // isGeometryFlipped. lockFocusFlipped(!layer.isGeometryFlipped) compensates at draw
        // time but leaves the resulting NSImage in y-down orientation. Flip it vertically
        // here so that NSBitmapImageRep.colorAt(x:y:) uses y-up convention (y=0 = visual
        // bottom) consistently for both flipped and non-flipped views.
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocusFlipped(false)
        defer { result.unlockFocus() }
        image.draw(
            in: CGRect(origin: .zero, size: size),
            from: CGRect(origin: .zero, size: size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        return result
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

    private func normalizedCanvasRect(for layer: CALayer, in rootLayer: CALayer, rootView: NSView) -> NSRect {
        if let hostView = layer.viewScopeHostView {
            return normalizedCanvasRect(for: hostView, in: rootView)
        }
        let rect = rootLayer.convert(layer.bounds, from: layer)
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

            // Control 通用属性：controlSize / alignment / fontSize（Lookin NSControl group）
            if let fontName = control.font?.fontName {
                controlItems.append(ViewScopePropertyItem(title: "Font Name", value: fontName))
            }
            controlItems.append(contentsOf: [
                editableNumberItem(title: "Control Size", key: "control.controlSize", value: Double(control.controlSize.rawValue), decimals: 0),
                editableNumberItem(title: "Alignment", key: "control.alignment", value: Double(control.alignment.rawValue), decimals: 0),
                editableNumberItem(title: "Font Size", key: "control.fontSize", value: Double(control.font?.pointSize ?? NSFont.systemFontSize), decimals: 1)
            ])

            sections.append(
                ViewScopePropertySection(
                    title: text("server.section.control"),
                    items: controlItems
                )
            )
        }

        sections.append(contentsOf: appKitSpecificSections(for: view))
        return sections
    }

    private func layerSections(for layer: CALayer) -> [ViewScopePropertySection] {
        var identityItems = [
            ViewScopePropertyItem(
                title: text("server.item.class"),
                value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: layer)))
            ),
            ViewScopePropertyItem(title: text("server.item.address"), value: layer.viewScopeAddress)
        ]
        if let hostView = layer.viewScopeHostView {
            identityItems.append(
                ViewScopePropertyItem(
                    title: "Hosted View",
                    value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: hostView)))
                )
            )
            if let identifier = hostView.identifier?.rawValue, !identifier.isEmpty {
                identityItems.append(ViewScopePropertyItem(title: text("server.item.identifier"), value: identifier))
            }
            if let title = sanitizedDisplayText(hostView.viewScopeTitle(interfaceLanguage: interfaceLanguage)) {
                identityItems.append(ViewScopePropertyItem(title: text("server.item.title"), value: title))
            }
            if let rootViewControllerClassName = hostView.viewScopeExactRootViewControllerClassName {
                identityItems.append(
                    ViewScopePropertyItem(
                        title: text("server.item.view_controller"),
                        value: ViewScopeClassNameFormatter.displayName(for: rootViewControllerClassName)
                    )
                )
            }
        }

        let layoutItems = [
            ViewScopePropertyItem(title: text("server.item.frame"), value: layer.frame.viewScopeString),
            editableNumberItem(title: text("server.item.x"), key: "frame.x", value: Double(layer.frame.origin.x), decimals: 1),
            editableNumberItem(title: text("server.item.y"), key: "frame.y", value: Double(layer.frame.origin.y), decimals: 1),
            editableNumberItem(title: text("server.item.width"), key: "frame.width", value: Double(layer.frame.width), decimals: 1),
            editableNumberItem(title: text("server.item.height"), key: "frame.height", value: Double(layer.frame.height), decimals: 1),
            ViewScopePropertyItem(title: text("server.item.bounds"), value: layer.bounds.viewScopeString),
            editableNumberItem(title: text("server.item.bounds_x"), key: "bounds.x", value: Double(layer.bounds.origin.x), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_y"), key: "bounds.y", value: Double(layer.bounds.origin.y), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_width"), key: "bounds.width", value: Double(layer.bounds.width), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_height"), key: "bounds.height", value: Double(layer.bounds.height), decimals: 1)
        ]

        var renderingItems = [
            editableToggleItem(title: text("server.item.hidden"), key: "hidden", value: layer.isHidden),
            editableNumberItem(title: text("server.item.alpha"), key: "alpha", value: Double(layer.opacity), decimals: 2),
            ViewScopePropertyItem(title: text("server.item.flipped"), value: (layer.viewScopeHostView?.isFlipped ?? layer.isGeometryFlipped).viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: "Masks To Bounds", value: layer.masksToBounds.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: "Sublayers", value: String(layer.sublayers?.count ?? 0))
        ]
        if let background = layer.backgroundColor?.viewScopeHexString {
            renderingItems.append(editableColorItem(title: text("server.item.background"), key: "backgroundColor", value: background))
        }
        renderingItems.append(
            editableNumberItem(
                title: text("server.item.corner_radius"),
                key: "layer.cornerRadius",
                value: Double(layer.cornerRadius),
                decimals: 1
            )
        )
        renderingItems.append(
            editableNumberItem(
                title: text("server.item.border_width"),
                key: "layer.borderWidth",
                value: Double(layer.borderWidth),
                decimals: 1
            )
        )

        return [
            ViewScopePropertySection(title: text("server.section.identity"), items: identityItems),
            ViewScopePropertySection(title: text("server.section.layout"), items: layoutItems),
            ViewScopePropertySection(title: text("server.section.rendering"), items: renderingItems)
        ]
    }

    private func appKitSpecificSections(for view: NSView) -> [ViewScopePropertySection] {
        var sections: [ViewScopePropertySection] = []

        if let imageView = view as? NSImageView {
            var imageItems: [ViewScopePropertyItem] = []
            if let imageName = imageView.image?.name() {
                imageItems.append(ViewScopePropertyItem(title: "Image Name", value: imageName))
            }
            imageItems.append(contentsOf: [
                editableNumberItem(title: "Image Scaling", key: "imageView.imageScaling", value: Double(imageView.imageScaling.rawValue), decimals: 0),
                editableNumberItem(title: "Image Alignment", key: "imageView.imageAlignment", value: Double(imageView.imageAlignment.rawValue), decimals: 0),
                editableToggleItem(title: "Animates", key: "imageView.animates", value: imageView.animates)
            ])
            sections.append(ViewScopePropertySection(title: "Image View", items: imageItems))
        }

        if let scrollView = view as? NSScrollView {
            sections.append(
                ViewScopePropertySection(
                    title: "Scroll View",
                    items: [
                        editableNumberItem(title: "Content Offset X", key: "contentOffset.x", value: Double(scrollView.contentView.bounds.origin.x), decimals: 1),
                        editableNumberItem(title: "Content Offset Y", key: "contentOffset.y", value: Double(scrollView.contentView.bounds.origin.y), decimals: 1),
                        editableNumberItem(title: "Content Size Width", key: "contentSize.width", value: Double(scrollView.documentView?.frame.width ?? 0), decimals: 1),
                        editableNumberItem(title: "Content Size Height", key: "contentSize.height", value: Double(scrollView.documentView?.frame.height ?? 0), decimals: 1),
                        editableToggleItem(title: "Automatically Adjusts Content Insets", key: "automaticallyAdjustsContentInsets", value: scrollView.automaticallyAdjustsContentInsets),
                        editableNumberItem(title: "Border Type", key: "borderType", value: Double(scrollView.borderType.rawValue), decimals: 0),
                        editableToggleItem(title: "Horizontal Scroller", key: "hasHorizontalScroller", value: scrollView.hasHorizontalScroller),
                        editableToggleItem(title: "Vertical Scroller", key: "hasVerticalScroller", value: scrollView.hasVerticalScroller),
                        editableToggleItem(title: "Autohides Scrollers", key: "autohidesScrollers", value: scrollView.autohidesScrollers),
                        editableNumberItem(title: "Scroller Style", key: "scrollerStyle", value: Double(scrollView.scrollerStyle.rawValue), decimals: 0),
                        editableNumberItem(title: "Scroller Knob Style", key: "scrollerKnobStyle", value: Double(scrollView.scrollerKnobStyle.rawValue), decimals: 0),
                        editableToggleItem(title: "Scrolls Dynamically", key: "scrollsDynamically", value: scrollView.scrollsDynamically),
                        editableToggleItem(title: "Uses Predominant Axis Scrolling", key: "usesPredominantAxisScrolling", value: scrollView.usesPredominantAxisScrolling),
                        editableToggleItem(title: "Allows Magnification", key: "allowsMagnification", value: scrollView.allowsMagnification),
                        editableNumberItem(title: "Magnification", key: "magnification", value: Double(scrollView.magnification), decimals: 2),
                        editableNumberItem(title: "Max Magnification", key: "maxMagnification", value: Double(scrollView.maxMagnification), decimals: 2),
                        editableNumberItem(title: "Min Magnification", key: "minMagnification", value: Double(scrollView.minMagnification), decimals: 2)
                    ]
                )
            )
        }

        if let tableView = view as? NSTableView {
            var tableItems: [ViewScopePropertyItem] = [
                editableNumberItem(title: "Row Height", key: "rowHeight", value: Double(tableView.rowHeight), decimals: 1),
                editableToggleItem(title: "Uses Automatic Row Heights", key: "usesAutomaticRowHeights", value: tableView.usesAutomaticRowHeights),
                editableNumberItem(title: "Intercell Spacing Width", key: "intercellSpacing.width", value: Double(tableView.intercellSpacing.width), decimals: 1),
                editableNumberItem(title: "Intercell Spacing Height", key: "intercellSpacing.height", value: Double(tableView.intercellSpacing.height), decimals: 1),
                editableNumberItem(title: "Style", key: "style", value: Double(tableView.style.rawValue), decimals: 0),
                editableNumberItem(title: "Column Autoresizing", key: "columnAutoresizingStyle", value: Double(tableView.columnAutoresizingStyle.rawValue), decimals: 0),
                editableNumberItem(title: "Grid Style Mask", key: "gridStyleMask", value: Double(tableView.gridStyleMask.rawValue), decimals: 0),
                editableNumberItem(title: "Selection Highlight Style", key: "selectionHighlightStyle", value: Double(tableView.selectionHighlightStyle.rawValue), decimals: 0),
                editableNumberItem(title: "Row Size Style", key: "rowSizeStyle", value: Double(tableView.rowSizeStyle.rawValue), decimals: 0),
                ViewScopePropertyItem(title: "Number Of Rows", value: String(tableView.numberOfRows)),
                ViewScopePropertyItem(title: "Number Of Columns", value: String(tableView.numberOfColumns)),
                editableToggleItem(title: "Alternating Row Backgrounds", key: "usesAlternatingRowBackgroundColors", value: tableView.usesAlternatingRowBackgroundColors),
                editableToggleItem(title: "Allows Column Reordering", key: "allowsColumnReordering", value: tableView.allowsColumnReordering),
                editableToggleItem(title: "Allows Column Resizing", key: "allowsColumnResizing", value: tableView.allowsColumnResizing),
                editableToggleItem(title: "Allows Multiple Selection", key: "allowsMultipleSelection", value: tableView.allowsMultipleSelection),
                editableToggleItem(title: "Allows Empty Selection", key: "allowsEmptySelection", value: tableView.allowsEmptySelection),
                editableToggleItem(title: "Allows Column Selection", key: "allowsColumnSelection", value: tableView.allowsColumnSelection),
                editableToggleItem(title: "Allows Type Select", key: "allowsTypeSelect", value: tableView.allowsTypeSelect),
                editableToggleItem(title: "Floats Group Rows", key: "floatsGroupRows", value: tableView.floatsGroupRows),
                editableToggleItem(title: "Vertical Motion Can Begin Drag", key: "verticalMotionCanBeginDrag", value: tableView.verticalMotionCanBeginDrag)
            ]
            if let color = tableView.gridColor.cgColor.viewScopeHexString {
                tableItems.append(editableColorItem(title: "Grid Color", key: "gridColor", value: color))
            }
            sections.append(ViewScopePropertySection(title: "Table View", items: tableItems))
        }

        if let textView = view as? NSTextView {
            var textViewItems: [ViewScopePropertyItem] = [
                editableTextItem(title: "String", key: "textView.string", value: textView.string)
            ]
            if let fontName = textView.font?.fontName {
                textViewItems.append(ViewScopePropertyItem(title: "Font Name", value: fontName))
            }
            textViewItems.append(contentsOf: [
                editableNumberItem(title: "Font Size", key: "textView.fontSize", value: Double(textView.font?.pointSize ?? NSFont.systemFontSize), decimals: 1),
                editableNumberItem(title: "Alignment", key: "textView.alignment", value: Double(textView.alignment.rawValue), decimals: 0),
                editableNumberItem(title: "Text Container Inset Width", key: "textView.textContainerInset.width", value: Double(textView.textContainerInset.width), decimals: 1),
                editableNumberItem(title: "Text Container Inset Height", key: "textView.textContainerInset.height", value: Double(textView.textContainerInset.height), decimals: 1),
                editableNumberItem(title: "Max Size Width", key: "textView.maxSize.width", value: Double(textView.maxSize.width), decimals: 1),
                editableNumberItem(title: "Max Size Height", key: "textView.maxSize.height", value: Double(textView.maxSize.height), decimals: 1),
                editableNumberItem(title: "Min Size Width", key: "textView.minSize.width", value: Double(textView.minSize.width), decimals: 1),
                editableNumberItem(title: "Min Size Height", key: "textView.minSize.height", value: Double(textView.minSize.height), decimals: 1),
                editableToggleItem(title: "Editable", key: "textView.isEditable", value: textView.isEditable),
                editableToggleItem(title: "Selectable", key: "textView.isSelectable", value: textView.isSelectable),
                editableToggleItem(title: "Rich Text", key: "textView.isRichText", value: textView.isRichText),
                editableToggleItem(title: "Imports Graphics", key: "textView.importsGraphics", value: textView.importsGraphics),
                editableToggleItem(title: "Horizontally Resizable", key: "textView.isHorizontallyResizable", value: textView.isHorizontallyResizable),
                editableToggleItem(title: "Vertically Resizable", key: "textView.isVerticallyResizable", value: textView.isVerticallyResizable)
            ])
            if let color = textView.textColor?.cgColor.viewScopeHexString {
                textViewItems.append(editableColorItem(title: "Text Color", key: "textView.textColor", value: color))
            }
            sections.append(ViewScopePropertySection(title: "Text View", items: textViewItems))
        }

        if let textField = view as? NSTextField {
            var textFieldItems: [ViewScopePropertyItem] = [
                editableToggleItem(title: "Bordered", key: "textField.isBordered", value: textField.isBordered),
                editableToggleItem(title: "Bezeled", key: "textField.isBezeled", value: textField.isBezeled),
                editableNumberItem(title: "Bezel Style", key: "textField.bezelStyle", value: Double(textField.bezelStyle.rawValue), decimals: 0),
                editableToggleItem(title: "Editable", key: "textField.isEditable", value: textField.isEditable),
                editableToggleItem(title: "Selectable", key: "textField.isSelectable", value: textField.isSelectable),
                editableToggleItem(title: "Draws Background", key: "textField.drawsBackground", value: textField.drawsBackground),
                editableNumberItem(title: "Preferred Max Layout Width", key: "textField.preferredMaxLayoutWidth", value: Double(textField.preferredMaxLayoutWidth), decimals: 1),
                editableNumberItem(title: "Maximum Number Of Lines", key: "textField.maximumNumberOfLines", value: Double(textField.maximumNumberOfLines), decimals: 0),
                editableToggleItem(title: "Allows Default Tightening", key: "textField.allowsDefaultTighteningForTruncation", value: textField.allowsDefaultTighteningForTruncation),
                editableNumberItem(title: "Line Break Strategy", key: "textField.lineBreakStrategy", value: Double(textField.lineBreakStrategy.rawValue), decimals: 0)
            ]
            if let color = textField.textColor?.cgColor.viewScopeHexString {
                textFieldItems.append(editableColorItem(title: "Text Color", key: "textField.textColor", value: color))
            }
            sections.append(ViewScopePropertySection(title: "Text Field", items: textFieldItems))
        }

        if let button = view as? NSButton {
            var buttonItems: [ViewScopePropertyItem] = [
                editableTextItem(title: "Title", key: "button.title", value: button.title),
                editableTextItem(title: "Alternate Title", key: "button.alternateTitle", value: button.alternateTitle),
                editableNumberItem(title: "Button Type", key: "button.buttonType", value: Double(button.viewScopeButtonType.rawValue), decimals: 0),
                editableNumberItem(title: "Bezel Style", key: "button.bezelStyle", value: Double(button.bezelStyle.rawValue), decimals: 0),
                editableToggleItem(title: "Bordered", key: "button.isBordered", value: button.isBordered),
                editableToggleItem(title: "Transparent", key: "button.isTransparent", value: button.isTransparent),
                editableToggleItem(title: "Shows Border Only While Mouse Inside", key: "button.showsBorderOnlyWhileMouseInside", value: button.showsBorderOnlyWhileMouseInside),
                editableToggleItem(title: "Spring Loaded", key: "button.isSpringLoaded", value: button.isSpringLoaded)
            ]
            if let color = button.bezelColor?.cgColor.viewScopeHexString {
                buttonItems.append(editableColorItem(title: "Bezel Color", key: "button.bezelColor", value: color))
            }
            if let color = button.contentTintColor?.cgColor.viewScopeHexString {
                buttonItems.append(editableColorItem(title: "Content Tint Color", key: "button.contentTintColor", value: color))
            }
            sections.append(ViewScopePropertySection(title: "Button", items: buttonItems))
        }

        if let visualEffectView = view as? NSVisualEffectView {
            sections.append(
                ViewScopePropertySection(
                    title: "Visual Effect",
                    items: [
                        editableNumberItem(title: "Material", key: "visualEffect.material", value: Double(visualEffectView.material.rawValue), decimals: 0),
                        ViewScopePropertyItem(title: "Interior Background Style", value: String(visualEffectView.interiorBackgroundStyle.rawValue)),
                        editableNumberItem(title: "Blending Mode", key: "visualEffect.blendingMode", value: Double(visualEffectView.blendingMode.rawValue), decimals: 0),
                        editableNumberItem(title: "State", key: "visualEffect.state", value: Double(visualEffectView.state.rawValue), decimals: 0),
                        editableToggleItem(title: "Emphasized", key: "visualEffect.isEmphasized", value: visualEffectView.isEmphasized)
                    ]
                )
            )
        }

        if let stackView = view as? NSStackView {
            sections.append(
                ViewScopePropertySection(
                    title: "Stack View",
                    items: [
                        editableNumberItem(title: "Orientation", key: "stack.orientation", value: Double(stackView.orientation.rawValue), decimals: 0),
                        editableNumberItem(title: "Edge Insets Top", key: "stack.edgeInsets.top", value: Double(stackView.edgeInsets.top), decimals: 1),
                        editableNumberItem(title: "Edge Insets Left", key: "stack.edgeInsets.left", value: Double(stackView.edgeInsets.left), decimals: 1),
                        editableNumberItem(title: "Edge Insets Bottom", key: "stack.edgeInsets.bottom", value: Double(stackView.edgeInsets.bottom), decimals: 1),
                        editableNumberItem(title: "Edge Insets Right", key: "stack.edgeInsets.right", value: Double(stackView.edgeInsets.right), decimals: 1),
                        editableToggleItem(title: "Detaches Hidden Views", key: "stack.detachesHiddenViews", value: stackView.detachesHiddenViews),
                        editableNumberItem(title: "Distribution", key: "stack.distribution", value: Double(stackView.distribution.rawValue), decimals: 0),
                        editableNumberItem(title: "Alignment", key: "stack.alignment", value: Double(stackView.alignment.rawValue), decimals: 0),
                        editableNumberItem(title: "Spacing", key: "stack.spacing", value: Double(stackView.spacing), decimals: 1)
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

    private func ancestry(for layer: CALayer) -> [String] {
        if let hostView = layer.viewScopeHostView {
            return ancestry(for: hostView)
        }

        var chain: [String] = []
        var cursor: CALayer? = layer
        while let current = cursor {
            chain.append(ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: current))))
            cursor = current.superlayer
        }
        if let title = sanitizedDisplayText(layer.viewScopeWindow?.title), !title.isEmpty {
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
        case .layer(let layer):
            var targets: [ViewScopeConsoleTargetDescriptor] = []
            if let descriptor = makeConsoleTargetDescriptor(
                reference: .layer(layer),
                sourceNodeID: nodeID,
                captureID: context.captureID,
                subtitle: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: layer)))
            ) {
                targets.append(descriptor)
            }
            if let hostView = layer.viewScopeHostView,
               let descriptor = makeConsoleTargetDescriptor(
                reference: .view(hostView),
                sourceNodeID: nodeID,
                captureID: context.captureID,
                subtitle: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: hostView)))
               ) {
                targets.append(descriptor)
            }
            if let controller = layer.viewScopeHostView?.viewScopeOwningViewController,
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
        case .layer(let layer):
            object = layer
            kind = .layer
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
    case layer(CALayer)
    case viewController(NSViewController)
    case object(AnyObject)
}

extension NSView {
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

private extension NSView {
    func viewScopeIsDescendant(of ancestor: NSView) -> Bool {
        var candidate = superview
        while let current = candidate {
            if current === ancestor {
                return true
            }
            candidate = current.superview
        }
        return false
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

extension NSWindow {
    var viewScopeAddress: String {
        String(describing: Unmanaged.passUnretained(self).toOpaque())
    }

    var viewScopeRootView: NSView? {
        contentView?.superview ?? contentView
    }

    var viewScopeBounds: NSRect {
        NSRect(origin: .zero, size: frame.size)
    }

    var viewScopeSnapshotImage: NSImage? {
        guard windowNumber > 0,
              let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(windowNumber), [.boundsIgnoreFraming]) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: frame.size)
    }
}

private extension NSButton {
    var viewScopeButtonType: NSButton.ButtonType {
        if let rawValue = cell?.value(forKey: "_buttonType") as? NSNumber,
           let buttonType = NSButton.ButtonType(rawValue: rawValue.uintValue) {
            return buttonType
        }
        return .momentaryPushIn
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
            subtitle: viewScopeEventMaskDescription,
            targetActions: [targetAction]
        )
    }

    var viewScopeEventMaskDescription: String? {
        guard let cell,
              cell.responds(to: Selector(("sendActionOnMask"))) else {
            return nil
        }
        let rawValue = (cell.value(forKey: "sendActionOnMask") as? NSNumber)?.uint64Value ?? 0
        let mask = NSEvent.EventTypeMask(rawValue: rawValue)
        let names = mask.viewScopeNames
        return names.isEmpty ? nil : names.joined(separator: " | ")
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
            subtitle: viewScopeInheritedRecognizerName,
            targetActions: (targetAction.targetClassName != nil || targetAction.actionName != nil) ? [targetAction] : [],
            isEnabled: isEnabled,
            delegateClassName: delegateClassName
        )
    }

    var viewScopeInheritedRecognizerName: String? {
        let bases: [NSGestureRecognizer.Type] = [
            NSClickGestureRecognizer.self,
            NSMagnificationGestureRecognizer.self,
            NSPanGestureRecognizer.self,
            NSPressGestureRecognizer.self,
            NSRotationGestureRecognizer.self
        ]

        for base in bases {
            if type(of: self) == base {
                return nil
            }
            if isKind(of: base) {
                return String(describing: base)
            }
        }
        return "NSGestureRecognizer"
    }
}

private extension NSEvent.EventTypeMask {
    var viewScopeNames: [String] {
        let mappings: [(NSEvent.EventTypeMask, String)] = [
            (.leftMouseDown, "LeftMouseDown"),
            (.leftMouseUp, "LeftMouseUp"),
            (.rightMouseDown, "RightMouseDown"),
            (.rightMouseUp, "RightMouseUp"),
            (.mouseMoved, "MouseMoved"),
            (.leftMouseDragged, "LeftMouseDragged"),
            (.rightMouseDragged, "RightMouseDragged"),
            (.mouseEntered, "MouseEntered"),
            (.mouseExited, "MouseExited"),
            (.keyDown, "KeyDown"),
            (.keyUp, "KeyUp"),
            (.flagsChanged, "FlagsChanged"),
            (.appKitDefined, "AppKitDefined"),
            (.systemDefined, "SystemDefined"),
            (.applicationDefined, "ApplicationDefined"),
            (.periodic, "Periodic"),
            (.cursorUpdate, "CursorUpdate"),
            (.scrollWheel, "ScrollWheel"),
            (.tabletPoint, "TabletPoint"),
            (.tabletProximity, "TabletProximity"),
            (.otherMouseDown, "OtherMouseDown"),
            (.otherMouseUp, "OtherMouseUp"),
            (.otherMouseDragged, "OtherMouseDragged"),
            (.gesture, "Gesture"),
            (.magnify, "Magnify"),
            (.swipe, "Swipe"),
            (.rotate, "Rotate"),
            (.beginGesture, "BeginGesture"),
            (.endGesture, "EndGesture"),
            (.smartMagnify, "SmartMagnify"),
            (.pressure, "Pressure"),
            (.directTouch, "DirectTouch")
        ]

        if contains(.any) {
            return ["Any"]
        }
        return mappings.compactMap { contains($0.0) ? $0.1 : nil }
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
