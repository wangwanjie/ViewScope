import Foundation
import ViewScopeServer

/// 负责把原始抓取层级转换成“界面展示层级”。
///
/// AppKit 会插入一些系统 wrapper view，它们存在于抓取数据里，
/// 但默认不应该改变用户在左侧层级树里看到的父子关系。
/// 3D/2D 分层预览也必须使用同一套 presented hierarchy，
/// 否则展开链、挖空区域和图层层级会和树面板脱节。
enum ViewHierarchyPresentation {
    static func isSystemWrapper(_ node: ViewScopeHierarchyNode) -> Bool {
        let candidateClassName: String
        switch node.kind {
        case .view:
            candidateClassName = node.className
        case .layer:
            guard let hostViewClassName = node.hostViewClassName else {
                return false
            }
            candidateClassName = hostViewClassName
        case .window:
            return false
        }

        let className = ViewScopeClassNameFormatter.displayName(for: candidateClassName)
        let exactMatches: Set<String> = [
            "_NSSplitViewItemViewWrapper",
            "_NSSplitViewCollapsedInteractionsView",
            "NSBlurryAlleywayView",
            "NSThemeFrame",
            "NSTitlebarContainerBlockingView",
            "NSTitlebarView",
            "_NSTitlebarDecorationView",
            "_NSTitlebarContainerView",
            "_NSToolbarFullScreenWindowContentView"
        ]
        return exactMatches.contains(className)
    }

    static func presentedRootNodeIDs(
        from rootNodeIDs: [String],
        nodes: [String: ViewScopeHierarchyNode],
        showsSystemWrappers: Bool
    ) -> [String] {
        flatten(nodeIDs: rootNodeIDs, nodes: nodes, showsSystemWrappers: showsSystemWrappers)
    }

    static func presentedChildNodeIDs(
        of nodeID: String,
        nodes: [String: ViewScopeHierarchyNode],
        showsSystemWrappers: Bool
    ) -> [String] {
        guard let node = nodes[nodeID] else { return [] }
        return flatten(nodeIDs: node.childIDs, nodes: nodes, showsSystemWrappers: showsSystemWrappers)
    }

    /// 返回“当前界面展示层级”里某个节点的父节点。
    ///
    /// 如果中间夹着被折叠掉的系统 wrapper，就会直接跳过，
    /// 保证树面板、2D/3D preview、选中回退都看到同一条 presented 链路。
    static func presentedParentNodeID(
        of nodeID: String,
        nodes: [String: ViewScopeHierarchyNode],
        showsSystemWrappers: Bool
    ) -> String? {
        var currentParentNodeID = nodes[nodeID]?.parentID

        while let candidateNodeID = currentParentNodeID {
            guard let candidateNode = nodes[candidateNodeID] else {
                return nil
            }
            if showsSystemWrappers || isSystemWrapper(candidateNode) == false {
                return candidateNodeID
            }
            currentParentNodeID = candidateNode.parentID
        }

        return nil
    }

    /// 返回当前展开态下真正可见于“展示层级”的节点集合。
    ///
    /// 这里的“可见”包含两层含义：
    /// 1. 节点没有被 wrapper flatten 掉。
    /// 2. 它到根路径上的 presented 祖先都处于展开状态。
    static func visiblePresentedNodeIDs(
        rootNodeIDs: [String],
        nodes: [String: ViewScopeHierarchyNode],
        expandedNodeIDs: Set<String>,
        showsSystemWrappers: Bool
    ) -> Set<String> {
        let presentedRoots = presentedRootNodeIDs(
            from: rootNodeIDs,
            nodes: nodes,
            showsSystemWrappers: showsSystemWrappers
        )
        var result = Set<String>()

        func visit(nodeID: String, expandsAutomatically: Bool) {
            guard let node = nodes[nodeID], node.isHidden == false else {
                return
            }

            result.insert(nodeID)

            let shouldExpand = expandsAutomatically || expandedNodeIDs.contains(nodeID)
            guard shouldExpand else { return }

            for childNodeID in presentedChildNodeIDs(
                of: nodeID,
                nodes: nodes,
                showsSystemWrappers: showsSystemWrappers
            ) {
                visit(nodeID: childNodeID, expandsAutomatically: false)
            }
        }

        for rootNodeID in presentedRoots {
            visit(nodeID: rootNodeID, expandsAutomatically: true)
        }

        return result
    }

    private static func flatten(
        nodeIDs: [String],
        nodes: [String: ViewScopeHierarchyNode],
        showsSystemWrappers: Bool
    ) -> [String] {
        var result: [String] = []
        result.reserveCapacity(nodeIDs.count)

        for nodeID in nodeIDs {
            guard let node = nodes[nodeID] else { continue }
            if showsSystemWrappers || isSystemWrapper(node) == false {
                result.append(nodeID)
            } else {
                result.append(contentsOf: flatten(
                    nodeIDs: node.childIDs,
                    nodes: nodes,
                    showsSystemWrappers: false
                ))
            }
        }

        return result
    }
}
