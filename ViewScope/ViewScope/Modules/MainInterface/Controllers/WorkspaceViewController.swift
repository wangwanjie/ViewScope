import AppKit
import Combine
import SnapKit

@MainActor
final class WorkspaceViewController: NSViewController {
    private enum Layout {
        static let inspectorWidth: CGFloat = 360
        static let panelSpacing: CGFloat = 12
        static let separatorWidth: CGFloat = 1
    }

    private let store: WorkspaceStore
    private let contentController: WorkspaceContentSplitViewController
    private let inspectorController: InspectorPanelController
    private let separatorView = WorkspaceSeparatorView()
    private var cancellables = Set<AnyCancellable>()
    private var isShowingInspector: Bool?

    init(store: WorkspaceStore) {
        self.store = store
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
        bindSettings()
    }

    /// 根据偏好设置显示/隐藏 Inspector。
    private func bindSettings() {
        store.settings.$showsInspector
            .receive(on: RunLoop.main)
            .sink { [weak self] showsInspector in
                self?.applyInspectorVisibility(showsInspector)
            }
            .store(in: &cancellables)
    }

    private func applyInspectorVisibility(_ showsInspector: Bool) {
        guard isShowingInspector != showsInspector else {
            return
        }
        isShowingInspector = showsInspector
        inspectorController.view.isHidden = showsInspector == false
        separatorView.isHidden = showsInspector == false
        contentController.view.snp.remakeConstraints { make in
            make.top.leading.bottom.equalToSuperview()
            if showsInspector {
                make.trailing.equalTo(separatorView.snp.leading).offset(-(Layout.panelSpacing / 2))
            } else {
                make.trailing.equalToSuperview()
            }
        }
        separatorView.snp.remakeConstraints { make in
            make.centerY.equalToSuperview()
            make.width.equalTo(Layout.separatorWidth)
            make.height.equalToSuperview()
            if showsInspector {
                make.trailing.equalTo(inspectorController.view.snp.leading).offset(-(Layout.panelSpacing / 2))
            } else {
                make.leading.equalTo(view.snp.trailing)
            }
        }
        inspectorController.view.snp.remakeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.width.equalTo(Layout.inspectorWidth)
            if showsInspector {
                make.trailing.equalToSuperview()
            } else {
                // 隐藏时移到可见区域外，避免占用布局空间
                make.leading.equalTo(view.snp.trailing).offset(Layout.panelSpacing)
            }
        }
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
