import AppKit
import SnapKit

@MainActor
final class PreviewLayerSettingsPopoverController: NSViewController {
    private let spacingSlider = NSSlider(value: 22, minValue: 10, maxValue: 150, target: nil, action: nil)
    private let spacingValueLabel = NSTextField(labelWithString: "")
    private let spacingHintLabel = NSTextField(labelWithString: "")
    private let borderToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let isLayeredMode: Bool
    private let onLayerSpacingChange: (CGFloat) -> Void
    private let onShowsLayerBordersChange: (Bool) -> Void

    init(
        layerSpacing: CGFloat,
        showsLayerBorders: Bool,
        isLayeredMode: Bool = true,
        onLayerSpacingChange: @escaping (CGFloat) -> Void,
        onShowsLayerBordersChange: @escaping (Bool) -> Void
    ) {
        self.isLayeredMode = isLayeredMode
        self.onLayerSpacingChange = onLayerSpacingChange
        self.onShowsLayerBordersChange = onShowsLayerBordersChange
        super.init(nibName: nil, bundle: nil)
        spacingSlider.doubleValue = layerSpacing
        borderToggle.state = showsLayerBorders ? .on : .off
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        view = container

        let spacingTitleLabel = NSTextField(labelWithString: L10n.previewLayerSpacing)
        spacingTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        spacingValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        spacingValueLabel.alignment = .right

        spacingSlider.target = self
        spacingSlider.action = #selector(handleSpacingSlider(_:))
        // 平面预览下层间距没有效果：禁用滑块并给出提示，避免用户以为功能失效。
        spacingSlider.isEnabled = isLayeredMode
        spacingHintLabel.stringValue = L10n.previewToolsFlatSpacingHint
        spacingHintLabel.font = NSFont.systemFont(ofSize: 10.5)
        spacingHintLabel.textColor = .secondaryLabelColor
        spacingHintLabel.isHidden = isLayeredMode

        borderToggle.title = L10n.previewLayerBorders
        borderToggle.target = self
        borderToggle.action = #selector(handleBorderToggle(_:))

        container.addSubview(spacingTitleLabel)
        container.addSubview(spacingValueLabel)
        container.addSubview(spacingSlider)
        container.addSubview(spacingHintLabel)
        container.addSubview(borderToggle)

        spacingTitleLabel.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(12)
        }
        spacingValueLabel.snp.makeConstraints { make in
            make.centerY.equalTo(spacingTitleLabel)
            make.trailing.equalToSuperview().inset(12)
            make.leading.greaterThanOrEqualTo(spacingTitleLabel.snp.trailing).offset(12)
        }
        spacingSlider.snp.makeConstraints { make in
            make.top.equalTo(spacingTitleLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(12)
        }
        spacingHintLabel.snp.makeConstraints { make in
            make.top.equalTo(spacingSlider.snp.bottom).offset(4)
            make.leading.trailing.equalToSuperview().inset(12)
        }
        borderToggle.snp.makeConstraints { make in
            make.top.equalTo(isLayeredMode ? spacingSlider.snp.bottom : spacingHintLabel.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview().inset(12)
        }

        updateSpacingValueLabel()
        preferredContentSize = NSSize(width: 260, height: isLayeredMode ? 104 : 124)
    }

    @objc private func handleSpacingSlider(_ sender: NSSlider) {
        let spacing = CGFloat(sender.doubleValue)
        updateSpacingValueLabel()
        onLayerSpacingChange(spacing)
    }

    @objc private func handleBorderToggle(_ sender: NSButton) {
        onShowsLayerBordersChange(sender.state == .on)
    }

    private func updateSpacingValueLabel() {
        spacingValueLabel.stringValue = String(format: "%.0f", spacingSlider.doubleValue)
    }
}
