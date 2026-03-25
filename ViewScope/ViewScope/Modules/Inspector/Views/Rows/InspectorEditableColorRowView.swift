import AppKit
import SnapKit

final class InspectorEditableColorRowView: NSView, InspectorCommitCapable {
    private let colorWell = NSColorWell()
    private let textField: InspectorTextField
    private let originalValue: String

    var commitHandler: ((String) -> Void)?

    init(title: String, hexValue: String) {
        self.originalValue = hexValue
        self.textField = InspectorTextField(value: hexValue)
        super.init(frame: .zero)

        let titleLabel = InspectorRowTitleLabel(text: title)
        colorWell.target = self
        colorWell.action = #selector(handleColorWell(_:))
        colorWell.color = NSColor(viewScopeHexString: hexValue) ?? .clear
        textField.onCommit = { [weak self] in
            self?.commitHandler?(self?.textField.stringValue ?? "")
        }

        let controls = NSStackView(views: [colorWell, textField])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let stack = NSStackView(views: [titleLabel, controls])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        textField.snp.makeConstraints { make in
            make.width.equalTo(110)
            make.height.equalTo(26)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setEditingEnabled(_ enabled: Bool) {
        colorWell.isEnabled = enabled
        textField.isEnabled = enabled
    }

    func resetDisplayedValue() {
        textField.stringValue = originalValue
        colorWell.color = NSColor(viewScopeHexString: originalValue) ?? .clear
    }

    @objc private func handleColorWell(_ sender: NSColorWell) {
        let hex = sender.color.viewScopeHexString
        textField.stringValue = hex
        commitHandler?(hex)
    }
}
