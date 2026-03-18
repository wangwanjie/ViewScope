import AppKit

@MainActor
final class WorkspaceContentSplitViewController: NSSplitViewController {
    private enum Layout {
        static let minimumTreeWidth: CGFloat = 240
        static let initialTreeWidth: CGFloat = 300
        static let minimumPreviewWidth: CGFloat = 480
    }

    private let treeController: ViewTreePanelController
    private let previewController: PreviewPanelController
    private var didApplyInitialLayout = false

    init(store: WorkspaceStore) {
        self.treeController = ViewTreePanelController(store: store)
        self.previewController = PreviewPanelController(store: store)
        super.init(nibName: nil, bundle: nil)
        configureSplitItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .paneSplitter
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didApplyInitialLayout, splitView.bounds.width > 0 else { return }
        didApplyInitialLayout = true
        splitView.setPosition(Layout.initialTreeWidth, ofDividerAt: 0)
    }

    private func configureSplitItems() {
        let treeItem = NSSplitViewItem(viewController: treeController)
        treeItem.minimumThickness = Layout.minimumTreeWidth
        treeItem.canCollapse = false
        treeItem.holdingPriority = .defaultHigh

        let previewItem = NSSplitViewItem(viewController: previewController)
        previewItem.minimumThickness = Layout.minimumPreviewWidth
        previewItem.canCollapse = false
        previewItem.holdingPriority = .defaultLow

        addSplitViewItem(treeItem)
        addSplitViewItem(previewItem)
    }
}
