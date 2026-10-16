import Combine
import CoreGraphics
import Foundation
import ViewScopeServer

@MainActor
/// 预览区“检查工具”的共享状态：悬停联动、测量、布局诊断开关。
///
/// 由 `WorkspaceStore` 持有一份实例（`store.inspectionTools`），
/// 层级树与预览面板都订阅它，避免把这些纯 UI 状态塞进 `WorkspaceStore` 本身。
final class WorkspaceInspectionToolsState {
    /// 当前鼠标悬停的节点（树或预览任一侧），用于双向 hover 高亮。
    @Published var hoveredNodeID: String?
    /// 是否开启测量模式：开启后，选中节点与悬停节点之间显示间距标注。
    @Published var isMeasurementEnabled = false
    /// 测量时固定的参照节点；为 nil 时使用当前选中节点。
    @Published var measurementAnchorNodeID: String?
    /// 是否在预览与层级树中标记布局问题。
    @Published var showsDiagnostics = true
    /// 按住 Option 键时临时开启测量（类似 Sketch / Reveal），松开即恢复。
    @Published var isTemporaryMeasurementActive = false
    /// 层级树是否只显示存在布局问题的节点（以及它们的祖先链）。
    @Published var showsOnlyIssueNodes = false
    /// 是否开启取色器：开启后预览区单击复制光标下像素的十六进制颜色，而不是选中节点。
    @Published var isColorPickerEnabled = false

    /// 其它面板请求把焦点移到层级树搜索框（例如在预览区按下 Cmd+F）。
    let searchFocusRequests = PassthroughSubject<Void, Never>()

    /// hover 写入合并：同一个 runloop 周期内多次写入只发布最后一次，避免鼠标移动时频繁触发重绘。
    private var pendingHoveredNodeID: String??
    private var isHoverFlushScheduled = false

    /// 诊断结果缓存：同一次抓取只分析一次，树和预览共享。
    private var cachedDiagnosticsKey: String?
    private var cachedDiagnosticsReport = LayoutDiagnosticsReport.empty

    /// 测量是否实际生效（常驻开关或 Option 临时开启任一满足）。
    var isMeasurementActive: Bool {
        isMeasurementEnabled || isTemporaryMeasurementActive
    }

    /// 断开连接或切换宿主时重置。
    func reset() {
        hoveredNodeID = nil
        measurementAnchorNodeID = nil
        isTemporaryMeasurementActive = false
        pendingHoveredNodeID = nil
        cachedDiagnosticsKey = nil
        cachedDiagnosticsReport = .empty
    }

    /// 合并写入悬停节点：鼠标移动产生的高频写入会在下一个主线程周期统一发布一次。
    func setHoveredNodeIDCoalesced(_ nodeID: String?) {
        pendingHoveredNodeID = .some(nodeID)
        guard isHoverFlushScheduled == false else {
            return
        }
        isHoverFlushScheduled = true
        MainRunLoopScheduler.perform { [weak self] in
            self?.flushPendingHover()
        }
    }

    /// 立即清除悬停（鼠标离开视图时调用），同时丢弃尚未发布的合并写入。
    func clearHover() {
        pendingHoveredNodeID = nil
        if hoveredNodeID != nil {
            hoveredNodeID = nil
        }
    }

    /// 返回某次抓取的诊断结果；同一 captureID 只计算一次。
    func diagnosticsReport(for capture: ViewScopeCapturePayload?) -> LayoutDiagnosticsReport {
        guard let capture else {
            return .empty
        }
        let key = "\(capture.captureID)|\(capture.nodes.count)"
        if cachedDiagnosticsKey == key {
            return cachedDiagnosticsReport
        }
        let issues = LayoutDiagnosticsAnalyzer.analyze(
            capture: capture,
            platform: capture.host.resolvedPlatform
        )
        let report = LayoutDiagnosticsReport(issuesByNodeID: issues)
        cachedDiagnosticsKey = key
        cachedDiagnosticsReport = report
        return report
    }

    private func flushPendingHover() {
        isHoverFlushScheduled = false
        guard let pending = pendingHoveredNodeID else {
            return
        }
        pendingHoveredNodeID = nil
        if hoveredNodeID != pending {
            hoveredNodeID = pending
        }
    }
}
