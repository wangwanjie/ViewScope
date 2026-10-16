import AppKit
import Foundation

/// 单条布局问题。
struct LayoutDiagnosticIssue: Hashable {
    enum Severity: Int, Comparable, CaseIterable {
        case info = 0
        case warning = 1
        case error = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// 树徽标、预览描边使用的颜色。
        var color: NSColor {
            switch self {
            case .info:
                return .systemBlue
            case .warning:
                return .systemOrange
            case .error:
                return .systemRed
            }
        }

        var title: String {
            switch self {
            case .info:
                return L10n.previewToolsSeverityInfo
            case .warning:
                return L10n.previewToolsSeverityWarning
            case .error:
                return L10n.previewToolsSeverityError
            }
        }
    }

    enum Kind: String, CaseIterable {
        case ambiguousLayout
        case clippedByAncestor
        case outsideParentBounds
        case zeroSizeWithVisibleChildren
        case misalignedToPixels
        case invisibleButInteractive
        case occludedBySibling
        case textTruncated
        case imageUpscaled
        case smallTapTarget
        case excessiveDepth

        /// 每种问题的默认严重程度。
        var defaultSeverity: Severity {
            switch self {
            case .ambiguousLayout:
                return .error
            case .misalignedToPixels, .excessiveDepth:
                return .info
            case .clippedByAncestor,
                 .outsideParentBounds,
                 .zeroSizeWithVisibleChildren,
                 .invisibleButInteractive,
                 .occludedBySibling,
                 .textTruncated,
                 .imageUpscaled,
                 .smallTapTarget:
                return .warning
            }
        }

        var title: String {
            L10n.previewToolsDiagnosticKindTitle(rawValue)
        }
    }

    let nodeID: String
    let kind: Kind
    let severity: Severity
    /// 面向用户的说明（已本地化）。
    let message: String
}

/// 一次抓取的诊断汇总，供树、预览与诊断面板共享。
struct LayoutDiagnosticsReport {
    let issuesByNodeID: [String: [LayoutDiagnosticIssue]]
    /// 所有问题，按严重程度降序、种类、节点 ID 排序，便于列表展示。
    let allIssues: [LayoutDiagnosticIssue]
    let countsByKind: [LayoutDiagnosticIssue.Kind: Int]
    let countsBySeverity: [LayoutDiagnosticIssue.Severity: Int]

    static let empty = LayoutDiagnosticsReport(issuesByNodeID: [:])

    init(issuesByNodeID: [String: [LayoutDiagnosticIssue]]) {
        self.issuesByNodeID = issuesByNodeID
        let flattened = issuesByNodeID.values.flatMap { $0 }
        allIssues = flattened.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity > rhs.severity
            }
            if lhs.kind != rhs.kind {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.nodeID < rhs.nodeID
        }
        var kindCounts: [LayoutDiagnosticIssue.Kind: Int] = [:]
        var severityCounts: [LayoutDiagnosticIssue.Severity: Int] = [:]
        for issue in flattened {
            kindCounts[issue.kind, default: 0] += 1
            severityCounts[issue.severity, default: 0] += 1
        }
        countsByKind = kindCounts
        countsBySeverity = severityCounts
    }

    var isEmpty: Bool {
        issuesByNodeID.isEmpty
    }

    func issues(for nodeID: String) -> [LayoutDiagnosticIssue] {
        issuesByNodeID[nodeID] ?? []
    }

    /// 节点问题的最高严重程度；没有问题时为 nil。
    func maximumSeverity(for nodeID: String) -> LayoutDiagnosticIssue.Severity? {
        issuesByNodeID[nodeID]?.map(\.severity).max()
    }

    /// 树徽标 tooltip：逐条列出问题。
    func tooltip(for nodeID: String) -> String? {
        let issues = issues(for: nodeID)
        guard issues.isEmpty == false else {
            return nil
        }
        return issues
            .sorted { $0.severity > $1.severity }
            .map { "[\($0.severity.title)] \($0.kind.title): \($0.message)" }
            .joined(separator: "\n")
    }
}
