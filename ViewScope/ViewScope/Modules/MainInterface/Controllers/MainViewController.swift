import AppKit
import SnapKit

@MainActor
final class MainViewController: NSViewController {
    private enum Layout {
        static let toolbarHeight: CGFloat = 52
        static let topInset: CGFloat = 10
        static let sideInset: CGFloat = 12
        static let bottomInset: CGFloat = 12
        static let sectionSpacing: CGFloat = 12
    }

    private let store: WorkspaceStore
    private let toolbarController: WorkspaceToolbarViewController
    private let workspaceController: WorkspaceViewController

    init(store: WorkspaceStore) {
        self.store = store
        self.toolbarController = WorkspaceToolbarViewController(store: store)
        self.workspaceController = WorkspaceViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = WorkspaceBackgroundView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        store.start()
    }

    private func buildUI() {
        addChild(toolbarController)
        addChild(workspaceController)

        view.addSubview(toolbarController.view)
        view.addSubview(workspaceController.view)

        toolbarController.view.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(Layout.topInset)
            make.leading.trailing.equalToSuperview().inset(Layout.sideInset)
            make.height.equalTo(Layout.toolbarHeight)
        }

        workspaceController.view.snp.makeConstraints { make in
            make.top.equalTo(toolbarController.view.snp.bottom).offset(Layout.sectionSpacing)
            make.leading.trailing.equalToSuperview().inset(Layout.sideInset)
            make.bottom.equalToSuperview().inset(Layout.bottomInset)
        }
    }
}

private final class WorkspaceBackgroundView: NSView {
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
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}
