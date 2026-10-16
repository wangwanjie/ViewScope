#if os(iOS)
import Foundation
import ObjectiveC.runtime
import UIKit

/// 节点引用：关联值全部是弱引用包装，避免 `lastReferenceContext` 强持有整棵视图树（审计 A9）。
enum ViewScopeInspectableReference {
    case window(ViewScopeWeakReference<UIWindow>)
    case view(ViewScopeWeakReference<UIView>)
    case layer(ViewScopeWeakReference<CALayer>)
    case viewController(ViewScopeWeakReference<UIViewController>)
    case object(ViewScopeWeakReference<AnyObject>)

    /// 解析出的对象；对象已释放时返回 nil。
    var resolvedObject: AnyObject? {
        switch self {
        case .window(let box):
            return box.object
        case .view(let box):
            return box.object
        case .layer(let box):
            return box.object
        case .viewController(let box):
            return box.object
        case .object(let box):
            return box.object
        }
    }

    /// 根据对象的实际类型生成引用。
    static func wrapping(_ object: AnyObject) -> ViewScopeInspectableReference {
        switch object {
        case let window as UIWindow:
            return .window(ViewScopeWeakReference(window))
        case let view as UIView:
            return .view(ViewScopeWeakReference(view))
        case let layer as CALayer:
            return .layer(ViewScopeWeakReference(layer))
        case let controller as UIViewController:
            return .viewController(ViewScopeWeakReference(controller))
        default:
            return .object(ViewScopeWeakReference(object))
        }
    }
}

/// UIKit 抓取端总入口：把宿主 UIKit 视图树转换成 ViewScope 可传输的数据模型。
///
/// 节点结构与 macOS 保持一致：
/// - `.window` 节点的唯一子节点是 UIWindow 自身 layer 的节点；
/// - 每个 UIView 输出为带 `hostViewClassName` 的 `.layer` 节点；
/// - 不承载视图的纯 CALayer 输出为不带 `hostViewClassName` 的 `.layer` 节点。
///
/// 坐标：`node.frame` 是相对所在窗口的左上角原点画布坐标（UIKit 天然左上原点），`isFlipped` 恒为 true。
@MainActor
final class ViewScopeSnapshotBuilder {
    struct ReferenceContext {
        var nodeReferences: [String: ViewScopeInspectableReference]
        var rootNodeIDs: [String]
        var captureID: String
    }

    /// 单次抓取的可变状态。
    private struct CaptureState {
        var nodes: [String: ViewScopeHierarchyNode] = [:]
        var references: [String: ViewScopeInspectableReference] = [:]
        var visitedLayers = Set<ObjectIdentifier>()
    }

    /// 单次抓取最多生成的 solo 截图数量，避免节点很多时 PNG 编码拖慢主线程。
    private static let maximumSoloScreenshotCount = 200

    private let hostInfo: ViewScopeHostInfo
    private let interfaceLanguage: ViewScopeInterfaceLanguage
    private let sectionBuilder: ViewScopeUIKitDetailSectionBuilder

    init(hostInfo: ViewScopeHostInfo, interfaceLanguage: ViewScopeInterfaceLanguage = .english) {
        self.hostInfo = hostInfo
        self.interfaceLanguage = interfaceLanguage
        self.sectionBuilder = ViewScopeUIKitDetailSectionBuilder(language: interfaceLanguage)
    }

    // MARK: - Capture

    func makeCapture() -> (ViewScopeCapturePayload, ReferenceContext) {
        let start = Date()
        let captureID = UUID().uuidString
        let windows = Self.capturableWindows()

        let traceStore = ViewScopeUIKitTraceStore()
        traceStore.reload(windows: windows, isExcluded: Self.isExcluded)

        var state = CaptureState()
        var rootNodeIDs: [String] = []
        for window in windows {
            let windowNodeID = ViewScopeNodeIdentity.nodeID(kind: .window, object: window)
            let canvasBounds = CGRect(origin: .zero, size: window.bounds.size)
            let rootLayerNodeID = buildLayerNode(
                layer: window.layer,
                window: window,
                parentID: windowNodeID,
                depth: 1,
                traceStore: traceStore,
                state: &state
            )
            state.nodes[windowNodeID] = ViewScopeHierarchyNode(
                id: windowNodeID,
                parentID: nil,
                kind: .window,
                className: NSStringFromClass(type(of: window)),
                title: windowTitle(for: window),
                subtitle: windowSubtitle(for: window),
                identifier: Self.sanitized(window.accessibilityIdentifier),
                address: ViewScopeNodeIdentity.address(of: window),
                frame: canvasBounds.kg_viewScopeRect,
                bounds: canvasBounds.kg_viewScopeRect,
                childIDs: rootLayerNodeID.map { [$0] } ?? [],
                isHidden: window.isHidden,
                alphaValue: Double(window.alpha),
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: true,
                depth: 0
            )
            state.references[windowNodeID] = .window(ViewScopeWeakReference(window))
            rootNodeIDs.append(windowNodeID)
        }

        let capturedAt = Date()
        let context = ReferenceContext(nodeReferences: state.references, rootNodeIDs: rootNodeIDs, captureID: captureID)

        // 截图前临时隐藏高亮浮层，避免它出现在预览里。
        let restoreOverlays = Self.hideActiveOverlays()
        defer {
            restoreOverlays()
        }

        let encoder = ViewScopeImageEncoder()
        var previewBitmaps: [ViewScopePreviewBitmap] = []
        for window in windows where Self.isVisible(window) {
            guard let image = makeWindowScreenshot(window),
                  let base64 = encoder.base64PNG(for: image) else {
                continue
            }
            previewBitmaps.append(ViewScopePreviewBitmap(
                rootNodeID: ViewScopeNodeIdentity.nodeID(kind: .layer, object: window.layer),
                pngBase64: base64,
                size: image.size.kg_viewScopeSize,
                capturedAt: capturedAt,
                scale: Double(Self.scale(of: window))
            ))
        }

        let nodePreviewScreenshots = makeNodePreviewScreenshots(
            windows: windows,
            nodes: state.nodes,
            context: context,
            capturedAt: capturedAt
        )

        let summary = ViewScopeCaptureSummary(
            nodeCount: state.nodes.count,
            windowCount: windows.count,
            visibleWindowCount: windows.filter(Self.isVisible).count,
            captureDurationMilliseconds: Int(Date().timeIntervalSince(start) * 1000)
        )

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

    /// 递归构建 layer 节点，返回节点 ID；被排除或重复访问时返回 nil。
    private func buildLayerNode(
        layer: CALayer,
        window: UIWindow,
        parentID: String,
        depth: Int,
        traceStore: ViewScopeUIKitTraceStore,
        state: inout CaptureState
    ) -> String? {
        guard Self.isExcluded(layer) == false,
              state.visitedLayers.insert(ObjectIdentifier(layer)).inserted else {
            return nil
        }
        let hostView = layer.kg_viewScopeHostView
        if let hostView, Self.isExcluded(hostView) {
            return nil
        }

        let nodeID = ViewScopeNodeIdentity.nodeID(kind: .layer, object: layer)
        var childIDs: [String] = []

        // sublayers 的顺序就是 z 序；子视图的 layer 必然出现在其中。
        for sublayer in layer.sublayers ?? [] {
            if let childID = buildLayerNode(
                layer: sublayer,
                window: window,
                parentID: nodeID,
                depth: depth + 1,
                traceStore: traceStore,
                state: &state
            ) {
                childIDs.append(childID)
            }
        }
        // 防御：极少数情况下子视图的 layer 不在 sublayers 中（例如被手工挪走），补在最后。
        if let hostView {
            for subview in hostView.subviews where subview.layer.superlayer !== layer {
                if let childID = buildLayerNode(
                    layer: subview.layer,
                    window: window,
                    parentID: nodeID,
                    depth: depth + 1,
                    traceStore: traceStore,
                    state: &state
                ) {
                    childIDs.append(childID)
                }
            }
        }

        let layerClassName = NSStringFromClass(type(of: layer))
        let traceObject: AnyObject = hostView ?? layer
        let ivarTraces = traceStore.traces(forNodeObject: traceObject)
        let canvasRect = Self.canvasRect(for: layer, hostView: hostView, in: window)

        if let hostView {
            let control = hostView as? UIControl
            let primaryTargetAction = control.flatMap(ViewScopeUIKitViewDescriber.primaryTargetAction)
            state.nodes[nodeID] = ViewScopeHierarchyNode(
                id: nodeID,
                parentID: parentID,
                kind: .layer,
                className: layerClassName,
                hostViewClassName: NSStringFromClass(type(of: hostView)),
                title: ViewScopeUIKitViewDescriber.title(for: hostView, language: interfaceLanguage)
                    ?? ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: hostView))),
                subtitle: Self.sanitized(traceStore.specialTrace(for: hostView))
                    ?? ViewScopeUIKitViewDescriber.subtitle(for: hostView, language: interfaceLanguage),
                identifier: Self.sanitized(hostView.accessibilityIdentifier),
                address: ViewScopeNodeIdentity.address(of: hostView),
                frame: canvasRect.kg_viewScopeRect,
                bounds: hostView.bounds.kg_viewScopeRect,
                childIDs: childIDs,
                isHidden: hostView.isHidden,
                alphaValue: Double(hostView.alpha),
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: hostView.clipsToBounds,
                depth: depth,
                ivarName: ivarTraces.first?.ivarName,
                ivarTraces: ivarTraces,
                rootViewControllerClassName: hostView.kg_viewScopeExactViewController.map { NSStringFromClass(type(of: $0)) },
                controlTargetClassName: primaryTargetAction?.targetClassName,
                controlActionName: primaryTargetAction?.actionName,
                eventHandlers: ViewScopeUIKitViewDescriber.eventHandlers(for: hostView, idPrefix: nodeID).kg_viewScopeNonEmpty,
                traits: ViewScopeUIKitViewDescriber.traits(for: hostView)
            )
        } else {
            state.nodes[nodeID] = ViewScopeHierarchyNode(
                id: nodeID,
                parentID: parentID,
                kind: .layer,
                className: layerClassName,
                hostViewClassName: nil,
                title: ViewScopeClassNameFormatter.displayName(for: layerClassName),
                subtitle: Self.sanitized(traceStore.specialTrace(for: layer)) ?? Self.sanitized(layer.name),
                identifier: Self.sanitized(layer.name),
                address: ViewScopeNodeIdentity.address(of: layer),
                frame: canvasRect.kg_viewScopeRect,
                bounds: layer.bounds.kg_viewScopeRect,
                childIDs: childIDs,
                isHidden: layer.isHidden,
                alphaValue: Double(layer.opacity),
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: layer.masksToBounds,
                depth: depth,
                ivarName: ivarTraces.first?.ivarName,
                ivarTraces: ivarTraces,
                traits: ViewScopeUIKitViewDescriber.traits(for: layer)
            )
        }
        state.references[nodeID] = .layer(ViewScopeWeakReference(layer))
        return nodeID
    }

    // MARK: - Detail

    func makeDetail(for nodeID: String, in context: ReferenceContext) -> ViewScopeNodeDetailPayload? {
        guard let reference = context.nodeReferences[nodeID],
              let object = reference.resolvedObject else {
            return nil
        }

        let restoreOverlays = Self.hideActiveOverlays()
        defer {
            restoreOverlays()
        }

        let sections: [ViewScopePropertySection]
        var constraints: [String] = []
        let ancestry: [String]
        let window: UIWindow?
        let highlightRect: CGRect

        switch object {
        case let targetWindow as UIWindow:
            sections = sectionBuilder.windowSections(for: targetWindow)
            constraints = sectionBuilder.constraintDescriptions(for: targetWindow)
            ancestry = [windowTitle(for: targetWindow)]
            window = targetWindow
            highlightRect = CGRect(origin: .zero, size: targetWindow.bounds.size)
        case let layer as CALayer:
            let hostView = layer.kg_viewScopeHostView
            let layerWindow = layer.kg_viewScopeWindow
            if let hostView {
                sections = sectionBuilder.viewSections(for: hostView)
                constraints = sectionBuilder.constraintDescriptions(for: hostView)
            } else {
                sections = sectionBuilder.layerSections(for: layer)
            }
            ancestry = self.ancestry(for: layer)
            window = layerWindow
            highlightRect = layerWindow.map { Self.canvasRect(for: layer, hostView: hostView, in: $0) } ?? .zero
        case let view as UIView:
            sections = sectionBuilder.viewSections(for: view)
            constraints = sectionBuilder.constraintDescriptions(for: view)
            ancestry = self.ancestry(for: view.layer)
            window = view.window
            highlightRect = view.window.map { Self.canvasRect(for: view.layer, hostView: view, in: $0) } ?? .zero
        case let controller as UIViewController:
            sections = sectionBuilder.controllerSections(for: controller)
            ancestry = []
            window = controller.viewIfLoaded?.window
            if let view = controller.viewIfLoaded, let window {
                highlightRect = Self.canvasRect(for: view.layer, hostView: view, in: window)
            } else {
                highlightRect = .zero
            }
        default:
            sections = sectionBuilder.objectSections(for: object)
            ancestry = []
            window = nil
            highlightRect = .zero
        }

        let image = window.flatMap { Self.isVisible($0) ? makeWindowScreenshot($0) : nil }
        return ViewScopeNodeDetailPayload(
            nodeID: nodeID,
            host: hostInfo,
            sections: sections,
            constraints: constraints,
            ancestry: ancestry,
            screenshotRootNodeID: window.map { ViewScopeNodeIdentity.nodeID(kind: .layer, object: $0.layer) },
            screenshotPNGBase64: image.flatMap { ViewScopeImageEncoder().base64PNG(for: $0) },
            screenshotSize: image?.size.kg_viewScopeSize ?? .zero,
            highlightedRect: highlightRect.kg_viewScopeRect,
            consoleTargets: makeConsoleTargets(for: object, nodeID: nodeID, context: context)
        )
    }

    /// 从窗口到节点的标题链。
    private func ancestry(for layer: CALayer) -> [String] {
        var chain: [String] = []
        var current: CALayer? = layer
        while let currentLayer = current {
            if let hostView = currentLayer.kg_viewScopeHostView {
                chain.append(
                    ViewScopeUIKitViewDescriber.title(for: hostView, language: interfaceLanguage)
                        ?? ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: hostView)))
                )
            } else {
                chain.append(ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: currentLayer))))
            }
            current = currentLayer.superlayer
        }
        return chain.reversed()
    }

    // MARK: - Console targets

    /// console target：layer、宿主视图、精确拥有该视图的 VC（`controller.view === hostView`）。
    private func makeConsoleTargets(for object: AnyObject, nodeID: String, context: ReferenceContext) -> [ViewScopeConsoleTargetDescriptor] {
        var targets: [ViewScopeConsoleTargetDescriptor] = []
        switch object {
        case let window as UIWindow:
            targets.append(consoleTarget(window, kind: .window, nodeID: nodeID, context: context))
            if let controller = window.rootViewController {
                targets.append(consoleTarget(controller, kind: .viewController, nodeID: nodeID, context: context))
            }
        case let layer as CALayer:
            targets.append(consoleTarget(layer, kind: .layer, nodeID: nodeID, context: context))
            if let hostView = layer.kg_viewScopeHostView {
                let kind: ViewScopeRemoteObjectReference.Kind = hostView is UIWindow ? .window : .view
                targets.append(consoleTarget(hostView, kind: kind, nodeID: nodeID, context: context))
                if let controller = hostView.kg_viewScopeExactViewController {
                    targets.append(consoleTarget(controller, kind: .viewController, nodeID: nodeID, context: context))
                }
            }
        case let view as UIView:
            targets.append(consoleTarget(view, kind: .view, nodeID: nodeID, context: context))
            if let controller = view.kg_viewScopeExactViewController {
                targets.append(consoleTarget(controller, kind: .viewController, nodeID: nodeID, context: context))
            }
        case let controller as UIViewController:
            targets.append(consoleTarget(controller, kind: .viewController, nodeID: nodeID, context: context))
        default:
            break
        }
        return targets
    }

    private func consoleTarget(
        _ object: AnyObject,
        kind: ViewScopeRemoteObjectReference.Kind,
        nodeID: String,
        context: ReferenceContext
    ) -> ViewScopeConsoleTargetDescriptor {
        let className = NSStringFromClass(type(of: object))
        let address = ViewScopeNodeIdentity.address(of: object)
        let reference = ViewScopeRemoteObjectReference(
            captureID: context.captureID,
            objectID: address,
            kind: kind,
            className: className,
            address: address,
            sourceNodeID: nodeID
        )
        let displayName = ViewScopeClassNameFormatter.displayName(for: className)
        return ViewScopeConsoleTargetDescriptor(
            reference: reference,
            title: "<\(displayName): \(address)>",
            subtitle: displayName
        )
    }

    // MARK: - 截图

    /// 窗口截图：优先 `drawHierarchy`（能拿到 UIVisualEffectView 等合成内容），失败时退回 `layer.render(in:)`。
    private func makeWindowScreenshot(_ window: UIWindow) -> UIImage? {
        let size = window.bounds.size
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        // 窗口上挂着（已被临时隐藏的）高亮浮层时，必须等待屏幕更新才能让隐藏生效。
        let needsScreenUpdates = window.subviews.contains { Self.isExcluded($0) }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: Self.rendererFormat(scale: Self.scale(of: window)))
        return renderer.image { context in
            let drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: needsScreenUpdates)
            if drawn == false {
                window.layer.render(in: context.cgContext)
            }
        }
    }

    /// 节点 solo 截图：只渲染节点自身 layer，临时隐藏全部 sublayer（禁用隐式动画，渲染后立即恢复）。
    private func makeNodePreviewScreenshots(
        windows: [UIWindow],
        nodes: [String: ViewScopeHierarchyNode],
        context: ReferenceContext,
        capturedAt: Date
    ) -> [ViewScopeNodePreviewScreenshotSet] {
        let visibleWindowIDs = Set(windows.filter(Self.isVisible).map { ObjectIdentifier($0) })
        let encoder = ViewScopeImageEncoder()

        // 浅层节点优先，超过上限后不再生成。
        let candidates = nodes.values
            .filter { node in
                node.kind == .layer &&
                    node.hostViewClassName != nil &&
                    node.isHidden == false &&
                    node.childIDs.isEmpty == false &&
                    node.bounds.width > 2 &&
                    node.bounds.height > 2
            }
            .sorted { left, right in
                if left.depth == right.depth {
                    return left.id < right.id
                }
                return left.depth < right.depth
            }

        var screenshots: [ViewScopeNodePreviewScreenshotSet] = []
        for node in candidates {
            guard screenshots.count < Self.maximumSoloScreenshotCount else {
                break
            }
            guard let reference = context.nodeReferences[node.id],
                  let layer = reference.resolvedObject as? CALayer,
                  let hostView = layer.kg_viewScopeHostView,
                  (hostView is UIWindow) == false,
                  let window = hostView.window,
                  visibleWindowIDs.contains(ObjectIdentifier(window)) else {
                continue
            }
            guard let image = makeSoloLayerScreenshot(layer, scale: Self.scale(of: window)),
                  let base64 = encoder.base64PNG(for: image) else {
                continue
            }
            screenshots.append(ViewScopeNodePreviewScreenshotSet(
                nodeID: node.id,
                groupPNGBase64: nil,
                soloPNGBase64: base64,
                size: layer.bounds.size.kg_viewScopeSize,
                capturedAt: capturedAt,
                scale: Double(Self.scale(of: window))
            ))
        }
        return screenshots
    }

    private func makeSoloLayerScreenshot(_ layer: CALayer, scale: CGFloat) -> UIImage? {
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else {
            return nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let sublayers = layer.sublayers ?? []
        let hiddenStates = sublayers.map { $0.isHidden }
        for sublayer in sublayers {
            sublayer.isHidden = true
        }
        defer {
            for (sublayer, isHidden) in zip(sublayers, hiddenStates) {
                sublayer.isHidden = isHidden
            }
            CATransaction.commit()
        }

        // renderer 的 bounds 与 layer.bounds 一致，bounds.origin（如 scroll view 的偏移）会被正确平移。
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: Self.rendererFormat(scale: scale))
        return renderer.image { context in
            layer.render(in: context.cgContext)
        }
    }

    private static func rendererFormat(scale: CGFloat) -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        return format
    }

    // MARK: - 窗口与排除

    /// 所有已连接 UIWindowScene 的窗口（可见窗口在前，同组内按 windowLevel 升序）；没有场景时退回 `UIApplication.windows`。
    static func capturableWindows() -> [UIWindow] {
        var windows: [UIWindow] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ window: UIWindow) {
            guard isExcluded(window) == false,
                  seen.insert(ObjectIdentifier(window)).inserted else {
                return
            }
            windows.append(window)
        }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let orderedScenes = scenes.sorted { left, right in
            sceneOrder(left.activationState) < sceneOrder(right.activationState)
        }
        for scene in orderedScenes {
            scene.windows.forEach(append)
        }
        if windows.isEmpty {
            // iOS 15 起所有窗口都隶属于某个 UIWindowScene，只有更早的系统才需要退回 UIApplication.windows。
            if #available(iOS 15.0, *) {
                // 无需回退。
            } else {
                UIApplication.shared.windows.forEach(append)
            }
        }

        let indexed = windows.enumerated().map { (offset: $0.offset, window: $0.element) }
        return indexed.sorted { left, right in
            let leftVisible = isVisible(left.window)
            let rightVisible = isVisible(right.window)
            if leftVisible != rightVisible {
                return leftVisible
            }
            if left.window.windowLevel != right.window.windowLevel {
                return left.window.windowLevel < right.window.windowLevel
            }
            return left.offset < right.offset
        }.map(\.window)
    }

    private static func sceneOrder(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive:
            return 0
        case .foregroundInactive:
            return 1
        case .background:
            return 2
        case .unattached:
            return 3
        @unknown default:
            return 4
        }
    }

    static func isVisible(_ window: UIWindow) -> Bool {
        window.isHidden == false && window.alpha > 0 && window.bounds.width > 0 && window.bounds.height > 0
    }

    /// 高亮浮层（视图或其 layer）不进入抓取结果。
    static func isExcluded(_ object: AnyObject) -> Bool {
        ViewScopeHighlightOverlay.isOverlayObject(object)
    }

    /// 临时隐藏当前所有高亮浮层，返回恢复闭包。
    private static func hideActiveOverlays() -> () -> Void {
        let overlays = ViewScopeHighlightOverlay.activeOverlayViews.allObjects.filter { $0.isHidden == false }
        guard overlays.isEmpty == false else {
            return {}
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlays.forEach { $0.isHidden = true }
        CATransaction.commit()
        return {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlays.forEach { $0.isHidden = false }
            CATransaction.commit()
        }
    }

    static func scale(of window: UIWindow) -> CGFloat {
        let scale = window.screen.scale
        return scale > 0 ? scale : 1
    }

    // MARK: - 几何

    /// 节点在窗口画布中的矩形（左上原点，point）。
    static func canvasRect(for layer: CALayer, hostView: UIView?, in window: UIWindow) -> CGRect {
        if let hostView {
            if hostView === window {
                return CGRect(origin: .zero, size: window.bounds.size)
            }
            return hostView.convert(hostView.bounds, to: window)
        }
        return window.layer.convert(layer.bounds, from: layer)
    }

    // MARK: - 文案

    private func windowTitle(for window: UIWindow) -> String {
        if let title = Self.sanitized(window.rootViewController?.title) {
            return title
        }
        if let title = Self.sanitized(window.windowScene?.title) {
            return title
        }
        return ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: window)))
    }

    private func windowSubtitle(for window: UIWindow) -> String {
        var parts = ["level \(Int(window.windowLevel.rawValue))"]
        if window.isKeyWindow {
            parts.append("key")
        }
        if let controller = window.rootViewController {
            parts.append(ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: controller))))
        }
        return parts.joined(separator: " · ")
    }

    static func sanitized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let sanitized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return sanitized.isEmpty ? nil : sanitized
    }
}

// MARK: - 视图描述

/// 视图标题、副标题、事件处理器、诊断 traits 的计算。
@MainActor
enum ViewScopeUIKitViewDescriber {
    /// 节点标题；没有专属标题时返回 nil（调用方回退为类名）。
    static func title(for view: UIView, language: ViewScopeInterfaceLanguage) -> String? {
        let sanitized = ViewScopeSnapshotBuilder.sanitized
        if let label = view as? UILabel, let text = sanitized(label.text) {
            return text
        }
        if let button = view as? UIButton, let title = sanitized(button.currentTitle ?? button.title(for: .normal)) {
            return title
        }
        if let textField = view as? UITextField {
            if let text = sanitized(textField.text) {
                return text
            }
            if let placeholder = sanitized(textField.placeholder) {
                return placeholder
            }
        }
        if let textView = view as? UITextView, let text = sanitized(textView.text.map { String($0.prefix(80)) }) {
            return text
        }
        if let segmented = view as? UISegmentedControl,
           segmented.selectedSegmentIndex != UISegmentedControl.noSegment,
           let title = sanitized(segmented.titleForSegment(at: segmented.selectedSegmentIndex)) {
            return title
        }
        if let navigationBar = view as? UINavigationBar, let title = sanitized(navigationBar.topItem?.title) {
            return title
        }
        if let identifier = sanitized(view.accessibilityIdentifier) {
            return identifier
        }
        return nil
    }

    static func subtitle(for view: UIView, language: ViewScopeInterfaceLanguage) -> String? {
        if let imageView = view as? UIImageView, let image = imageView.image {
            return "\(language.text("server.value.image")) \(Int(image.size.width.rounded()))×\(Int(image.size.height.rounded()))"
        }
        if let tableView = view as? UITableView {
            return language.text("server.uikit.subtitle.sections", tableView.numberOfSections)
        }
        if let collectionView = view as? UICollectionView {
            return language.text("server.uikit.subtitle.sections", collectionView.numberOfSections)
        }
        if let stackView = view as? UIStackView {
            return language.text("server.subtitle.arranged", stackView.arrangedSubviews.count)
        }
        if let toggleSwitch = view as? UISwitch {
            return toggleSwitch.isOn ? language.text("server.uikit.value.on") : language.text("server.uikit.value.off")
        }
        if let slider = view as? UISlider {
            return String(format: "%.2f", locale: language.locale, Double(slider.value))
        }
        if let progressView = view as? UIProgressView {
            return String(format: "%.0f%%", locale: language.locale, Double(progressView.progress * 100))
        }
        if view is UIScrollView {
            return language.text("server.value.scrollable")
        }
        return nil
    }

    // MARK: 事件

    static func eventHandlers(for view: UIView, idPrefix: String) -> [ViewScopeEventHandler] {
        var handlers: [ViewScopeEventHandler] = []
        if let control = view as? UIControl {
            handlers.append(contentsOf: controlEventHandlers(for: control, idPrefix: idPrefix))
        }
        for (index, recognizer) in (view.gestureRecognizers ?? []).enumerated() {
            handlers.append(gestureEventHandler(for: recognizer, id: "\(idPrefix)-gesture-\(index)"))
        }
        return handlers
    }

    /// 每个 (target, action) 一条记录，副标题列出触发它的事件。
    static func controlEventHandlers(for control: UIControl, idPrefix: String) -> [ViewScopeEventHandler] {
        struct Entry {
            var targetClassName: String?
            var actionName: String
            var events: [String]
        }
        var entries: [Entry] = []

        // allTargets 是无序集合，这里按类名排序保证结果稳定（便于两次抓取做 diff）。
        let targets = control.allTargets.map { $0.base as AnyObject }.sorted { left, right in
            NSStringFromClass(type(of: left)) < NSStringFromClass(type(of: right))
        }
        for target in targets {
            let isNullTarget = target is NSNull
            let targetClassName = isNullTarget ? nil : NSStringFromClass(type(of: target))
            for (event, eventName) in controlEvents {
                let actions = control.actions(forTarget: isNullTarget ? nil : target, forControlEvent: event) ?? []
                for action in actions {
                    if let index = entries.firstIndex(where: { $0.targetClassName == targetClassName && $0.actionName == action }) {
                        if entries[index].events.contains(eventName) == false {
                            entries[index].events.append(eventName)
                        }
                    } else {
                        entries.append(Entry(targetClassName: targetClassName, actionName: action, events: [eventName]))
                    }
                }
            }
        }

        return entries.enumerated().map { index, entry in
            ViewScopeEventHandler(
                id: "\(idPrefix)-control-\(index)",
                kind: .controlAction,
                title: entry.actionName,
                subtitle: entry.events.joined(separator: " | "),
                targetActions: [ViewScopeEventTargetAction(targetClassName: entry.targetClassName, actionName: entry.actionName)],
                isEnabled: control.isEnabled
            )
        }
    }

    /// 节点上展示的主 target/action：优先 touchUpInside / valueChanged / primaryActionTriggered。
    static func primaryTargetAction(for control: UIControl) -> ViewScopeEventTargetAction? {
        let handlers = controlEventHandlers(for: control, idPrefix: "primary")
        let preferredEvents = ["touchUpInside", "valueChanged", "primaryActionTriggered"]
        for eventName in preferredEvents {
            if let handler = handlers.first(where: { ($0.subtitle ?? "").contains(eventName) }) {
                return handler.targetActions.first
            }
        }
        return handlers.first?.targetActions.first
    }

    private static var controlEvents: [(UIControl.Event, String)] {
        var events: [(UIControl.Event, String)] = [
            (.touchDown, "touchDown"),
            (.touchDownRepeat, "touchDownRepeat"),
            (.touchDragInside, "touchDragInside"),
            (.touchDragOutside, "touchDragOutside"),
            (.touchDragEnter, "touchDragEnter"),
            (.touchDragExit, "touchDragExit"),
            (.touchUpInside, "touchUpInside"),
            (.touchUpOutside, "touchUpOutside"),
            (.touchCancel, "touchCancel"),
            (.valueChanged, "valueChanged"),
            (.primaryActionTriggered, "primaryActionTriggered"),
            (.editingDidBegin, "editingDidBegin"),
            (.editingChanged, "editingChanged"),
            (.editingDidEnd, "editingDidEnd"),
            (.editingDidEndOnExit, "editingDidEndOnExit")
        ]
        if #available(iOS 14.0, *) {
            events.append((.menuActionTriggered, "menuActionTriggered"))
        }
        return events
    }

    private static func gestureEventHandler(for recognizer: UIGestureRecognizer, id: String) -> ViewScopeEventHandler {
        let className = NSStringFromClass(type(of: recognizer))
        return ViewScopeEventHandler(
            id: id,
            kind: .gesture,
            title: ViewScopeClassNameFormatter.displayName(for: className),
            subtitle: inheritedRecognizerName(for: recognizer),
            targetActions: gestureTargetActions(for: recognizer),
            isEnabled: recognizer.isEnabled,
            delegateClassName: recognizer.delegate.map { NSStringFromClass(type(of: $0 as AnyObject)) }
        )
    }

    /// UIGestureRecognizer 不公开 target 列表；这里先确认私有 ivar `_targets` 存在且是数组，
    /// 再从每个元素的 description（形如 `(action=onTap:, target=<App.ViewController 0x...>)`）中解析，读不到就返回空。
    private static func gestureTargetActions(for recognizer: UIGestureRecognizer) -> [ViewScopeEventTargetAction] {
        guard let ivar = class_getInstanceVariable(UIGestureRecognizer.self, "_targets"),
              let encoding = ivar_getTypeEncoding(ivar),
              String(cString: encoding).hasPrefix("@"),
              let targets = object_getIvar(recognizer, ivar) as? NSArray else {
            return []
        }
        var result: [ViewScopeEventTargetAction] = []
        for element in targets {
            guard let object = element as? NSObject else {
                continue
            }
            let description = object.description
            let action = capture(in: description, pattern: "action=([^,\\s)]+)")
            let target = capture(in: description, pattern: "target=<([^\\s>]+)")
            if action != nil || target != nil {
                result.append(ViewScopeEventTargetAction(targetClassName: target, actionName: action))
            }
        }
        return result
    }

    private static func capture(in string: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string) else {
            return nil
        }
        return String(string[range])
    }

    private static func inheritedRecognizerName(for recognizer: UIGestureRecognizer) -> String? {
        let bases: [(UIGestureRecognizer.Type, String)] = [
            (UITapGestureRecognizer.self, "UITapGestureRecognizer"),
            (UILongPressGestureRecognizer.self, "UILongPressGestureRecognizer"),
            (UIScreenEdgePanGestureRecognizer.self, "UIScreenEdgePanGestureRecognizer"),
            (UIPanGestureRecognizer.self, "UIPanGestureRecognizer"),
            (UIPinchGestureRecognizer.self, "UIPinchGestureRecognizer"),
            (UIRotationGestureRecognizer.self, "UIRotationGestureRecognizer"),
            (UISwipeGestureRecognizer.self, "UISwipeGestureRecognizer")
        ]
        for (base, name) in bases {
            if type(of: recognizer) == base {
                return nil
            }
            if recognizer.isKind(of: base) {
                return name
            }
        }
        return type(of: recognizer) == UIGestureRecognizer.self ? nil : "UIGestureRecognizer"
    }

    // MARK: Traits

    static func traits(for view: UIView) -> ViewScopeNodeTraits {
        let intrinsic = view.intrinsicContentSize
        let hasIntrinsicSize = intrinsic.width != UIView.noIntrinsicMetric && intrinsic.height != UIView.noIntrinsicMetric
        let usesAutoLayout = view.translatesAutoresizingMaskIntoConstraints == false
        var constraintCount = view.constraints.count
        if let superview = view.superview {
            constraintCount += superview.constraints.filter { ViewScopeUIKitDetailSectionBuilder.constraint($0, references: view) }.count
        }
        let enabledRecognizers = (view.gestureRecognizers ?? []).filter(\.isEnabled)

        var imageSize: ViewScopeSize?
        var imageScale: Double?
        if let image = (view as? UIImageView)?.image {
            imageSize = image.size.kg_viewScopeSize
            imageScale = Double(image.scale)
        }

        return ViewScopeNodeTraits(
            isUserInteractionEnabled: view.isUserInteractionEnabled,
            // hasAmbiguousLayout 只对参与 Auto Layout 的视图有意义，避免对全部视图做引擎查询。
            hasAmbiguousLayout: usesAutoLayout ? view.hasAmbiguousLayout : nil,
            translatesAutoresizingMaskIntoConstraints: view.translatesAutoresizingMaskIntoConstraints,
            isOpaque: view.isOpaque,
            backgroundAlpha: view.backgroundColor.map { Double($0.cgColor.alpha) },
            frameInSuperview: view.frame.kg_viewScopeRect,
            displayScale: Double(view.contentScaleFactor),
            intrinsicContentSize: hasIntrinsicSize ? intrinsic.kg_viewScopeSize : nil,
            constraintCount: constraintCount,
            accessibilityIdentifier: ViewScopeSnapshotBuilder.sanitized(view.accessibilityIdentifier),
            accessibilityLabel: ViewScopeSnapshotBuilder.sanitized(view.accessibilityLabel),
            isAccessibilityElement: view.isAccessibilityElement,
            isInteractiveControl: view is UIControl || enabledRecognizers.isEmpty == false,
            isTextTruncated: (view as? UILabel).flatMap(isTextTruncated),
            imageSize: imageSize,
            imageScale: imageScale
        )
    }

    static func traits(for layer: CALayer) -> ViewScopeNodeTraits {
        ViewScopeNodeTraits(
            isOpaque: layer.isOpaque,
            backgroundAlpha: layer.backgroundColor.map { Double($0.alpha) },
            frameInSuperview: layer.frame.kg_viewScopeRect,
            displayScale: Double(layer.contentsScale)
        )
    }

    /// UILabel 文本是否被截断：比较文本所需尺寸与 label 的 bounds / numberOfLines。
    /// 开启 adjustsFontSizeToFitWidth 时系统会缩小字号，无法可靠判断，返回 nil。
    static func isTextTruncated(_ label: UILabel) -> Bool? {
        guard let text = label.attributedText, text.length > 0,
              label.bounds.width > 0, label.bounds.height > 0,
              label.adjustsFontSizeToFitWidth == false else {
            return nil
        }
        let tolerance: CGFloat = 0.5
        let width = label.bounds.width
        let unbounded = CGFloat.greatestFiniteMagnitude
        let fullRect = label.textRect(
            forBounds: CGRect(x: 0, y: 0, width: width, height: unbounded),
            limitedToNumberOfLines: 0
        )
        if label.numberOfLines == 1 {
            let singleLineRect = label.textRect(
                forBounds: CGRect(x: 0, y: 0, width: unbounded, height: unbounded),
                limitedToNumberOfLines: 1
            )
            return singleLineRect.width > width + tolerance
        }
        if label.numberOfLines > 1 {
            let limitedRect = label.textRect(
                forBounds: CGRect(x: 0, y: 0, width: width, height: unbounded),
                limitedToNumberOfLines: label.numberOfLines
            )
            if fullRect.height > limitedRect.height + tolerance {
                return true
            }
            return limitedRect.height > label.bounds.height + tolerance
        }
        return fullRect.height > label.bounds.height + tolerance
    }

    /// 旧式按钮内容边距（仅用于未启用 UIButton.Configuration 的按钮）。
    ///
    /// `contentEdgeInsets` 在 iOS 15 起 deprecated 但仍然生效；这里通过公开属性的 KVC 读写，
    /// 避免部署目标提高到 iOS 15+ 时产生弃用警告。
    static func legacyContentEdgeInsets(of button: UIButton) -> UIEdgeInsets {
        (button.value(forKey: "contentEdgeInsets") as? NSValue)?.uiEdgeInsetsValue ?? .zero
    }

    static func setLegacyContentEdgeInsets(_ insets: UIEdgeInsets, on button: UIButton) {
        button.setValue(NSValue(uiEdgeInsets: insets), forKey: "contentEdgeInsets")
    }
}

// MARK: - 系统类型扩展

extension CGRect {
    var kg_viewScopeRect: ViewScopeRect {
        ViewScopeRect(
            x: ViewScopeNumberConversion.finite(Double(origin.x)),
            y: ViewScopeNumberConversion.finite(Double(origin.y)),
            width: ViewScopeNumberConversion.finite(Double(size.width)),
            height: ViewScopeNumberConversion.finite(Double(size.height))
        )
    }
}

extension CGSize {
    var kg_viewScopeSize: ViewScopeSize {
        ViewScopeSize(
            width: ViewScopeNumberConversion.finite(Double(width)),
            height: ViewScopeNumberConversion.finite(Double(height))
        )
    }
}

extension Array {
    var kg_viewScopeNonEmpty: Self? {
        isEmpty ? nil : self
    }
}
#endif
