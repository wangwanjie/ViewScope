import AppKit
import Combine

@MainActor
/// 管理“修改记录”“抓取对比”两个辅助面板窗口。
///
/// 订阅 `store.panelRequests`，因此工具栏、菜单等任意入口只需调用 `store.requestPanel(_:)`。
final class WorkspaceAuxiliaryPanelCoordinator {
    private let store: WorkspaceStore
    private var modificationLogWindowController: NSWindowController?
    private var captureDiffWindowController: NSWindowController?
    private var cancellables = Set<AnyCancellable>()

    init(store: WorkspaceStore) {
        self.store = store
        store.panelRequests
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                self?.present(request)
            }
            .store(in: &cancellables)

        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.modificationLogWindowController?.window?.title = L10n.changesTitle
                self?.captureDiffWindowController?.window?.title = L10n.diffTitle
            }
            .store(in: &cancellables)
    }

    func present(_ request: WorkspacePanelRequest) {
        switch request {
        case .modificationLog:
            let controller = modificationLogWindowController ?? makeWindowController(
                contentViewController: ModificationLogViewController(store: store),
                title: L10n.changesTitle,
                autosaveName: "ViewScopeModificationLogWindow"
            )
            modificationLogWindowController = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        case .captureDiff:
            let controller = captureDiffWindowController ?? makeWindowController(
                contentViewController: CaptureDiffViewController(store: store),
                title: L10n.diffTitle,
                autosaveName: "ViewScopeCaptureDiffWindow"
            )
            captureDiffWindowController = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func makeWindowController(
        contentViewController: NSViewController,
        title: String,
        autosaveName: String
    ) -> NSWindowController {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 260)
        panel.contentViewController = contentViewController
        if panel.setFrameUsingName(autosaveName) == false {
            panel.center()
        }
        panel.setFrameAutosaveName(autosaveName)
        return NSWindowController(window: panel)
    }
}
