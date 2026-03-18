import Foundation

enum L10n {
    static var appName: String { tr("app.name") }
    static var mainWindowSubtitle: String { tr("window.main.subtitle") }
    static var mainSubtitle: String { tr("main.subtitle") }
    static var refresh: String { tr("main.button.refresh") }
    static var highlight: String { tr("main.button.highlight") }
    static var disconnect: String { tr("main.button.disconnect") }
    static var waitingForDebugHost: String { tr("main.status.waiting_debug_host") }
    static var searchPlaceholder: String { tr("main.search.placeholder") }
    static var showSidebar: String { tr("main.toggle.sidebar.show") }
    static var hideSidebar: String { tr("main.toggle.sidebar.hide") }
    static var showInspector: String { tr("main.toggle.inspector.show") }
    static var hideInspector: String { tr("main.toggle.inspector.hide") }
    static var liveHosts: String { tr("sidebar.live_hosts") }
    static var recentSessions: String { tr("sidebar.recent_sessions") }
    static var hierarchy: String { tr("section.hierarchy") }
    static var inspector: String { tr("section.inspector") }
    static var ancestry: String { tr("detail.ancestry") }
    static var constraints: String { tr("detail.constraints") }
    static var idleBadge: String { tr("badge.idle") }
    static var linkingBadge: String { tr("badge.link") }
    static var liveBadge: String { tr("badge.live") }
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
    static var noHostsOnlineTitle: String { tr("hosts.empty.live.title") }
    static var noHostsOnlineSubtitle: String { tr("hosts.empty.live.subtitle") }
    static var noRecentSessionsTitle: String { tr("hosts.empty.recent.title") }
    static var noRecentSessionsSubtitle: String { tr("hosts.empty.recent.subtitle") }
    static var hierarchyBadgeWindow: String { tr("hierarchy.badge.window") }
    static var hierarchyBadgeHidden: String { tr("hierarchy.badge.hidden") }
    static var hierarchyBadgeView: String { tr("hierarchy.badge.view") }
    static var hierarchyMenuHighlight: String { tr("hierarchy.menu.highlight") }
    static var hierarchyMenuRefresh: String { tr("hierarchy.menu.refresh") }
    static var hierarchyMenuCopyTitle: String { tr("hierarchy.menu.copy_title") }
    static var hierarchyMenuCopyClassName: String { tr("hierarchy.menu.copy_class_name") }
    static var hierarchyMenuCopyNodeID: String { tr("hierarchy.menu.copy_node_id") }
    static var hierarchyMenuCopyIdentifier: String { tr("hierarchy.menu.copy_identifier") }
    static var hierarchyMenuCopyAddress: String { tr("hierarchy.menu.copy_address") }
    static var hierarchyMenuExpandChildren: String { tr("hierarchy.menu.expand_children") }
    static var hierarchyMenuCollapseChildren: String { tr("hierarchy.menu.collapse_children") }
    static var integrationTitle: String { tr("integration.title") }
    static var integrationSubtitle: String { tr("integration.subtitle") }
    static var integrationSwiftPackageManager: String { tr("integration.package.swiftpm") }
    static var integrationCocoaPods: String { tr("integration.package.cocoapods") }
    static var integrationCarthage: String { tr("integration.package.carthage") }
    static var previewPlaceholder: String { tr("preview.placeholder") }

    static var menuAbout: String { tr("menu.about") }
    static var menuPreferences: String { tr("menu.preferences") }
    static var menuCheckForUpdates: String { tr("menu.check_updates") }
    static var menuHideApp: String { tr("menu.hide_app") }
    static var menuHideOthers: String { tr("menu.hide_others") }
    static var menuShowAll: String { tr("menu.show_all") }
    static var menuQuitApp: String { tr("menu.quit_app") }
    static var menuView: String { tr("menu.view") }
    static var menuShowMainWindow: String { tr("menu.show_main_window") }
    static var menuRefreshCapture: String { tr("menu.refresh_capture") }
    static var menuWindow: String { tr("menu.window") }
    static var menuMinimize: String { tr("menu.minimize") }
    static var menuZoom: String { tr("menu.zoom") }
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

    static func connecting(_ name: String) -> String { tr("status.connecting", name) }
    static func connected(_ name: String) -> String { tr("status.connected", name) }
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

    private static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        AppLocalization.shared.string(key, arguments: arguments)
    }
}
