import ViewScopeServer

struct WorkspaceExpansionUpdate {
    let expandedNodeIDs: Set<String>
    let selectedNodeID: String?
    let focusedNodeID: String?
}

struct WorkspaceSelectionNormalizationResult {
    let expandedNodeIDs: Set<String>
    let selectedNodeID: String?
    let focusedNodeID: String?
    let targetNodeID: String?
    let shouldReloadDetail: Bool
}

@MainActor
final class WorkspaceSelectionController {
    func focusedNodeID(
        for requestedNodeID: String?,
        capture: ViewScopeCapturePayload?
    ) -> String? {
        guard let requestedNodeID else { return nil }
        guard capture?.nodes[requestedNodeID] != nil else { return nil }
        return requestedNodeID
    }

    func setNodeExpanded(
        nodeID: String,
        isExpanded: Bool,
        capture: ViewScopeCapturePayload?,
        expandedNodeIDs: Set<String>,
        selectedNodeID: String?,
        focusedNodeID: String?,
        showsSystemWrapperViews: Bool
    ) -> WorkspaceExpansionUpdate {
        guard let capture, capture.nodes[nodeID] != nil else {
            return WorkspaceExpansionUpdate(
                expandedNodeIDs: expandedNodeIDs,
                selectedNodeID: selectedNodeID,
                focusedNodeID: focusedNodeID
            )
        }
        guard capture.rootNodeIDs.contains(nodeID) == false else {
            return WorkspaceExpansionUpdate(
                expandedNodeIDs: expandedNodeIDs,
                selectedNodeID: selectedNodeID,
                focusedNodeID: focusedNodeID
            )
        }

        var nextExpandedNodeIDs = expandedNodeIDs
        if isExpanded {
            nextExpandedNodeIDs.insert(nodeID)
        } else {
            nextExpandedNodeIDs.remove(nodeID)
            collapseExpandedDescendants(
                of: nodeID,
                capture: capture,
                expandedNodeIDs: &nextExpandedNodeIDs
            )
        }

        let visibleNodeIDs = visibleNodeIDs(
            in: capture,
            expandedNodeIDs: nextExpandedNodeIDs,
            showsSystemWrapperViews: showsSystemWrapperViews
        )
        // 收起节点导致选中节点不可见时，直接清除选中
        // focusedNodeID 则回退到最近可见祖节点，保持子树聚焦连续性。
        let resolvedSelectedNodeID: String? = if let selectedNodeID,
            visibleNodeIDs.contains(selectedNodeID) {
            selectedNodeID
        } else {
            nil
        }
        return WorkspaceExpansionUpdate(
            expandedNodeIDs: nextExpandedNodeIDs,
            selectedNodeID: resolvedSelectedNodeID,
            focusedNodeID: resolvedVisibleSelectionTarget(
                from: focusedNodeID,
                capture: capture,
                visibleNodeIDs: visibleNodeIDs,
                showsSystemWrapperViews: showsSystemWrapperViews
            )
        )
    }

    func expandedNodeIDsAfterExpandingAncestors(
        of nodeID: String,
        capture: ViewScopeCapturePayload?,
        expandedNodeIDs: Set<String>
    ) -> Set<String> {
        guard let capture else { return expandedNodeIDs }
        var nextExpandedNodeIDs = expandedNodeIDs
        var currentNodeID = capture.nodes[nodeID]?.parentID
        while let candidateNodeID = currentNodeID {
            if capture.rootNodeIDs.contains(candidateNodeID) == false {
                nextExpandedNodeIDs.insert(candidateNodeID)
            }
            currentNodeID = capture.nodes[candidateNodeID]?.parentID
        }
        return nextExpandedNodeIDs
    }

    func normalizeAfterCaptureUpdate(
        capture: ViewScopeCapturePayload?,
        preferredNodeID: String?,
        preferredFocusedNodeID: String?,
        currentSelectedNodeID: String?,
        currentFocusedNodeID: String?,
        selectedNodeDetailNodeID: String?,
        expandedNodeIDs: Set<String>,
        showsSystemWrapperViews: Bool,
        forceReloadDetail: Bool
    ) -> WorkspaceSelectionNormalizationResult {
        guard let capture else {
            return WorkspaceSelectionNormalizationResult(
                expandedNodeIDs: [],
                selectedNodeID: nil,
                focusedNodeID: nil,
                targetNodeID: nil,
                shouldReloadDetail: true
            )
        }

        var nextExpandedNodeIDs = expandedNodeIDs.filter {
            capture.nodes[$0] != nil && capture.rootNodeIDs.contains($0) == false
        }
        let visibleNodeIDs = visibleNodeIDs(
            in: capture,
            expandedNodeIDs: nextExpandedNodeIDs,
            showsSystemWrapperViews: showsSystemWrapperViews
        )

        let nextFocusedNodeID: String?
        if let preferredFocusedNodeID {
            nextFocusedNodeID = resolvedVisibleSelectionTarget(
                from: preferredFocusedNodeID,
                capture: capture,
                visibleNodeIDs: visibleNodeIDs,
                showsSystemWrapperViews: showsSystemWrapperViews
            )
        } else if let currentFocusedNodeID, capture.nodes[currentFocusedNodeID] == nil {
            nextFocusedNodeID = nil
        } else {
            nextFocusedNodeID = resolvedVisibleSelectionTarget(
                from: currentFocusedNodeID,
                capture: capture,
                visibleNodeIDs: visibleNodeIDs,
                showsSystemWrapperViews: showsSystemWrapperViews
            )
        }

        var nextSelectedNodeID = resolvedVisibleSelectionTarget(
            from: currentSelectedNodeID,
            capture: capture,
            visibleNodeIDs: visibleNodeIDs,
            showsSystemWrapperViews: showsSystemWrapperViews
        )

        let targetNodeID: String?
        if let preferredNodeID {
            targetNodeID = resolvedVisibleSelectionTarget(
                from: preferredNodeID,
                capture: capture,
                visibleNodeIDs: visibleNodeIDs,
                showsSystemWrapperViews: showsSystemWrapperViews
            ) ?? capture.rootNodeIDs.first
        } else if let nextSelectedNodeID {
            targetNodeID = resolvedVisibleSelectionTarget(
                from: nextSelectedNodeID,
                capture: capture,
                visibleNodeIDs: visibleNodeIDs,
                showsSystemWrapperViews: showsSystemWrapperViews
            ) ?? capture.rootNodeIDs.first
        } else {
            targetNodeID = capture.rootNodeIDs.first
        }

        if let targetNodeID {
            nextExpandedNodeIDs = expandedNodeIDsAfterExpandingAncestors(
                of: targetNodeID,
                capture: capture,
                expandedNodeIDs: nextExpandedNodeIDs
            )
        }
        nextSelectedNodeID = targetNodeID

        let shouldReloadDetail = currentSelectedNodeID != targetNodeID ||
            selectedNodeDetailNodeID != targetNodeID ||
            selectedNodeDetailNodeID == nil ||
            forceReloadDetail

        return WorkspaceSelectionNormalizationResult(
            expandedNodeIDs: nextExpandedNodeIDs,
            selectedNodeID: nextSelectedNodeID,
            focusedNodeID: nextFocusedNodeID,
            targetNodeID: targetNodeID,
            shouldReloadDetail: shouldReloadDetail
        )
    }

    private func visibleNodeIDs(
        in capture: ViewScopeCapturePayload,
        expandedNodeIDs: Set<String>,
        showsSystemWrapperViews: Bool
    ) -> Set<String> {
        ViewHierarchyPresentation.visiblePresentedNodeIDs(
            rootNodeIDs: capture.rootNodeIDs,
            nodes: capture.nodes,
            expandedNodeIDs: expandedNodeIDs,
            showsSystemWrappers: showsSystemWrapperViews
        )
    }

    private func resolvedVisibleSelectionTarget(
        from nodeID: String?,
        capture: ViewScopeCapturePayload,
        visibleNodeIDs: Set<String>,
        showsSystemWrapperViews: Bool
    ) -> String? {
        var currentNodeID = nodeID

        while let candidateNodeID = currentNodeID {
            if visibleNodeIDs.contains(candidateNodeID) {
                return candidateNodeID
            }
            currentNodeID = ViewHierarchyPresentation.presentedParentNodeID(
                of: candidateNodeID,
                nodes: capture.nodes,
                showsSystemWrappers: showsSystemWrapperViews
            )
        }

        return nil
    }

    private func collapseExpandedDescendants(
        of nodeID: String,
        capture: ViewScopeCapturePayload,
        expandedNodeIDs: inout Set<String>
    ) {
        guard let node = capture.nodes[nodeID] else { return }
        for childID in node.childIDs {
            expandedNodeIDs.remove(childID)
            collapseExpandedDescendants(
                of: childID,
                capture: capture,
                expandedNodeIDs: &expandedNodeIDs
            )
        }
    }
}
