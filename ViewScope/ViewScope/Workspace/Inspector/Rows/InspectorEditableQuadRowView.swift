import AppKit
import SnapKit

final class InspectorEditableQuadRowView: NSView, InspectorCommitCapable {
    private enum Metrics {
        static let titleWidth: CGFloat = 56
        static let fieldWidth: CGFloat = 48
        static let fieldSpacing: CGFloat = 4
    }

    private var fieldViews: [InspectorTextField] = []
    private let originalValues: [String]

    var commitHandler: ((InspectorEditableQuadModel.Field, String) -> Void)?

    init(title: String, fields: [InspectorEditableQuadModel.Field]) {
        self.originalValues = fields.map(\.value)
        super.init(frame: .zero)

        let titleLabel = InspectorRowTitleLabel(text: title, width: Metrics.titleWidth)
        let fieldsStack = NSStackView()
        fieldsStack.orientation = .horizontal
        fieldsStack.alignment = .centerY
        fieldsStack.spacing = Metrics.fieldSpacing

        fields.forEach { field in
            let label = NSTextField(labelWithString: field.label)
            label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor

            let input = InspectorTextField(value: field.value)
            input.onCommit = { [weak self, weak input] in
                guard let self, let input else { return }
                self.commitHandler?(field, input.stringValue)
            }
            fieldViews.append(input)

            let container = NSStackView(views: [label, input])
            container.orientation = .vertical
            container.alignment = .leading
            container.spacing = 3
            fieldsStack.addArrangedSubview(container)
            input.snp.makeConstraints { make in
                make.width.equalTo(Metrics.fieldWidth)
                make.height.equalTo(26)
            }
        }

        let stack = NSStackView(views: [titleLabel, fieldsStack])
        stack.orientation = .horizontal
        stack.alignment = .top
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

    func setEditingEnabled(_ enabled: Bool) {
        fieldViews.forEach { $0.isEnabled = enabled }
    }

    func resetDisplayedValue() {
        zip(fieldViews, originalValues).forEach { view, value in
            view.stringValue = value
        }
    }
}
