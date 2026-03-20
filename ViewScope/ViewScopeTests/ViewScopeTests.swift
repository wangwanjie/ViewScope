//
//  ViewScopeTests.swift
//  ViewScopeTests
//
//  Created by VanJay on 2026/3/18.
//

import AppKit
import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

@MainActor
struct ViewScopeTests {
    @Test func treePresentationShowsIvarNamesAndDemangledClassName() async throws {
        let rawClassName = "_TtGC6AppKit18_NSCoreHostingViewVS_17AppKitPopUpButton_"
        let node = ViewScopeHierarchyNode(
            id: "node-1",
            parentID: nil,
            kind: .view,
            className: rawClassName,
            title: "Confirm",
            subtitle: nil,
            identifier: nil,
            address: nil,
            frame: .zero,
            bounds: .zero,
            childIDs: [],
            isHidden: false,
            alphaValue: 1,
            wantsLayer: false,
            isFlipped: true,
            clippingEnabled: false,
            depth: 1,
            ivarName: "confirmButton",
            ivarTraces: [
                ViewScopeIvarTrace(hostClassName: "HostView", ivarName: "confirmButton"),
                ViewScopeIvarTrace(hostClassName: "HostView", ivarName: "primaryButton")
            ]
        )

        #expect(ViewTreeNodePresentation.classText(for: node).contains("_NSCoreHostingView"))
        #expect(ViewTreeNodePresentation.classText(for: node).contains("AppKitPopUpButton"))
        #expect(ViewTreeNodePresentation.classText(for: node) != rawClassName)
        #expect(ViewTreeNodePresentation.ivarText(for: node) == "confirmButton, primaryButton")
    }

    @Test func treeSearchTextIncludesIvarName() async throws {
        let node = ViewScopeHierarchyNode(
            id: "node-2",
            parentID: nil,
            kind: .view,
            className: "NSTextField",
            title: "Search",
            subtitle: nil,
            identifier: nil,
            address: nil,
            frame: .zero,
            bounds: .zero,
            childIDs: [],
            isHidden: false,
            alphaValue: 1,
            wantsLayer: false,
            isFlipped: true,
            clippingEnabled: false,
            depth: 1,
            ivarName: "queryField"
        )

        #expect(ViewTreeNodePresentation.matches(node: node, query: "queryfield"))
    }

    @Test func inspectorUsesDemangledClassName() async throws {
        let rawClassName = "_TtGC6AppKit18_NSCoreHostingViewVS_17AppKitPopUpButton_"
        let node = ViewScopeHierarchyNode(
            id: "node-3",
            parentID: nil,
            kind: .view,
            className: rawClassName,
            title: "Pop Up",
            subtitle: nil,
            identifier: nil,
            address: nil,
            frame: .zero,
            bounds: .zero,
            childIDs: [],
            isHidden: false,
            alphaValue: 1,
            wantsLayer: false,
            isFlipped: true,
            clippingEnabled: false,
            depth: 1
        )

        let model = InspectorPanelModelBuilder().makeModel(
            capture: nil,
            node: node,
            detail: nil
        )

        #expect(model.subtitle?.contains("_NSCoreHostingView") == true)
        guard case let .readOnly(_, classValue) = try #require(model.sections.first?.rows.dropFirst().first) else {
            Issue.record("Expected read-only class row")
            return
        }
        #expect(classValue.contains("AppKitPopUpButton"))
        #expect(classValue != rawClassName)
    }

    @Test func layeredPreviewRecentersFullCanvasWhenEntering3DWithoutFocus() async throws {
        let shouldRecenter = PreviewPanelRenderDecisions.shouldRecenterFullCanvas(
            displayMode: .layered,
            lastRenderedDisplayMode: .flat,
            focusedNodeID: nil,
            lastRenderedFocusedNodeID: nil,
            canvasSize: CGSize(width: 1200, height: 640)
        )

        #expect(shouldRecenter)
    }

    @Test func layeredPreviewRecentersFullCanvasWhenFocusChangesIn3D() async throws {
        let shouldRecenter = PreviewPanelRenderDecisions.shouldRecenterFullCanvas(
            displayMode: .layered,
            lastRenderedDisplayMode: .layered,
            focusedNodeID: "window-0-view-1-2",
            lastRenderedFocusedNodeID: "window-0-view-1-1",
            canvasSize: CGSize(width: 1200, height: 640)
        )

        #expect(shouldRecenter)
    }

    @Test func normalizedDemangledClassNameFlattensPrivateContext() async throws {
        let formatted = ViewScopeClassNameFormatter.displayName(
            for: "_TtC6AppKitP33_72EBFCF981BE77E1C6F26FD717D0893922NSTextFieldSimpleLabel"
        )

        #expect(formatted == "AppKit.NSTextFieldSimpleLabel _72EBFCF981BE77E1C6F26FD717D08939")
    }

    @Test func previewImageSliceGeometryFlipsCanvasRectIntoImageSpace() async throws {
        let imageRect = PreviewImageSliceGeometry.imageRect(
            forCanvasRect: CGRect(x: 12, y: 18, width: 60, height: 24),
            canvasSize: CGSize(width: 200, height: 120),
            imageSize: CGSize(width: 200, height: 120)
        )

        #expect(imageRect.origin.x == 12)
        #expect(imageRect.origin.y == 78)
        #expect(imageRect.width == 60)
        #expect(imageRect.height == 24)
    }

    @Test func previewImageSliceGeometryScalesCanvasRectIntoRetinaImageSpace() async throws {
        let imageRect = PreviewImageSliceGeometry.imageRect(
            forCanvasRect: CGRect(x: 12, y: 18, width: 60, height: 24),
            canvasSize: CGSize(width: 200, height: 120),
            imageSize: CGSize(width: 400, height: 240)
        )

        #expect(imageRect.origin.x == 24)
        #expect(imageRect.origin.y == 156)
        #expect(imageRect.width == 120)
        #expect(imageRect.height == 48)
    }

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
        let nodeID = ViewHierarchyGeometry().deepestNodeID(at: CGPoint(x: 600, y: 200), in: capture)
        #expect(nodeID == "window-0-view-1-2")
    }

    @Test func previewHitTestingRespectsFlippedCoordinates() async throws {
        let capture = SampleFixture.capture()
        let nodeID = ViewHierarchyGeometry().deepestNodeID(at: CGPoint(x: 100, y: 590), in: capture)
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
