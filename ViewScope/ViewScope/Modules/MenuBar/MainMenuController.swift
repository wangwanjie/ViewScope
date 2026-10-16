import AppKit
import Combine
import ViewScopeServer

@MainActor
final class MainMenuController: NSObject {
    private let store: WorkspaceStore
    private let captureFileService: CaptureFileService
    private let openMainWindowHandler: () -> Void
    private let openPreferencesHandler: () -> Void
    private let presentErrorHandler: (Error, String) -> Void
    private var cancellables = Set<AnyCancellable>()
    /// “最近宿主”子菜单，打开时按需重建。
    /// 每次重建主菜单都新建一个实例：同一个 NSMenu 不能同时挂在两个父菜单项上，
    /// 复用旧实例会抛出 “already a submenu of some menu” 异常。
    private var recentHostsMenu = NSMenu()

    init(
        store: WorkspaceStore,
        captureFileService: CaptureFileService,
        openMainWindowHandler: @escaping () -> Void,
        openPreferencesHandler: @escaping () -> Void,
        presentErrorHandler: @escaping (Error, String) -> Void
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
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeViewMenuItem())
        mainMenu.addItem(makeHostMenuItem())
        mainMenu.addItem(makeWindowMenuItem())
        mainMenu.addItem(makeHelpMenuItem())

        NSApp.mainMenu = mainMenu
    }

    private func makeItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if keyEquivalent.isEmpty == false {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appItem = NSMenuItem()
        let appMenu = NSMenu()

        appMenu.addItem(NSMenuItem(title: L10n.menuAbout, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(makeItem(L10n.menuPreferences, action: #selector(openPreferencesWindow), keyEquivalent: ","))
        appMenu.addItem(makeItem(L10n.menuCheckForUpdates, action: #selector(checkForUpdates)))

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: L10n.menuHideApp, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthersItem = NSMenuItem(title: L10n.menuHideOthers, action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        // 隐藏其他：⌥⌘H，避免与“隐藏”冲突
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(NSMenuItem(title: L10n.menuShowAll, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: L10n.menuQuitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        appItem.submenu = appMenu
        return appItem
    }

    private func makeFileMenuItem() -> NSMenuItem {
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L10n.menuFile)

        fileMenu.addItem(makeItem(L10n.menuOpenCaptureFile, action: #selector(openCaptureFile), keyEquivalent: "o"))
        fileMenu.addItem(makeItem(L10n.menuExportCaptureFile, action: #selector(exportCaptureFile), keyEquivalent: "e", modifiers: [.command, .option]))

        fileItem.title = L10n.menuFile
        fileItem.submenu = fileMenu
        return fileItem
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.menuEdit)
        // 撤销/重做：文本编辑时交给字段编辑器，否则撤销实时修改
        editMenu.addItem(makeItem(L10n.menuUndo, action: #selector(handleUndo(_:)), keyEquivalent: "z"))
        editMenu.addItem(makeItem(L10n.menuRedo, action: #selector(handleRedo(_:)), keyEquivalent: "z", modifiers: [.command, .shift]))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: L10n.menuCut, action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L10n.menuCopy, action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.menuPaste, action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L10n.menuDelete, action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: L10n.menuSelectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        return editItem
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L10n.menuView)

        viewMenu.addItem(makeItem(L10n.menuShowMainWindow, action: #selector(openMainWindow), keyEquivalent: "1"))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(makeItem(L10n.menuDisplay2D, action: #selector(showFlatPreview), keyEquivalent: "2", modifiers: [.command, .option]))
        viewMenu.addItem(makeItem(L10n.menuDisplay3D, action: #selector(showLayeredPreview), keyEquivalent: "3", modifiers: [.command, .option]))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(makeItem(L10n.menuZoomIn, action: #selector(zoomInPreview), keyEquivalent: "="))
        viewMenu.addItem(makeItem(L10n.menuZoomOut, action: #selector(zoomOutPreview), keyEquivalent: "-"))
        viewMenu.addItem(makeItem(L10n.menuActualSize, action: #selector(resetPreviewZoom), keyEquivalent: "0"))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(makeItem(L10n.menuFocusSelection, action: #selector(focusSelection), keyEquivalent: "f", modifiers: [.command, .option]))
        viewMenu.addItem(makeItem(L10n.menuClearFocus, action: #selector(clearFocus)))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(makeItem(L10n.menuMeasurement, action: #selector(toggleMeasurement), keyEquivalent: "m", modifiers: [.command, .option]))
        viewMenu.addItem(makeItem(L10n.menuDiagnostics, action: #selector(toggleDiagnostics), keyEquivalent: "d", modifiers: [.command, .option]))
        viewMenu.addItem(makeItem(L10n.hideInspector, action: #selector(toggleInspector), keyEquivalent: "i", modifiers: [.command, .option]))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(makeItem(L10n.menuModificationLog, action: #selector(showModificationLog), keyEquivalent: "l", modifiers: [.command, .shift]))
        viewMenu.addItem(makeItem(L10n.menuCaptureDiff, action: #selector(showCaptureDiff), keyEquivalent: "d", modifiers: [.command, .shift]))

        viewItem.title = L10n.menuView
        viewItem.submenu = viewMenu
        return viewItem
    }

    private func makeHostMenuItem() -> NSMenuItem {
        let hostItem = NSMenuItem()
        let hostMenu = NSMenu(title: L10n.menuHost)

        hostMenu.addItem(makeItem(L10n.menuRefreshCapture, action: #selector(refreshCapture), keyEquivalent: "r"))
        hostMenu.addItem(makeItem(L10n.menuDisconnect, action: #selector(disconnect)))
        hostMenu.addItem(makeItem(L10n.menuCloseImportedCapture, action: #selector(closeImportedCapture)))
        hostMenu.addItem(NSMenuItem.separator())
        let recentItem = NSMenuItem(title: L10n.menuRecentHosts, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: L10n.menuRecentHosts)
        menu.delegate = self
        recentHostsMenu = menu
        recentItem.submenu = menu
        hostMenu.addItem(recentItem)
        hostMenu.addItem(NSMenuItem.separator())
        hostMenu.addItem(makeItem(L10n.menuSetDiffBaseline, action: #selector(setDiffBaseline), keyEquivalent: "b", modifiers: [.command, .shift]))

        hostItem.title = L10n.menuHost
        hostItem.submenu = hostMenu
        return hostItem
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

        helpMenu.addItem(makeItem(L10n.menuGitHub, action: #selector(openGitHubHomepage), keyEquivalent: "?"))

        helpItem.title = L10n.menuHelp
        helpItem.submenu = helpMenu
        return helpItem
    }

    // MARK: - 文本编辑判断

    /// 当前第一响应者是否为文本编辑器（字段编辑器或文本视图）。
    private var activeTextResponder: NSResponder? {
        guard let responder = NSApp.keyWindow?.firstResponder else {
            return nil
        }
        if responder is NSText {
            return responder
        }
        return nil
    }

    // MARK: - 事件

    @objc private func handleUndo(_ sender: Any?) {
        if let textResponder = activeTextResponder {
            textResponder.undoManager?.undo()
            return
        }
        Task {
            await store.undoLastModification()
        }
    }

    @objc private func handleRedo(_ sender: Any?) {
        if let textResponder = activeTextResponder {
            textResponder.undoManager?.redo()
            return
        }
        Task {
            await store.redoLastModification()
        }
    }

    @objc private func openMainWindow() {
        openMainWindowHandler()
    }

    @objc private func refreshCapture() {
        Task {
            await store.refreshCapture(forceReloadSelectionDetail: true, clearingVisibleState: true)
        }
    }

    @objc private func disconnect() {
        store.disconnect()
    }

    @objc private func closeImportedCapture() {
        store.closeImportedCapture()
    }

    @objc private func showFlatPreview() {
        store.setPreviewDisplayMode(.flat)
    }

    @objc private func showLayeredPreview() {
        store.setPreviewDisplayMode(.layered)
    }

    @objc private func zoomInPreview() {
        store.zoomInPreview()
    }

    @objc private func zoomOutPreview() {
        store.zoomOutPreview()
    }

    @objc private func resetPreviewZoom() {
        store.resetPreviewZoom()
    }

    @objc private func focusSelection() {
        store.focusSelectedNode()
    }

    @objc private func clearFocus() {
        store.clearFocus()
    }

    @objc private func toggleMeasurement() {
        store.inspectionTools.isMeasurementEnabled.toggle()
    }

    @objc private func toggleDiagnostics() {
        store.inspectionTools.showsDiagnostics.toggle()
    }

    @objc private func toggleInspector() {
        store.settings.showsInspector.toggle()
    }

    @objc private func showModificationLog() {
        openMainWindowHandler()
        store.requestPanel(.modificationLog)
    }

    @objc private func showCaptureDiff() {
        openMainWindowHandler()
        store.requestPanel(.captureDiff)
    }

    @objc private func setDiffBaseline() {
        if store.setCurrentCaptureAsDiffBaseline() {
            store.requestPanel(.captureDiff)
        }
    }

    @objc private func connectRecentHost(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String,
              let record = store.recentHosts.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }
        openMainWindowHandler()
        Task {
            await store.connect(using: record)
        }
    }

    @objc private func openCaptureFile() {
        captureFileService.presentOpenPanelAndImportFiles(
            didImport: openMainWindowHandler,
            onError: { [weak self] error in
                self?.presentErrorHandler(error, L10n.importFailedTitle)
            }
        )
    }

    @objc private func exportCaptureFile() {
        captureFileService.exportCurrentCapture(onError: { [weak self] error in
            self?.presentErrorHandler(error, L10n.exportFailedTitle)
        })
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

extension MainMenuController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else {
            return true
        }
        let hasCapture = store.capture != nil
        switch action {
        case #selector(handleUndo(_:)):
            if let textResponder = activeTextResponder {
                return textResponder.undoManager?.canUndo ?? false
            }
            return store.canUndoModification
        case #selector(handleRedo(_:)):
            if let textResponder = activeTextResponder {
                return textResponder.undoManager?.canRedo ?? false
            }
            return store.canRedoModification
        case #selector(refreshCapture):
            return store.canRefreshCapture
        case #selector(disconnect):
            return store.connectionState.activeHost != nil || store.connectionState.lostHost != nil
        case #selector(closeImportedCapture):
            return store.connectionState.importedCaptureName != nil
        case #selector(exportCaptureFile), #selector(setDiffBaseline):
            return hasCapture
        case #selector(showFlatPreview):
            menuItem.state = store.previewDisplayMode == .flat ? .on : .off
            return hasCapture
        case #selector(showLayeredPreview):
            menuItem.state = store.previewDisplayMode == .layered ? .on : .off
            return hasCapture
        case #selector(zoomInPreview), #selector(zoomOutPreview), #selector(resetPreviewZoom):
            return hasCapture
        case #selector(focusSelection):
            return store.selectedNodeID != nil
        case #selector(clearFocus):
            return store.focusedNodeID != nil
        case #selector(toggleMeasurement):
            menuItem.state = store.inspectionTools.isMeasurementEnabled ? .on : .off
            return hasCapture
        case #selector(toggleDiagnostics):
            menuItem.state = store.inspectionTools.showsDiagnostics ? .on : .off
            return true
        case #selector(toggleInspector):
            menuItem.title = store.settings.showsInspector ? L10n.hideInspector : L10n.showInspector
            return true
        case #selector(connectRecentHost(_:)):
            guard let bundleIdentifier = menuItem.representedObject as? String else {
                return false
            }
            return store.discoveredHosts.contains(where: { $0.bundleIdentifier == bundleIdentifier })
        default:
            return true
        }
    }
}

extension MainMenuController: NSMenuDelegate {
    /// 打开“最近宿主”子菜单时按最新记录重建。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentHostsMenu else {
            return
        }
        menu.removeAllItems()
        let records = store.recentHosts.prefix(10)
        guard records.isEmpty == false else {
            let item = NSMenuItem(title: L10n.menuNoRecentHosts, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        for record in records {
            let isRunning = store.discoveredHosts.contains(where: { $0.bundleIdentifier == record.bundleIdentifier })
            let suffix = isRunning ? "" : " \(L10n.hostRecentNotRunningSuffix)"
            let item = NSMenuItem(
                title: "\(record.displayName) · \(record.bundleIdentifier)\(suffix)",
                action: #selector(connectRecentHost(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = record.bundleIdentifier
            menu.addItem(item)
        }
    }
}
