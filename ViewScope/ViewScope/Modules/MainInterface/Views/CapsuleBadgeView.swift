import AppKit

final class CapsuleBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let horizontalInset: CGFloat
    private let verticalInset: CGFloat
    private let minimumHeight: CGFloat

    init(fontSize: CGFloat = 12, horizontalInset: CGFloat = 10, verticalInset: CGFloat = 4, minimumHeight: CGFloat = 24) {
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset
        self.minimumHeight = minimumHeight
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = minimumHeight / 2

        label.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalInset),
            heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    func applyStyle(textColor: NSColor, backgroundColor: NSColor) {
        label.textColor = textColor
        layer?.backgroundColor = backgroundColor.cgColor
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        let width = labelSize.width + (horizontalInset * 2)
        let height = max(minimumHeight, labelSize.height + (verticalInset * 2))
        layer?.cornerRadius = height / 2
        return NSSize(width: width, height: height)
    }
}
