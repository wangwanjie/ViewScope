import AppKit
import SnapKit

final class WorkspacePanelContainerView: NSView {
    let headerView = NSVisualEffectView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let accessoryStackView = NSStackView()
    let contentView = NSView()
    private let titleStack = NSStackView()
    private let headerStack = NSStackView()
    private let spacerView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildViewHierarchy()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String, subtitle: String? = nil) {
        titleLabel.stringValue = title
        if let subtitle, !subtitle.isEmpty {
            subtitleLabel.stringValue = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.stringValue = ""
            subtitleLabel.isHidden = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func buildViewHierarchy() {
        wantsLayer = true

        headerView.material = .headerView
        headerView.blendingMode = .withinWindow
        headerView.state = .active
        headerView.wantsLayer = true
        headerView.layer?.borderWidth = 1

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isHidden = true

        accessoryStackView.orientation = .horizontal
        accessoryStackView.alignment = .centerY
        accessoryStackView.spacing = 8

        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(subtitleLabel)

        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8
        headerStack.addArrangedSubview(titleStack)
        headerStack.addArrangedSubview(spacerView)
        headerStack.addArrangedSubview(accessoryStackView)

        addSubview(headerView)
        addSubview(contentView)
        headerView.addSubview(headerStack)

        headerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(42)
        }
        headerStack.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.trailing.equalToSuperview().inset(10)
            make.centerY.equalToSuperview()
        }
        contentView.snp.makeConstraints { make in
            make.top.equalTo(headerView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        headerView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }
}
