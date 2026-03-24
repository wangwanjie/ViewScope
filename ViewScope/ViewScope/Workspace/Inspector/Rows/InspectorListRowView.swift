import AppKit
import SnapKit

final class InspectorListRowView: NSView {
    init(title: String, values: [String]) {
        super.init(frame: .zero)

        let titleLabel = InspectorRowTitleLabel(text: title)
        let valueLabel = NSTextField(wrappingLabelWithString: values.joined(separator: "\n"))
        valueLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        valueLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

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
