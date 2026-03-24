import AppKit
import SnapKit

final class InspectorEditableToggleRowView: NSView, InspectorCommitCapable {
    private let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let originalValue: Bool

    var toggleHandler: ((Bool) -> Void)?

    init(title: String, isOn: Bool) {
        self.originalValue = isOn
        super.init(frame: .zero)

        let titleLabel = InspectorRowTitleLabel(text: title)
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(handleToggle(_:))

        let stack = NSStackView(views: [titleLabel, toggle])
        stack.orientation = .horizontal
        stack.alignment = .centerY
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
        toggle.isEnabled = enabled
    }

    func resetDisplayedValue() {
        toggle.state = originalValue ? .on : .off
    }

    @objc private func handleToggle(_ sender: NSButton) {
        toggleHandler?(sender.state == .on)
    }
}
