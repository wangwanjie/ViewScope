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
    private var currentNodeID: String?

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
                Task {
                    await self.commitCoordinator.commitText(
                        value,
                        property: model.property,
                        rowView: rowView,
                        nodeID: self.currentNodeID
                    )
                }
            }
            return rowView
        case .toggle(let model):
            let rowView = InspectorEditableToggleRowView(title: model.title, isOn: model.isOn)
            rowView.toggleHandler = { [weak self, weak rowView] isOn in
                guard let self, let rowView else { return }
                Task {
                    await self.commitCoordinator.commitToggle(
                        isOn,
                        property: model.property,
                        rowView: rowView,
                        nodeID: self.currentNodeID
                    )
                }
            }
            return rowView
        case .number(let model):
            let rowView = InspectorEditableNumberRowView(title: model.title, value: model.value)
            rowView.commitHandler = { [weak self, weak rowView] value in
                guard let self, let rowView else { return }
                Task {
                    await self.commitCoordinator.commitNumber(
                        value,
                        property: model.property,
                        rowView: rowView,
                        nodeID: self.currentNodeID
                    )
                }
            }
            return rowView
        case .quad(let model):
            let rowView = InspectorEditableQuadRowView(title: model.title, fields: model.fields)
            rowView.commitHandler = { [weak self, weak rowView] field, value in
                guard let self, let rowView else { return }
                Task {
                    await self.commitCoordinator.commitNumber(
                        value,
                        property: field.property,
                        rowView: rowView,
                        nodeID: self.currentNodeID
                    )
                }
            }
            return rowView
        case .color(let model):
            let rowView = InspectorEditableColorRowView(title: model.title, hexValue: model.value)
            rowView.commitHandler = { [weak self, weak rowView] hexValue in
                guard let self, let rowView else { return }
                Task {
                    await self.commitCoordinator.commitColor(
                        hexValue,
                        property: model.property,
                        rowView: rowView,
                        nodeID: self.currentNodeID
                    )
                }
            }
            return rowView
        }
    }
}
