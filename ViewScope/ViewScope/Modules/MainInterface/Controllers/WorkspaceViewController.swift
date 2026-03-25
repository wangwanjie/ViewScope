import AppKit
import SnapKit

@MainActor
final class WorkspaceViewController: NSViewController {
    private enum Layout {
        static let inspectorWidth: CGFloat = 360
        static let panelSpacing: CGFloat = 12
        static let separatorWidth: CGFloat = 1
    }

    private let contentController: WorkspaceContentSplitViewController
    private let inspectorController: InspectorPanelController
    private let separatorView = WorkspaceSeparatorView()

    init(store: WorkspaceStore) {
        self.contentController = WorkspaceContentSplitViewController(store: store)
        self.inspectorController = InspectorPanelController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    private func buildUI() {
        addChild(contentController)
        addChild(inspectorController)

        view.addSubview(contentController.view)
        view.addSubview(separatorView)
        view.addSubview(inspectorController.view)

        contentController.view.snp.makeConstraints { make in
            make.top.leading.bottom.equalToSuperview()
            make.trailing.equalTo(separatorView.snp.leading).offset(-(Layout.panelSpacing / 2))
        }
        separatorView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalTo(contentController.view.snp.trailing).offset(Layout.panelSpacing / 2)
            make.width.equalTo(Layout.separatorWidth)
            make.height.equalToSuperview()
        }
        inspectorController.view.snp.makeConstraints { make in
            make.top.trailing.bottom.equalToSuperview()
            make.leading.equalTo(separatorView.snp.trailing).offset(Layout.panelSpacing / 2)
            make.width.equalTo(Layout.inspectorWidth)
        }
    }
}

private final class WorkspaceSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
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
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }
}
