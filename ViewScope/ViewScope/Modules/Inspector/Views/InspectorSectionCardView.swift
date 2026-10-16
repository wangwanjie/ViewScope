import AppKit

final class InspectorSectionCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = WorkspaceTheme.Metrics.sectionCornerRadius
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        // 分区只用浅色填充区分，不再描边，减少“框套框”的视觉噪音
        layer?.backgroundColor = resolvedCGColor(WorkspaceTheme.groupedFill)
    }
}
