import Combine
import Foundation
import ViewScopeServer

/// 一次成功的实时属性修改。
///
/// 旧值取自用户编辑时 Inspector 行里的可编辑属性（即服务端下发的当前值），
/// 用于“还原”“撤销”和导出代码。
struct WorkspaceModificationRecord: Identifiable, Equatable {
    enum State: Equatable {
        /// 修改当前生效。
        case applied
        /// 已被撤销（可重做）。
        case undone
    }

    let id: UUID
    let date: Date
    let hostIdentifier: String
    let hostDisplayName: String
    let platform: ViewScopePlatform
    let nodeID: String
    let nodeKind: ViewScopeHierarchyNode.Kind?
    let nodeAddress: String?
    let className: String
    let hostViewClassName: String?
    let ivarName: String?
    let key: String
    let title: String
    let oldValue: ViewScopeEditableProperty?
    let newValue: ViewScopeEditableProperty
    var state: State

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        hostIdentifier: String,
        hostDisplayName: String,
        platform: ViewScopePlatform,
        nodeID: String,
        nodeKind: ViewScopeHierarchyNode.Kind? = nil,
        nodeAddress: String? = nil,
        className: String,
        hostViewClassName: String? = nil,
        ivarName: String? = nil,
        key: String,
        title: String,
        oldValue: ViewScopeEditableProperty?,
        newValue: ViewScopeEditableProperty,
        state: State = .applied
    ) {
        self.id = id
        self.date = date
        self.hostIdentifier = hostIdentifier
        self.hostDisplayName = hostDisplayName
        self.platform = platform
        self.nodeID = nodeID
        self.nodeKind = nodeKind
        self.nodeAddress = nodeAddress
        self.className = className
        self.hostViewClassName = hostViewClassName
        self.ivarName = ivarName
        self.key = key
        self.title = title
        self.oldValue = oldValue
        self.newValue = newValue
        self.state = state
    }

    /// 界面展示用的对象类名：带宿主视图的 layer 节点优先显示视图类名。
    var displayClassName: String {
        hostViewClassName ?? className
    }
}

/// 把可编辑属性格式化为便于阅读的字符串。
enum WorkspaceModificationValueFormatter {
    static func displayString(for property: ViewScopeEditableProperty?) -> String {
        guard let property else {
            return "—"
        }
        switch property.kind {
        case .toggle:
            return (property.boolValue ?? false) ? "YES" : "NO"
        case .number:
            let value = property.numberValue ?? 0
            // 枚举属性优先显示候选项标题
            if let option = property.options?.first(where: { $0.value == value }) {
                return option.title
            }
            return compactNumber(value)
        case .text:
            return property.textValue ?? ""
        }
    }

    /// 去掉多余的小数位：12 → "12"，0.5 → "0.5"，1/3 → "0.3333"。
    static func compactNumber(_ value: Double) -> String {
        guard value.isFinite else {
            return "0"
        }
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }
}

@MainActor
/// 修改记录与撤销/重做栈。
///
/// - `records` 保存所有成功的修改（包括被撤销的，状态为 `.undone`）；
/// - 撤销栈只在同一宿主会话内有效，切换宿主时由 Store 调用 `invalidateUndoHistory()`。
final class WorkspaceModificationLog {
    @Published private(set) var records: [WorkspaceModificationRecord] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [UUID] = []
    private var redoStack: [UUID] = []
    private let maximumRecords: Int

    init(maximumRecords: Int = 500) {
        self.maximumRecords = maximumRecords
    }

    /// 记录一次新修改：入撤销栈，并清空重做栈。
    func append(_ record: WorkspaceModificationRecord) {
        records.append(record)
        if records.count > maximumRecords {
            let removed = records.prefix(records.count - maximumRecords).map(\.id)
            records.removeFirst(records.count - maximumRecords)
            let removedSet = Set(removed)
            undoStack.removeAll { removedSet.contains($0) }
            redoStack.removeAll { removedSet.contains($0) }
        }
        undoStack.append(record.id)
        redoStack.removeAll()
        syncFlags()
    }

    func record(withID id: UUID) -> WorkspaceModificationRecord? {
        records.first(where: { $0.id == id })
    }

    /// 下一条可撤销的记录（不出栈）。
    var nextUndoRecord: WorkspaceModificationRecord? {
        undoStack.last.flatMap { record(withID: $0) }
    }

    /// 下一条可重做的记录（不出栈）。
    var nextRedoRecord: WorkspaceModificationRecord? {
        redoStack.last.flatMap { record(withID: $0) }
    }

    /// 撤销成功后调用：记录移入重做栈并标记为已撤销。
    func markUndone(_ id: UUID) {
        guard undoStack.last == id else {
            return
        }
        undoStack.removeLast()
        redoStack.append(id)
        updateState(of: id, to: .undone)
        syncFlags()
    }

    /// 重做成功后调用：记录移回撤销栈并标记为生效。
    func markRedone(_ id: UUID) {
        guard redoStack.last == id else {
            return
        }
        redoStack.removeLast()
        undoStack.append(id)
        updateState(of: id, to: .applied)
        syncFlags()
    }

    /// 切换宿主/断开时调用：节点引用已失效，撤销与重做都不再可用，但保留日志。
    func invalidateUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        syncFlags()
    }

    func clear() {
        records.removeAll()
        invalidateUndoHistory()
    }

    private func updateState(of id: UUID, to state: WorkspaceModificationRecord.State) {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return
        }
        records[index].state = state
    }

    private func syncFlags() {
        let nextCanUndo = undoStack.isEmpty == false
        let nextCanRedo = redoStack.isEmpty == false
        if canUndo != nextCanUndo {
            canUndo = nextCanUndo
        }
        if canRedo != nextCanRedo {
            canRedo = nextCanRedo
        }
    }
}
