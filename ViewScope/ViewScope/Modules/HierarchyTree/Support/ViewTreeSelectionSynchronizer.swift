import AppKit
import ViewScopeServer

enum ViewTreeUserSelectionChange: Equatable {
    case ignored
    case update(String?)
}

@MainActor
final class ViewTreeSelectionSynchronizer {
    private var isApplyingProgrammaticSelection = false

    /// 把 store 的选中同步到树。
    ///
    /// 所有对 NSOutlineView 选中状态的程序化修改（包括取消选中）都包在 `withProgrammaticSelection` 里，
    /// 否则 `deselectAll` 触发的回调会被当成用户操作，把 store 的选中清空。
    func syncSelection(
        selectedNodeID: String?,
        item: ViewTreeNodeItem?,
        outlineView: NSOutlineView,
        revealItem: (ViewTreeNodeItem) -> Void
    ) {
        guard selectedNodeID != nil, let item else {
            withProgrammaticSelection {
                outlineView.deselectAll(nil)
            }
            return
        }

        revealItem(item)
        let row = outlineView.row(forItem: item)
        guard row >= 0 else {
            withProgrammaticSelection {
                outlineView.deselectAll(nil)
            }
            return
        }

        withProgrammaticSelection {
            if outlineView.selectedRow != row {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            outlineView.scrollRowToVisible(row)
        }
    }

    func userSelectionChange(
        selectedRow: Int,
        itemAtRow: (Int) -> Any?
    ) -> ViewTreeUserSelectionChange {
        // 程序化选中会触发 NSOutlineView 的回调；这里显式忽略，
        // 防止把“同步 UI 状态”误当成“用户操作”再写回 store。
        guard !isApplyingProgrammaticSelection else {
            return .ignored
        }
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

    /// 支持嵌套调用：内层结束时不会提前清除外层的标记。
    func withProgrammaticSelection<T>(_ operation: () -> T) -> T {
        let wasApplying = isApplyingProgrammaticSelection
        isApplyingProgrammaticSelection = true
        defer {
            isApplyingProgrammaticSelection = wasApplying
        }
        return operation()
    }
}
