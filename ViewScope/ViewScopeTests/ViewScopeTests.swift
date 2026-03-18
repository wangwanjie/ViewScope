//
//  ViewScopeTests.swift
//  ViewScopeTests
//
//  Created by VanJay on 2026/3/18.
//

import AppKit
import Foundation
import Testing
@testable import ViewScope

@MainActor
struct ViewScopeTests {
    @Test func releaseVersionComparison() async throws {
        #expect(ReleaseVersion("1.0") == ReleaseVersion("1.0.0"))
        #expect(ReleaseVersion("1.0.1") > ReleaseVersion("1.0.0"))
        #expect(ReleaseVersion("v1.2.0-beta.1") > ReleaseVersion("1.1.9"))
        #expect(ReleaseVersion("2.0") > ReleaseVersion("1.9.9"))
    }

    @Test func captureHistoryInsightEmptyState() async throws {
        #expect(CaptureHistoryInsight.empty.totalCaptures == 0)
        #expect(CaptureHistoryInsight.empty.averageDurationMilliseconds == 0)
        #expect(CaptureHistoryInsight.empty.mostRecentDurationMilliseconds == 0)
    }

    @Test func previewHitTestingFindsChartCard() async throws {
        let capture = SampleFixture.capture()
        let nodeID = PreviewHitTester().deepestNodeID(at: CGPoint(x: 600, y: 200), in: capture)
        #expect(nodeID == "window-0-view-1-2")
    }

    @Test func previewHitTestingRespectsFlippedCoordinates() async throws {
        let capture = SampleFixture.capture()
        let nodeID = PreviewHitTester().deepestNodeID(at: CGPoint(x: 100, y: 590), in: capture)
        #expect(nodeID == "window-0-view-0-0")
    }

    @Test func localizationSwitchesBetweenSupportedLanguages() async throws {
        let suiteName = "ViewScopeLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults, environment: ["VIEWSCOPE_LANGUAGE": AppLanguage.simplifiedChinese.rawValue])
        #expect(settings.appLanguage == .simplifiedChinese)
        #expect(L10n.preferencesTitle == "偏好设置")

        settings.appLanguage = .traditionalChinese
        #expect(L10n.preferencesTitle == "偏好設定")

        settings.appLanguage = .english
        #expect(L10n.preferencesTitle == "Preferences")
    }

    @Test func renderReadmeScreenshots() async throws {
        let suiteName = "ViewScopeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults, environment: ["VIEWSCOPE_LANGUAGE": AppLanguage.english.rawValue])
        let updateManager = UpdateManager(settings: settings)

        setenv("VIEWSCOPE_PREVIEW_FIXTURE", "1", 1)
        setenv("VIEWSCOPE_DISABLE_UPDATES", "1", 1)
        defer {
            unsetenv("VIEWSCOPE_PREVIEW_FIXTURE")
            unsetenv("VIEWSCOPE_DISABLE_UPDATES")
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        let store = try WorkspaceStore(settings: settings, updateManager: updateManager)
        let mainWindowController = MainWindowController(store: store)
        let preferencesWindowController = PreferencesWindowController(store: store)

        _ = mainWindowController.window
        _ = preferencesWindowController.window
        mainWindowController.present()
        preferencesWindowController.showPreferencesWindow()
        store.start()
        await store.selectNode(withID: "window-0-view-1-2")
        #expect(store.discoveredHosts.count == 1)
        mainWindowController.window?.setFrame(NSRect(x: 0, y: 0, width: 1680, height: 1040), display: true)
        preferencesWindowController.window?.setFrame(NSRect(x: 0, y: 0, width: 960, height: 760), display: true)
        pumpRunLoop(for: 1.0)

        let screenshotsDirectory = screenshotOutputDirectory
        try FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
        try WindowSnapshot.writePNG(for: mainWindowController.window, to: screenshotsDirectory.appendingPathComponent("main-window.png"))
        try WindowSnapshot.writePNG(for: preferencesWindowController.window, to: screenshotsDirectory.appendingPathComponent("preferences.png"))

        #expect(FileManager.default.fileExists(atPath: screenshotsDirectory.appendingPathComponent("main-window.png").path))
        #expect(FileManager.default.fileExists(atPath: screenshotsDirectory.appendingPathComponent("preferences.png").path))

        mainWindowController.window?.close()
        preferencesWindowController.window?.close()
        store.shutdown()
    }

    private func pumpRunLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private var screenshotOutputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("READMEAssets", isDirectory: true)
    }
}
