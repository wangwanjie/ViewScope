import AppKit
import Combine
import SnapKit

final class IntegrationGuideView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let swiftPackageCard = CodeCardView()
    private let cocoaPodsCard = CodeCardView()
    private let carthageCard = CodeCardView()
    private var cancellables = Set<AnyCancellable>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyAppearance()

        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [swiftPackageCard, cocoaPodsCard, carthageCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(stack)

        titleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(24)
        }
        subtitleLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(24)
        }
        stack.snp.makeConstraints { make in
            make.top.equalTo(subtitleLabel.snp.bottom).offset(18)
            make.leading.trailing.bottom.lessThanOrEqualToSuperview().inset(24)
        }
        [swiftPackageCard, cocoaPodsCard, carthageCard].forEach { card in
            card.snp.makeConstraints { make in
                make.width.equalTo(stack)
            }
        }

        applyLocalization()
        bindLocalization()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyLocalization() {
        titleLabel.stringValue = L10n.integrationTitle
        subtitleLabel.stringValue = L10n.integrationSubtitle
        swiftPackageCard.configure(
            title: L10n.integrationSwiftPackageManager,
            snippet: ".package(url: \"https://github.com/wangwanjie/ViewScope.git\", from: \"1.1.0\")\nimport ViewScopeServer\n// Auto-starts after launch by default"
        )
        cocoaPodsCard.configure(
            title: L10n.integrationCocoaPods,
            snippet: "pod 'ViewScopeServer', :git => 'https://github.com/wangwanjie/ViewScope.git', :tag => 'v1.1.0', :configurations => ['Debug']"
        )
        carthageCard.configure(
            title: L10n.integrationCarthage,
            snippet: "github \"wangwanjie/ViewScope\" ~> 1.1"
        )
    }

    private func bindLocalization() {
        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyLocalization()
            }
            .store(in: &cancellables)
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

private final class CodeCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        codeLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        codeLabel.lineBreakMode = .byCharWrapping
        codeLabel.textColor = .labelColor

        addSubview(titleLabel)
        addSubview(codeLabel)

        titleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(16)
        }
        codeLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview().inset(16)
        }

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

    func configure(title: String, snippet: String) {
        titleLabel.stringValue = title
        codeLabel.stringValue = snippet
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }
}
