import AppKit
import Combine

@MainActor
/// Owns the main application window and restores its frame between launches.
final class MainWindowController: NSWindowController {
    private static let autosaveName = NSWindow.FrameAutosaveName("ViewScopeMainWindowFrame")
    let contentController: MainViewController
    private var cancellables = Set<AnyCancellable>()

    init(store: WorkspaceStore) {
        contentController = MainViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1480, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.appName
        window.subtitle = L10n.mainWindowSubtitle
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
        normalizeWindowFrame(window)
        window.setFrameAutosaveName(Self.autosaveName)
        bindLocalization()
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

    private func bindLocalization() {
        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.window?.title = L10n.appName
                self?.window?.subtitle = L10n.mainWindowSubtitle
            }
            .store(in: &cancellables)
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

    private func normalizeWindowFrame(_ window: NSWindow) {
        let targetScreen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(window.frame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let targetScreen else { return }

        let visibleFrame = targetScreen.visibleFrame
        var frame = window.frame
        frame.size.width = min(max(frame.size.width, window.minSize.width), visibleFrame.width)
        frame.size.height = min(max(frame.size.height, window.minSize.height), visibleFrame.height)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.size.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.size.height)

        guard frame != window.frame else { return }
        window.setFrame(frame, display: false)
    }
}
