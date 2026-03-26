import AppKit
import ViewScopeServer
import ViewScopeServer

enum ViewTreeUserSelectionChange: Equatable {
    case ignored
    case update(String?)
}

@MainActor
final class ViewTreeSelectionSynchronizer {
    private var isApplyingProgrammaticSelection = false

    func syncSelection(
        selectedNodeID: String?,
        rootItems: [ViewTreeNodeItem],
        outlineView: NSOutlineView,
        expandAncestors: (ViewTreeNodeItem) -> Void
    ) {
        guard let selectedNodeID,
              let item = findItem(nodeID: selectedNodeID, items: rootItems) else {
            outlineView.deselectAll(nil)
            return
        }

        expandAncestors(item)
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }

        withProgrammaticSelection {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    func userSelectionChange(
        selectedRow: Int,
        itemAtRow: (Int) -> Any?
    ) -> ViewTreeUserSelectionChange {
        // 程序化选中会触发 NSOutlineView 的回调；这里显式忽略，
        // 防止把“同步 UI 状态”误当成“用户操作”再写回 store。
        guard !isApplyingProgrammaticSelection else { return .ignored }
        guard selectedRow >= 0,
              let item = itemAtRow(selectedRow) as? ViewTreeNodeItem else {
            return .update(nil)
        }
        return .update(item.node.id)
    }

    func beginProgrammaticSelection() {
        isApplyingProgrammaticSelection = true
    }

    func endProgrammaticSelection() {
        isApplyingProgrammaticSelection = false
    }

    func withProgrammaticSelection<T>(_ operation: () -> T) -> T {
        beginProgrammaticSelection()
        defer { endProgrammaticSelection() }
        return operation()
    }

    private func findItem(nodeID: String, items: [ViewTreeNodeItem]) -> ViewTreeNodeItem? {
        for item in items {
            if item.node.id == nodeID {
                return item
            }
            if let child = findItem(nodeID: nodeID, items: item.children) {
                return child
            }
        }
        return nil
    }
}
