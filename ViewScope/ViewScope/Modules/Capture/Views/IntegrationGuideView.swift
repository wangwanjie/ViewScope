import AppKit
import Combine
import SnapKit

struct IntegrationGuideContent {
    struct Entry {
        let title: String
        let snippet: String
    }

    static let currentReleaseVersion = "1.2.1"

    static func entries(releaseVersion: String) -> [Entry] {
        let minorVersion = releaseVersion
            .split(separator: ".")
            .prefix(2)
            .joined(separator: ".")
        
        let podBase = "pod 'ViewScopeServer', :git => 'https://github.com/wangwanjie/ViewScope.git'"
        let debugConfig = ", :configurations => ['Debug']"
        
        return [
            Entry(
                title: L10n.integrationSwiftPackageManager,
                snippet: ".package(url: \"https://github.com/wangwanjie/ViewScope.git\", from: \"\(releaseVersion)\")\nimport ViewScopeServer\n// Auto-starts after launch by default"
            ),
            Entry(
                title: L10n.integrationCocoaPods,
                snippet: """
                \(podBase), :tag => 'v\(releaseVersion)'\(debugConfig)
                或者
                \(podBase), :branch => 'main'\(debugConfig)
                """
            ),
            Entry(
                title: L10n.integrationCarthage,
                snippet: "github \"wangwanjie/ViewScope\" ~> \(minorVersion)"
            )
        ]
    }
}

final class IntegrationGuideView: NSView {
    enum HelpButtonPlacement {
        case bottom
    }

    private enum Layout {
        static let horizontalInset: CGFloat = 24
        static let preferredContentWidth: CGFloat = 960
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let contentStackView = NSStackView()
    private let cardsStackView = NSStackView()
    private let helpButton = NSButton()
    private var codeCards: [CodeCardView] = []
    private var cancellables = Set<AnyCancellable>()

    var showsSegmentedSelector: Bool {
        false
    }

    var visibleEntryTitles: [String] {
        codeCards.map(\.titleText)
    }

    var visibleSnippets: [String] {
        codeCards.map(\.snippet)
    }

    var helpButtonTitle: String {
        helpButton.title
    }

    var helpButtonPlacement: HelpButtonPlacement {
        .bottom
    }

    var visibleCardWidth: CGFloat {
        layoutSubtreeIfNeeded()
        return cardsStackView.bounds.width
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyAppearance()
        buildViewHierarchy()
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

    @objc private func openGitHubHomepage(_ sender: Any?) {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "ViewScopeGitHubURL") as? String,
              let url = URL(string: rawValue) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func buildViewHierarchy() {
        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        titleLabel.alignment = .center

        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.alignment = .center

        helpButton.bezelStyle = .rounded
        helpButton.controlSize = .large
        helpButton.target = self
        helpButton.action = #selector(openGitHubHomepage(_:))

        cardsStackView.orientation = .vertical
        cardsStackView.alignment = .width
        cardsStackView.spacing = 14

        contentStackView.orientation = .vertical
        contentStackView.alignment = .centerX
        contentStackView.spacing = 18
        contentStackView.addArrangedSubview(titleLabel)
        contentStackView.addArrangedSubview(subtitleLabel)
        contentStackView.addArrangedSubview(cardsStackView)
        contentStackView.addArrangedSubview(helpButton)

        addSubview(contentStackView)

        subtitleLabel.snp.makeConstraints { make in
            make.width.equalTo(contentStackView)
        }
        cardsStackView.snp.makeConstraints { make in
            make.width.equalTo(contentStackView)
        }
        contentStackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().inset(Layout.horizontalInset)
            make.trailing.lessThanOrEqualToSuperview().inset(Layout.horizontalInset)
            make.top.greaterThanOrEqualToSuperview().inset(Layout.horizontalInset)
            make.bottom.lessThanOrEqualToSuperview().inset(Layout.horizontalInset)
            make.width.lessThanOrEqualTo(Layout.preferredContentWidth)
            make.width.equalToSuperview().inset(Layout.horizontalInset * 2).priority(.high)
        }
    }

    private func applyLocalization() {
        titleLabel.stringValue = L10n.integrationTitle
        subtitleLabel.stringValue = L10n.integrationSubtitle
        helpButton.title = L10n.menuGitHub
        let entries = IntegrationGuideContent.entries(releaseVersion: IntegrationGuideContent.currentReleaseVersion)
        render(entries: entries)
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

    private func render(entries: [IntegrationGuideContent.Entry]) {
        codeCards.forEach {
            cardsStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        codeCards = entries.map { entry in
            let card = CodeCardView()
            card.configure(title: entry.title, snippet: entry.snippet)
            cardsStackView.addArrangedSubview(card)
            card.snp.makeConstraints { make in
                make.width.equalTo(cardsStackView)
            }
            return card
        }
    }
}

private final class CodeCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(wrappingLabelWithString: "")

    var snippet: String {
        codeLabel.stringValue
    }

    var titleText: String {
        titleLabel.stringValue
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        codeLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        codeLabel.lineBreakMode = .byWordWrapping
        codeLabel.textColor = .labelColor
        codeLabel.maximumNumberOfLines = 0

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
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }
}
