import AppKit
import SnapKit

final class WorkspaceEmptyStateView: NSView {
    struct Configuration {
        let symbolName: String
        let title: String
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?
    }

    private let iconContainerView = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private let contentStackView = NSStackView()
    private var actionHandler: (() -> Void)?

    var messageText: String {
        messageLabel.stringValue
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        buildViewHierarchy()
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

    func configure(_ configuration: Configuration) {
        iconView.image = NSImage(systemSymbolName: configuration.symbolName, accessibilityDescription: nil)
        titleLabel.stringValue = configuration.title
        messageLabel.stringValue = configuration.message
        actionHandler = configuration.action

        if let actionTitle = configuration.actionTitle, configuration.action != nil {
            actionButton.title = actionTitle
            actionButton.isHidden = false
        } else {
            actionButton.title = ""
            actionButton.isHidden = true
        }
    }

    @objc private func handleAction(_ sender: Any?) {
        actionHandler?()
    }

    private func buildViewHierarchy() {
        iconContainerView.wantsLayer = true
        iconContainerView.translatesAutoresizingMaskIntoConstraints = false

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        iconView.contentTintColor = .secondaryLabelColor

        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .center

        messageLabel.font = NSFont.systemFont(ofSize: 13)
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.target = self
        actionButton.action = #selector(handleAction(_:))

        iconContainerView.addSubview(iconView)
        iconView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        contentStackView.orientation = .vertical
        contentStackView.alignment = .centerX
        contentStackView.spacing = 14
        contentStackView.addArrangedSubview(iconContainerView)
        contentStackView.addArrangedSubview(titleLabel)
        contentStackView.addArrangedSubview(messageLabel)
        contentStackView.addArrangedSubview(actionButton)

        addSubview(contentStackView)
        iconContainerView.snp.makeConstraints { make in
            make.width.height.equalTo(72)
        }
        messageLabel.snp.makeConstraints { make in
            make.width.lessThanOrEqualTo(340)
        }
        contentStackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().inset(20)
            make.trailing.lessThanOrEqualToSuperview().inset(20)
        }
    }

    private func applyAppearance() {
        iconContainerView.layer?.cornerRadius = 20
        iconContainerView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.09).cgColor
        iconContainerView.layer?.borderWidth = 1
        iconContainerView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
    }
}
