import AppKit
import SnapKit

@MainActor
final class MainViewController: NSViewController {
    private enum Layout {
        static let toolbarHeight = WorkspaceTheme.Metrics.titlebarHeight
        static let toolbarLeadingInset = WorkspaceTheme.Metrics.trafficLightsInset
        static let sideInset = WorkspaceTheme.Metrics.panelGap
        static let bottomInset = WorkspaceTheme.Metrics.panelGap
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
        // 发现服务由 AppDelegate 在启动时开启，这里只做幂等兜底，不再依赖视图生命周期
        store.start()
    }

    private func buildUI() {
        addChild(toolbarController)
        addChild(workspaceController)

        view.addSubview(toolbarController.view)
        view.addSubview(workspaceController.view)

        // 工具栏与红绿灯同处标题栏这一行（窗口使用 fullSizeContentView + 透明标题栏）
        toolbarController.view.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.equalToSuperview().inset(Layout.toolbarLeadingInset)
            make.trailing.equalToSuperview()
            make.height.equalTo(Layout.toolbarHeight)
        }

        workspaceController.view.snp.makeConstraints { make in
            make.top.equalTo(toolbarController.view.snp.bottom)
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
        layer?.backgroundColor = resolvedCGColor(WorkspaceTheme.canvasBackground)
    }
}
