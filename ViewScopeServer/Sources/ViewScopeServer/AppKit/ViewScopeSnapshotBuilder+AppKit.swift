#if os(macOS)
import AppKit
import Foundation
import ObjectiveC.runtime

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

/// 抓取结果里对宿主对象的引用。关联值全部是弱引用，避免抓取上下文强持有整棵视图树（A9）。
enum ViewScopeInspectableReference {
    case window(ViewScopeWeakReference<NSWindow>)
    case view(ViewScopeWeakReference<NSView>)
    case layer(ViewScopeWeakReference<CALayer>)
    case viewController(ViewScopeWeakReference<NSViewController>)
    case object(ViewScopeWeakReference<AnyObject>)

    static func window(_ window: NSWindow) -> ViewScopeInspectableReference {
        .window(ViewScopeWeakReference(window))
    }

    static func view(_ view: NSView) -> ViewScopeInspectableReference {
        .view(ViewScopeWeakReference(view))
    }

    static func layer(_ layer: CALayer) -> ViewScopeInspectableReference {
        .layer(ViewScopeWeakReference(layer))
    }

    static func viewController(_ controller: NSViewController) -> ViewScopeInspectableReference {
        .viewController(ViewScopeWeakReference(controller))
    }

    /// 解析出的对象；对象已释放时返回 nil。
    var resolvedObject: AnyObject? {
        switch self {
        case .window(let reference):
            return reference.object
        case .view(let reference):
            return reference.object
        case .layer(let reference):
            return reference.object
        case .viewController(let reference):
            return reference.object
        case .object(let reference):
            return reference.object
        }
    }
}

/// 解析后的强引用快照，只在单次调用内部使用。
enum ViewScopeResolvedReference {
    case window(NSWindow)
    case view(NSView)
    case layer(CALayer)
    case viewController(NSViewController)
    case object(AnyObject)

    init?(_ reference: ViewScopeInspectableReference) {
        switch reference {
        case .window(let weak):
            guard let object = weak.object else {
                return nil
            }
            self = .window(object)
        case .view(let weak):
            guard let object = weak.object else {
                return nil
            }
            self = .view(object)
        case .layer(let weak):
            guard let object = weak.object else {
                return nil
            }
            self = .layer(object)
        case .viewController(let weak):
            guard let object = weak.object else {
                return nil
            }
            self = .viewController(object)
        case .object(let weak):
            guard let object = weak.object else {
                return nil
            }
            self = .object(object)
        }
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

    /// 单次遍历时的可变状态。
    private struct BuildState {
        var nodes: [String: ViewScopeHierarchyNode] = [:]
        var references: [String: ViewScopeInspectableReference] = [:]
        var visitedViews = Set<ObjectIdentifier>()
        var visitedLayers = Set<ObjectIdentifier>()
    }

    let hostInfo: ViewScopeHostInfo
    let interfaceLanguage: ViewScopeInterfaceLanguage

    init(hostInfo: ViewScopeHostInfo, interfaceLanguage: ViewScopeInterfaceLanguage = .english) {
        self.hostInfo = hostInfo
        self.interfaceLanguage = interfaceLanguage
    }

    /// 抓取当前应用所有窗口，构造完整 capture。
    ///
    /// 这里写入到 `node.frame` 的值，就是客户端可直接消费的统一画布坐标（左上角原点）。
    func makeCapture() -> (ViewScopeCapturePayload, ReferenceContext) {
        let start = Date()
        let captureID = UUID().uuidString
        let windows = NSApp.windows
            .filter { window in
                // 排除高亮浮层自身（B5）。
                guard isOverlayWindow(window) == false else {
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

        var state = BuildState()
        var rootNodeIDs: [String] = []
        for window in windows {
            let windowID = ViewScopeNodeIdentity.nodeID(kind: .window, object: window)
            let rootView = window.viewScopeRootView
            let windowBounds = window.viewScopeBounds
            state.nodes[windowID] = ViewScopeHierarchyNode(
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
                depth: 0,
                traits: windowTraits(for: window)
            )
            state.references[windowID] = .window(window)
            rootNodeIDs.append(windowID)

            guard let rootView else {
                continue
            }
            let rootNodeID = nodeID(forViewOrBackingLayer: rootView)
            if let rootLayer = rootView.layer {
                buildLayerNode(layer: rootLayer, rootView: rootView, nodeID: rootNodeID, parentID: windowID, depth: 1, state: &state)
            } else {
                buildViewNode(view: rootView, rootView: rootView, nodeID: rootNodeID, parentID: windowID, depth: 1, state: &state)
            }
            if state.nodes[rootNodeID] != nil {
                state.nodes[windowID]?.childIDs = [rootNodeID]
            }
        }

        let summary = ViewScopeCaptureSummary(
            nodeCount: state.nodes.count,
            windowCount: windows.count,
            visibleWindowCount: windows.filter(\.isVisible).count,
            captureDurationMilliseconds: Int(Date().timeIntervalSince(start) * 1000)
        )
        let capturedAt = Date()
        let context = ReferenceContext(nodeReferences: state.references, rootNodeIDs: rootNodeIDs, captureID: captureID)
        let nodePreviewScreenshots = makeNodePreviewScreenshots(
            nodes: state.nodes,
            context: context,
            capturedAt: capturedAt
        )

        var previewBitmaps: [ViewScopePreviewBitmap] = []
        let bitmapEncoder = ViewScopeImageEncoder()
        for window in windows {
            guard window.isVisible,
                  let rootView = window.viewScopeRootView,
                  rootView.bounds.width > 0, rootView.bounds.height > 0 else {
                continue
            }
            let rootNodeID = nodeID(forViewOrBackingLayer: rootView)
            if let image = makeWindowScreenshot(window: window),
               let base64 = bitmapEncoder.base64PNG(for: image) {
                previewBitmaps.append(ViewScopePreviewBitmap(
                    rootNodeID: rootNodeID,
                    pngBase64: base64,
                    size: image.size.viewScopeSize,
                    capturedAt: capturedAt,
                    scale: Double(window.backingScaleFactor)
                ))
            }
        }

        return (
            ViewScopeCapturePayload(
                host: hostInfo,
                capturedAt: capturedAt,
                summary: summary,
                rootNodeIDs: rootNodeIDs,
                nodes: state.nodes,
                captureID: captureID,
                previewBitmaps: previewBitmaps,
                nodePreviewScreenshots: nodePreviewScreenshots
            ),
            context
        )
    }

    func makeDetail(for nodeID: String, in context: ReferenceContext) -> ViewScopeNodeDetailPayload? {
        guard let reference = context.nodeReferences[nodeID],
              let resolved = ViewScopeResolvedReference(reference) else {
            return nil
        }

        switch resolved {
        case .window(let window):
            let image = makeWindowScreenshot(window: window)
            return ViewScopeNodeDetailPayload(
                nodeID: nodeID,
                host: hostInfo,
                sections: windowSections(for: window),
                constraints: [],
                ancestry: [sanitizedDisplayText(window.title) ?? interfaceLanguage.text("server.value.window_fallback")],
                screenshotRootNodeID: nodeID,
                screenshotPNGBase64: image.flatMap(ViewScopeImageEncoder().base64PNG),
                screenshotSize: image?.size.viewScopeSize ?? .zero,
                highlightedRect: window.viewScopeBounds.viewScopeRect,
                consoleTargets: makeConsoleTargets(for: resolved, nodeID: nodeID, context: context)
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
                consoleTargets: makeConsoleTargets(for: resolved, nodeID: nodeID, context: context)
            )
        case .layer(let layer):
            let screenshotRootView = screenshotRootView(for: layer)
            let image = screenshotRootView.flatMap { root in
                makeCanvasScreenshot(rootView: root)
            }
            let highlightRect = screenshotRootView.map { rootView -> ViewScopeRect in
                normalizedCanvasRect(for: layer, rootView: rootView)?.viewScopeRect ?? .zero
            } ?? .zero
            // 带宿主视图的 layer 节点：分区、约束都取宿主视图（B1）。
            let hostView = layer.viewScopeHostView
            return ViewScopeNodeDetailPayload(
                nodeID: nodeID,
                host: hostInfo,
                sections: hostView.map { viewSections(for: $0) } ?? layerSections(for: layer),
                constraints: hostView.map { constraintDescriptions(for: $0) } ?? [],
                ancestry: ancestry(for: layer),
                screenshotRootNodeID: screenshotRootView.flatMap { screenshotRootNodeID(for: $0, in: context) },
                screenshotPNGBase64: image.flatMap(ViewScopeImageEncoder().base64PNG),
                screenshotSize: image?.size.viewScopeSize ?? .zero,
                highlightedRect: highlightRect,
                consoleTargets: makeConsoleTargets(for: resolved, nodeID: nodeID, context: context)
            )
        case .viewController(let controller):
            return ViewScopeNodeDetailPayload(
                nodeID: nodeID,
                host: hostInfo,
                sections: [identityOnlySection(for: controller)],
                constraints: [],
                ancestry: [],
                screenshotRootNodeID: nil,
                screenshotPNGBase64: nil,
                screenshotSize: .zero,
                highlightedRect: .zero,
                consoleTargets: makeConsoleTargets(for: resolved, nodeID: nodeID, context: context)
            )
        case .object(let object):
            return ViewScopeNodeDetailPayload(
                nodeID: nodeID,
                host: hostInfo,
                sections: [identityOnlySection(for: object)],
                constraints: [],
                ancestry: [],
                screenshotRootNodeID: nil,
                screenshotPNGBase64: nil,
                screenshotSize: .zero,
                highlightedRect: .zero,
                consoleTargets: []
            )
        }
    }

    // MARK: - 节点构建

    /// 视图在树里的节点 ID：有 backing layer 时以 layer 节点出现，否则是 view 节点。
    func nodeID(forViewOrBackingLayer view: NSView) -> String {
        if let layer = view.layer {
            return ViewScopeNodeIdentity.nodeID(kind: .layer, object: layer)
        }
        return ViewScopeNodeIdentity.nodeID(kind: .view, object: view)
    }

    private func isOverlayWindow(_ window: NSWindow) -> Bool {
        if window is ViewScopeHighlightPanel {
            return true
        }
        return ViewScopeOverlayRegistry.isOverlayObject(window)
    }

    private func isOverlayView(_ view: NSView) -> Bool {
        ViewScopeOverlayRegistry.isOverlayObject(view)
    }

    private func buildViewNode(
        view: NSView,
        rootView: NSView,
        nodeID: String,
        parentID: String,
        depth: Int,
        state: inout BuildState
    ) {
        guard state.visitedViews.insert(ObjectIdentifier(view)).inserted else {
            return
        }
        let ivarTraces = view.viewScopeIvarTracesForNode
        let childIDs = buildChildNodeIDs(forView: view, rootView: rootView, depth: depth + 1, state: &state)

        state.nodes[nodeID] = ViewScopeHierarchyNode(
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
            eventHandlers: view.viewScopeEventHandlers(interfaceLanguage: interfaceLanguage).nonEmpty,
            traits: viewTraits(for: view, layer: view.layer)
        )
        state.references[nodeID] = .view(view)
    }

    private func buildLayerNode(
        layer: CALayer,
        rootView: NSView,
        nodeID: String,
        parentID: String,
        depth: Int,
        state: inout BuildState
    ) {
        guard state.visitedLayers.insert(ObjectIdentifier(layer)).inserted else {
            return
        }
        let ivarTraces = layer.viewScopeIvarTracesForNode
        let childIDs = buildChildNodeIDs(forLayer: layer, rootView: rootView, depth: depth + 1, state: &state)
        let layerClassName = NSStringFromClass(type(of: layer))
        let hostView = layer.viewScopeHostView

        state.nodes[nodeID] = ViewScopeHierarchyNode(
            id: nodeID,
            parentID: parentID,
            kind: .layer,
            className: layerClassName,
            hostViewClassName: hostView.map { NSStringFromClass(type(of: $0)) },
            title: sanitizedDisplayText(hostView?.viewScopeTitle(interfaceLanguage: interfaceLanguage))
                ?? ViewScopeClassNameFormatter.displayName(for: layerClassName),
            subtitle: sanitizedDisplayText(layer.viewScopeSpecialTraceForNode)
                ?? sanitizedDisplayText(hostView?.viewScopeSubtitle(interfaceLanguage: interfaceLanguage)),
            identifier: hostView.flatMap { sanitizedDisplayText($0.identifier?.rawValue) },
            address: layer.viewScopeAddress,
            frame: (normalizedCanvasRect(for: layer, rootView: rootView) ?? .zero).viewScopeRect,
            bounds: layer.bounds.viewScopeRect,
            childIDs: childIDs,
            isHidden: hostView?.isHidden ?? layer.isHidden,
            alphaValue: Double(hostView?.alphaValue ?? CGFloat(layer.opacity)),
            wantsLayer: true,
            isFlipped: hostView?.isFlipped ?? layer.isGeometryFlipped,
            clippingEnabled: layer.masksToBounds,
            depth: depth,
            ivarName: ivarTraces.first?.ivarName,
            ivarTraces: ivarTraces,
            // 只认“精确拥有该视图”的 VC（B4）。
            rootViewControllerClassName: hostView?.viewScopeExactRootViewControllerClassName,
            controlTargetClassName: (hostView as? NSControl)?.viewScopeTargetClassName,
            controlActionName: (hostView as? NSControl)?.viewScopeActionName,
            eventHandlers: hostView?.viewScopeEventHandlers(interfaceLanguage: interfaceLanguage).nonEmpty,
            traits: hostView.map { viewTraits(for: $0, layer: layer) } ?? layerTraits(for: layer)
        )
        state.references[nodeID] = .layer(layer)
    }

    private func buildChildNodeIDs(
        forView view: NSView,
        rootView: NSView,
        depth: Int,
        state: inout BuildState
    ) -> [String] {
        var childIDs: [String] = []
        for child in capturedChildViews(of: view) {
            appendChild(child, rootView: rootView, parentNodeID: nodeID(forViewOrBackingLayer: view), depth: depth, childIDs: &childIDs, state: &state)
        }
        return childIDs
    }

    private func appendChild(
        _ child: NSView,
        rootView: NSView,
        parentNodeID: String,
        depth: Int,
        childIDs: inout [String],
        state: inout BuildState
    ) {
        guard isOverlayView(child) == false else {
            return
        }
        let childNodeID = nodeID(forViewOrBackingLayer: child)
        if let childLayer = child.layer {
            buildLayerNode(layer: childLayer, rootView: rootView, nodeID: childNodeID, parentID: parentNodeID, depth: depth, state: &state)
        } else {
            buildViewNode(view: child, rootView: rootView, nodeID: childNodeID, parentID: parentNodeID, depth: depth, state: &state)
        }
        if state.nodes[childNodeID] != nil, childIDs.contains(childNodeID) == false {
            childIDs.append(childNodeID)
        }
    }

    private func buildChildNodeIDs(
        forLayer layer: CALayer,
        rootView: NSView,
        depth: Int,
        state: inout BuildState
    ) -> [String] {
        var childIDs: [String] = []
        var representedLayerIDs = Set<ObjectIdentifier>()
        let parentNodeID = ViewScopeNodeIdentity.nodeID(kind: .layer, object: layer)
        let hostView = layer.viewScopeHostView

        if let hostView {
            for childView in capturedChildViews(of: hostView) {
                if let childLayer = childView.layer {
                    representedLayerIDs.insert(ObjectIdentifier(childLayer))
                }
                appendChild(childView, rootView: rootView, parentNodeID: parentNodeID, depth: depth, childIDs: &childIDs, state: &state)
            }
        }

        for sublayer in layer.sublayers ?? [] {
            guard representedLayerIDs.contains(ObjectIdentifier(sublayer)) == false else {
                continue
            }
            if let hostView,
               let sublayerHostView = sublayer.viewScopeHostView,
               sublayerHostView === hostView || sublayerHostView.viewScopeIsDescendant(of: hostView) {
                continue
            }

            let childNodeID = ViewScopeNodeIdentity.nodeID(kind: .layer, object: sublayer)
            buildLayerNode(layer: sublayer, rootView: rootView, nodeID: childNodeID, parentID: parentNodeID, depth: depth, state: &state)
            if state.nodes[childNodeID] != nil, childIDs.contains(childNodeID) == false {
                childIDs.append(childNodeID)
            }
        }

        return childIDs
    }

    func capturedChildViews(of view: NSView) -> [NSView] {
        // 这里只补齐当前节点的一层直接孩子，整棵树的递归由 build*Node 完成。
        //
        // AppKit 有一些容器会把逻辑子节点藏在普通 `subviews` 之外，
        // 或者由复用/虚拟化机制托管，因此这里补充 `subviews` 不稳定覆盖的系统容器。
        var orderedChildren: [NSView] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ child: NSView?) {
            guard let child else {
                return
            }
            guard seen.insert(ObjectIdentifier(child)).inserted else {
                return
            }
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

    // MARK: - 截图

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

        // 宿主视图恰好是窗口 contentView 时，用它作截图根，避免把标题栏截进来。
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
        if let hostView = layer.viewScopeNearestHostView {
            return screenshotRootView(for: hostView)
        }
        return nil
    }

    /// 截图根在本次抓取中的节点 ID。视图可能在抓取之后才获得 layer（例如截图触发了 layer-backing），
    /// 所以 layer 节点与 view 节点两种 ID 都要尝试。
    private func screenshotRootNodeID(for view: NSView, in context: ReferenceContext) -> String? {
        if let layer = view.layer {
            let layerNodeID = ViewScopeNodeIdentity.nodeID(kind: .layer, object: layer)
            if context.nodeReferences[layerNodeID] != nil {
                return layerNodeID
            }
        }
        let viewNodeID = ViewScopeNodeIdentity.nodeID(kind: .view, object: view)
        return context.nodeReferences[viewNodeID] != nil ? viewNodeID : nil
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
                  node.bounds.width > 2,
                  node.bounds.height > 2,
                  node.childIDs.isEmpty == false,
                  let reference = context.nodeReferences[nodeID],
                  let resolved = ViewScopeResolvedReference(reference) else {
                return nil
            }
            // 深层且孩子很少的节点不生成 solo 图，控制抓取耗时。
            if node.depth > 4, node.childIDs.count <= 3 {
                return nil
            }

            if debugNodePreview {
                fputs("node-preview \(nodeID) \(node.className)\n", stderr)
                fflush(stderr)
            }

            let soloImage: NSImage?
            let size: CGSize
            let window: NSWindow?
            switch resolved {
            case .view(let view):
                // 无 layer 的视图拿不到“自身内容”，solo 图会是全透明，直接跳过（B10）。
                guard view.window?.contentView !== view,
                      view.window?.isVisible == true else {
                    return nil
                }
                soloImage = makeSoloViewScreenshot(view: view)
                size = view.bounds.size
                window = view.window
            case .layer(let layer):
                guard let hostView = layer.viewScopeHostView,
                      hostView.window?.contentView !== hostView,
                      hostView.window?.isVisible == true else {
                    return nil
                }
                soloImage = makeSoloLayerScreenshot(layer: layer, hostView: hostView)
                size = layer.bounds.size
                window = hostView.window
            case .window, .viewController, .object:
                return nil
            }

            guard let soloPNGBase64 = soloImage.flatMap(encoder.base64PNG) else {
                return nil
            }
            return ViewScopeNodePreviewScreenshotSet(
                nodeID: nodeID,
                groupPNGBase64: nil,
                soloPNGBase64: soloPNGBase64,
                size: size.viewScopeSize,
                capturedAt: capturedAt,
                scale: Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
            )
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
        return rasterizedScreenshot(image)
    }

    /// 无 layer 视图的 solo 图：只能画出它自身 layer 的背景/边框；没有 layer 时返回 nil（B10）。
    private func makeSoloViewScreenshot(view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }
        guard let layerImage = makeOwnLayerScreenshot(for: view) else {
            return nil
        }
        return rasterizedScreenshot(layerImage)
    }

    /// Returns true for layers that use (or are nested inside) a compositor-backed view such as
    /// NSVisualEffectView or NSGlassEffectView, and therefore cannot safely be rendered via
    /// CALayer.render(in:) in an off-screen context (the compositor must own the render pass).
    private func isCompositorRenderedLayer(_ layer: CALayer) -> Bool {
        var current: CALayer? = layer
        while let candidate = current {
            if let hostView = candidate.viewScopeHostView {
                if hostView is NSVisualEffectView {
                    return true
                }
                if #available(macOS 26.0, *), hostView is NSGlassEffectView {
                    return true
                }
                // 找到普通宿主视图，下面的层级可以安全渲染。
                return false
            }
            current = candidate.superlayer
        }
        return false
    }

    /// 带宿主视图的 layer 的 solo 图：临时隐藏 sublayer 后只画自身内容。
    ///
    /// 截图方向统一走 `makeDirectViewScreenshot`（B8），不再有单独的纯 CALayer 渲染分支。
    private func makeSoloLayerScreenshot(layer: CALayer, hostView: NSView) -> NSImage? {
        guard layer.bounds.width > 0, layer.bounds.height > 0 else {
            return nil
        }
        guard isCompositorRenderedLayer(layer) == false else {
            return nil
        }

        let hiddenStates = (layer.sublayers ?? []).map { sublayer in
            (layer: sublayer, isHidden: sublayer.isHidden)
        }
        // 关闭隐式动画，避免临时隐藏/恢复在宿主界面上产生闪烁（B9）。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (sublayer, isHidden) in hiddenStates where isHidden == false {
            sublayer.isHidden = true
        }
        defer {
            for (sublayer, isHidden) in hiddenStates {
                sublayer.isHidden = isHidden
            }
            CATransaction.commit()
        }

        guard let image = makeDirectViewScreenshot(view: hostView) else {
            return nil
        }
        return rasterizedScreenshot(image)
    }

    /// 直接截取单个视图。
    ///
    /// 方向约定（所有截图路径共用这一处实现，B8）：
    /// - 显式 layer-backed 视图走 `layer.render(in:)`，绘制上下文使用 `lockFocusFlipped(layer.isGeometryFlipped)`；
    ///   已用独立脚本对 flipped / 非 flipped 根视图分别实测（红上蓝下的视图渲染后仍是红上蓝下），
    ///   旧实现 `!layer.isGeometryFlipped` 会把两种视图都画成上下颠倒；
    /// - 隐式 layer-backing（`wantsLayer == false`）走 `cacheDisplay`，由 AppKit 自己处理方向。
    /// 后续绘制均使用 `respectFlipped: false` 原样贴图，不再做额外翻转（旧代码注释声称会翻转，实际并未翻转）。
    private func makeDirectViewScreenshot(view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }

        // NSVisualEffectView / NSGlassEffectView 由窗口合成器渲染，离屏 layer.render 会崩溃，退回 cacheDisplay。
        if view.wantsLayer, let layer = view.layer {
            var usesCompositorRendering = view is NSVisualEffectView
            if !usesCompositorRendering, #available(macOS 26.0, *) {
                usesCompositorRendering = view is NSGlassEffectView
            }
            if !usesCompositorRendering {
                let image = NSImage(size: view.bounds.size)
                // 上下文翻转与 layer.isGeometryFlipped 保持一致，渲染结果才是视觉正立（见函数注释）。
                image.lockFocusFlipped(layer.isGeometryFlipped)
                defer {
                    image.unlockFocus()
                }
                guard let context = NSGraphicsContext.current?.cgContext else {
                    return nil
                }
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
        let image = NSImage(size: view.bounds.size)
        image.lockFocusFlipped(true)
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: view.bounds.size).fill()

        if !shouldSkipDirectCompositeBase(for: view, inheritsCompositeCapture: inheritsCompositeCapture),
           let baseImage = makeDirectViewScreenshot(view: view) {
            rasterizedScreenshot(baseImage).draw(
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

    /// 只画视图自身 layer 的背景与边框（不含子视图）；视图没有 layer 时返回 nil。
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

    /// 画布级截图：根视图是窗口 frame 根（NSThemeFrame）时优先用窗口合成截图，
    /// 这样 NSGlassEffectView / NSVisualEffectView 等合成器内容也能正确显示。
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

    /// 把截图重新栅格化到一个普通 NSImage 中（视觉方向保持不变）。
    ///
    /// 输入图像已经是视觉正立的（见 `makeDirectViewScreenshot` 注释），这里用 `respectFlipped: false`
    /// 原样绘制，只是把 CGImage/缓存表示统一成位图，便于后续 PNG 编码；不做任何翻转。
    private func rasterizedScreenshot(_ image: NSImage) -> NSImage {
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocusFlipped(false)
        defer {
            result.unlockFocus()
        }
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

    // MARK: - 坐标

    func normalizedCanvasRect(for view: NSView, in rootView: NSView) -> NSRect {
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

    /// layer 的画布坐标。
    ///
    /// - 带宿主视图：直接按宿主视图计算；
    /// - 纯 CALayer：先转换到最近的“带宿主视图的祖先 layer”坐标（其坐标与宿主视图坐标一致），
    ///   再由宿主视图转换到画布根（修复 B3：不再相对错误的 layer 计算后按根视图高度翻转）。
    func normalizedCanvasRect(for layer: CALayer, rootView: NSView) -> NSRect? {
        if let hostView = layer.viewScopeHostView {
            return normalizedCanvasRect(for: hostView, in: rootView)
        }
        var ancestor = layer.superlayer
        while let candidate = ancestor {
            if let hostView = candidate.viewScopeHostView {
                let rectInHost = candidate.convert(layer.bounds, from: layer)
                let rectInRoot = hostView.convert(rectInHost, to: rootView)
                guard rootView.isFlipped == false else {
                    return rectInRoot
                }
                return NSRect(
                    x: rectInRoot.origin.x,
                    y: rootView.bounds.height - rectInRoot.maxY,
                    width: rectInRoot.width,
                    height: rectInRoot.height
                )
            }
            ancestor = candidate.superlayer
        }
        return nil
    }

    // MARK: - 祖先链与约束

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
            if let hostView = current.viewScopeHostView {
                chain.append(contentsOf: ancestry(for: hostView).reversed())
                return chain.reversed()
            }
            chain.append(ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: current))))
            cursor = current.superlayer
        }
        if let title = sanitizedDisplayText(layer.viewScopeWindow?.title), !title.isEmpty {
            chain.append(title)
        }
        return chain.reversed()
    }

    /// 与视图相关的约束：自身持有的 + 父视图中引用它的。
    func relatedConstraints(for view: NSView) -> [NSLayoutConstraint] {
        var allConstraints = view.constraints
        if let superview = view.superview {
            allConstraints.append(contentsOf: superview.constraints.filter { constraint in
                (constraint.firstItem as AnyObject?) === view || (constraint.secondItem as AnyObject?) === view
            })
        }
        return allConstraints
    }

    private func constraintDescriptions(for view: NSView) -> [String] {
        let descriptions = relatedConstraints(for: view).map { constraint -> String in
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
        return "\(className).\(attribute.viewScopeName)"
    }

    // MARK: - Console targets

    private func makeConsoleTargets(
        for reference: ViewScopeResolvedReference,
        nodeID: String,
        context: ReferenceContext
    ) -> [ViewScopeConsoleTargetDescriptor] {
        var targets: [ViewScopeConsoleTargetDescriptor] = []
        func append(_ object: AnyObject, kind: ViewScopeRemoteObjectReference.Kind) {
            targets.append(makeConsoleTargetDescriptor(object: object, kind: kind, sourceNodeID: nodeID, captureID: context.captureID))
        }

        switch reference {
        case .window(let window):
            append(window, kind: .window)
        case .view(let view):
            append(view, kind: .view)
            if let controller = view.viewScopeExactRootOwningViewController {
                append(controller, kind: .viewController)
            }
        case .layer(let layer):
            append(layer, kind: .layer)
            if let hostView = layer.viewScopeHostView {
                append(hostView, kind: .view)
                // 只给精确拥有宿主视图的 VC（B4）。
                if let controller = hostView.viewScopeExactRootOwningViewController {
                    append(controller, kind: .viewController)
                }
            }
        case .viewController(let controller):
            append(controller, kind: .viewController)
        case .object:
            break
        }
        return targets
    }

    private func makeConsoleTargetDescriptor(
        object: AnyObject,
        kind: ViewScopeRemoteObjectReference.Kind,
        sourceNodeID: String?,
        captureID: String
    ) -> ViewScopeConsoleTargetDescriptor {
        let className = NSStringFromClass(type(of: object))
        let address = ViewScopeNodeIdentity.address(of: object)
        let referencePayload = ViewScopeRemoteObjectReference(
            captureID: captureID,
            objectID: address,
            kind: kind,
            className: className,
            address: address,
            sourceNodeID: sourceNodeID
        )
        let displayName = ViewScopeClassNameFormatter.displayName(for: className)
        return ViewScopeConsoleTargetDescriptor(
            reference: referencePayload,
            title: "<\(displayName): \(address)>",
            subtitle: displayName
        )
    }

    // MARK: - 通用工具

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        interfaceLanguage.text(key, arguments: arguments)
    }

    func sanitizedDisplayText(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let sanitized = value.viewScopeSanitizedSingleLine
        return sanitized.isEmpty ? nil : sanitized
    }
}

// MARK: - AppKit 扩展

extension NSView {
    /// 非精确的 VC 查找：返回“包含”该视图的最深层 VC。仅用于兜底展示，不用于 console target。
    var viewScopeOwningViewController: NSViewController? {
        guard let windowController = window?.contentViewController else {
            return nil
        }
        return windowController.viewScopeOwningController(containing: self)
    }

    var viewScopeExactRootViewControllerClassName: String? {
        viewScopeExactRootOwningViewController.map { NSStringFromClass(type(of: $0)) }
    }

    /// 精确拥有该视图的 VC（`controller.view === self`）。
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
        ViewScopeNodeIdentity.address(of: self)
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

extension CALayer {
    /// 自身或最近祖先 layer 的宿主视图。
    @MainActor
    var viewScopeNearestHostView: NSView? {
        var current: CALayer? = self
        while let candidate = current {
            if let hostView = candidate.viewScopeHostView {
                return hostView
            }
            current = candidate.superlayer
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

extension NSLayoutConstraint.Attribute {
    var viewScopeName: String {
        switch self {
        case .left:
            return "left"
        case .right:
            return "right"
        case .top:
            return "top"
        case .bottom:
            return "bottom"
        case .leading:
            return "leading"
        case .trailing:
            return "trailing"
        case .width:
            return "width"
        case .height:
            return "height"
        case .centerX:
            return "centerX"
        case .centerY:
            return "centerY"
        case .lastBaseline:
            return "lastBaseline"
        case .firstBaseline:
            return "firstBaseline"
        case .notAnAttribute:
            return "notAnAttribute"
        @unknown default:
            return String(rawValue)
        }
    }
}

extension NSWindow {
    var viewScopeAddress: String {
        ViewScopeNodeIdentity.address(of: self)
    }

    var viewScopeRootView: NSView? {
        contentView?.superview ?? contentView
    }

    var viewScopeBounds: NSRect {
        NSRect(origin: .zero, size: frame.size)
    }

    /// 窗口合成截图。`CGWindowListCreateImage` 在 macOS 15 起被标记为 obsoleted，
    /// 这里通过运行时符号查找调用；不可用或失败时返回 nil，由调用方回退到视图截图。
    var viewScopeSnapshotImage: NSImage? {
        // windowNumber 可能超出 CGWindowID（UInt32）范围（例如尚未真正上屏的窗口），
        // 直接 `CGWindowID(windowNumber)` 会在宿主进程里 trap，这里用 exactly 安全转换。
        guard windowNumber > 0,
              let windowID = CGWindowID(exactly: windowNumber),
              let cgImage = ViewScopeWindowImageCapturer.image(windowID: windowID) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: frame.size)
    }
}

/// 通过 dlsym 调用 `CGWindowListCreateImage`，避免新 SDK 上的编译期不可用错误。
enum ViewScopeWindowImageCapturer {
    private typealias CreateImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let createImage: CreateImageFunction? = {
        // RTLD_DEFAULT（-2）：在所有已加载镜像中查找符号。
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CreateImageFunction.self)
    }()

    static func image(windowID: CGWindowID) -> CGImage? {
        guard let createImage else {
            return nil
        }
        // kCGWindowListOptionIncludingWindow = 1 << 3；kCGWindowImageBoundsIgnoreFraming = 1 << 0。
        return createImage(.null, 1 << 3, windowID, 1 << 0)?.takeRetainedValue()
    }
}

extension NSControl {
    var viewScopeTargetClassName: String? {
        guard let target else {
            return nil
        }
        return NSStringFromClass(type(of: target))
    }

    var viewScopeActionName: String? {
        guard let action else {
            return nil
        }
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
            id: "control-\(ViewScopeNodeIdentity.address(of: self))",
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
            id: "gesture-\(ViewScopeNodeIdentity.address(of: self))",
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

extension NSRect {
    var viewScopeRect: ViewScopeRect {
        ViewScopeRect(
            x: ViewScopeNumberConversion.finite(Double(origin.x)),
            y: ViewScopeNumberConversion.finite(Double(origin.y)),
            width: ViewScopeNumberConversion.finite(Double(size.width)),
            height: ViewScopeNumberConversion.finite(Double(size.height))
        )
    }

    var viewScopeString: String {
        String(format: "x %.1f y %.1f w %.1f h %.1f", origin.x, origin.y, size.width, size.height)
    }
}

extension NSSize {
    var viewScopeSize: ViewScopeSize {
        ViewScopeSize(
            width: ViewScopeNumberConversion.finite(Double(width)),
            height: ViewScopeNumberConversion.finite(Double(height))
        )
    }

    /// AppKit 用 -1（`NSView.noIntrinsicMetric`）表示没有固有尺寸。
    var viewScopeHasIntrinsicMetric: Bool {
        width != -1 && height != -1
    }

    func viewScopeString(interfaceLanguage: ViewScopeInterfaceLanguage) -> String {
        if viewScopeHasIntrinsicMetric == false {
            return interfaceLanguage.text("server.value.no_intrinsic_size")
        }
        return String(format: "w %.1f h %.1f", width, height)
    }
}

extension Bool {
    func viewScopeBoolText(interfaceLanguage: ViewScopeInterfaceLanguage) -> String {
        self ? interfaceLanguage.text("server.value.yes") : interfaceLanguage.text("server.value.no")
    }
}

extension NSLayoutConstraint.Relation {
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

extension CGColor {
    /// sRGB 下的 #RRGGBBAA。
    var viewScopeHexString: String? {
        ViewScopeColorParsing.hexString(from: self)
    }
}

extension NSColor {
    /// 由 #RRGGBB / #RRGGBBAA 构造 sRGB 颜色（B13：不再使用 deviceRGB）。
    static func kg_viewScopeColor(hexString: String) -> NSColor? {
        guard let rgba = ViewScopeColorParsing.rgba(fromHex: hexString) else {
            return nil
        }
        return NSColor(srgbRed: CGFloat(rgba.red), green: CGFloat(rgba.green), blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha))
    }
}

extension NSEdgeInsets {
    var viewScopeString: String {
        String(format: "t %.1f l %.1f b %.1f r %.1f", top, left, bottom, right)
    }
}

extension String {
    var viewScopeSanitizedSingleLine: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension Array {
    var nonEmpty: Self? {
        isEmpty ? nil : self
    }
}
#endif
