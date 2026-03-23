import AppKit
import Combine
import UniformTypeIdentifiers
import ViewScopeServer

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: WorkspaceStore?
    private var mainWindowController: MainWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var statusItemController: StatusItemController?
    private var hasPresentedInitialWindow = false
    private var pendingOpenFileURLs: [URL] = []
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
                self?.consumePendingOpenFileURLsIfNeeded()
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

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.isEmpty == false else { return }
        if store == nil {
            pendingOpenFileURLs.append(contentsOf: urls)
            return
        }
        openCaptureFiles(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        application(sender, open: filenames.map { URL(fileURLWithPath: $0) })
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
        Task { await store.refreshCapture(forceReloadSelectionDetail: true, clearingVisibleState: true) }
    }

    @objc private func openCaptureFile(_ sender: Any?) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.viewScopeCapture]

        guard openPanel.runModal() == .OK else { return }
        openCaptureFiles(openPanel.urls)
    }

    @objc private func exportCaptureFile(_ sender: Any?) {
        guard let store,
              let document = store.makeRawPreviewExport() else {
            NSSound.beep()
            return
        }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "ViewScopeCapture-\(document.capture.captureID).\(WorkspaceArchiveCodec.fileExtension)"
        savePanel.allowedContentTypes = [.viewScopeCapture]
        savePanel.isExtensionHidden = false

        guard savePanel.runModal() == .OK,
              let url = savePanel.url else {
            return
        }

        do {
            let data = try WorkspaceArchiveCodec.encode(document)
            try data.write(to: url, options: .atomic)
        } catch {
            presentErrorAlert(error)
        }
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

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L10n.menuFile)
        let openItem = NSMenuItem(title: L10n.menuOpenCaptureFile, action: #selector(openCaptureFile(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        let exportItem = NSMenuItem(title: L10n.menuExportCaptureFile, action: #selector(exportCaptureFile(_:)), keyEquivalent: "e")
        exportItem.target = self
        exportItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(exportItem)
        fileItem.title = L10n.menuFile
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

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
        presentErrorAlert(error, messageText: L10n.fatalLaunchTitle)
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

    private func consumePendingOpenFileURLsIfNeeded() {
        guard pendingOpenFileURLs.isEmpty == false else { return }
        let urls = pendingOpenFileURLs
        pendingOpenFileURLs.removeAll()
        openCaptureFiles(urls)
    }

    private func openCaptureFiles(_ urls: [URL]) {
        guard let store else { return }

        for url in urls {
            do {
                try store.loadPreviewExport(from: url)
                openMainWindow(nil)
            } catch {
                presentErrorAlert(error)
            }
        }
    }

    private func presentErrorAlert(_ error: Error, messageText: String = L10n.fatalLaunchTitle) {
        let alert = NSAlert(error: error)
        alert.messageText = messageText
        alert.informativeText = error.localizedDescription
        alert.runModal()
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

private extension JSONEncoder {
    static var viewScopeDebug: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension UTType {
    static let viewScopeCapture = UTType(exportedAs: WorkspaceArchiveCodec.typeIdentifier, conformingTo: .data)
}
