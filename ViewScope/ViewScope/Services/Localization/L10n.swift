import Foundation

enum L10n {
    static var appName: String { tr("app.name") }
    static var mainWindowSubtitle: String { tr("window.main.subtitle") }
    static var mainSubtitle: String { tr("main.subtitle") }
    static var refresh: String { tr("main.button.refresh") }
    static var highlight: String { tr("main.button.highlight") }
    static var disconnect: String { tr("main.button.disconnect") }
    static var waitingForDebugHost: String { tr("main.status.waiting_debug_host") }
    static var hostPickerPlaceholder: String { tr("main.host_picker.placeholder") }
    static var searchPlaceholder: String { tr("main.search.placeholder") }
    static var showSidebar: String { tr("main.toggle.sidebar.show") }
    static var hideSidebar: String { tr("main.toggle.sidebar.hide") }
    static var showInspector: String { tr("main.toggle.inspector.show") }
    static var hideInspector: String { tr("main.toggle.inspector.hide") }
    static var liveHosts: String { tr("sidebar.live_hosts") }
    static var recentSessions: String { tr("sidebar.recent_sessions") }
    static var hierarchy: String { tr("section.hierarchy") }
    static var inspector: String { tr("section.inspector") }
    static var hierarchyEmptyTitle: String { tr("workspace.empty.hierarchy.title") }
    static var inspectorEmptyDisconnectedTitle: String { tr("workspace.empty.inspector.disconnected.title") }
    static var inspectorEmptySelectionTitle: String { tr("workspace.empty.inspector.selection.title") }
    static var ancestry: String { tr("detail.ancestry") }
    static var constraints: String { tr("detail.constraints") }
    static var idleBadge: String { tr("badge.idle") }
    static var linkingBadge: String { tr("badge.link") }
    static var liveBadge: String { tr("badge.live") }
    static var loadedBadge: String { tr("badge.loaded") }
    static var errorBadge: String { tr("badge.error") }
    static var sessionSummary: String { tr("detail.session_summary") }
    static var canvasPreview: String { tr("detail.canvas_preview") }
    static var detailHost: String { tr("detail.field.host") }
    static var detailBundle: String { tr("detail.field.bundle") }
    static var detailVersion: String { tr("detail.field.version") }
    static var detailNodes: String { tr("detail.field.nodes") }
    static var detailWindows: String { tr("detail.field.windows") }
    static var detailCapture: String { tr("detail.field.capture") }
    static var detailHistory: String { tr("detail.field.history") }
    static var pickNodePlaceholder: String { tr("detail.placeholder.pick_node") }
    static var previewDisconnectedPlaceholder: String { tr("detail.placeholder.disconnected") }
    static var noHostsOnlineTitle: String { tr("hosts.empty.live.title") }
    static var noHostsOnlineSubtitle: String { tr("hosts.empty.live.subtitle") }
    static var noRecentSessionsTitle: String { tr("hosts.empty.recent.title") }
    static var noRecentSessionsSubtitle: String { tr("hosts.empty.recent.subtitle") }
    static var hierarchyBadgeWindow: String { tr("hierarchy.badge.window") }
    static var hierarchyBadgeHidden: String { tr("hierarchy.badge.hidden") }
    static var hierarchyBadgeView: String { tr("hierarchy.badge.view") }
    static var hierarchyMenuShowView: String { tr("hierarchy.menu.show_view") }
    static var hierarchyMenuHideView: String { tr("hierarchy.menu.hide_view") }
    static var hierarchyMenuFocusSubtree: String { tr("hierarchy.menu.focus_subtree") }
    static var hierarchyMenuClearFocus: String { tr("hierarchy.menu.clear_focus") }
    static var hierarchyMenuHighlight: String { tr("hierarchy.menu.highlight") }
    static var hierarchyMenuRefresh: String { tr("hierarchy.menu.refresh") }
    static var hierarchyMenuCopyTitle: String { tr("hierarchy.menu.copy_title") }
    static var hierarchyMenuCopyClassName: String { tr("hierarchy.menu.copy_class_name") }
    static var hierarchyMenuCopyIvarName: String { tr("hierarchy.menu.copy_ivar_name") }
    static var hierarchyMenuCopyNodeID: String { tr("hierarchy.menu.copy_node_id") }
    static var hierarchyMenuCopyIdentifier: String { tr("hierarchy.menu.copy_identifier") }
    static var hierarchyMenuCopyAddress: String { tr("hierarchy.menu.copy_address") }
    static var hierarchyMenuExpandChildren: String { tr("hierarchy.menu.expand_children") }
    static var hierarchyMenuCollapseChildren: String { tr("hierarchy.menu.collapse_children") }
    static var hierarchyShowHandlers: String { tr("hierarchy.action.show_handlers") }
    static var hierarchyShowSystemWrappers: String { tr("hierarchy.action.show_system_wrappers") }
    static var consoleTitle: String { tr("section.console") }
    static var consoleAutoSync: String { tr("console.action.auto_sync") }
    static var consoleClearHistory: String { tr("console.action.clear_history") }
    static var consoleInputPlaceholder: String { tr("console.input.placeholder") }
    static var consoleSubmit: String { tr("console.action.submit") }
    static var consoleNoTargets: String { tr("console.target.none") }
    static var consoleRecentSuffix: String { tr("console.target.recent_suffix") }
    static var consoleSelectionSuffix: String { tr("console.target.selection_suffix") }
    static var consoleEmptyState: String { tr("console.state.empty") }
    static var consoleStatusLoading: String { tr("console.state.loading") }
    static var consoleStatusNoTarget: String { tr("console.state.no_target") }
    static var consoleStatusDisconnected: String { tr("console.state.disconnected") }
    static var consoleStatusStaleTarget: String { tr("console.state.stale_target") }
    static var consoleStatusUnavailable: String { tr("console.state.unavailable") }
    static var consoleErrorEmptyInput: String { tr("console.error.empty_input") }
    static var consoleErrorArgumentsUnsupported: String { tr("console.error.arguments_unsupported") }
    static var consoleErrorSyntaxUnsupported: String { tr("console.error.syntax_unsupported") }
    static var integrationTitle: String { tr("integration.title") }
    static var integrationSubtitle: String { tr("integration.subtitle") }
    static var integrationSwiftPackageManager: String { tr("integration.package.swiftpm") }
    static var integrationCocoaPods: String { tr("integration.package.cocoapods") }
    static var integrationCarthage: String { tr("integration.package.carthage") }
    static var previewPlaceholder: String { tr("preview.placeholder") }
    static var previewZoomOut: String { tr("preview.action.zoom_out") }
    static var previewResetZoom: String { tr("preview.action.reset_zoom") }
    static var previewZoomIn: String { tr("preview.action.zoom_in") }
    static var previewDisplayFlat: String { tr("preview.action.display_flat") }
    static var previewDisplayLayered: String { tr("preview.action.display_layered") }
    static var previewShowConsole: String { tr("preview.action.show_console") }
    static var previewHideConsole: String { tr("preview.action.hide_console") }
    static var previewLayerSettings: String { tr("preview.action.layer_settings") }
    static var previewLayerSpacing: String { tr("preview.setting.layer_spacing") }
    static var previewLayerBorders: String { tr("preview.setting.layer_borders") }
    static var previewFocusSelection: String { tr("preview.action.focus_selection") }
    static var previewClearFocus: String { tr("preview.action.clear_focus") }
    static var previewToggleVisibility: String { tr("preview.action.toggle_visibility") }
    static var previewHighlightSelection: String { tr("preview.action.highlight_selection") }

    static var archiveUnsupportedFile: String { tr("archive.error.unsupported_file") }
    static var archiveCorruptedFile: String { tr("archive.error.corrupted_file") }

    static var menuFile: String { tr("menu.file") }
    static var menuAbout: String { tr("menu.about") }
    static var menuPreferences: String { tr("menu.preferences") }
    static var menuCheckForUpdates: String { tr("menu.check_updates") }
    static var menuHideApp: String { tr("menu.hide_app") }
    static var menuHideOthers: String { tr("menu.hide_others") }
    static var menuShowAll: String { tr("menu.show_all") }
    static var menuQuitApp: String { tr("menu.quit_app") }
    static var menuView: String { tr("menu.view") }
    static var menuOpenCaptureFile: String { tr("menu.open_capture_file") }
    static var menuShowMainWindow: String { tr("menu.show_main_window") }
    static var menuRefreshCapture: String { tr("menu.refresh_capture") }
    static var menuExportCaptureFile: String { tr("menu.export_capture_file") }
    static var menuWindow: String { tr("menu.window") }
    static var menuCloseWindow: String { tr("menu.close_window") }
    static var menuMinimize: String { tr("menu.minimize") }
    static var menuZoom: String { tr("menu.zoom") }
    static var menuEdit: String { tr("menu.edit") }
    static var menuUndo: String { tr("menu.undo") }
    static var menuRedo: String { tr("menu.redo") }
    static var menuCut: String { tr("menu.cut") }
    static var menuCopy: String { tr("menu.copy") }
    static var menuPaste: String { tr("menu.paste") }
    static var menuDelete: String { tr("menu.delete") }
    static var menuSelectAll: String { tr("menu.select_all") }
    static var menuHelp: String { tr("menu.help") }
    static var menuGitHub: String { tr("menu.github") }
    static var fatalLaunchTitle: String { tr("alert.launch_failed.title") }

    static var preferencesWindowTitle: String { tr("preferences.window.title") }
    static var preferencesTitle: String { tr("preferences.title") }
    static var preferencesDescription: String { tr("preferences.description") }
    static var preferencesSegmentGeneral: String { tr("preferences.segment.general") }
    static var preferencesSegmentUpdates: String { tr("preferences.segment.updates") }
    static var preferencesLanguage: String { tr("preferences.language") }
    static var preferencesLanguageHint: String { tr("preferences.language.hint") }
    static var preferencesUpdateChecks: String { tr("preferences.update_checks") }
    static var preferencesAutoRefresh: String { tr("preferences.auto_refresh") }
    static var preferencesAutoHighlight: String { tr("preferences.auto_highlight") }
    static var preferencesStatusCount: String { tr("preferences.status_count") }
    static var preferencesAutoDownloads: String { tr("preferences.auto_downloads") }
    static var preferencesAutoDownloadsAvailable: String { tr("preferences.auto_downloads.available") }
    static var preferencesAutoDownloadsUnavailable: String { tr("preferences.auto_downloads.unavailable") }
    static var preferencesCheckForUpdates: String { tr("preferences.check_updates") }
    static var preferencesOpenGitHub: String { tr("preferences.open_github") }

    static var updateStrategyManual: String { tr("settings.update.manual") }
    static var updateStrategyDaily: String { tr("settings.update.daily") }
    static var updateStrategyOnLaunch: String { tr("settings.update.on_launch") }

    static var statusOpen: String { tr("status.open") }
    static var statusRefresh: String { tr("status.refresh") }
    static var statusAutoRefresh: String { tr("status.auto_refresh") }
    static var statusAutoHighlight: String { tr("status.auto_highlight") }
    static var statusPreferences: String { tr("status.preferences") }
    static var statusCheckForUpdates: String { tr("status.check_updates") }
    static var statusQuit: String { tr("status.quit") }
    static var statusWaitingForLocalHosts: String { tr("status.waiting_local_hosts") }

    static var updateUpToDateTitle: String { tr("update.up_to_date.title") }
    static var updateAvailableFallback: String { tr("update.available.body_fallback") }
    static var updateButtonOpenGitHub: String { tr("update.button.open_github") }
    static var cancel: String { tr("update.button.cancel") }
    static var updateFailureTitle: String { tr("update.failure.title") }

    static var recentHostNotRunning: String { tr("workspace.recent_not_running") }
    static var connectedHostDisappeared: String { tr("workspace.host_disappeared") }
    static var sessionDisconnected: String { tr("session.error.disconnected") }
    static var sessionInvalidResponse: String { tr("session.error.invalid_response") }

    static var snapshotMissingWindow: String { tr("snapshot.error.missing_window") }
    static var snapshotMissingView: String { tr("snapshot.error.missing_snapshot_view") }
    static var snapshotBitmapFailed: String { tr("snapshot.error.bitmap_creation_failed") }
    static var snapshotPNGFailed: String { tr("snapshot.error.png_encoding_failed") }

    static var serverNodeGone: String { tr("server.error.selected_node_gone") }
    static var serverNoActiveConstraints: String { tr("server.value.no_active_constraints") }
    static var serverWindowFallback: String { tr("server.value.window_fallback") }
    static var serverOutlineView: String { tr("server.value.outline_view") }
    static var serverTableView: String { tr("server.value.table_view") }
    static var serverImage: String { tr("server.value.image") }
    static var serverScrollable: String { tr("server.value.scrollable") }
    static var serverNoIntrinsicSize: String { tr("server.value.no_intrinsic_size") }
    static var serverYes: String { tr("server.value.yes") }
    static var serverNo: String { tr("server.value.no") }
    static var serverFirstResponder: String { tr("server.value.first_responder") }

    static func connecting(_ name: String) -> String { tr("status.connecting", name) }
    static func connected(_ name: String) -> String { tr("status.connected", name) }
    static func loadedCaptureFile(_ name: String) -> String { tr("status.loaded_capture_file", name) }
    static func hostsAvailable(_ count: Int) -> String {
        tr(count == 1 ? "status.hosts_available.one" : "status.hosts_available.other", count)
    }

    static func hostVersionAndBuild(_ version: String, _ build: String) -> String {
        tr("detail.version_build", version, build)
    }

    static func captureDuration(_ milliseconds: Int) -> String {
        tr("detail.capture_duration", milliseconds)
    }

    static func historySummary(count: Int, averageMilliseconds: Int) -> String {
        if count == 0 {
            return tr("detail.history.first")
        }
        return tr(count == 1 ? "detail.history.summary.one" : "detail.history.summary.other", count, averageMilliseconds)
    }

    static func recentHostDetail(version: String, processIdentifier: Int32) -> String {
        tr("hosts.live.detail", version, processIdentifier)
    }

    static func currentVersion(_ shortVersion: String, _ buildVersion: String) -> String {
        tr("preferences.version", shortVersion, buildVersion)
    }

    static func updateUpToDateBody(current: String, latest: String) -> String {
        tr("update.up_to_date.body", current, latest)
    }

    static func updateAvailableTitle(_ version: String) -> String {
        tr("update.available.title", version)
    }

    static func languageName(_ language: AppLanguage) -> String {
        switch language {
        case .english:
            return tr("settings.language.english")
        case .simplifiedChinese:
            return tr("settings.language.simplified")
        case .traditionalChinese:
            return tr("settings.language.traditional")
        }
    }

    static func serverSectionTitle(_ key: String) -> String { tr("server.section.\(key)") }
    static func serverItemTitle(_ key: String) -> String { tr("server.item.\(key)") }
    static func serverRow(_ row: Int) -> String { tr("server.value.row_format", row) }
    static func serverVisibleRows(_ count: Int) -> String { tr("server.subtitle.visible_rows", count) }
    static func serverRowsAndColumns(rows: Int, columns: Int) -> String { tr("server.subtitle.rows_cols", rows, columns) }
    static func serverTabs(_ count: Int) -> String { tr("server.subtitle.tabs", count) }
    static func serverArranged(_ count: Int) -> String { tr("server.subtitle.arranged", count) }

    // MARK: - 1.3 主界面与工具（App 块）

    static var consoleErrorArgumentsRequireNewerHost: String { tr("app.console.error.arguments_need_v3") }
    static var consoleErrorKeyPathRequireNewerHost: String { tr("app.console.error.keypath_need_v3") }
    static var consoleInsertObjectReference: String { tr("app.console.action.insert_reference") }
    static var consoleNoRecentObjects: String { tr("app.console.reference.none") }
    static var consoleInputPlaceholderExtended: String { tr("app.console.input.placeholder_v3") }

    static var hostRecentSection: String { tr("app.host.recent_section") }
    static var hostRecentNotRunningSuffix: String { tr("app.host.recent_not_running") }
    static var lostBadge: String { tr("app.badge.lost") }
    static func hostPlatformSimulator(_ platform: String) -> String { tr("app.host.platform.simulator", platform) }
    static func hostPlatformDevice(_ platform: String, _ connection: String) -> String { tr("app.host.platform.device", platform, connection) }
    static func hostDeviceWithoutHosts(_ device: String) -> String { tr("app.host.device_without_hosts", device) }

    static var menuHost: String { tr("app.menu.host") }
    static var menuDisconnect: String { tr("app.menu.disconnect") }
    static var menuCloseImportedCapture: String { tr("app.menu.close_imported") }
    static var menuRecentHosts: String { tr("app.menu.recent_hosts") }
    static var menuNoRecentHosts: String { tr("app.menu.no_recent_hosts") }
    static var menuDisplay2D: String { tr("app.menu.display_2d") }
    static var menuDisplay3D: String { tr("app.menu.display_3d") }
    static var menuZoomIn: String { tr("app.menu.zoom_in") }
    static var menuZoomOut: String { tr("app.menu.zoom_out") }
    static var menuActualSize: String { tr("app.menu.actual_size") }
    static var menuFocusSelection: String { tr("app.menu.focus_selection") }
    static var menuClearFocus: String { tr("app.menu.clear_focus") }
    static var menuMeasurement: String { tr("app.menu.measurement") }
    static var menuDiagnostics: String { tr("app.menu.diagnostics") }
    static var menuModificationLog: String { tr("app.menu.modification_log") }
    static var menuCaptureDiff: String { tr("app.menu.capture_diff") }
    static var menuSetDiffBaseline: String { tr("app.menu.set_diff_baseline") }
    static var importFailedTitle: String { tr("app.alert.import_failed") }
    static var exportFailedTitle: String { tr("app.alert.export_failed") }

    static var inspectorGroupContentInset: String { tr("app.inspector.group.content_inset") }
    static var inspectorGroupLayoutMargins: String { tr("app.inspector.group.layout_margins") }
    static var inspectorGroupEdgeInsets: String { tr("app.inspector.group.edge_insets") }
    static var inspectorGroupTextContainerInset: String { tr("app.inspector.group.text_container_inset") }
    static var inspectorGroupSectionInset: String { tr("app.inspector.group.section_inset") }
    static var inspectorGroupContentEdgeInsets: String { tr("app.inspector.group.content_edge_insets") }
    static var inspectorGroupContentOffset: String { tr("app.inspector.group.content_offset") }
    static var inspectorGroupContentSize: String { tr("app.inspector.group.content_size") }
    static var inspectorGroupIntercellSpacing: String { tr("app.inspector.group.intercell_spacing") }

    static var changesTitle: String { tr("app.changes.title") }
    static var changesColumnTime: String { tr("app.changes.column.time") }
    static var changesColumnObject: String { tr("app.changes.column.object") }
    static var changesColumnProperty: String { tr("app.changes.column.property") }
    static var changesColumnChange: String { tr("app.changes.column.change") }
    static var changesRevert: String { tr("app.changes.action.revert") }
    static var changesClear: String { tr("app.changes.action.clear") }
    static var changesExportCode: String { tr("app.changes.action.export_code") }
    static var changesCopyCode: String { tr("app.changes.action.copy_code") }
    static var changesSaveCode: String { tr("app.changes.action.save_code") }
    static var changesEmpty: String { tr("app.changes.empty") }
    static var changesUndoneSuffix: String { tr("app.changes.undone") }
    static var changesCodeCopied: String { tr("app.changes.code_copied") }
    static var changesReadOnlyHint: String { tr("app.changes.read_only_hint") }

    static var diffTitle: String { tr("app.diff.title") }
    static var diffSetBaseline: String { tr("app.diff.action.set_baseline") }
    static var diffImportBaseline: String { tr("app.diff.action.import_baseline") }
    static var diffClearBaseline: String { tr("app.diff.action.clear_baseline") }
    static var diffColumnCategory: String { tr("app.diff.column.category") }
    static var diffColumnDetail: String { tr("app.diff.column.detail") }
    static var diffNoBaseline: String { tr("app.diff.empty.no_baseline") }
    static var diffNoCapture: String { tr("app.diff.empty.no_capture") }
    static var diffNoChanges: String { tr("app.diff.empty.no_changes") }
    static var diffFilterAll: String { tr("app.diff.filter.all") }
    static var diffNodeMissing: String { tr("app.diff.node_missing") }
    static func diffBaselineInfo(_ name: String, _ time: String) -> String { tr("app.diff.baseline_info", name, time) }
    static func diffCategoryTitle(_ category: CaptureDiffEntry.Category) -> String {
        tr("app.diff.category.\(category.rawValue)")
    }

    static var preferencesAutoReconnect: String { tr("app.preferences.auto_reconnect") }

    static var integrationOr: String { tr("app.integration.or") }
    static var integrationAutoStartComment: String { tr("app.integration.auto_start") }
    static var integrationIOSTitle: String { tr("app.integration.ios.title") }
    static var integrationIOSSimulatorNote: String { tr("app.integration.ios.simulator") }
    static var integrationIOSDeviceNote: String { tr("app.integration.ios.device") }

    private static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        AppLocalization.shared.string(key, arguments: arguments)
    }
}
