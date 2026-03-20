import AppKit
import Combine
import SnapKit
import ViewScopeServer

@MainActor
final class InspectorPanelController: NSViewController {
    private let store: WorkspaceStore
    private let panelView = WorkspacePanelContainerView()
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let stackView = NSStackView()
    private let emptyStateView = WorkspaceEmptyStateView()
    private let builder = InspectorPanelModelBuilder()
    private var cancellables = Set<AnyCancellable>()
    private var currentNodeID: String?

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = panelView
        panelView.setAccessibilityElement(true)
        panelView.setAccessibilityRole(.group)
        panelView.setAccessibilityIdentifier("workspace.inspectorPanel")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bindStore()
        renderCurrentState()
    }

    private func buildUI() {
        panelView.setTitle(L10n.inspector)

        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 14

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = documentView

        documentView.addSubview(stackView)

        panelView.contentView.addSubview(scrollView)
        panelView.contentView.addSubview(emptyStateView)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        emptyStateView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        documentView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.width.equalTo(scrollView.contentView)
            make.height.greaterThanOrEqualTo(scrollView.contentView)
            make.bottom.equalTo(stackView.snp.bottom).offset(14)
        }
        stackView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(14)
        }
    }

    private func bindStore() {
        Publishers.CombineLatest4(store.$capture, store.$selectedNodeID, store.$selectedNodeDetail, AppLocalization.shared.$language)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.renderCurrentState()
            }
            .store(in: &cancellables)
    }

    private func renderCurrentState() {
        let node = store.selectedNode
        currentNodeID = node?.id
        let model = builder.makeModel(capture: store.capture, node: node, detail: store.selectedNodeDetail)
        panelView.setTitle(model.title, subtitle: model.subtitle)

        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if let placeholder = model.placeholder {
            scrollView.isHidden = true
            emptyStateView.isHidden = false
            emptyStateView.configure(
                .init(
                    symbolName: store.capture == nil ? "slider.horizontal.3" : "cursorarrow.click.2",
                    title: store.capture == nil ? L10n.inspectorEmptyDisconnectedTitle : L10n.inspectorEmptySelectionTitle,
                    message: placeholder,
                    actionTitle: nil,
                    action: nil
                )
            )
            return
        }

        scrollView.isHidden = false
        emptyStateView.isHidden = true

        model.sections.forEach { section in
            let sectionView = makeSectionView(section)
            stackView.addArrangedSubview(sectionView)
            sectionView.snp.makeConstraints { make in
                make.width.equalTo(stackView)
            }
        }
    }

    private func makeSectionView(_ section: InspectorSectionModel) -> NSView {
        let container = InspectorSectionCardView()
        container.setContentHuggingPriority(.required, for: .vertical)
        container.setContentCompressionResistancePriority(.required, for: .vertical)

        let titleLabel = NSTextField(labelWithString: section.title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 8

        container.addSubview(titleLabel)
        container.addSubview(rowsStack)
        titleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }
        rowsStack.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview().inset(12)
        }

        section.rows.forEach { row in
            let rowView = makeRowView(row)
            rowsStack.addArrangedSubview(rowView)
            rowView.snp.makeConstraints { make in
                make.width.equalTo(rowsStack)
            }
        }

        return container
    }

    private func makeRowView(_ row: InspectorRowModel) -> NSView {
        switch row {
        case .readOnly(let title, let value):
            return InspectorReadOnlyRowView(title: title, value: value)
        case .list(let title, let values):
            return InspectorListRowView(title: title, values: values)
        case .text(let model):
            let rowView = InspectorEditableTextRowView(title: model.title, value: model.value)
            rowView.commitHandler = { [weak self, weak rowView] value in
                guard let self, let rowView else { return }
                self.commitTextValue(value, property: model.property, rowView: rowView)
            }
            return rowView
        case .toggle(let model):
            let rowView = InspectorEditableToggleRowView(title: model.title, isOn: model.isOn)
            rowView.toggleHandler = { [weak self, weak rowView] isOn in
                guard let self, let rowView else { return }
                self.commitToggleValue(isOn, property: model.property, rowView: rowView)
            }
            return rowView
        case .number(let model):
            let rowView = InspectorEditableNumberRowView(title: model.title, value: model.value)
            rowView.commitHandler = { [weak self, weak rowView] value in
                guard let self, let rowView else { return }
                self.commitNumberValue(value, property: model.property, rowView: rowView)
            }
            return rowView
        case .quad(let model):
            let rowView = InspectorEditableQuadRowView(title: model.title, fields: model.fields)
            rowView.commitHandler = { [weak self, weak rowView] field, value in
                guard let self, let rowView else { return }
                self.commitNumberValue(value, property: field.property, rowView: rowView)
            }
            return rowView
        case .color(let model):
            let rowView = InspectorEditableColorRowView(title: model.title, hexValue: model.value)
            rowView.commitHandler = { [weak self, weak rowView] hexValue in
                guard let self, let rowView else { return }
                self.commitColorValue(hexValue, property: model.property, rowView: rowView)
            }
            return rowView
        }
    }

    private func commitTextValue(_ value: String, property: ViewScopeEditableProperty, rowView: InspectorCommitCapable) {
        commitProperty(.text(key: property.key, value: value), rowView: rowView)
    }

    private func commitToggleValue(_ isOn: Bool, property: ViewScopeEditableProperty, rowView: InspectorCommitCapable) {
        commitProperty(.toggle(key: property.key, value: isOn), rowView: rowView)
    }

    private func commitNumberValue(_ value: String, property: ViewScopeEditableProperty, rowView: InspectorCommitCapable) {
        guard let number = parseNumber(value) else {
            NSSound.beep()
            rowView.resetDisplayedValue()
            return
        }
        commitProperty(.number(key: property.key, value: number), rowView: rowView)
    }

    private func commitColorValue(_ value: String, property: ViewScopeEditableProperty, rowView: InspectorCommitCapable) {
        guard NSColor(viewScopeHexString: value) != nil else {
            NSSound.beep()
            rowView.resetDisplayedValue()
            return
        }
        commitProperty(.text(key: property.key, value: value.uppercased()), rowView: rowView)
    }

    private func commitProperty(_ property: ViewScopeEditableProperty, rowView: InspectorCommitCapable) {
        guard let nodeID = currentNodeID else { return }
        rowView.setEditingEnabled(false)
        Task { [weak self] in
            guard let self else { return }
            let success = await store.applyMutation(nodeID: nodeID, property: property)
            await MainActor.run {
                rowView.setEditingEnabled(true)
                if !success {
                    rowView.resetDisplayedValue()
                }
            }
        }
    }

    private func parseNumber(_ value: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = AppLocalization.shared.locale
        formatter.numberStyle = .decimal
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let number = formatter.number(from: trimmed) {
            return number.doubleValue
        }
        return Double(trimmed)
    }
}

private final class InspectorSectionCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
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

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
    }
}

private protocol InspectorCommitCapable: AnyObject {
    func setEditingEnabled(_ enabled: Bool)
    func resetDisplayedValue()
}

private final class InspectorReadOnlyRowView: NSView {
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

private final class InspectorListRowView: NSView {
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

private final class InspectorEditableTextRowView: NSView, InspectorCommitCapable {
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

private final class InspectorEditableNumberRowView: NSView, InspectorCommitCapable {
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

private final class InspectorEditableToggleRowView: NSView, InspectorCommitCapable {
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

private final class InspectorEditableQuadRowView: NSView, InspectorCommitCapable {
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

private final class InspectorEditableColorRowView: NSView, InspectorCommitCapable {
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

private final class InspectorRowTitleLabel: NSTextField {
    init(text: String, width: CGFloat = 88) {
        super.init(frame: .zero)
        stringValue = text.uppercased()
        font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        textColor = .secondaryLabelColor
        isBezeled = false
        isBordered = false
        isEditable = false
        drawsBackground = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        snp.makeConstraints { make in
            make.width.equalTo(width)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class InspectorTextField: NSTextField {
    var onCommit: (() -> Void)?

    init(value: String) {
        super.init(frame: .zero)
        stringValue = value
        font = NSFont.systemFont(ofSize: 12)
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        isBordered = true
        isBezeled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onCommit?()
    }
}

private extension NSColor {
    convenience init?(viewScopeHexString: String) {
        let sanitized = viewScopeHexString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6 || sanitized.count == 8,
              let rawValue = UInt64(sanitized, radix: 16) else {
            return nil
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        if sanitized.count == 8 {
            red = CGFloat((rawValue & 0xFF000000) >> 24) / 255
            green = CGFloat((rawValue & 0x00FF0000) >> 16) / 255
            blue = CGFloat((rawValue & 0x0000FF00) >> 8) / 255
            alpha = CGFloat(rawValue & 0x000000FF) / 255
        } else {
            red = CGFloat((rawValue & 0xFF0000) >> 16) / 255
            green = CGFloat((rawValue & 0x00FF00) >> 8) / 255
            blue = CGFloat(rawValue & 0x0000FF) / 255
            alpha = 1
        }

        self.init(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }

    var viewScopeHexString: String {
        guard let rgb = usingColorSpace(.deviceRGB) else {
            return "#000000FF"
        }
        return String(
            format: "#%02X%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255)),
            Int(round(rgb.alphaComponent * 255))
        )
    }
}
