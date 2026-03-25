import AppKit
import Combine

@MainActor
final class MainMenuController: NSObject {
    private let store: WorkspaceStore
    private let captureFileService: CaptureFileService
    private let openMainWindowHandler: () -> Void
    private let openPreferencesHandler: () -> Void
    private let presentErrorHandler: (Error) -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        store: WorkspaceStore,
        captureFileService: CaptureFileService,
        openMainWindowHandler: @escaping () -> Void,
        openPreferencesHandler: @escaping () -> Void,
        presentErrorHandler: @escaping (Error) -> Void
    ) {
        self.store = store
        self.captureFileService = captureFileService
        self.openMainWindowHandler = openMainWindowHandler
        self.openPreferencesHandler = openPreferencesHandler
        self.presentErrorHandler = presentErrorHandler
        super.init()
        rebuildMainMenu()
        bindLocalization()
    }

    private func bindLocalization() {
        // 菜单标题依赖当前语言，切换语言后需要整棵菜单重建。
        AppLocalization.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMainMenu()
            }
            .store(in: &cancellables)
    }

    private func rebuildMainMenu() {
        let mainMenu = NSMenu()

        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeFileMenuItem())
        mainMenu.addItem(makeViewMenuItem())
        mainMenu.addItem(makeWindowMenuItem())
        mainMenu.addItem(makeHelpMenuItem())

        NSApp.mainMenu = mainMenu
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appItem = NSMenuItem()
        let appMenu = NSMenu()

        appMenu.addItem(NSMenuItem(title: L10n.menuAbout, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))

        let preferencesItem = NSMenuItem(title: L10n.menuPreferences, action: #selector(openPreferencesWindow), keyEquivalent: ",")
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)

        let updateItem = NSMenuItem(title: L10n.menuCheckForUpdates, action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(updateItem)

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: L10n.menuHideApp, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: L10n.menuHideOthers, action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: L10n.menuShowAll, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: L10n.menuQuitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        appItem.submenu = appMenu
        return appItem
    }

    private func makeFileMenuItem() -> NSMenuItem {
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L10n.menuFile)

        let openItem = NSMenuItem(title: L10n.menuOpenCaptureFile, action: #selector(openCaptureFile), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)

        let exportItem = NSMenuItem(title: L10n.menuExportCaptureFile, action: #selector(exportCaptureFile), keyEquivalent: "e")
        exportItem.target = self
        exportItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(exportItem)

        fileItem.title = L10n.menuFile
        fileItem.submenu = fileMenu
        return fileItem
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L10n.menuView)

        let showWindowItem = NSMenuItem(title: L10n.menuShowMainWindow, action: #selector(openMainWindow), keyEquivalent: "1")
        showWindowItem.keyEquivalentModifierMask = [.command]
        showWindowItem.target = self
        viewMenu.addItem(showWindowItem)

        let refreshItem = NSMenuItem(title: L10n.menuRefreshCapture, action: #selector(refreshCapture), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(refreshItem)

        viewItem.title = L10n.menuView
        viewItem.submenu = viewMenu
        return viewItem
    }

    private func makeWindowMenuItem() -> NSMenuItem {
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.menuWindow)

        windowMenu.addItem(NSMenuItem(title: L10n.menuCloseWindow, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: L10n.menuMinimize, action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: L10n.menuZoom, action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))

        NSApp.windowsMenu = windowMenu
        windowItem.title = L10n.menuWindow
        windowItem.submenu = windowMenu
        return windowItem
    }

    private func makeHelpMenuItem() -> NSMenuItem {
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: L10n.menuHelp)

        let githubItem = NSMenuItem(title: L10n.menuGitHub, action: #selector(openGitHubHomepage), keyEquivalent: "?")
        githubItem.target = self
        helpMenu.addItem(githubItem)

        helpItem.title = L10n.menuHelp
        helpItem.submenu = helpMenu
        return helpItem
    }

    @objc private func openMainWindow() {
        openMainWindowHandler()
    }

    @objc private func refreshCapture() {
        Task { await store.refreshCapture(forceReloadSelectionDetail: true, clearingVisibleState: true) }
    }

    @objc private func openCaptureFile() {
        captureFileService.presentOpenPanelAndImportFiles(
            didImport: openMainWindowHandler,
            onError: presentErrorHandler
        )
    }

    @objc private func exportCaptureFile() {
        captureFileService.exportCurrentCapture(onError: presentErrorHandler)
    }

    @objc private func openPreferencesWindow() {
        openPreferencesHandler()
    }

    @objc private func checkForUpdates() {
        store.updateManager.checkForUpdates()
    }

    @objc private func openGitHubHomepage() {
        store.updateManager.openGitHubHomepage()
    }
}
