import AppKit
import SnapKit

final class InspectorEditableNumberRowView: NSView, InspectorCommitCapable {
    private let textField: InspectorTextField
    private let originalValue: String

    var commitHandler: ((String) -> Void)?

    init(title: String, value: String) {
        self.textField = InspectorTextField(value: value)
        self.originalValue = value
        super.init(frame: .zero)

        let titleLabel = InspectorRowTitleLabel(text: title)
        textField.onCommit = { [weak self] in
            self?.commitHandler?(self?.textField.stringValue ?? "")
        }

        let stack = NSStackView(views: [titleLabel, textField])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        textField.snp.makeConstraints { make in
            make.width.equalTo(92)
            make.height.equalTo(26)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setEditingEnabled(_ enabled: Bool) {
        textField.isEnabled = enabled
    }

    func resetDisplayedValue() {
        textField.stringValue = originalValue
    }
}
