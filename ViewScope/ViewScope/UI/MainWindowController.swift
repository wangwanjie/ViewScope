import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    private static let autosaveName = NSWindow.FrameAutosaveName("ViewScopeMainWindowFrame")
    let contentController: MainViewController

    init(store: WorkspaceStore) {
        contentController = MainViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1480, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ViewScope"
        window.subtitle = "Native AppKit UI inspection"
        window.appearance = NSAppearance(named: .aqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }
        window.isRestorable = false
        window.center()
        window.minSize = NSSize(width: 1220, height: 760)
        window.contentViewController = contentController
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
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

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        recenterWindowIfNeeded(window)
        window.deminiaturize(sender)
        window.setIsVisible(true)
        window.makeMain()
        window.makeKey()
        window.makeKeyAndOrderFront(sender)
        window.orderFrontRegardless()
    }

    func present(_ sender: Any? = nil) {
        showWindow(sender)
    }

    private func recenterWindowIfNeeded(_ window: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.contains(where: { $0.intersects(window.frame) }) else { return }

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let size = window.frame.size
            let centered = NSRect(
                x: frame.midX - (size.width / 2),
                y: frame.midY - (size.height / 2),
                width: size.width,
                height: size.height
            )
            window.setFrame(centered, display: false)
            return
        }

        window.center()
    }
}
