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

@Suite(.serialized)
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
        guard case let .readOnly(_, classValue) = try #require(model.sections.first?.rows.first) else {
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

    @Test func workspacePanelDisablesAutoresizingMaskConstraints() async throws {
        let panel = WorkspacePanelContainerView(frame: .zero)
        #expect(panel.translatesAutoresizingMaskIntoConstraints == false)
    }

    @Test func inspectorSectionRowsStretchToCardWidth() async throws {
        let suiteName = "ViewScopeInspectorLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(
            defaults: defaults,
            environment: [
                "VIEWSCOPE_DISABLE_UPDATES": "1",
                "VIEWSCOPE_LANGUAGE": AppLanguage.english.rawValue,
                "VIEWSCOPE_PREVIEW_FIXTURE": "1"
            ]
        )
        let store = try WorkspaceStore(settings: settings, updateManager: UpdateManager(settings: settings))
        defer { store.shutdown() }
        store.start()
        await store.selectNode(withID: "window-0-view-1-2", highlightInHost: false)

        let controller = InspectorPanelController(store: store)
        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()

        let rowStack = try #require(findRowStack(in: controller.view))
        #expect(rowStack.alignment == .width)
    }

    @Test func normalizedDemangledClassNameFlattensPrivateContext() async throws {
        let formatted = ViewScopeClassNameFormatter.displayName(
            for: "_TtC6AppKitP33_72EBFCF981BE77E1C6F26FD717D0893922NSTextFieldSimpleLabel"
        )

        #expect(formatted == "AppKit.NSTextFieldSimpleLabel _72EBFCF981BE77E1C6F26FD717D08939")
    }

    @Test func releaseVersionComparison() async throws {
        #expect(ReleaseVersion("1.0") == ReleaseVersion("1.0.0"))
        #expect(ReleaseVersion("1.0.1") > ReleaseVersion("1.0.0"))
        #expect(ReleaseVersion("v1.2.1-beta.1") > ReleaseVersion("1.1.9"))
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
        let nodeID = ViewHierarchyGeometry().deepestNodeID(at: CGPoint(x: 100, y: 40), in: capture)
        #expect(nodeID == "window-0-view-0-0")
    }

    @Test func previewGeometryUsesCaptureCanvasRectWithoutReaccumulatingParentOffsets() async throws {
        let capture = SampleFixture.capture()
        let rect = try #require(ViewHierarchyGeometry().canvasRect(for: "window-0-view-1-2", in: capture))

        #expect(rect == CGRect(x: 292, y: 152, width: 760, height: 408))
    }

    @Test func previewSelectionPrefersDetailHighlightRectWhenAvailable() async throws {
        let capture = SampleFixture.capture()
        var detail = SampleFixture.detail(for: "window-0-view-1-2")
        detail.highlightedRect = ViewScopeRect(x: 16, y: 24, width: 80, height: 44)

        let selectionRect = PreviewPanelRenderDecisions.selectionRect(
            capture: capture,
            selectedNodeID: "window-0-view-1-2",
            detail: detail,
            geometryMode: .directGlobalCanvasRect
        )

        #expect(selectionRect == CGRect(x: 16, y: 24, width: 80, height: 44))
    }

    @Test func previewGeometryModePrefersDirectCanvasRectsWhenCaptureAlreadyMatchesDetail() async throws {
        let capture = SampleFixture.capture()
        let detail = SampleFixture.detail(for: "window-0-view-1-2")

        let mode = PreviewPanelRenderDecisions.geometryMode(
            capture: capture,
            selectedNodeID: "window-0-view-1-2",
            detail: detail
        )

        #expect(mode == .directGlobalCanvasRect)
    }

    @Test func previewGeometryModeFallsBackToLegacyLocalFramesWhenCaptureUsesParentRelativeFrames() async throws {
        let host = SampleFixture.capture().host
        let capture = ViewScopeCapturePayload(
            host: host,
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(nodeCount: 2, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["window-0"],
            nodes: [
                "window-0": ViewScopeHierarchyNode(
                    id: "window-0",
                    parentID: nil,
                    kind: .window,
                    className: "NSWindow",
                    title: "Legacy",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 0, width: 200, height: 120),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 200, height: 120),
                    childIDs: ["window-0-view-0"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: true,
                    depth: 0
                ),
                "window-0-view-0": ViewScopeHierarchyNode(
                    id: "window-0-view-0",
                    parentID: "window-0",
                    kind: .view,
                    className: "NSButton",
                    title: "Legacy Button",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 12, y: 18, width: 60, height: 24),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 60, height: 24),
                    childIDs: [],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: false,
                    depth: 1
                )
            ]
        )
        let detail = ViewScopeNodeDetailPayload(
            nodeID: "window-0-view-0",
            host: host,
            sections: [],
            constraints: [],
            ancestry: [],
            screenshotPNGBase64: nil,
            screenshotSize: ViewScopeSize(width: 200, height: 120),
            highlightedRect: ViewScopeRect(x: 12, y: 78, width: 60, height: 24)
        )

        let mode = PreviewPanelRenderDecisions.geometryMode(
            capture: capture,
            selectedNodeID: "window-0-view-0",
            detail: detail
        )

        #expect(mode == .legacyLocalFrames)
    }

    @Test func inspectorPlaceholderChangesWhenNoCaptureIsAvailable() async throws {
        let noCaptureModel = InspectorPanelModelBuilder().makeModel(
            capture: nil,
            node: nil,
            detail: nil
        )
        let captureModel = InspectorPanelModelBuilder().makeModel(
            capture: SampleFixture.capture(),
            node: nil,
            detail: nil
        )

        #expect(noCaptureModel.placeholder == L10n.previewDisconnectedPlaceholder)
        #expect(captureModel.placeholder == L10n.pickNodePlaceholder)
    }

    @Test func hierarchyHiddenStatePropagatesToDescendants() async throws {
        let capture = ViewScopeCapturePayload(
            host: SampleFixture.capture().host,
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(nodeCount: 3, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["window-0"],
            nodes: [
                "window-0": ViewScopeHierarchyNode(
                    id: "window-0",
                    parentID: nil,
                    kind: .window,
                    className: "NSWindow",
                    title: "Window",
                    subtitle: nil,
                    frame: .zero,
                    bounds: .zero,
                    childIDs: ["parent"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: true,
                    depth: 0
                ),
                "parent": ViewScopeHierarchyNode(
                    id: "parent",
                    parentID: "window-0",
                    kind: .view,
                    className: "NSView",
                    title: "Parent",
                    subtitle: nil,
                    frame: .zero,
                    bounds: .zero,
                    childIDs: ["child"],
                    isHidden: true,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: true,
                    clippingEnabled: false,
                    depth: 1
                ),
                "child": ViewScopeHierarchyNode(
                    id: "child",
                    parentID: "parent",
                    kind: .view,
                    className: "NSButton",
                    title: "Child",
                    subtitle: nil,
                    frame: .zero,
                    bounds: .zero,
                    childIDs: [],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: true,
                    clippingEnabled: false,
                    depth: 2
                )
            ]
        )

        let item = try #require(ViewTreeNodeItem.make(nodeID: "window-0", nodes: capture.nodes))
        let parent = try #require(item.children.first)
        let child = try #require(parent.children.first)

        #expect(parent.isEffectivelyHidden)
        #expect(child.isEffectivelyHidden)
    }

    @Test func integrationGuideEntriesUseCurrentReleaseVersion() async throws {
        let entries = IntegrationGuideContent.entries(releaseVersion: "1.2.1")

        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.snippet.contains("1.2.1") || $0.snippet.contains("~> 1.2") })
    }

    @Test func treePanelShowsEmptyStateWhenDisconnected() async throws {
        let store = try makeDisconnectedStore()
        defer { store.shutdown() }

        let controller = ViewTreePanelController(store: store)
        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()

        #expect(findView(ofType: WorkspaceEmptyStateView.self, in: controller.view) != nil)
    }

    @Test func inspectorPanelShowsEmptyStateWhenDisconnected() async throws {
        let store = try makeDisconnectedStore()
        defer { store.shutdown() }

        let controller = InspectorPanelController(store: store)
        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()

        let emptyStateView = try #require(findView(ofType: WorkspaceEmptyStateView.self, in: controller.view))
        #expect(emptyStateView.messageText == L10n.previewDisconnectedPlaceholder)
    }

    @Test func integrationGuideShowsAllPackagesVerticallyWithBottomHelpButton() async throws {
        let guideView = IntegrationGuideView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        guideView.layoutSubtreeIfNeeded()

        #expect(guideView.showsSegmentedSelector == false)
        #expect(guideView.visibleEntryTitles == [
            L10n.integrationSwiftPackageManager,
            L10n.integrationCocoaPods,
            L10n.integrationCarthage
        ])
        #expect(guideView.visibleSnippets.count == 3)
        #expect(guideView.visibleSnippets.joined(separator: "\n").contains("1.2.1"))
        #expect(guideView.helpButtonTitle == L10n.menuGitHub)
        #expect(guideView.helpButtonPlacement == .bottom)
    }

    @Test func integrationGuideExpandsCardsToAvailablePreviewWidth() async throws {
        let guideView = IntegrationGuideView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720))
        guideView.layoutSubtreeIfNeeded()

        #expect(guideView.visibleCardWidth > 900)
    }

    @Test func flatPreviewKeepsNonFlippedHostScreenshotUpright() async throws {
        let previewImage = try #require(pngRoundTripped(makeNonFlippedRootScreenshot()))
        let canvasSize = CGSize(width: 200, height: 120)
        let previewView = PreviewCanvasView(frame: NSRect(x: 0, y: 0, width: 256, height: 176))
        previewView.canvasSize = canvasSize
        previewView.image = previewImage
        previewView.displayMode = .flat
        previewView.layoutSubtreeIfNeeded()

        let rendered = render(view: previewView)
        let expectedRect = CGRect(x: 8, y: 82, width: 40, height: 30)
        let samplePoint = center(of: previewView.viewRect(fromCanvasRect: expectedRect))
        let pixel = color(in: rendered, atViewPoint: samplePoint)

        #expect((pixel?.redComponent ?? 0) > 0.8)
        #expect((pixel?.greenComponent ?? 0) < 0.5)
        #expect((pixel?.blueComponent ?? 0) < 0.5)
    }

    @Test func flatPreviewSelectionUsesNormalizedTopLeftCanvasCoordinates() async throws {
        let previewImage = try #require(pngRoundTripped(makeNonFlippedRootScreenshot()))
        let canvasSize = CGSize(width: 200, height: 120)
        let previewView = PreviewCanvasView(frame: NSRect(x: 0, y: 0, width: 256, height: 176))
        previewView.canvasSize = canvasSize
        previewView.image = previewImage
        previewView.highlightedCanvasRect = CGRect(x: 8, y: 82, width: 40, height: 30)
        previewView.displayMode = .flat
        previewView.layoutSubtreeIfNeeded()

        let rendered = render(view: previewView)
        let highlightRect = previewView.viewRect(fromCanvasRect: CGRect(x: 8, y: 82, width: 40, height: 30))
        let borderSample = CGPoint(x: highlightRect.midX, y: highlightRect.minY + 1)
        let pixel = color(in: rendered, atViewPoint: borderSample)

        #expect((pixel?.blueComponent ?? 0) > 0.7)
    }

    @Test func layeredPreviewKeepsBaseImageTopEdgeAtProjectedTopEdge() async throws {
        let previewImage = try #require(pngRoundTripped(makeVerticallySplitScreenshot()))
        let canvasSize = CGSize(width: 200, height: 120)
        let previewView = PreviewCanvasView(frame: NSRect(x: 0, y: 0, width: 256, height: 176))
        previewView.canvasSize = canvasSize
        previewView.image = previewImage
        previewView.capture = makeImageOnlyCapture(canvasSize: canvasSize)
        previewView.displayMode = .layered
        previewView.layoutSubtreeIfNeeded()

        let rendered = render(view: previewView)
        let topSample = center(of: previewView.viewRect(fromCanvasRect: CGRect(x: 90, y: 12, width: 20, height: 12)))
        let bottomSample = center(of: previewView.viewRect(fromCanvasRect: CGRect(x: 90, y: 96, width: 20, height: 12)))

        let topPixel = color(in: rendered, atViewPoint: topSample)
        let bottomPixel = color(in: rendered, atViewPoint: bottomSample)

        #expect((topPixel?.redComponent ?? 0) > 0.75)
        #expect((topPixel?.blueComponent ?? 0) < 0.35)
        #expect((bottomPixel?.blueComponent ?? 0) > 0.75)
        #expect((bottomPixel?.redComponent ?? 0) < 0.35)
    }

    @Test func layeredPreviewKeepsSelectedLowerLeftMarkerInsideSelectedQuad() async throws {
        let previewImage = try #require(pngRoundTripped(makeNonFlippedRootScreenshot()))
        let canvasSize = CGSize(width: 200, height: 120)
        let previewView = PreviewCanvasView(frame: NSRect(x: 0, y: 0, width: 256, height: 176))
        previewView.canvasSize = canvasSize
        previewView.image = previewImage
        previewView.capture = makeImageOnlyCapture(canvasSize: canvasSize)
        previewView.highlightedCanvasRect = CGRect(x: 8, y: 82, width: 40, height: 30)
        previewView.displayMode = .layered
        previewView.layoutSubtreeIfNeeded()

        let rendered = render(view: previewView)
        let selectedQuad = PreviewLayerTransform().projectedQuad(
            for: PreviewCanvasCoordinateSpace.displayRect(
                fromNormalizedRect: CGRect(x: 8, y: 82, width: 40, height: 30),
                canvasSize: canvasSize
            ),
            depth: 0,
            canvasSize: canvasSize
        )
        let selectionCenter = center(of: boundingRect(for: selectedQuad))
        let samplePoint = previewView.viewRect(fromCanvasRect: CGRect(origin: selectionCenter, size: .zero)).origin
        let pixel = color(in: rendered, atViewPoint: samplePoint)

        #expect((pixel?.redComponent ?? 0) > 0.75)
        #expect((pixel?.greenComponent ?? 0) < 0.45)
        #expect((pixel?.blueComponent ?? 0) < 0.45)
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
        let settings = AppSettings(
            defaults: defaults,
            environment: [
                "VIEWSCOPE_DISABLE_UPDATES": "1",
                "VIEWSCOPE_LANGUAGE": AppLanguage.english.rawValue,
                "VIEWSCOPE_PREVIEW_FIXTURE": "1"
            ]
        )
        let updateManager = UpdateManager(settings: settings)

        defer {
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

    private func makeDisconnectedStore() throws -> WorkspaceStore {
        let defaults = try #require(UserDefaults(suiteName: "ViewScopeDisconnectedStateTests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, environment: ["VIEWSCOPE_DISABLE_UPDATES": "1"])
        return try WorkspaceStore(settings: settings, updateManager: UpdateManager(settings: settings))
    }

    private func findRowStack(in view: NSView) -> NSStackView? {
        if let stackView = view as? NSStackView,
           stackView.orientation == .vertical,
           abs(stackView.spacing - 8) < 0.5,
           stackView.alignment == .width {
            return stackView
        }

        for subview in view.subviews {
            if let stackView = findRowStack(in: subview) {
                return stackView
            }
        }
        return nil
    }

    private func findView<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let typedView = view as? T {
            return typedView
        }

        for subview in view.subviews {
            if let typedView = findView(ofType: type, in: subview) {
                return typedView
            }
        }
        return nil
    }

    private func makeNonFlippedRootScreenshot() -> NSImage {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor

        let marker = NSView(frame: NSRect(x: 8, y: 8, width: 40, height: 30))
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.systemRed.cgColor
        root.addSubview(marker)

        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)

        let image = NSImage(size: root.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makeVerticallySplitScreenshot() -> NSImage {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor

        let top = NSView(frame: NSRect(x: 0, y: 60, width: 200, height: 60))
        top.wantsLayer = true
        top.layer?.backgroundColor = NSColor.systemRed.cgColor
        root.addSubview(top)

        let bottom = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        bottom.wantsLayer = true
        bottom.layer?.backgroundColor = NSColor.systemBlue.cgColor
        root.addSubview(bottom)

        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)

        let image = NSImage(size: root.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makeImageOnlyCapture(canvasSize: CGSize) -> ViewScopeCapturePayload {
        let host = SampleFixture.capture().host
        let rootNode = ViewScopeHierarchyNode(
            id: "window-0",
            parentID: nil,
            kind: .window,
            className: "NSWindow",
            title: "Preview",
            subtitle: nil,
            frame: ViewScopeRect(x: 0, y: 0, width: Double(canvasSize.width), height: Double(canvasSize.height)),
            bounds: ViewScopeRect(x: 0, y: 0, width: Double(canvasSize.width), height: Double(canvasSize.height)),
            childIDs: [],
            isHidden: true,
            alphaValue: 1,
            wantsLayer: true,
            isFlipped: false,
            clippingEnabled: true,
            depth: 0
        )

        return ViewScopeCapturePayload(
            host: host,
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(nodeCount: 1, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["window-0"],
            nodes: ["window-0": rootNode]
        )
    }

    private func pngRoundTripped(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return NSImage(data: pngData)
    }

    private func render(view: NSView) -> NSBitmapImageRep {
        let size = view.bounds.size
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func boundingRect(for quad: [CGPoint]) -> CGRect {
        let minX = quad.map(\.x).min() ?? 0
        let maxX = quad.map(\.x).max() ?? 0
        let minY = quad.map(\.y).min() ?? 0
        let maxY = quad.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func color(in bitmap: NSBitmapImageRep, atViewPoint point: CGPoint) -> NSColor? {
        let pixelX = Int(point.x.rounded(.towardZero))
        let pixelY = Int(point.y.rounded(.towardZero))
        guard pixelX >= 0, pixelX < bitmap.pixelsWide,
              pixelY >= 0, pixelY < bitmap.pixelsHigh else {
            return nil
        }
        return bitmap.colorAt(x: pixelX, y: pixelY)
    }

    private var screenshotOutputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("READMEAssets", isDirectory: true)
    }
}
