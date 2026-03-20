import AppKit
import Combine
import ViewScopeServer

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: WorkspaceStore?
    private var mainWindowController: MainWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var statusItemController: StatusItemController?
    private var hasPresentedInitialWindow = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid exposing the ViewScope client itself as an inspectable host.
        ViewScopeInspector.disableAutomaticStart()

        do {
            NSApp.setActivationPolicy(.regular)
            let store = try WorkspaceStore()
            self.store = store

            buildMainMenu()
            bindLocalization()

            let mainWindowController = MainWindowController(store: store)
            self.mainWindowController = mainWindowController
            self.preferencesWindowController = PreferencesWindowController(store: store)
            self.statusItemController = StatusItemController(
                store: store,
                openMainWindowHandler: { [weak self] in self?.openMainWindow(nil) },
                openPreferencesHandler: { [weak self] in self?.openPreferencesWindow(nil) }
            )

            store.updateManager.configure()
            store.updateManager.scheduleBackgroundUpdateCheck()
            DispatchQueue.main.async { [weak self] in
                self?.presentInitialMainWindowIfNeeded()
            }
            runAutomationIfNeeded()
        } catch {
            presentFatalError(error)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        presentInitialMainWindowIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.shutdown()
        statusItemController = nil
        mainWindowController = nil
        preferencesWindowController = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        openMainWindow(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    @objc private func openMainWindow(_ sender: Any?) {
        hasPresentedInitialWindow = true
        guard let mainWindowController else { return }
        present(mainWindowController: mainWindowController, sender: sender)
    }

    @objc private func refreshCapture(_ sender: Any?) {
        guard let store else { return }
        Task { await store.refreshCapture() }
    }

    @objc private func openPreferencesWindow(_ sender: Any?) {
        preferencesWindowController?.showPreferencesWindow()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        store?.updateManager.checkForUpdates()
    }

    @objc private func openGitHubHomepage(_ sender: Any?) {
        store?.updateManager.openGitHubHomepage()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: L10n.menuAbout, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        let preferencesItem = NSMenuItem(title: L10n.menuPreferences, action: #selector(openPreferencesWindow(_:)), keyEquivalent: ",")
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        let updateItem = NSMenuItem(title: L10n.menuCheckForUpdates, action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: L10n.menuHideApp, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: L10n.menuHideOthers, action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: L10n.menuShowAll, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: L10n.menuQuitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L10n.menuView)
        let showWindowItem = NSMenuItem(title: L10n.menuShowMainWindow, action: #selector(openMainWindow(_:)), keyEquivalent: "1")
        showWindowItem.keyEquivalentModifierMask = [.command]
        showWindowItem.target = self
        viewMenu.addItem(showWindowItem)
        let refreshItem = NSMenuItem(title: L10n.menuRefreshCapture, action: #selector(refreshCapture(_:)), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(refreshItem)
        viewItem.title = L10n.menuView
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.menuWindow)
        windowMenu.addItem(NSMenuItem(title: L10n.menuCloseWindow, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: L10n.menuMinimize, action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: L10n.menuZoom, action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu
        windowItem.title = L10n.menuWindow
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: L10n.menuHelp)
        let githubItem = NSMenuItem(title: L10n.menuGitHub, action: #selector(openGitHubHomepage(_:)), keyEquivalent: "?")
        githubItem.target = self
        helpMenu.addItem(githubItem)
        helpItem.title = L10n.menuHelp
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
    }

    private func bindLocalization() {
        guard cancellables.isEmpty else { return }
        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.buildMainMenu()
            }
            .store(in: &cancellables)
    }

    private func presentFatalError(_ error: Error) {
        NSApp.setActivationPolicy(.regular)
        activateAppBringingAllWindowsForward()
        let alert = NSAlert(error: error)
        alert.messageText = L10n.fatalLaunchTitle
        alert.informativeText = error.localizedDescription
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func presentInitialMainWindowIfNeeded() {
        guard !hasPresentedInitialWindow else { return }
        guard let mainWindowController else { return }

        hasPresentedInitialWindow = true
        present(mainWindowController: mainWindowController, sender: nil)
    }

    private func present(mainWindowController: MainWindowController, sender: Any?) {
        mainWindowController.present(sender)
        activateAppBringingAllWindowsForward()
    }

    private func activateAppBringingAllWindowsForward() {
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func runAutomationIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        let mainScreenshotPath = environment["VIEWSCOPE_AUTOMATION_MAIN_SCREENSHOT"]
        let preferencesScreenshotPath = environment["VIEWSCOPE_AUTOMATION_PREFERENCES_SCREENSHOT"]
        guard mainScreenshotPath != nil || preferencesScreenshotPath != nil else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: 800_000_000)

            do {
                if let mainScreenshotPath {
                    try WindowSnapshot.writePNG(
                        for: self.mainWindowController?.window,
                        to: URL(fileURLWithPath: mainScreenshotPath)
                    )
                }

                if let preferencesScreenshotPath {
                    self.preferencesWindowController?.showPreferencesWindow()
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    try WindowSnapshot.writePNG(
                        for: self.preferencesWindowController?.window,
                        to: URL(fileURLWithPath: preferencesScreenshotPath)
                    )
                }
            } catch {
                NSLog("ViewScope automation failed: %@", error.localizedDescription)
            }

            if environment["VIEWSCOPE_AUTOMATION_TERMINATE"] != "0" {
                NSApp.terminate(nil)
            }
        }
    }
}
