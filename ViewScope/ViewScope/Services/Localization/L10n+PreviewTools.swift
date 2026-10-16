import Foundation

/// 预览工具（测量、取色、布局诊断、层级树搜索增强）文案。
///
/// key 统一使用 `preview_tools.` 前缀，文案追加在三个 `Localizable.strings` 的 PreviewTools 块里。
extension L10n {
    // MARK: - 严重程度

    static var previewToolsSeverityInfo: String { previewToolsString("preview_tools.severity.info") }
    static var previewToolsSeverityWarning: String { previewToolsString("preview_tools.severity.warning") }
    static var previewToolsSeverityError: String { previewToolsString("preview_tools.severity.error") }

    // MARK: - 诊断种类与说明

    static func previewToolsDiagnosticKindTitle(_ rawValue: String) -> String {
        previewToolsString("preview_tools.diagnostic.kind.\(rawValue)")
    }

    static var previewToolsDiagnosticMessageAmbiguous: String { previewToolsString("preview_tools.diagnostic.message.ambiguous") }
    static var previewToolsDiagnosticMessageOutsideClip: String { previewToolsString("preview_tools.diagnostic.message.outside_clip") }
    static func previewToolsDiagnosticMessageClipped(_ percent: Int) -> String {
        previewToolsString("preview_tools.diagnostic.message.clipped", percent)
    }
    static var previewToolsDiagnosticMessageOutsideParent: String { previewToolsString("preview_tools.diagnostic.message.outside_parent") }
    static var previewToolsDiagnosticMessageOutsideParentUntouchable: String {
        previewToolsString("preview_tools.diagnostic.message.outside_parent_untouchable")
    }
    static func previewToolsDiagnosticMessageZeroSize(_ childCount: Int) -> String {
        previewToolsString("preview_tools.diagnostic.message.zero_size", childCount)
    }
    static func previewToolsDiagnosticMessageMisaligned(_ rect: String, _ scale: String) -> String {
        previewToolsString("preview_tools.diagnostic.message.misaligned", rect, scale)
    }
    static var previewToolsDiagnosticMessageInvisibleInteractive: String {
        previewToolsString("preview_tools.diagnostic.message.invisible_interactive")
    }
    static var previewToolsDiagnosticMessageTruncated: String { previewToolsString("preview_tools.diagnostic.message.truncated") }
    static func previewToolsDiagnosticMessageUpscaled(_ imagePixels: String, _ neededPixels: String) -> String {
        previewToolsString("preview_tools.diagnostic.message.upscaled", imagePixels, neededPixels)
    }
    static func previewToolsDiagnosticMessageSmallTapTarget(_ width: String, _ height: String) -> String {
        previewToolsString("preview_tools.diagnostic.message.small_tap_target", width, height)
    }
    static func previewToolsDiagnosticMessageDepth(_ depth: Int) -> String {
        previewToolsString("preview_tools.diagnostic.message.depth", depth)
    }
    static func previewToolsDiagnosticMessageOccluded(_ occluder: String) -> String {
        previewToolsString("preview_tools.diagnostic.message.occluded", occluder)
    }

    // MARK: - 预览工具栏

    static var previewToolsMeasure: String { previewToolsString("preview_tools.action.measure") }
    static var previewToolsColorPicker: String { previewToolsString("preview_tools.action.color_picker") }
    static var previewToolsDiagnostics: String { previewToolsString("preview_tools.action.diagnostics") }
    static var previewToolsResetView: String { previewToolsString("preview_tools.action.reset_view") }
    static var previewToolsMeasureUnavailableIn3D: String { previewToolsString("preview_tools.measure.unavailable_3d") }
    static var previewToolsMeasureHint: String { previewToolsString("preview_tools.measure.hint") }
    static func previewToolsCursorPosition(_ x: String, _ y: String) -> String {
        previewToolsString("preview_tools.status.cursor", x, y)
    }
    static func previewToolsColorCopied(_ hex: String) -> String {
        previewToolsString("preview_tools.color.copied", hex)
    }
    static var previewToolsFlatSpacingHint: String { previewToolsString("preview_tools.settings.flat_spacing_hint") }

    // MARK: - 诊断面板

    static var previewToolsDiagnosticsTitle: String { previewToolsString("preview_tools.diagnostics.title") }
    static var previewToolsDiagnosticsEmpty: String { previewToolsString("preview_tools.diagnostics.empty") }
    static func previewToolsDiagnosticsSummary(errors: Int, warnings: Int, infos: Int) -> String {
        previewToolsString("preview_tools.diagnostics.summary", errors, warnings, infos)
    }
    static var previewToolsDiagnosticsShowOverlay: String { previewToolsString("preview_tools.diagnostics.show_overlay") }
    static var previewToolsDiagnosticsAllKinds: String { previewToolsString("preview_tools.diagnostics.all_kinds") }

    // MARK: - 层级树

    static var previewToolsTreeOnlyIssues: String { previewToolsString("preview_tools.tree.only_issues") }
    static func previewToolsSearchMatchCount(current: Int, total: Int) -> String {
        previewToolsString("preview_tools.search.match_count", current, total)
    }
    static var previewToolsSearchNoMatch: String { previewToolsString("preview_tools.search.no_match") }
    static var previewToolsSearchPrevious: String { previewToolsString("preview_tools.search.previous") }
    static var previewToolsSearchNext: String { previewToolsString("preview_tools.search.next") }

    /// `L10n.tr` 是私有的，这里提供等价的私有 helper。
    private static func previewToolsString(_ key: String, _ arguments: CVarArg...) -> String {
        AppLocalization.shared.string(key, arguments: arguments)
    }
}
