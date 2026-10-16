import AppKit
import Combine
import SnapKit
import ViewScopeServer

@MainActor
final class InspectorPanelController: NSViewController {
    private let store: WorkspaceStore
    private let commitCoordinator: InspectorPropertyCommitCoordinator
    private let panelView = WorkspacePanelContainerView()
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let stackView = NSStackView()
    private let emptyStateView = WorkspaceEmptyStateView()
    private let builder = InspectorPanelModelBuilder()
    private var cancellables = Set<AnyCancellable>()
    /// 上一次渲染的模型；模型未变化时不重建，避免打断用户操作。
    private var lastRenderedModel: InspectorPanelModel?
    /// 有字段正在编辑时推迟的重建。
    private var hasPendingRender = false

    init(store: WorkspaceStore) {
        self.store = store
        self.commitCoordinator = InspectorPropertyCommitCoordinator(store: store)
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
        stackView.spacing = 10

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
            make.bottom.equalTo(stackView.snp.bottom).offset(12)
        }
        stackView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }
    }

    private func bindStore() {
        Publishers.CombineLatest4(store.$capture, store.$selectedNodeID, store.$selectedNodeDetail, AppLocalization.shared.$language)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.renderCurrentState()
            }
            .store(in: &cancellables)

        // 字段结束编辑后，补上编辑期间被推迟的重建
        NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self,
                      let field = notification.object as? NSView,
                      field.isDescendant(of: self.documentView),
                      self.hasPendingRender else {
                    return
                }
                // 等提交流程把行禁用/恢复后再重建
                DispatchQueue.main.async { [weak self] in
                    self?.renderCurrentState()
                }
            }
            .store(in: &cancellables)
    }

    /// 是否有 Inspector 内的文本框正在编辑。
    var isEditingField: Bool {
        guard let textView = view.window?.firstResponder as? NSTextView, textView.isFieldEditor else {
            return false
        }
        guard let field = textView.delegate as? NSView else {
            return false
        }
        return field.isDescendant(of: documentView)
    }

    private func renderCurrentState() {
        let node = store.selectedNode
        let model = builder.makeModel(capture: store.capture, node: node, detail: store.selectedNodeDetail)
        guard model != lastRenderedModel else {
            hasPendingRender = false
            return
        }
        // 用户正在编辑字段时不重建（否则输入框被移除，半截值会被提交），等编辑结束后再刷新
        if isEditingField, lastRenderedModel?.editableNodeID == model.editableNodeID, model.editableNodeID != nil {
            hasPendingRender = true
            return
        }
        hasPendingRender = false
        lastRenderedModel = model
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
            let sectionView = makeSectionView(section, nodeID: model.editableNodeID)
            stackView.addArrangedSubview(sectionView)
            sectionView.snp.makeConstraints { make in
                make.width.equalTo(stackView)
            }
        }
    }

    private func makeSectionView(_ section: InspectorSectionModel, nodeID: String?) -> NSView {
        let container = InspectorSectionCardView()
        container.setContentHuggingPriority(.required, for: .vertical)
        container.setContentCompressionResistancePriority(.required, for: .vertical)

        let titleLabel = NSTextField(labelWithString: section.title)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 8

        container.addSubview(titleLabel)
        container.addSubview(rowsStack)
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(10)
            make.leading.trailing.equalToSuperview().inset(12)
        }
        rowsStack.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(12)
            make.bottom.equalToSuperview().inset(12)
        }

        section.rows.forEach { row in
            let rowView = makeRowView(row, nodeID: nodeID)
            rowsStack.addArrangedSubview(rowView)
            rowView.snp.makeConstraints { make in
                make.width.equalTo(rowsStack)
            }
        }

        return container
    }

    /// 创建行视图。提交目标固定为创建时 detail 对应的节点，避免选中切换后写错节点。
    private func makeRowView(_ row: InspectorRowModel, nodeID: String?) -> NSView {
        switch row {
        case .readOnly(let title, let value):
            return InspectorReadOnlyRowView(title: title, value: value)
        case .list(let title, let values):
            return InspectorListRowView(title: title, values: values)
        case .text(let model):
            let rowView = InspectorEditableTextRowView(title: model.title, value: model.value)
            rowView.commitHandler = { [weak self, weak rowView] value in
                guard let self, let rowView else {
                    return
                }
                Task {
                    await self.commitCoordinator.commitText(
                        value,
                        property: model.property,
                        rowView: rowView,
                        nodeID: nodeID,
                        title: model.title
                    )
                }
            }
            return rowView
        case .toggle(let model):
            let rowView = InspectorEditableToggleRowView(title: model.title, isOn: model.isOn)
            rowView.toggleHandler = { [weak self, weak rowView] isOn in
                guard let self, let rowView else {
                    return
                }
                Task {
                    await self.commitCoordinator.commitToggle(
                        isOn,
                        property: model.property,
                        rowView: rowView,
                        nodeID: nodeID,
                        title: model.title
                    )
                }
            }
            return rowView
        case .number(let model):
            let rowView = InspectorEditableNumberRowView(title: model.title, value: model.value)
            rowView.commitHandler = { [weak self, weak rowView] value in
                guard let self, let rowView else {
                    return
                }
                Task {
                    await self.commitCoordinator.commitNumber(
                        value,
                        property: model.property,
                        rowView: rowView,
                        nodeID: nodeID,
                        title: model.title
                    )
                }
            }
            return rowView
        case .enumeration(let model):
            let rowView = InspectorEditableEnumRowView(
                title: model.title,
                options: model.options,
                selectedIndex: model.selectedIndex,
                currentValueText: WorkspaceModificationValueFormatter.displayString(for: model.property)
            )
            rowView.selectionHandler = { [weak self, weak rowView] value in
                guard let self, let rowView else {
                    return
                }
                Task {
                    await self.commitCoordinator.commitEnumeration(
                        value,
                        property: model.property,
                        rowView: rowView,
                        nodeID: nodeID,
                        title: model.title
                    )
                }
            }
            return rowView
        case .quad(let model):
            let rowView = InspectorEditableQuadRowView(title: model.title, fields: model.fields)
            rowView.commitHandler = { [weak self, weak rowView] field, value in
                guard let self, let rowView else {
                    return
                }
                Task {
                    await self.commitCoordinator.commitNumber(
                        value,
                        property: field.property,
                        rowView: rowView,
                        nodeID: nodeID,
                        title: field.title.isEmpty ? model.title : field.title
                    )
                }
            }
            return rowView
        case .color(let model):
            let rowView = InspectorEditableColorRowView(title: model.title, hexValue: model.value)
            rowView.commitHandler = { [weak self, weak rowView] hexValue in
                guard let self, let rowView else {
                    return
                }
                Task {
                    await self.commitCoordinator.commitColor(
                        hexValue,
                        property: model.property,
                        rowView: rowView,
                        nodeID: nodeID,
                        title: model.title
                    )
                }
            }
            return rowView
        }
    }
}
