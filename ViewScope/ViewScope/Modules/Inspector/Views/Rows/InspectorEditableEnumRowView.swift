import AppKit
import SnapKit
import ViewScopeServer

/// 枚举属性行：使用下拉框选择候选值。
final class InspectorEditableEnumRowView: NSView, InspectorCommitCapable {
    private let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let options: [ViewScopeEditableOption]
    private let originalIndex: Int?

    var selectionHandler: ((Double) -> Void)?

    init(title: String, options: [ViewScopeEditableOption], selectedIndex: Int?, currentValueText: String) {
        self.options = options
        self.originalIndex = selectedIndex
        super.init(frame: .zero)

        let titleLabel = InspectorRowTitleLabel(text: title)
        popUpButton.controlSize = .small
        popUpButton.font = NSFont.systemFont(ofSize: 12)
        popUpButton.target = self
        popUpButton.action = #selector(handleSelection(_:))
        for option in options {
            popUpButton.addItem(withTitle: option.title)
        }
        if selectedIndex == nil {
            // 当前值不在候选项中：追加一个不可选的占位项显示原始值
            popUpButton.addItem(withTitle: currentValueText)
            popUpButton.lastItem?.isEnabled = false
            popUpButton.autoenablesItems = false
        }
        resetDisplayedValue()

        let stack = NSStackView(views: [titleLabel, popUpButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        popUpButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setEditingEnabled(_ enabled: Bool) {
        popUpButton.isEnabled = enabled
    }

    func resetDisplayedValue() {
        if let originalIndex {
            popUpButton.selectItem(at: originalIndex)
        } else {
            popUpButton.selectItem(at: options.count)
        }
    }

    @objc private func handleSelection(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < options.count else {
            return
        }
        selectionHandler?(options[index].value)
    }
}
