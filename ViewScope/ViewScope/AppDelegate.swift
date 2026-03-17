import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: WorkspaceStore?
    private var mainWindowController: MainWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var statusItemController: StatusItemController?
    private var hasPresentedInitialWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            NSApp.setActivationPolicy(.regular)
            let store = try WorkspaceStore()
            self.store = store

            buildMainMenu()

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
        appMenu.addItem(NSMenuItem(title: "About ViewScope", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        let preferencesItem = NSMenuItem(title: "Preferences", action: #selector(openPreferencesWindow(_:)), keyEquivalent: ",")
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        let updateItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Hide ViewScope", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit ViewScope", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let showWindowItem = NSMenuItem(title: "Show Main Window", action: #selector(openMainWindow(_:)), keyEquivalent: "1")
        showWindowItem.keyEquivalentModifierMask = [.command]
        showWindowItem.target = self
        viewMenu.addItem(showWindowItem)
        let refreshItem = NSMenuItem(title: "Refresh Capture", action: #selector(refreshCapture(_:)), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(refreshItem)
        viewItem.title = "View"
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu
        windowItem.title = "Window"
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let githubItem = NSMenuItem(title: "ViewScope on GitHub", action: #selector(openGitHubHomepage(_:)), keyEquivalent: "?")
        githubItem.target = self
        helpMenu.addItem(githubItem)
        helpItem.title = "Help"
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
    }

    private func presentFatalError(_ error: Error) {
        NSApp.setActivationPolicy(.regular)
        activateAppBringingAllWindowsForward()
        let alert = NSAlert(error: error)
        alert.messageText = "ViewScope could not launch"
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
