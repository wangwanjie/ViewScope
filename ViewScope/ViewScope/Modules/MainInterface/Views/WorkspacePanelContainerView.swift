import AppKit
import SnapKit

/// 工作区面板容器：圆角卡片 + 标题栏 + 内容区。
final class WorkspacePanelContainerView: NSView {
    private static let defaultInitialFrame = NSRect(x: 0, y: 0, width: 320, height: 220)

    let headerView = NSView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let accessoryStackView = NSStackView()
    let contentView = NSView()
    private let headerDivider = NSView()
    private let titleStack = NSStackView()
    private let headerStack = NSStackView()
    private let spacerView = NSView()

    override init(frame frameRect: NSRect) {
        let initialFrame = (frameRect.width > 0 && frameRect.height > 0)
            ? frameRect
            : Self.defaultInitialFrame
        super.init(frame: initialFrame)
        buildViewHierarchy()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String, subtitle: String? = nil) {
        titleLabel.stringValue = title
        if let subtitle, !subtitle.isEmpty, subtitle != title {
            subtitleLabel.stringValue = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.stringValue = ""
            subtitleLabel.isHidden = true
        }
    }

    /// 隐藏标题文字（标题栏完全留给工具按钮时使用）。
    var isTitleHidden: Bool {
        get { titleStack.isHidden }
        set { titleStack.isHidden = newValue }
    }

    /// 按组添加标题栏右侧的控件，组与组之间插入竖向分隔线。
    func setAccessoryGroups(_ groups: [[NSView]]) {
        accessoryStackView.arrangedSubviews.forEach {
            accessoryStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, group) in groups.enumerated() where group.isEmpty == false {
            if index > 0 {
                accessoryStackView.addArrangedSubview(WorkspaceToolbarDivider())
            }
            group.forEach {
                accessoryStackView.addArrangedSubview($0)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = WorkspaceTheme.Metrics.panelCornerRadius
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        headerDivider.wantsLayer = true

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isHidden = true

        accessoryStackView.orientation = .horizontal
        accessoryStackView.alignment = .centerY
        accessoryStackView.spacing = 2
        accessoryStackView.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 标题与副标题横向排列，副标题以次要颜色跟在标题后面，节省纵向空间
        titleStack.orientation = .horizontal
        titleStack.alignment = .firstBaseline
        titleStack.spacing = 6
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        headerView.addSubview(headerDivider)

        headerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(WorkspaceTheme.Metrics.panelHeaderHeight)
        }
        headerStack.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(14)
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
        }
        headerDivider.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(1)
        }
        contentView.snp.makeConstraints { make in
            make.top.equalTo(headerView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    private func applyAppearance() {
        layer?.backgroundColor = resolvedCGColor(WorkspaceTheme.panelBackground)
        layer?.borderColor = resolvedCGColor(WorkspaceTheme.panelBorder)
        headerDivider.layer?.backgroundColor = resolvedCGColor(WorkspaceTheme.hairline)
    }
}

/// 工具栏按钮组之间的竖向分隔线。
final class WorkspaceToolbarDivider: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        snp.makeConstraints { make in
            make.width.equalTo(1)
            make.height.equalTo(16)
        }
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 1, height: 16)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = resolvedCGColor(NSColor.separatorColor)
    }
}

/// 工具栏/面板标题栏使用的无边框图标按钮：悬停时显示浅色底，开启状态显示强调色。
final class WorkspaceIconButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            updateBackground()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 6
        snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(26)
            make.height.equalTo(26)
        }
    }

    /// 纯图标时固定 26pt 宽；带文字（如问题计数、缩放比例）时按内容加左右留白。
    override var intrinsicContentSize: NSSize {
        guard title.isEmpty == false else {
            return NSSize(width: 26, height: 26)
        }
        return NSSize(width: ceil(super.intrinsicContentSize.width) + 12, height: 26)
    }

    override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
        }
    }

    override var state: NSControl.StateValue {
        didSet {
            updateBackground()
        }
    }

    override var isEnabled: Bool {
        didSet {
            updateBackground()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        let background: NSColor
        // 瞬时按钮的 state 始终为 off，只有可切换按钮会进入开启态
        if state == .on && isEnabled {
            background = NSColor.controlAccentColor.withAlphaComponent(0.18)
            contentTintColor = .controlAccentColor
        } else if isHovering && isEnabled {
            background = NSColor.labelColor.withAlphaComponent(0.08)
            contentTintColor = .labelColor
        } else {
            background = .clear
            contentTintColor = .secondaryLabelColor
        }
        layer?.backgroundColor = resolvedCGColor(background)
    }
}
