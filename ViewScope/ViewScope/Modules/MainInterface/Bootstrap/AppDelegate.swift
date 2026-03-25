import AppKit
import ViewScopeServer

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: WorkspaceStore?
    private var captureFileService: CaptureFileService?
    private var mainWindowController: MainWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var mainMenuController: MainMenuController?
    private var statusItemController: StatusItemController?
    private var hasPresentedInitialWindow = false
    private var pendingOpenFileURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid exposing the ViewScope client itself as an inspectable host.
        ViewScopeInspector.disableAutomaticStart()

        do {
            NSApp.setActivationPolicy(.regular)
            let store = try WorkspaceStore()
            self.store = store
            let captureFileService = CaptureFileService(store: store)
            self.captureFileService = captureFileService

            let mainWindowController = MainWindowController(store: store)
            self.mainWindowController = mainWindowController
            self.preferencesWindowController = PreferencesWindowController(store: store)
            self.mainMenuController = MainMenuController(
                store: store,
                captureFileService: captureFileService,
                openMainWindowHandler: { [weak self] in self?.openMainWindow(nil) },
                openPreferencesHandler: { [weak self] in self?.preferencesWindowController?.showPreferencesWindow() },
                presentErrorHandler: { [weak self] error in self?.presentErrorAlert(error) }
            )
            self.statusItemController = StatusItemController(
                store: store,
                openMainWindowHandler: { [weak self] in self?.openMainWindow(nil) },
                openPreferencesHandler: { [weak self] in self?.preferencesWindowController?.showPreferencesWindow() }
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
        captureFileService = nil
        mainMenuController = nil
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
        if captureFileService == nil {
            pendingOpenFileURLs.append(contentsOf: urls)
            return
        }
        captureFileService?.importFiles(
            at: urls,
            didImport: { [weak self] in self?.openMainWindow(nil) },
            onError: { [weak self] error in self?.presentErrorAlert(error) }
        )
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
        captureFileService?.importFiles(
            at: urls,
            didImport: { [weak self] in self?.openMainWindow(nil) },
            onError: { [weak self] error in self?.presentErrorAlert(error) }
        )
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
