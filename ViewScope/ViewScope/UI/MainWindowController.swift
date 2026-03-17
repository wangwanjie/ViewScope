import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    private static let autosaveName = NSWindow.FrameAutosaveName("ViewScopeMainWindowFrame")

    init(store: WorkspaceStore) {
        let contentController = MainViewController(store: store)
        let window = NSWindow(contentViewController: contentController)
        window.title = "ViewScope"
        window.subtitle = "Native AppKit UI inspection"
        window.appearance = NSAppearance(named: .aqua)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }
        window.isRestorable = false
        window.setContentSize(NSSize(width: 1480, height: 920))
        window.minSize = NSSize(width: 1220, height: 760)
        super.init(window: window)
        shouldCascadeWindows = false

        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
