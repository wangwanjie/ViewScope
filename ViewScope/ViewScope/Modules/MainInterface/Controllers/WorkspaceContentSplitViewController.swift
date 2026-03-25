import AppKit
import SnapKit

@MainActor
final class WorkspaceContentSplitViewController: NSViewController {
    private enum Layout {
        static let minimumTreeWidth: CGFloat = 240
        static let initialTreeWidth: CGFloat = 300
        static let minimumPreviewWidth: CGFloat = 480
        static let autosaveKey = "workspace.contentSplit.treeWidth"
        static let legacySplitAutosaveKey = "NSSplitView Subview Frames workspace.contentSplit"
    }

    private let treeController: ViewTreePanelController
    private let previewController: PreviewPanelController
    private let splitView = NSSplitView()
    private var didApplyInitialLayout = false

    init(store: WorkspaceStore) {
        self.treeController = ViewTreePanelController(store: store)
        self.previewController = PreviewPanelController(store: store)
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

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialLayoutIfNeeded()
    }

    private func buildUI() {
        splitView.isVertical = true
        splitView.dividerStyle = .paneSplitter
        splitView.delegate = self

        UserDefaults.standard.removeObject(forKey: Layout.legacySplitAutosaveKey)

        addChild(treeController)
        addChild(previewController)

        splitView.addArrangedSubview(treeController.view)
        splitView.addArrangedSubview(previewController.view)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        view.addSubview(splitView)

        splitView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func applyInitialLayoutIfNeeded() {
        guard !didApplyInitialLayout,
              splitView.bounds.width > 0,
              splitView.subviews.count >= 2 else {
            return
        }

        let treeWidth = splitView.subviews[0].frame.width
        let previewWidth = splitView.subviews[1].frame.width
        guard treeWidth > 0, previewWidth > 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.applyInitialLayoutIfNeeded()
            }
            return
        }

        didApplyInitialLayout = true
        applyTreeWidth(savedTreeWidth)
    }

    private var savedTreeWidth: CGFloat {
        let persistedWidth = UserDefaults.standard.double(forKey: Layout.autosaveKey)
        guard persistedWidth >= Layout.minimumTreeWidth else { return Layout.initialTreeWidth }
        return CGFloat(persistedWidth)
    }

    private var currentTreeWidth: CGFloat {
        treeController.view.frame.width
    }

    private func applyTreeWidth(_ requestedWidth: CGFloat) {
        let clampedWidth = clampTreeWidth(requestedWidth)
        splitView.setPosition(clampedWidth, ofDividerAt: 0)
        splitView.adjustSubviews()
        UserDefaults.standard.set(Double(clampedWidth), forKey: Layout.autosaveKey)
    }

    private func clampTreeWidth(_ width: CGFloat) -> CGFloat {
        let maxTreeWidth = max(
            Layout.minimumTreeWidth,
            splitView.bounds.width - splitView.dividerThickness - Layout.minimumPreviewWidth
        )
        return min(max(width, Layout.minimumTreeWidth), maxTreeWidth)
    }
}

extension WorkspaceContentSplitViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        Layout.minimumTreeWidth
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.width - splitView.dividerThickness - Layout.minimumPreviewWidth
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        clampTreeWidth(proposedPosition)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard didApplyInitialLayout else { return }
        UserDefaults.standard.set(Double(clampTreeWidth(currentTreeWidth)), forKey: Layout.autosaveKey)
    }
}
