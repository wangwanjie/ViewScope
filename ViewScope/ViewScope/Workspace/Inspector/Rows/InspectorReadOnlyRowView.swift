import AppKit
import SnapKit

final class InspectorReadOnlyRowView: NSView {
    init(title: String, value: String) {
        super.init(frame: .zero)

        let titleLabel = InspectorRowTitleLabel(text: title)
        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 10

        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
