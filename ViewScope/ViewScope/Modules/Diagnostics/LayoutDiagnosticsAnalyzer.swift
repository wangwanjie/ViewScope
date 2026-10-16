import CoreGraphics
import Foundation
import ViewScopeServer

/// 布局问题分析器（纯函数）。
///
/// 输入一次抓取，输出 `nodeID -> [问题]`。整体复杂度：
/// - 一次深度优先遍历收集每个节点的上下文（画布矩形、裁剪区域、有效可见性、深度），O(n)；
/// - 遮挡检测借助 `CanvasSpatialIndex`，只检查与不透明遮挡者相交的候选节点，近似 O(n log n)。
///
/// 旧宿主没有 `traits` 时，依赖 traits 的规则直接跳过，不会误报。
enum LayoutDiagnosticsAnalyzer {
    /// 视图层级深度超过该值视为过深。
    static let maximumRecommendedDepth = 40
    /// iOS 人机交互指南建议的最小点击区域（pt）。
    static let minimumTapTargetSide: CGFloat = 44
    /// 像素对齐的容差（像素）。
    static let pixelAlignmentTolerance: CGFloat = 0.01
    /// 图片放大超过 10% 视为可能模糊。
    static let imageUpscaleTolerance: CGFloat = 1.1

    /// 每个节点在遍历中得到的上下文。
    private struct NodeContext {
        let nodeID: String
        let parentID: String?
        let rect: CGRect
        /// 祖先裁剪区域（不含滚动类容器）；nil 表示没有裁剪祖先。
        let clipRect: CGRect?
        /// 节点矩形与裁剪区域的交集，即实际可见区域。
        let visibleRect: CGRect
        let isEffectivelyHidden: Bool
        let effectiveAlpha: Double
        let depth: Int
        /// 节点所属画布（不同窗口的画布坐标互不相干）。
        let canvasRootID: String
        /// 先序遍历序号，即绘制顺序。
        let drawIndex: Int
        /// 子树结束位置（不含），用于 O(1) 判断祖先关系。
        var subtreeEnd: Int
    }

    static func analyze(
        capture: ViewScopeCapturePayload,
        platform: ViewScopePlatform
    ) -> [String: [LayoutDiagnosticIssue]] {
        let contexts = collectContexts(capture: capture)
        var issues: [String: [LayoutDiagnosticIssue]] = [:]

        func append(_ nodeID: String, _ kind: LayoutDiagnosticIssue.Kind, _ message: String, severity: LayoutDiagnosticIssue.Severity? = nil) {
            issues[nodeID, default: []].append(
                LayoutDiagnosticIssue(
                    nodeID: nodeID,
                    kind: kind,
                    severity: severity ?? kind.defaultSeverity,
                    message: message
                )
            )
        }

        let contextByID = Dictionary(uniqueKeysWithValues: contexts.map { ($0.nodeID, $0) })
        let hostScale = capture.host.screenScale
        let isTouchPlatform = platform == .iOS || platform == .iPadOS || platform == .visionOS

        for context in contexts {
            guard let node = capture.nodes[context.nodeID],
                  node.kind != .window,
                  context.isEffectivelyHidden == false else {
                continue
            }
            let traits = node.traits
            let rect = context.rect
            let hasArea = rect.width > 0.01 && rect.height > 0.01
            let parentContext = context.parentID.flatMap { contextByID[$0] }
            let parentNode = context.parentID.flatMap { capture.nodes[$0] }

            // 1. 约束歧义：直接来自宿主的 hasAmbiguousLayout。
            if traits?.hasAmbiguousLayout == true {
                append(context.nodeID, .ambiguousLayout, L10n.previewToolsDiagnosticMessageAmbiguous)
            }

            // 2. 越界 / 被裁剪：只在父节点不是窗口、自身有面积时检查。
            if hasArea,
               let parentContext,
               parentNode?.kind != .window {
                if let clipRect = context.clipRect,
                   clipRect.intersects(rect) == false {
                    append(context.nodeID, .outsideParentBounds, L10n.previewToolsDiagnosticMessageOutsideClip)
                } else if let clipRect = context.clipRect,
                          contains(clipRect, rect) == false {
                    let hiddenRatio = 1 - area(of: clipRect.intersection(rect)) / max(area(of: rect), 0.0001)
                    append(
                        context.nodeID,
                        .clippedByAncestor,
                        L10n.previewToolsDiagnosticMessageClipped(Int((hiddenRatio * 100).rounded()))
                    )
                } else if parentContext.rect.width > 0.01,
                          parentContext.rect.height > 0.01,
                          parentContext.rect.intersects(rect) == false {
                    // 父节点不裁剪时内容仍可见，但 iOS 上超出父视图的部分无法接收触摸。
                    let isInteractive = traits?.isInteractiveControl == true
                    append(
                        context.nodeID,
                        .outsideParentBounds,
                        isTouchPlatform && isInteractive
                            ? L10n.previewToolsDiagnosticMessageOutsideParentUntouchable
                            : L10n.previewToolsDiagnosticMessageOutsideParent,
                        severity: isTouchPlatform && isInteractive ? .warning : .info
                    )
                }
            }

            // 3. 零尺寸容器却有可见子节点：子节点要么被裁掉，要么越界显示，布局多半有误。
            if hasArea == false {
                let visibleChildCount = node.childIDs.reduce(into: 0) { count, childID in
                    guard let child = capture.nodes[childID],
                          child.isHidden == false,
                          child.frame.width > 0.01,
                          child.frame.height > 0.01 else {
                        return
                    }
                    count += 1
                }
                if visibleChildCount > 0 {
                    append(
                        context.nodeID,
                        .zeroSizeWithVisibleChildren,
                        L10n.previewToolsDiagnosticMessageZeroSize(visibleChildCount)
                    )
                }
            }

            // 4. 非整像素：边缘乘以显示缩放后不是整数。存在变换（frame 与原始尺寸不一致）时跳过。
            if hasArea,
               isTransformed(node: node) == false {
                let scale = CGFloat(traits?.displayScale ?? hostScale ?? 2)
                if scale > 0, isPixelAligned(rect, scale: scale) == false {
                    append(
                        context.nodeID,
                        .misalignedToPixels,
                        L10n.previewToolsDiagnosticMessageMisaligned(formatRect(rect), formatNumber(scale))
                    )
                }
            }

            // 5. 完全透明却仍可交互。
            if hasArea,
               node.alphaValue < 0.01,
               traits?.isUserInteractionEnabled == true {
                append(context.nodeID, .invisibleButInteractive, L10n.previewToolsDiagnosticMessageInvisibleInteractive)
            }

            // 6. 文本截断。
            if traits?.isTextTruncated == true {
                append(context.nodeID, .textTruncated, L10n.previewToolsDiagnosticMessageTruncated)
            }

            // 7. 图片放大：图片像素尺寸比视图需要的像素尺寸小 10% 以上（任一方向）。
            if hasArea,
               let imageSize = traits?.imageSize,
               imageSize.width > 0,
               imageSize.height > 0 {
                let imageScale = CGFloat(traits?.imageScale ?? 1)
                let displayScale = CGFloat(traits?.displayScale ?? hostScale ?? 2)
                let imagePixels = CGSize(width: CGFloat(imageSize.width) * imageScale, height: CGFloat(imageSize.height) * imageScale)
                let neededPixels = CGSize(width: rect.width * displayScale, height: rect.height * displayScale)
                let horizontalFactor = neededPixels.width / max(imagePixels.width, 0.0001)
                let verticalFactor = neededPixels.height / max(imagePixels.height, 0.0001)
                let factor = max(horizontalFactor, verticalFactor)
                if factor > imageUpscaleTolerance {
                    append(
                        context.nodeID,
                        .imageUpscaled,
                        L10n.previewToolsDiagnosticMessageUpscaled(
                            "\(Int(imagePixels.width.rounded()))×\(Int(imagePixels.height.rounded()))",
                            "\(Int(neededPixels.width.rounded()))×\(Int(neededPixels.height.rounded()))"
                        )
                    )
                }
            }

            // 8. 点击区域过小：只针对触摸平台的可交互控件。
            if isTouchPlatform,
               traits?.isInteractiveControl == true,
               hasArea,
               min(rect.width, rect.height) < minimumTapTargetSide {
                append(
                    context.nodeID,
                    .smallTapTarget,
                    L10n.previewToolsDiagnosticMessageSmallTapTarget(formatNumber(rect.width), formatNumber(rect.height))
                )
            }

            // 9. 层级过深：只标记每条路径上第一个超过阈值的节点，避免整棵子树刷屏。
            if context.depth > maximumRecommendedDepth,
               (parentContext?.depth ?? 0) <= maximumRecommendedDepth {
                append(context.nodeID, .excessiveDepth, L10n.previewToolsDiagnosticMessageDepth(context.depth))
            }
        }

        // 10. 被后绘制的不透明节点完全遮挡。
        for (occludedID, occluderID) in occlusions(contexts: contexts, capture: capture) {
            let occluderName = capture.nodes[occluderID].map(displayClassName(for:)) ?? occluderID
            append(occludedID, .occludedBySibling, L10n.previewToolsDiagnosticMessageOccluded(occluderName))
        }

        return issues
    }

    // MARK: - 遍历

    private static func collectContexts(capture: ViewScopeCapturePayload) -> [NodeContext] {
        var contexts: [NodeContext] = []
        contexts.reserveCapacity(capture.nodes.count)
        var visited = Set<String>()

        struct Frame {
            let nodeID: String
            let parentID: String?
            let clipRect: CGRect?
            let parentHidden: Bool
            let parentAlpha: Double
            let depth: Int
            let canvasRootID: String?
        }

        // 用显式栈做先序遍历，避免超深层级导致递归栈溢出；
        // 出栈标记用于回填 subtreeEnd。
        enum Step {
            case enter(Frame)
            case exit(Int)
        }

        var stack: [Step] = capture.rootNodeIDs.reversed().map {
            .enter(Frame(nodeID: $0, parentID: nil, clipRect: nil, parentHidden: false, parentAlpha: 1, depth: 0, canvasRootID: nil))
        }

        while let step = stack.popLast() {
            switch step {
            case .exit(let index):
                contexts[index].subtreeEnd = contexts.count
            case .enter(let frame):
                guard visited.insert(frame.nodeID).inserted,
                      let node = capture.nodes[frame.nodeID] else {
                    continue
                }
                let rect = node.frame.cgRect.standardized
                let isHidden = frame.parentHidden || node.isHidden
                let alpha = frame.parentAlpha * max(0, min(1, node.alphaValue))
                // 窗口下的第一个节点开始一张新画布。
                let canvasRootID: String
                if node.kind == .window {
                    canvasRootID = node.id
                } else if let inherited = frame.canvasRootID,
                          capture.nodes[inherited]?.kind != .window {
                    canvasRootID = inherited
                } else {
                    canvasRootID = node.id
                }
                let visibleRect = frame.clipRect.map { $0.intersection(rect) } ?? rect
                let index = contexts.count
                contexts.append(
                    NodeContext(
                        nodeID: node.id,
                        parentID: frame.parentID,
                        rect: rect,
                        clipRect: frame.clipRect,
                        visibleRect: visibleRect.isNull ? .zero : visibleRect,
                        isEffectivelyHidden: isHidden,
                        effectiveAlpha: alpha,
                        depth: frame.depth,
                        canvasRootID: canvasRootID,
                        drawIndex: index,
                        subtreeEnd: index + 1
                    )
                )

                // 子节点继承的裁剪区域：窗口与滚动类容器不参与（滚动内容超出可视区是预期行为）。
                var childClipRect = frame.clipRect
                if node.kind == .window {
                    childClipRect = nil
                } else if node.clippingEnabled, isScrollContainer(node) == false {
                    childClipRect = childClipRect.map { $0.intersection(rect) } ?? rect
                }

                stack.append(.exit(index))
                for childID in node.childIDs.reversed() {
                    stack.append(
                        .enter(
                            Frame(
                                nodeID: childID,
                                parentID: node.id,
                                clipRect: childClipRect,
                                parentHidden: isHidden,
                                parentAlpha: alpha,
                                depth: frame.depth + 1,
                                canvasRootID: canvasRootID
                            )
                        )
                    )
                }
            }
        }
        return contexts
    }

    // MARK: - 遮挡

    /// 返回 (被遮挡节点, 遮挡者) 列表。只报告最上层的被遮挡节点，其后代不重复报告。
    private static func occlusions(
        contexts: [NodeContext],
        capture: ViewScopeCapturePayload
    ) -> [(String, String)] {
        var result: [(String, String)] = []
        let grouped = Dictionary(grouping: contexts.indices) { contexts[$0].canvasRootID }

        for (_, indices) in grouped {
            // 一张画布内建立空间索引，索引值映射回 contexts 下标。
            let candidates = indices.filter { index in
                let context = contexts[index]
                guard context.isEffectivelyHidden == false,
                      context.visibleRect.width > 0.01,
                      context.visibleRect.height > 0.01,
                      capture.nodes[context.nodeID]?.kind != .window else {
                    return false
                }
                return true
            }
            guard candidates.count > 1 else {
                continue
            }
            let bounds = candidates.reduce(CGRect.null) { $0.union(contexts[$1].visibleRect) }
            var index = CanvasSpatialIndex(bounds: bounds, expectedCount: candidates.count)
            for candidate in candidates {
                index.insert(contexts[candidate].visibleRect)
            }

            var occluderByContextIndex: [Int: Int] = [:]
            for (occluderSlot, occluderIndex) in candidates.enumerated() {
                let occluder = contexts[occluderIndex]
                guard let occluderNode = capture.nodes[occluder.nodeID],
                      isOpaqueOccluder(node: occluderNode, context: occluder) else {
                    continue
                }
                for slot in index.candidateIDs(intersecting: occluder.visibleRect) where slot < occluderSlot {
                    let targetIndex = candidates[slot]
                    let target = contexts[targetIndex]
                    // 祖先节点（子树包含遮挡者）不算被遮挡：子视图本来就画在父视图之上。
                    let isAncestor = target.drawIndex < occluder.drawIndex && target.subtreeEnd >= occluder.subtreeEnd
                    guard isAncestor == false,
                          occluderByContextIndex[targetIndex] == nil,
                          contains(occluder.visibleRect, target.visibleRect) else {
                        continue
                    }
                    occluderByContextIndex[targetIndex] = occluderIndex
                }
            }

            let occludedIDs = Set(occluderByContextIndex.keys.map { contexts[$0].nodeID })
            for (targetIndex, occluderIndex) in occluderByContextIndex.sorted(by: { $0.key < $1.key }) {
                let target = contexts[targetIndex]
                // 父节点已被报告时跳过，避免整棵子树重复刷屏。
                if let parentID = target.parentID, occludedIDs.contains(parentID) {
                    continue
                }
                result.append((target.nodeID, contexts[occluderIndex].nodeID))
            }
        }
        return result
    }

    private static func isOpaqueOccluder(node: ViewScopeHierarchyNode, context: NodeContext) -> Bool {
        guard context.effectiveAlpha >= 0.99,
              context.parentID != nil else {
            return false
        }
        let traits = node.traits
        let hasOpaqueBackground = (traits?.backgroundAlpha ?? 0) >= 0.99
        return traits?.isOpaque == true || hasOpaqueBackground
    }

    // MARK: - 工具

    private static func isScrollContainer(_ node: ViewScopeHierarchyNode) -> Bool {
        let className = displayClassName(for: node)
        let markers = ["ScrollView", "ClipView", "TableView", "CollectionView", "OutlineView", "TableViewWrapperView"]
        return markers.contains { className.contains($0) }
    }

    private static func displayClassName(for node: ViewScopeHierarchyNode) -> String {
        if node.kind == .layer, let hostViewClassName = node.hostViewClassName, hostViewClassName.isEmpty == false {
            return ViewScopeClassNameFormatter.displayName(for: hostViewClassName)
        }
        return ViewScopeClassNameFormatter.displayName(for: node.className)
    }

    /// 节点存在 transform（画布 frame 尺寸与父坐标系中的原始尺寸不一致）时，像素对齐检查没有意义。
    private static func isTransformed(node: ViewScopeHierarchyNode) -> Bool {
        guard let original = node.traits?.frameInSuperview else {
            return false
        }
        return abs(original.width - node.frame.width) > 0.5 || abs(original.height - node.frame.height) > 0.5
    }

    static func isPixelAligned(_ rect: CGRect, scale: CGFloat) -> Bool {
        let edges = [rect.minX, rect.minY, rect.maxX, rect.maxY]
        return edges.allSatisfy { edge in
            let pixels = edge * scale
            return abs(pixels - pixels.rounded()) <= pixelAlignmentTolerance
        }
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        let tolerance: CGFloat = 0.01
        return inner.minX >= outer.minX - tolerance &&
            inner.minY >= outer.minY - tolerance &&
            inner.maxX <= outer.maxX + tolerance &&
            inner.maxY <= outer.maxY + tolerance
    }

    private static func area(of rect: CGRect) -> CGFloat {
        guard rect.isNull == false else {
            return 0
        }
        return max(rect.width, 0) * max(rect.height, 0)
    }

    private static func formatRect(_ rect: CGRect) -> String {
        "(\(formatNumber(rect.minX)), \(formatNumber(rect.minY)), \(formatNumber(rect.width)), \(formatNumber(rect.height)))"
    }

    static func formatNumber(_ value: CGFloat) -> String {
        if abs(value - value.rounded()) < 0.005 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", Double(value))
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}
