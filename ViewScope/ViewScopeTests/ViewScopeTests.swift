//
//  ViewScopeTests.swift
//  ViewScopeTests
//
//  Created by VanJay on 2026/3/18.
//

import AppKit
import Foundation
import SceneKit
import Testing
@testable import ViewScope
@testable import ViewScopeServer

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
            ],
            rootViewControllerClassName: "Demo.SettingsViewController"
        )

        #expect(ViewTreeNodePresentation.classText(for: node).contains("_NSCoreHostingView"))
        #expect(ViewTreeNodePresentation.classText(for: node).contains("AppKitPopUpButton"))
        #expect(ViewTreeNodePresentation.classText(for: node) != rawClassName)
        #expect(ViewTreeNodePresentation.ivarText(for: node) == "confirmButton, primaryButton")
        #expect(ViewTreeNodePresentation.classText(for: node).contains("SettingsViewController.view"))
        #expect(ViewTreeNodePresentation.secondaryText(for: node)?.contains("confirmButton") == true)
    }

    @Test func treePresentationAppendsControllerViewSuffixOnlyInTitle() async throws {
        let node = ViewScopeHierarchyNode(
            id: "node-controller-root",
            parentID: nil,
            kind: .view,
            className: "NSView",
            title: "Root",
            subtitle: nil,
            frame: .zero,
            bounds: .zero,
            childIDs: [],
            isHidden: false,
            alphaValue: 1,
            wantsLayer: true,
            isFlipped: true,
            clippingEnabled: false,
            depth: 1,
            rootViewControllerClassName: "Demo.RootViewController"
        )

        #expect(ViewTreeNodePresentation.classText(for: node) == "NSView RootViewController.view")
        #expect(ViewTreeNodePresentation.secondaryText(for: node) == nil)
    }

    @Test func treePresentationRecognizesSystemWrapperViews() async throws {
        let wrapperNode = ViewScopeHierarchyNode(
            id: "node-wrapper",
            parentID: nil,
            kind: .view,
            className: "_NSSplitViewItemViewWrapper",
            title: "Wrapper",
            subtitle: nil,
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
        let titlebarWrapperNode = ViewScopeHierarchyNode(
            id: "node-titlebar-wrapper",
            parentID: nil,
            kind: .view,
            className: "NSTitlebarContainerBlockingView",
            title: "Wrapper",
            subtitle: nil,
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
        let regularNode = ViewScopeHierarchyNode(
            id: "node-regular",
            parentID: nil,
            kind: .view,
            className: "NSView",
            title: "Regular",
            subtitle: nil,
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

        #expect(ViewTreeNodePresentation.isSystemWrapper(node: wrapperNode))
        #expect(ViewTreeNodePresentation.isSystemWrapper(node: titlebarWrapperNode))
        #expect(ViewTreeNodePresentation.isSystemWrapper(node: regularNode) == false)
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
            ivarName: "queryField",
            rootViewControllerClassName: "Demo.SearchViewController",
            controlTargetClassName: "Demo.SearchCoordinator",
            controlActionName: "performSearch:"
        )

        #expect(ViewTreeNodePresentation.matches(node: node, query: "queryfield"))
        #expect(ViewTreeNodePresentation.matches(node: node, query: "searchviewcontroller"))
        #expect(ViewTreeNodePresentation.matches(node: node, query: "performsearch"))
        #expect(ViewTreeNodePresentation.matches(node: node, query: "searchcoordinator"))
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

    @Test func inspectorFallbackShowsControllerAndControlMetadata() async throws {
        let node = ViewScopeHierarchyNode(
            id: "node-4",
            parentID: nil,
            kind: .view,
            className: "NSButton",
            title: "Connect",
            subtitle: nil,
            identifier: nil,
            address: "0x123",
            frame: .zero,
            bounds: .zero,
            childIDs: [],
            isHidden: false,
            alphaValue: 1,
            wantsLayer: false,
            isFlipped: true,
            clippingEnabled: false,
            depth: 1,
            rootViewControllerClassName: "Demo.ConnectViewController",
            controlTargetClassName: "Demo.ConnectCoordinator",
            controlActionName: "connect:"
        )

        let model = InspectorPanelModelBuilder().makeModel(
            capture: nil,
            node: node,
            detail: nil
        )
        let viewControllerTitle = L10n.serverItemTitle("view_controller")
        let targetTitle = L10n.serverItemTitle("target")
        let actionTitle = L10n.serverItemTitle("action")

        #expect(model.sections.contains { section in
            section.rows.contains {
                if case .readOnly(let title, let value) = $0 {
                    return title == viewControllerTitle && value.contains("ConnectViewController")
                }
                return false
            }
        })
        #expect(model.sections.contains { section in
            section.rows.contains {
                if case .readOnly(let title, let value) = $0 {
                    return title == targetTitle && value.contains("ConnectCoordinator")
                }
                return false
            }
        })
        #expect(model.sections.contains { section in
            section.rows.contains {
                if case .readOnly(let title, let value) = $0 {
                    return title == actionTitle && value == "connect:"
                }
                return false
            }
        })
    }

    @Test func treeSearchTextIncludesEventHandlers() async throws {
        let node = ViewScopeHierarchyNode(
            id: "node-handlers",
            parentID: nil,
            kind: .view,
            className: "NSButton",
            title: "Connect",
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
            eventHandlers: [
                ViewScopeEventHandler(
                    kind: .controlAction,
                    title: "connect:",
                    subtitle: nil,
                    targetActions: [
                        ViewScopeEventTargetAction(
                            targetClassName: "Demo.ConnectCoordinator",
                            actionName: "connect:"
                        )
                    ]
                ),
                ViewScopeEventHandler(
                    kind: .gesture,
                    title: "NSClickGestureRecognizer",
                    subtitle: nil,
                    targetActions: [
                        ViewScopeEventTargetAction(
                            targetClassName: "Demo.GestureCoordinator",
                            actionName: "handleTap:"
                        )
                    ],
                    isEnabled: true,
                    delegateClassName: "Demo.GestureDelegate"
                )
            ]
        )

        #expect(ViewTreeNodePresentation.matches(node: node, query: "clickgesturerecognizer"))
        #expect(ViewTreeNodePresentation.matches(node: node, query: "gesturedelegate"))
        #expect(ViewTreeNodePresentation.matches(node: node, query: "connectcoordinator"))
        #expect(ViewTreeNodePresentation.matches(node: node, query: "handletap"))
    }

    @Test func treePresentationResolvesLookinStyleIconKinds() async throws {
        let windowNode = ViewScopeHierarchyNode(
            id: "window",
            parentID: nil,
            kind: .window,
            className: "NSWindow",
            title: "Window",
            subtitle: nil,
            frame: .zero,
            bounds: .zero,
            childIDs: [],
            isHidden: false,
            alphaValue: 1,
            wantsLayer: true,
            isFlipped: false,
            clippingEnabled: true,
            depth: 0
        )
        let controllerRootNode = ViewScopeHierarchyNode(
            id: "controller-root",
            parentID: "window",
            kind: .view,
            className: "NSView",
            title: "Root",
            subtitle: nil,
            frame: .zero,
            bounds: .zero,
            childIDs: [],
            isHidden: false,
            alphaValue: 1,
            wantsLayer: false,
            isFlipped: true,
            clippingEnabled: false,
            depth: 1,
            rootViewControllerClassName: "Demo.RootViewController"
        )
        let buttonNode = ViewScopeHierarchyNode(
            id: "button",
            parentID: "window",
            kind: .view,
            className: "NSButton",
            title: "Connect",
            subtitle: nil,
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
        let labelNode = ViewScopeHierarchyNode(
            id: "label",
            parentID: "window",
            kind: .view,
            className: "NSTextField",
            title: "Title",
            subtitle: nil,
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

        #expect(ViewTreeNodePresentation.iconKind(for: windowNode) == .window)
        #expect(ViewTreeNodePresentation.iconKind(for: controllerRootNode) == .viewController)
        #expect(ViewTreeNodePresentation.iconKind(for: buttonNode) == .button)
        #expect(ViewTreeNodePresentation.iconKind(for: labelNode) == .label)
    }

    @Test func sampleFixtureProvidesPreviewBitmapAndConsoleTargets() async throws {
        let capture = SampleFixture.capture()
        let detail = SampleFixture.detail(for: "window-0-view-1-2")
        let contentRoot = try #require(capture.nodes["window-0-view-1"])

        #expect(capture.previewBitmaps.count == 1)
        #expect(capture.previewBitmaps.first?.rootNodeID == "window-0")
        #expect(detail.consoleTargets.isEmpty == false)
        #expect(detail.consoleTargets.first?.reference.captureID == capture.captureID)
        #expect(contentRoot.rootViewControllerClassName == "SampleNotes.ContentViewController")
        #expect(ViewTreeNodePresentation.classText(for: contentRoot) == "ContentPaneView ContentViewController.view")
    }

    @Test func previewFixtureStoreSyncsConsoleTargetFromSelection() async throws {
        let suiteName = "ViewScopeConsoleFixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(
            defaults: defaults,
            environment: [
                "VIEWSCOPE_DISABLE_UPDATES": "1",
                "VIEWSCOPE_PREVIEW_FIXTURE": "1"
            ]
        )
        let store = try WorkspaceStore(settings: settings, updateManager: UpdateManager(settings: settings))
        defer { store.shutdown() }

        store.start()
        await store.selectNode(withID: "window-0-view-1-2", highlightInHost: false)

        #expect(store.consoleCandidateTargets.isEmpty == false)
        #expect(store.consoleCurrentTarget?.reference.kind == .view)
        #expect(store.consoleCurrentTarget?.reference.captureID == store.capture?.captureID)
    }

    @Test func consoleModelDisablesSubmissionForStaleTarget() async throws {
        let staleTarget = ViewScopeConsoleTargetDescriptor(
            reference: ViewScopeRemoteObjectReference(
                captureID: "capture-old",
                objectID: "obj-1",
                kind: .view,
                className: "NSView",
                address: "0x1",
                sourceNodeID: "node-1"
            ),
            title: "<NSView: 0x1>",
            subtitle: "ChartCard"
        )
        let model = ConsoleModelBuilder.make(
            currentTarget: staleTarget,
            candidateTargets: [],
            recentTargets: [staleTarget],
            rows: [],
            autoSyncEnabled: false,
            isLoading: false,
            captureID: "capture-current"
        )

        #expect(model.isSubmitEnabled == false)
        #expect(model.statusText == L10n.consoleStatusStaleTarget)
    }

    @Test func consolePanelDoesNotCreatePlaceholderRowsWhileDisconnected() async throws {
        let store = try makeDisconnectedStore()
        defer { store.shutdown() }

        let controller = ConsolePanelController(store: store)
        _ = controller.view
        pumpRunLoop(for: 0.1)
        controller.view.layoutSubtreeIfNeeded()

        let documentView = try #require(Mirror(reflecting: controller).descendant("documentView") as? NSView)
        #expect(documentView.subviews.isEmpty)
    }

    @Test func previewConsoleRequiresSelectionAndToggleToBeVisible() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)

        let controller = PreviewPanelController(store: store)
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: 1320, height: 900)
        view.layoutSubtreeIfNeeded()

        let toggleButton = try #require(Mirror(reflecting: controller).descendant("consoleToggleButton") as? NSButton)
        let consoleController = try #require(Mirror(reflecting: controller).descendant("consoleController") as? ConsolePanelController)

        #expect(consoleController.view.isHidden)

        toggleButton.performClick(nil)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()
        #expect(consoleController.view.isHidden == false)

        await store.selectNode(withID: nil, highlightInHost: false)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()
        #expect(consoleController.view.isHidden)

        await store.selectNode(withID: "window-0-view-1-2", highlightInHost: false)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()
        #expect(consoleController.view.isHidden == false)

        toggleButton.performClick(nil)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()
        #expect(consoleController.view.isHidden)
    }

    @Test func previewImageResolverFallsBackToDetailWhenCapturePreviewBitmapIsUnavailable() async throws {
        var capture = SampleFixture.capture()
        capture.previewBitmaps = []
        let detail = try #require(SampleFixture.detail(for: "window-0-view-1-2"))

        let resolved = PreviewImageResolver.resolve(
            capture: capture,
            preferredRootNodeID: "window-0",
            detail: detail
        )

        #expect(resolved?.cacheKey == "detail:\(capture.captureID):window-0")
        #expect(resolved?.base64PNG == detail.screenshotPNGBase64)
        #expect(resolved?.size == detail.screenshotSize.cgSize)
    }

    @Test func previewPanelReusesDecodedPreviewImageAcrossScaleUpdates() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)

        let controller = PreviewPanelController(store: store)
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: 1320, height: 900)
        view.layoutSubtreeIfNeeded()

        let canvasView = try #require(Mirror(reflecting: controller).descendant("canvasView") as? PreviewCanvasView)
        let initialImage = try #require(canvasView.image)

        store.setPreviewScale(1.25)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()

        let updatedImage = try #require(canvasView.image)
        #expect(initialImage === updatedImage)
    }

    @Test func previewPanelRoutesFlatModeThroughCanvasView() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)

        let controller = PreviewPanelController(store: store)
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: 1320, height: 900)
        view.layoutSubtreeIfNeeded()

        let canvasView = try #require(Mirror(reflecting: controller).descendant("canvasView") as? PreviewCanvasView)
        let layeredSceneView = try #require(Mirror(reflecting: controller).descendant("layeredSceneView") as? PreviewLayeredSceneView)

        #expect(store.previewDisplayMode == .flat)
        #expect(canvasView.isHidden == false)
        #expect(layeredSceneView.isHidden)

        store.setPreviewDisplayMode(.layered)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()

        #expect(canvasView.isHidden)
        #expect(layeredSceneView.isHidden == false)
    }

    @Test func previewPanelMakesControllerFirstResponderWhenShown() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)

        let controller = PreviewPanelController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.close()
        }

        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.viewDidAppear()
        pumpRunLoop(for: 0.1)

        #expect(window.firstResponder === controller)
    }

    @Test func previewPanelClipsPreviewContentToPanelBody() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)

        let controller = PreviewPanelController(store: store)
        _ = controller.view

        let panelView = try #require(controller.view as? WorkspacePanelContainerView)
        let previewContainerView = try #require(Mirror(reflecting: controller).descendant("previewContainerView") as? NSView)

        #expect(panelView.contentView.wantsLayer)
        #expect(panelView.contentView.layer?.masksToBounds == true)
        #expect(previewContainerView.wantsLayer)
        #expect(previewContainerView.layer?.masksToBounds == true)
    }

    @Test func previewPanelApplies3DRotationWithoutUsingResponderChain() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)

        let controller = PreviewPanelController(store: store)
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: 1320, height: 900)
        view.layoutSubtreeIfNeeded()

        store.setPreviewDisplayMode(.layered)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()

        let layeredSceneView = try #require(Mirror(reflecting: controller).descendant("layeredSceneView") as? PreviewLayeredSceneView)
        let before = try #require(Mirror(reflecting: layeredSceneView).descendant("stageRotation") as? CGPoint)

        controller.handleActivePreviewRotation(14)

        let after = try #require(Mirror(reflecting: layeredSceneView).descendant("stageRotation") as? CGPoint)
        #expect(after != before)
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

    @Test func layeredPreviewStartsFromFullCanvasWhenSelectionExistsButFocusDoesNot() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)
        await store.selectNode(withID: "window-0-view-1-2", highlightInHost: false)
        store.clearFocus()

        let controller = PreviewPanelController(store: store)
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: 1320, height: 900)
        view.layoutSubtreeIfNeeded()

        store.setPreviewDisplayMode(.layered)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()

        let layeredSceneView = try #require(Mirror(reflecting: controller).descendant("layeredSceneView") as? PreviewLayeredSceneView)
        let stageTranslation = try #require(Mirror(reflecting: layeredSceneView).descendant("stageTranslation") as? CGPoint)
        #expect(abs(stageTranslation.x) < 0.001)
        #expect(abs(stageTranslation.y) < 0.001)
    }

    @Test func layeredPreviewKeepsCurrentFlatViewportWhenEntering3D() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)

        let controller = PreviewPanelController(store: store)
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: 1320, height: 900)
        view.layoutSubtreeIfNeeded()

        let canvasView = try #require(Mirror(reflecting: controller).descendant("canvasView") as? PreviewCanvasView)
        store.setPreviewScale(2)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()

        canvasView.centerOnCanvasRect(CGRect(x: 920, y: 420, width: 140, height: 100))
        let visibleRect = canvasView.visibleCanvasRect()

        store.setPreviewDisplayMode(.layered)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()

        let layeredSceneView = try #require(Mirror(reflecting: controller).descendant("layeredSceneView") as? PreviewLayeredSceneView)
        let stageTranslation = try #require(Mirror(reflecting: layeredSceneView).descendant("stageTranslation") as? CGPoint)

        let expectedTranslation = CGPoint(
            x: -((visibleRect.midX - 600) * 0.01),
            y: -((320 - visibleRect.midY) * 0.01)
        )

        #expect(abs(stageTranslation.x - expectedTranslation.x) < 0.001)
        #expect(abs(stageTranslation.y - expectedTranslation.y) < 0.001)
        #expect(abs(stageTranslation.x) > 0.1 || abs(stageTranslation.y) > 0.1)
    }

    @Test func projectedQuadAppliesPerspectiveForeshorteningAcrossOppositeEdges() async throws {
        let transform = PreviewLayerTransform(yaw: -0.22, pitch: 0.16)
        let rect = CGRect(x: 292, y: 152, width: 760, height: 408)

        let quad = transform.projectedQuad(
            for: rect,
            depth: 2,
            canvasSize: CGSize(width: 1200, height: 640)
        )

        let topWidth = hypot(quad[1].x - quad[0].x, quad[1].y - quad[0].y)
        let bottomWidth = hypot(quad[2].x - quad[3].x, quad[2].y - quad[3].y)
        let leftHeight = hypot(quad[3].x - quad[0].x, quad[3].y - quad[0].y)
        let rightHeight = hypot(quad[2].x - quad[1].x, quad[2].y - quad[1].y)

        #expect(abs(topWidth - bottomWidth) > 20)
        #expect(abs(leftHeight - rightHeight) > 20)
    }

    @Test func layeredSceneBalancesPlaneDepthAroundStackMidpoint() async throws {
        let capture = SampleFixture.capture()
        let image = try #require(decodedPreviewImage(from: capture))
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 1320, height: 900))
        sceneView.capture = capture
        sceneView.image = image
        sceneView.canvasSize = CGSize(width: 1200, height: 640)
        sceneView.previewExpandedNodeIDs = ["window-0-view-1"]
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let zPositions = Array(
            Set(stageNode.childNodes.map { CGFloat($0.position.z).rounded(toPlaces: 3) })
        ).sorted()

        #expect(zPositions.count == 3)
        #expect(zPositions.first ?? 0 < 0)
        #expect(abs(zPositions[1]) < 0.001)
        #expect(zPositions.last ?? 0 > 0)
    }

    @Test func layeredSceneCreatesOneVisibleContentPlanePerGeneration() async throws {
        let capture = SampleFixture.capture()
        let image = try #require(decodedPreviewImage(from: capture))
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 1320, height: 900))
        sceneView.capture = capture
        sceneView.image = image
        sceneView.canvasSize = CGSize(width: 1200, height: 640)
        sceneView.previewExpandedNodeIDs = ["window-0-view-1"]
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let contentPlaneNames = stageNode.childNodes.compactMap(\.name).filter { $0.hasPrefix("content-plane-") }.sorted()

        #expect(contentPlaneNames == ["content-plane-0", "content-plane-1", "content-plane-2"])
    }

    @Test func layeredScenePunchesExpandedChildRectsOutOfParentTexture() async throws {
        let capture = SampleFixture.capture()
        let image = try #require(decodedPreviewImage(from: capture))
        let canvasSize = CGSize(width: 1200, height: 640)
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 1320, height: 900))
        sceneView.capture = capture
        sceneView.image = image
        sceneView.canvasSize = canvasSize
        sceneView.previewExpandedNodeIDs = ["window-0-view-1"]
        sceneView.layoutSubtreeIfNeeded()

        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: canvasSize,
            expandedNodeIDs: ["window-0-view-1"]
        )
        let parentItem = try #require(plan.item(for: "window-0-view-1"))
        let punchedOutRect = try #require(plan.item(for: "window-0-view-1-1")?.displayRect)

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let displayNode = try #require(stageNode.childNode(withName: "display-window-0-view-1", recursively: false))
        let contentNode = try #require(displayNode.childNode(withName: "window-0-view-1", recursively: true))
        let itemImage = try #require((contentNode.geometry as? SCNPlane)?.firstMaterial?.diffuse.contents as? NSImage)

        let localPoint = CGPoint(
            x: punchedOutRect.midX - parentItem.displayRect.minX,
            y: punchedOutRect.midY - parentItem.displayRect.minY
        )
        let pixel = color(in: itemImage, atImagePoint: localPoint)

        #expect((pixel?.alphaComponent ?? 1) < 0.05)
    }

    @Test func layeredSceneCropsBottomAlignedTextureInDisplayCoordinatesForFlippedPreviewRoot() async throws {
        let host = SampleFixture.capture().host
        let canvasSize = CGSize(width: 200, height: 120)
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
                    title: "Window",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 0, width: 200, height: 120),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 200, height: 120),
                    childIDs: ["bottom"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: true,
                    clippingEnabled: true,
                    depth: 0
                ),
                "bottom": ViewScopeHierarchyNode(
                    id: "bottom",
                    parentID: "window-0",
                    kind: .view,
                    className: "NSView",
                    title: "Bottom",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 60, width: 200, height: 60),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 200, height: 60),
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
        let image = makeTopLeftOrientedSplitScreenshot()

        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sceneView.capture = capture
        sceneView.image = image
        sceneView.canvasSize = canvasSize
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let displayNode = try #require(stageNode.childNode(withName: "display-bottom", recursively: false))
        let contentNode = try #require(displayNode.childNode(withName: "bottom", recursively: true))
        let itemImage = try #require((contentNode.geometry as? SCNPlane)?.firstMaterial?.diffuse.contents as? NSImage)

        let topSample = color(in: itemImage, atImagePoint: CGPoint(x: 100, y: 15))
        let bottomSample = color(in: itemImage, atImagePoint: CGPoint(x: 100, y: 45))

        #expect((topSample?.blueComponent ?? 0) > 0.7)
        #expect((topSample?.redComponent ?? 1) < 0.4)
        #expect((bottomSample?.blueComponent ?? 0) > 0.7)
        #expect((bottomSample?.redComponent ?? 1) < 0.4)
    }

    @Test func layeredSceneCropsBottomAlignedTextureInDisplayCoordinatesForNonFlippedPreviewRoot() async throws {
        let host = SampleFixture.capture().host
        let canvasSize = CGSize(width: 200, height: 120)
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
                    title: "Window",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 0, width: 200, height: 120),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 200, height: 120),
                    childIDs: ["bottom"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: true,
                    depth: 0
                ),
                "bottom": ViewScopeHierarchyNode(
                    id: "bottom",
                    parentID: "window-0",
                    kind: .view,
                    className: "NSView",
                    title: "Bottom",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 60, width: 200, height: 60),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 200, height: 60),
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
        let image = try #require(pngRoundTripped(makeVerticallySplitScreenshot()))

        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sceneView.capture = capture
        sceneView.image = image
        sceneView.canvasSize = canvasSize
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let displayNode = try #require(stageNode.childNode(withName: "display-bottom", recursively: false))
        let contentNode = try #require(displayNode.childNode(withName: "bottom", recursively: true))
        let itemImage = try #require((contentNode.geometry as? SCNPlane)?.firstMaterial?.diffuse.contents as? NSImage)

        let topSample = color(in: itemImage, atImagePoint: CGPoint(x: 100, y: 15))
        let bottomSample = color(in: itemImage, atImagePoint: CGPoint(x: 100, y: 45))

        #expect((topSample?.blueComponent ?? 0) > 0.7)
        #expect((topSample?.redComponent ?? 1) < 0.4)
        #expect((bottomSample?.blueComponent ?? 0) > 0.7)
        #expect((bottomSample?.redComponent ?? 1) < 0.4)
    }

    @Test func layeredSceneSkipsZeroSizedItemsInsteadOfCreatingZeroSizedImages() async throws {
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
                    title: "Window",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 0, width: 200, height: 120),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 200, height: 120),
                    childIDs: ["window-0-view-0"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: true,
                    clippingEnabled: true,
                    depth: 0
                ),
                "window-0-view-0": ViewScopeHierarchyNode(
                    id: "window-0-view-0",
                    parentID: "window-0",
                    kind: .view,
                    className: "NSView",
                    title: "Zero",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 40, y: 30, width: 0, height: 24),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 0, height: 24),
                    childIDs: [],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: true,
                    clippingEnabled: false,
                    depth: 1
                )
            ]
        )
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 1320, height: 900))
        sceneView.capture = capture
        sceneView.image = try #require(pngRoundTripped(makeNonFlippedRootScreenshot()))
        sceneView.canvasSize = CGSize(width: 200, height: 120)
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let displayNodeNames = stageNode.childNodes.compactMap(\.name)

        #expect(displayNodeNames.contains("display-window-0"))
        #expect(displayNodeNames.contains("display-window-0-view-0") == false)
    }

    @Test func layeredSceneVerticalRotationAllowsLargeSweep() async throws {
        let updated = PreviewLayeredSceneInteraction.updatedRotation(
            current: CGPoint(x: 0, y: 0),
            delta: CGPoint(x: 0, y: 240)
        )

        #expect(abs(updated.x) > 0.8)
    }

    @Test func layeredSceneVerticalRotationMatchesLookinDirection() async throws {
        let updated = PreviewLayeredSceneInteraction.updatedRotation(
            current: CGPoint(x: 0, y: 0),
            delta: CGPoint(x: 0, y: 120)
        )

        #expect(updated.x < 0)
    }

    @Test func layeredSceneRotationWrapsPastFullTurns() async throws {
        let updated = PreviewLayeredSceneInteraction.updatedRotation(
            current: CGPoint(x: .pi - 0.02, y: .pi - 0.03),
            delta: CGPoint(x: 420, y: 900)
        )

        #expect(updated.x < .pi)
        #expect(updated.x > -.pi)
        #expect(updated.y < .pi)
        #expect(updated.y > -.pi)
    }

    @Test func layeredSceneEntering3DUsesLookinMinimumYaw() async throws {
        let updated = PreviewLayeredSceneInteraction.rotationWhenEnteringLayered(from: .zero)

        #expect(abs(updated.x - ((-10 * .pi) / 180)) < 0.001)
        #expect(abs(updated.y - ((15 * .pi) / 180)) < 0.001)
    }

    @Test func layeredSceneDefaultsTo3DEntryPose() async throws {
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 1320, height: 900))
        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))

        #expect(abs(CGFloat(stageNode.eulerAngles.x) - ((-10 * .pi) / 180)) < 0.001)
        #expect(abs(CGFloat(stageNode.eulerAngles.y) - ((15 * .pi) / 180)) < 0.001)
    }

    @Test func layeredPreviewReentering3DResetsToLookinEntryPose() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)

        let controller = PreviewPanelController(store: store)
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: 1320, height: 900)
        view.layoutSubtreeIfNeeded()

        store.setPreviewDisplayMode(.layered)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()

        let layeredSceneView = try #require(Mirror(reflecting: controller).descendant("layeredSceneView") as? PreviewLayeredSceneView)
        layeredSceneView.applyRotationGesture(48)
        let scene = try #require(layeredSceneView.scene)
        let stageNode = try #require(scene.rootNode.childNode(withName: "stage", recursively: false))
        #expect(abs(CGFloat(stageNode.eulerAngles.y) - ((15 * .pi) / 180)) > 0.05)

        store.setPreviewDisplayMode(.flat)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()

        store.setPreviewDisplayMode(.layered)
        pumpRunLoop(for: 0.1)
        view.layoutSubtreeIfNeeded()

        #expect(abs(CGFloat(stageNode.eulerAngles.x) - ((-10 * .pi) / 180)) < 0.001)
        #expect(abs(CGFloat(stageNode.eulerAngles.y) - ((15 * .pi) / 180)) < 0.001)
    }

    @Test func layeredSceneSelectionOverlayUsesExplicitHighlightedRect() async throws {
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sceneView.canvasSize = CGSize(width: 200, height: 120)
        sceneView.highlightedCanvasRect = CGRect(x: 12, y: 18, width: 60, height: 24)
        sceneView.selectedNodeID = "selected-node"
        sceneView.displayMode = .layered
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let selectionNode = try #require(stageNode.childNode(withName: "selection-overlay", recursively: false))

        #expect(abs(CGFloat(selectionNode.position.x) - -0.58) < 0.001)
        #expect(abs(CGFloat(selectionNode.position.y) - 0.3) < 0.001)
    }

    @Test func layeredSceneSelectionOverlayUsesRenderedNodeGeometryWhenAvailable() async throws {
        let capture = SampleFixture.capture()
        let image = try #require(decodedPreviewImage(from: capture))
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 1320, height: 900))
        sceneView.capture = capture
        sceneView.image = image
        sceneView.canvasSize = CGSize(width: 1200, height: 640)
        sceneView.selectedNodeID = "window-0-view-1"
        sceneView.highlightedCanvasRect = CGRect(x: 24, y: 24, width: 40, height: 40)
        sceneView.displayMode = .layered
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let selectionNode = try #require(stageNode.childNode(withName: "selection-overlay", recursively: false))
        let renderedNode = try #require(stageNode.childNode(withName: "display-window-0-view-1", recursively: false))

        #expect(abs(CGFloat(selectionNode.position.x) - CGFloat(renderedNode.position.x)) < 0.001)
        #expect(abs(CGFloat(selectionNode.position.y) - CGFloat(renderedNode.position.y)) < 0.001)
    }

    @Test func layeredSceneSelectionOverlayUsesUnifiedDisplayCoordinates() async throws {
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sceneView.canvasSize = CGSize(width: 200, height: 120)
        sceneView.highlightedCanvasRect = CGRect(x: 12, y: 18, width: 60, height: 24)
        sceneView.selectedNodeID = "selected-node"
        sceneView.displayMode = .layered
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let selectionNode = try #require(stageNode.childNode(withName: "selection-overlay", recursively: false))

        #expect(abs(CGFloat(selectionNode.position.x) - -0.58) < 0.001)
        #expect(abs(CGFloat(selectionNode.position.y) - 0.3) < 0.001)
    }

    @Test func layeredSceneSelectionOverlayFollowsRenderedNodeInMixedFlippedHierarchy() async throws {
        let capture = ViewScopeCapturePayload(
            host: SampleFixture.capture().host,
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(nodeCount: 3, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: [
                "root": ViewScopeHierarchyNode(
                    id: "root",
                    parentID: nil,
                    kind: .window,
                    className: "NSWindow",
                    title: "Root",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    childIDs: ["stack"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: true,
                    clippingEnabled: false,
                    depth: 0
                ),
                "stack": ViewScopeHierarchyNode(
                    id: "stack",
                    parentID: "root",
                    kind: .view,
                    className: "NSStackView",
                    title: "Stack",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    childIDs: ["button"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: false,
                    depth: 1
                ),
                "button": ViewScopeHierarchyNode(
                    id: "button",
                    parentID: "stack",
                    kind: .view,
                    className: "NSButton",
                    title: "Button",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 207.5, y: 96, width: 76, height: 24),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 76, height: 24),
                    childIDs: [],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: false,
                    depth: 2
                )
            ]
        )
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sceneView.capture = capture
        sceneView.image = try #require(pngRoundTripped(makeNonFlippedRootScreenshot(size: CGSize(width: 320, height: 120))))
        sceneView.canvasSize = CGSize(width: 320, height: 120)
        sceneView.highlightedCanvasRect = CGRect(x: 207.5, y: 96, width: 76, height: 24)
        sceneView.selectedNodeID = "button"
        sceneView.displayMode = .layered
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let selectionNode = try #require(stageNode.childNode(withName: "selection-overlay", recursively: false))
        let renderedNode = try #require(stageNode.childNode(withName: "display-button", recursively: false))

        #expect(abs(CGFloat(selectionNode.position.x) - CGFloat(renderedNode.position.x)) < 0.001)
        #expect(abs(CGFloat(selectionNode.position.y) - CGFloat(renderedNode.position.y)) < 0.001)
        #expect(abs(CGFloat(renderedNode.position.y) - -0.48) < 0.001)
    }

    @Test func layeredSceneMixedFlippedHierarchyKeepsBottomButtonTextureAsSingleSlice() async throws {
        let buttonRect = CGRect(x: 207.5, y: 96, width: 76, height: 24)
        let capture = ViewScopeCapturePayload(
            host: SampleFixture.capture().host,
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(nodeCount: 3, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: [
                "root": ViewScopeHierarchyNode(
                    id: "root",
                    parentID: nil,
                    kind: .window,
                    className: "NSWindow",
                    title: "Root",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    childIDs: ["stack"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: true,
                    clippingEnabled: false,
                    depth: 0
                ),
                "stack": ViewScopeHierarchyNode(
                    id: "stack",
                    parentID: "root",
                    kind: .view,
                    className: "NSStackView",
                    title: "Stack",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    childIDs: ["button"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: false,
                    depth: 1
                ),
                "button": ViewScopeHierarchyNode(
                    id: "button",
                    parentID: "stack",
                    kind: .view,
                    className: "NSButton",
                    title: "Button",
                    subtitle: nil,
                    frame: ViewScopeRect(x: buttonRect.minX, y: buttonRect.minY, width: buttonRect.width, height: buttonRect.height),
                    bounds: ViewScopeRect(x: 0, y: 0, width: buttonRect.width, height: buttonRect.height),
                    childIDs: [],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: false,
                    depth: 2
                )
            ]
        )
        let image = makeTopLeftOrientedMarkerScreenshot(
            size: CGSize(width: 320, height: 120),
            markerRect: buttonRect,
            markerColor: .systemRed
        )

        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sceneView.capture = capture
        sceneView.image = image
        sceneView.canvasSize = CGSize(width: 320, height: 120)
        sceneView.displayMode = .layered
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let displayNode = try #require(stageNode.childNode(withName: "display-button", recursively: false))
        let contentNode = try #require(displayNode.childNode(withName: "button", recursively: true))
        let itemImage = try #require((contentNode.geometry as? SCNPlane)?.firstMaterial?.diffuse.contents as? NSImage)

        let topSample = color(in: itemImage, atImagePoint: CGPoint(x: 20, y: 4))
        let bottomSample = color(in: itemImage, atImagePoint: CGPoint(x: 20, y: 19))

        #expect((topSample?.redComponent ?? 0) > 0.7)
        #expect((topSample?.greenComponent ?? 1) < 0.45)
        #expect((topSample?.blueComponent ?? 1) < 0.45)
        #expect((bottomSample?.redComponent ?? 0) > 0.7)
        #expect((bottomSample?.greenComponent ?? 1) < 0.45)
        #expect((bottomSample?.blueComponent ?? 1) < 0.45)
    }

    @Test func layeredSceneMixedFlippedHierarchyPunchesExpandedButtonOutOfParentTexture() async throws {
        let buttonRect = CGRect(x: 207.5, y: 96, width: 76, height: 24)
        let capture = ViewScopeCapturePayload(
            host: SampleFixture.capture().host,
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(nodeCount: 3, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: [
                "root": ViewScopeHierarchyNode(
                    id: "root",
                    parentID: nil,
                    kind: .window,
                    className: "NSWindow",
                    title: "Root",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    childIDs: ["stack"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: true,
                    clippingEnabled: false,
                    depth: 0
                ),
                "stack": ViewScopeHierarchyNode(
                    id: "stack",
                    parentID: "root",
                    kind: .view,
                    className: "NSStackView",
                    title: "Stack",
                    subtitle: nil,
                    frame: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    bounds: ViewScopeRect(x: 0, y: 0, width: 320, height: 120),
                    childIDs: ["button"],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: false,
                    depth: 1
                ),
                "button": ViewScopeHierarchyNode(
                    id: "button",
                    parentID: "stack",
                    kind: .view,
                    className: "NSButton",
                    title: "Button",
                    subtitle: nil,
                    frame: ViewScopeRect(x: buttonRect.minX, y: buttonRect.minY, width: buttonRect.width, height: buttonRect.height),
                    bounds: ViewScopeRect(x: 0, y: 0, width: buttonRect.width, height: buttonRect.height),
                    childIDs: [],
                    isHidden: false,
                    alphaValue: 1,
                    wantsLayer: true,
                    isFlipped: false,
                    clippingEnabled: false,
                    depth: 2
                )
            ]
        )
        let image = makeTopLeftOrientedMarkerScreenshot(
            size: CGSize(width: 320, height: 120),
            markerRect: buttonRect,
            markerColor: .systemRed
        )

        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sceneView.capture = capture
        sceneView.image = image
        sceneView.canvasSize = CGSize(width: 320, height: 120)
        sceneView.previewExpandedNodeIDs = ["stack"]
        sceneView.displayMode = .layered
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let displayNode = try #require(stageNode.childNode(withName: "display-stack", recursively: false))
        let contentNode = try #require(displayNode.childNode(withName: "stack", recursively: true))
        let itemImage = try #require((contentNode.geometry as? SCNPlane)?.firstMaterial?.diffuse.contents as? NSImage)

        let localPoint = CGPoint(
            x: buttonRect.midX,
            y: buttonRect.midY
        )
        let pixel = color(in: itemImage, atImagePoint: localPoint)

        #expect((pixel?.alphaComponent ?? 1) < 0.05)
    }

    @Test func layeredSceneSnapshotKeepsTopLeftOrientedTextureUpright() async throws {
        let canvasSize = CGSize(width: 200, height: 120)
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sceneView.capture = makeImageOnlyCapture(canvasSize: canvasSize, rootIsHidden: false)
        sceneView.image = makeTopLeftOrientedSplitScreenshot()
        sceneView.canvasSize = canvasSize
        sceneView.displayMode = .layered
        sceneView.layoutSubtreeIfNeeded()
        pumpRunLoop(for: 0.1)

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let displayNode = try #require(stageNode.childNode(withName: "display-window-0", recursively: false))
        let contentNode = try #require(displayNode.childNode(withName: "window-0", recursively: true))
        let snapshot = try #require(pngRoundTripped(sceneView.snapshot()))

        let topSample = projectedSnapshotPoint(
            in: sceneView,
            node: contentNode,
            normalizedPoint: CGPoint(x: 0.5, y: 0.2)
        )
        let bottomSample = projectedSnapshotPoint(
            in: sceneView,
            node: contentNode,
            normalizedPoint: CGPoint(x: 0.5, y: 0.8)
        )

        let topPixel = color(in: snapshot, atImagePoint: topSample)
        let bottomPixel = color(in: snapshot, atImagePoint: bottomSample)

        #expect((topPixel?.redComponent ?? 0) > 0.7)
        #expect((topPixel?.blueComponent ?? 1) < 0.35)
        #expect((bottomPixel?.blueComponent ?? 0) > 0.7)
        #expect((bottomPixel?.redComponent ?? 1) < 0.35)
    }

    @Test func layeredSceneSnapshotKeepsSnapshotBuilderTextureUpright() async throws {
        let canvasSize = CGSize(width: 200, height: 120)
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sceneView.capture = makeImageOnlyCapture(canvasSize: canvasSize, rootIsHidden: false)
        sceneView.image = try #require(makeSnapshotBuilderScreenshot(for: makeVerticallySplitRootView()))
        sceneView.canvasSize = canvasSize
        sceneView.displayMode = .layered
        sceneView.layoutSubtreeIfNeeded()
        pumpRunLoop(for: 0.1)

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let displayNode = try #require(stageNode.childNode(withName: "display-window-0", recursively: false))
        let contentNode = try #require(displayNode.childNode(withName: "window-0", recursively: true))
        let snapshot = try #require(pngRoundTripped(sceneView.snapshot()))

        let topSample = projectedSnapshotPoint(
            in: sceneView,
            node: contentNode,
            normalizedPoint: CGPoint(x: 0.5, y: 0.2)
        )
        let bottomSample = projectedSnapshotPoint(
            in: sceneView,
            node: contentNode,
            normalizedPoint: CGPoint(x: 0.5, y: 0.8)
        )

        let topPixel = color(in: snapshot, atImagePoint: topSample)
        let bottomPixel = color(in: snapshot, atImagePoint: bottomSample)

        #expect((topPixel?.redComponent ?? 0) > 0.7)
        #expect((topPixel?.blueComponent ?? 1) < 0.35)
        #expect((bottomPixel?.blueComponent ?? 0) > 0.7)
        #expect((bottomPixel?.redComponent ?? 1) < 0.35)
    }

    @Test func layeredSceneTextureImageKeepsSnapshotBuilderImageUprightBeforeSceneRendering() async throws {
        let canvasSize = CGSize(width: 200, height: 120)
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sceneView.capture = makeImageOnlyCapture(canvasSize: canvasSize, rootIsHidden: false)
        sceneView.image = try #require(makeSnapshotBuilderScreenshot(for: makeVerticallySplitRootView()))
        sceneView.canvasSize = canvasSize
        sceneView.displayMode = .layered
        sceneView.layoutSubtreeIfNeeded()

        let stageNode = try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
        let displayNode = try #require(stageNode.childNode(withName: "display-window-0", recursively: false))
        let contentNode = try #require(displayNode.childNode(withName: "window-0", recursively: true))
        let itemImage = try #require((contentNode.geometry as? SCNPlane)?.firstMaterial?.diffuse.contents as? NSImage)

        let topPixel = color(in: itemImage, atImagePoint: CGPoint(x: 100, y: 24))
        let bottomPixel = color(in: itemImage, atImagePoint: CGPoint(x: 100, y: 96))

        #expect((topPixel?.redComponent ?? 0) > 0.7)
        #expect((topPixel?.blueComponent ?? 1) < 0.35)
        #expect((bottomPixel?.blueComponent ?? 0) > 0.7)
        #expect((bottomPixel?.redComponent ?? 1) < 0.35)
    }

    @Test func workspaceStoreClampsPreviewLayerSpacingToExpandedRange() async throws {
        let store = try makeDisconnectedStore()
        defer { store.shutdown() }

        store.setPreviewLayerSpacing(1)
        #expect(store.previewLayerSpacing == 10)

        store.setPreviewLayerSpacing(200)
        #expect(store.previewLayerSpacing == 150)
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
        pumpRunLoop(for: 0.1)
        controller.view.layoutSubtreeIfNeeded()

        let rowStack = try #require(findRowStack(in: controller.view))
        #expect(rowStack.spacing == 8)
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

    @Test func previewGeometryCanResolveRectsRelativeToPreviewRootNode() async throws {
        let capture = SampleFixture.capture()
        let rect = try #require(
            ViewHierarchyGeometry().canvasRect(
                for: "window-0-view-1-2",
                in: capture,
                coordinateRootNodeID: "window-0-view-1"
            )
        )

        #expect(rect == CGRect(x: 72, y: 152, width: 760, height: 408))
    }

    @Test func previewHitTestingCanUsePreviewRootLocalCoordinates() async throws {
        let capture = SampleFixture.capture()
        let nodeID = ViewHierarchyGeometry().deepestNodeID(
            at: CGPoint(x: 240, y: 200),
            in: capture,
            rootNodeID: "window-0-view-1",
            coordinateRootNodeID: "window-0-view-1"
        )

        #expect(nodeID == "window-0-view-1-2")
    }

    @Test func previewSelectionPrefersDetailHighlightRectWhenAvailable() async throws {
        let capture = SampleFixture.capture()
        var detail = SampleFixture.detail(for: "window-0-view-1-2")
        detail.highlightedRect = ViewScopeRect(x: 16, y: 24, width: 80, height: 44)

        let selectionRect = PreviewPanelRenderDecisions.selectionRect(
            capture: capture,
            selectedNodeID: "window-0-view-1-2",
            detail: detail,
            previewRootNodeID: nil,
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
            detail: detail,
            previewRootNodeID: nil
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
            detail: detail,
            previewRootNodeID: nil
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

    @Test func flatPreviewKeepsFlippedHostScreenshotUpright() async throws {
        let previewImage = try #require(await makeServerScreenshot(for: makeFlippedRootView()))
        let canvasSize = CGSize(width: 200, height: 120)
        let previewView = PreviewCanvasView(frame: NSRect(x: 0, y: 0, width: 256, height: 176))
        previewView.canvasSize = canvasSize
        previewView.image = previewImage
        previewView.displayMode = .flat
        previewView.layoutSubtreeIfNeeded()

        let rendered = render(view: previewView)
        let expectedRect = CGRect(x: 8, y: 8, width: 40, height: 30)
        let samplePoint = center(of: previewView.viewRect(fromCanvasRect: expectedRect))
        let pixel = color(in: rendered, atViewPoint: samplePoint)

        #expect((pixel?.redComponent ?? 0) > 0.8)
        #expect((pixel?.greenComponent ?? 0) < 0.5)
        #expect((pixel?.blueComponent ?? 0) < 0.5)
    }

    @Test func flatPreviewKeepsSnapshotBuilderFlippedRootScreenshotUpright() async throws {
        let previewImage = try #require(makeSnapshotBuilderScreenshot(for: makeFlippedRootView()))
        let canvasSize = CGSize(width: 200, height: 120)
        let previewView = PreviewCanvasView(frame: NSRect(x: 0, y: 0, width: 256, height: 176))
        previewView.canvasSize = canvasSize
        previewView.image = previewImage
        previewView.displayMode = .flat
        previewView.layoutSubtreeIfNeeded()

        let rendered = render(view: previewView)
        let viewport = PreviewViewportState(canvasSize: canvasSize, viewportSize: previewView.bounds.size)
        let samplePoint = try #require(viewport.viewPoint(forCanvasPoint: CGPoint(x: 28, y: 97)))
        let pixel = color(in: rendered, atViewPoint: samplePoint)

        #expect((pixel?.redComponent ?? 0) > 0.8)
        #expect((pixel?.greenComponent ?? 0) < 0.5)
        #expect((pixel?.blueComponent ?? 0) < 0.5)
    }

    @Test func flatPreviewKeepsSnapshotBuilderScreenshotUpright() async throws {
        let previewImage = try #require(makeSnapshotBuilderScreenshot(for: makeVerticallySplitRootView()))
        let canvasSize = CGSize(width: 200, height: 120)
        let previewView = PreviewCanvasView(frame: NSRect(x: 0, y: 0, width: 256, height: 176))
        previewView.canvasSize = canvasSize
        previewView.image = previewImage
        previewView.displayMode = .flat
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

        #expect((pixel?.blueComponent ?? 0) > 0.25)
    }

    @Test func flatPreviewSelectionForFlippedRootUsesSameDisplayCoordinatesAsScreenshot() async throws {
        let canvasSize = CGSize(width: 200, height: 120)
        let previewView = PreviewCanvasView(frame: NSRect(x: 0, y: 0, width: 256, height: 176))
        previewView.canvasSize = canvasSize
        previewView.highlightedCanvasRect = CGRect(x: 8, y: 8, width: 40, height: 30)
        previewView.displayMode = .flat
        previewView.layoutSubtreeIfNeeded()

        let rendered = render(view: previewView)
        let viewport = PreviewViewportState(canvasSize: canvasSize, viewportSize: previewView.bounds.size)
        let borderPoint = try #require(viewport.viewPoint(forCanvasPoint: CGPoint(x: 28, y: 111)))
        let pixel = color(in: rendered, atViewPoint: borderPoint)

        #expect((pixel?.blueComponent ?? 0) > 0.25)
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

    @Test func layeredPreviewKeepsSnapshotBuilderImageTopEdgeAtProjectedTopEdge() async throws {
        let previewImage = try #require(makeSnapshotBuilderScreenshot(for: makeVerticallySplitRootView()))
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
        let selectionCenterX = selectedQuad.map(\.x).reduce(0, +) / CGFloat(selectedQuad.count)
        let selectionCenterY = selectedQuad.map(\.y).reduce(0, +) / CGFloat(selectedQuad.count)
        let selectionCenter = CGPoint(x: selectionCenterX, y: selectionCenterY)
        let normalizedSelectionCenter = CGPoint(
            x: selectionCenter.x,
            y: canvasSize.height - selectionCenter.y
        )
        let samplePoint = previewView.viewRect(fromCanvasRect: CGRect(origin: normalizedSelectionCenter, size: .zero)).origin
        let pixel = color(in: rendered, atViewPoint: samplePoint)

        #expect((pixel?.redComponent ?? 0) > 0.45)
        #expect((pixel?.blueComponent ?? 0) > 0.2)
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

    @Test func appSettingsPersistPreviewLayerPreferences() async throws {
        let suiteName = "ViewScopePreviewPreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults, environment: [:])
        settings.previewLayerSpacing = 88
        settings.previewShowsLayerBorders = false

        let reloaded = AppSettings(defaults: defaults, environment: [:])
        #expect(reloaded.previewLayerSpacing == 88)
        #expect(reloaded.previewShowsLayerBorders == false)
    }

    @Test func workspaceRawPreviewExportIncludesCurrentPreviewContextAndBitmap() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)

        await store.selectNode(withID: "window-0-view-1-2", highlightInHost: false)
        store.setFocusedNode("window-0-view-1")
        store.setPreviewLayerSpacing(96)
        store.setPreviewShowsLayerBorders(false)
        store.setPreviewDisplayMode(.layered)
        store.setNodeExpanded("window-0-view-1", isExpanded: true)

        let exported = try #require(store.makeRawPreviewExport())
        #expect(exported.capture.captureID == store.capture?.captureID)
        #expect(exported.previewContext.selectedNodeID == "window-0-view-1-2")
        #expect(exported.previewContext.focusedNodeID == "window-0-view-1")
        #expect(exported.previewContext.previewDisplayMode == .layered)
        #expect(exported.previewContext.previewLayerSpacing == 96)
        #expect(exported.previewContext.previewShowsLayerBorders == false)
        #expect(exported.previewBitmap?.pngBase64.isEmpty == false)
    }

    @Test func workspaceArchiveCodecRoundTripsPreviewExport() async throws {
        let store = try makeFixtureStore()
        defer { store.shutdown() }
        store.start()
        pumpRunLoop(for: 0.1)

        await store.selectNode(withID: "window-0-view-1-2", highlightInHost: false)
        store.setFocusedNode("window-0-view-1")
        store.setPreviewLayerSpacing(96)
        store.setPreviewShowsLayerBorders(false)
        store.setPreviewDisplayMode(.layered)
        store.setNodeExpanded("window-0-view-1", isExpanded: true)

        let export = try #require(store.makeRawPreviewExport())
        let data = try WorkspaceArchiveCodec.encode(export)
        let decoded = try WorkspaceArchiveCodec.decode(data)

        #expect(decoded == export)
    }

    @Test func workspaceStoreLoadsPreviewExportArchiveFromFile() async throws {
        let sourceStore = try makeFixtureStore()
        defer { sourceStore.shutdown() }
        sourceStore.start()
        pumpRunLoop(for: 0.1)

        await sourceStore.selectNode(withID: "window-0-view-1-2", highlightInHost: false)
        sourceStore.setFocusedNode("window-0-view-1")
        sourceStore.setPreviewScale(1.8)
        sourceStore.setPreviewLayerSpacing(104)
        sourceStore.setPreviewShowsLayerBorders(false)
        sourceStore.setPreviewDisplayMode(.layered)
        sourceStore.setNodeExpanded("window-0-view-1", isExpanded: true)

        let export = try #require(sourceStore.makeRawPreviewExport())
        let data = try WorkspaceArchiveCodec.encode(export)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedFixture-\(UUID().uuidString)")
            .appendingPathExtension(WorkspaceArchiveCodec.fileExtension)
        try data.write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let importedStore = try makeDisconnectedStore()
        defer { importedStore.shutdown() }
        try importedStore.loadPreviewExport(from: fileURL)

        #expect(importedStore.connectionState == .imported(fileURL.deletingPathExtension().lastPathComponent))
        #expect(importedStore.capture?.captureID == export.capture.captureID)
        #expect(importedStore.selectedNodeID == export.previewContext.selectedNodeID)
        #expect(importedStore.focusedNodeID == export.previewContext.focusedNodeID)
        #expect(abs(importedStore.previewScale - 1.8) < 0.001)
        #expect(importedStore.previewDisplayMode == .layered)
        #expect(importedStore.previewLayerSpacing == 104)
        #expect(importedStore.previewShowsLayerBorders == false)
        #expect(importedStore.expandedNodeIDs.contains("window-0-view-1"))
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

    private func makeFixtureStore() throws -> WorkspaceStore {
        let defaults = try #require(UserDefaults(suiteName: "ViewScopePreviewFixtureTests.\(UUID().uuidString)"))
        let settings = AppSettings(
            defaults: defaults,
            environment: [
                "VIEWSCOPE_DISABLE_UPDATES": "1",
                "VIEWSCOPE_PREVIEW_FIXTURE": "1"
            ]
        )
        return try WorkspaceStore(settings: settings, updateManager: UpdateManager(settings: settings))
    }

    private func findRowStack(in view: NSView) -> NSStackView? {
        if let stackView = view as? NSStackView,
           stackView.orientation == .vertical,
           abs(stackView.spacing - 8) < 0.5 {
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

    private func makeNonFlippedRootScreenshot(size: CGSize = CGSize(width: 200, height: 120)) -> NSImage {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
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

    private func makeVerticallySplitRootView() -> NSView {
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

        return root
    }

    private func makeTopLeftOrientedSplitScreenshot() -> NSImage {
        let size = CGSize(width: 200, height: 120)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        NSColor.systemRed.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: size.width, height: 60)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 60, width: size.width, height: 60)).fill()
        image.unlockFocus()
        return image
    }

    private func makeTopLeftOrientedMarkerScreenshot(
        size: CGSize,
        markerRect: CGRect,
        markerColor: NSColor
    ) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        markerColor.setFill()
        NSBezierPath(rect: markerRect).fill()
        image.unlockFocus()
        return image
    }

    private func makeFlippedRootScreenshot() -> NSImage {
        let root = makeFlippedRootView()
        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)

        let image = NSImage(size: root.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makeFlippedRootView() -> NSView {
        let root = FlippedTestView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor

        let marker = NSView(frame: NSRect(x: 8, y: 8, width: 40, height: 30))
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.systemRed.cgColor
        root.addSubview(marker)
        return root
    }

    private func makeImageOnlyCapture(
        canvasSize: CGSize,
        rootIsFlipped: Bool = false,
        rootIsHidden: Bool = true
    ) -> ViewScopeCapturePayload {
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
            isHidden: rootIsHidden,
            alphaValue: 1,
            wantsLayer: true,
            isFlipped: rootIsFlipped,
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

    private func decodedPreviewImage(from capture: ViewScopeCapturePayload) -> NSImage? {
        guard let bitmap = capture.previewBitmaps.first,
              let data = Data(base64Encoded: bitmap.pngBase64) else {
            return nil
        }
        return NSImage(data: data)
    }

    @MainActor
    private func makeServerScreenshot(for rootView: NSView) -> NSImage? {
        guard let bitmap = rootView.bitmapImageRepForCachingDisplay(in: rootView.bounds) else {
            return nil
        }
        rootView.cacheDisplay(in: rootView.bounds, to: bitmap)

        let image = NSImage(size: rootView.bounds.size)
        image.addRepresentation(bitmap)
        return pngRoundTripped(image)
    }

    @MainActor
    private func makeSnapshotBuilderScreenshot(for rootView: NSView) -> NSImage? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: rootView.frame.width, height: rootView.frame.height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Preview Orientation Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }

        window.contentView = rootView
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let builder = ViewScopeSnapshotBuilder(
            hostInfo: ViewScopeHostInfo(
                displayName: "Fixture",
                bundleIdentifier: "fixture.tests",
                version: "1.0",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true
            )
        )
        let (_, context) = builder.makeCapture()
        guard let rootNodeID = context.nodeReferences.first(where: { _, reference in
            guard case .view(let capturedView) = reference else { return false }
            return capturedView === rootView
        })?.key,
        let detail = builder.makeDetail(for: rootNodeID, in: context) else {
            return nil
        }

        guard let base64PNG = detail.screenshotPNGBase64,
              let data = Data(base64Encoded: base64PNG) else {
            return nil
        }
        return NSImage(data: data)
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

    private func color(in image: NSImage, atImagePoint point: CGPoint) -> NSColor? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }

        let pixelX = Int(point.x.rounded(.towardZero))
        let pixelY = Int(point.y.rounded(.towardZero))
        let bitmapY = bitmap.pixelsHigh - 1 - pixelY
        guard pixelX >= 0, pixelX < bitmap.pixelsWide,
              bitmapY >= 0, bitmapY < bitmap.pixelsHigh else {
            return nil
        }
        return bitmap.colorAt(x: pixelX, y: bitmapY)
    }

    private func projectedSnapshotPoint(
        in sceneView: PreviewLayeredSceneView,
        node: SCNNode,
        normalizedPoint: CGPoint
    ) -> CGPoint {
        let (minimum, maximum) = node.boundingBox

        let x = CGFloat(minimum.x) + (CGFloat(maximum.x - minimum.x) * normalizedPoint.x)
        let y = CGFloat(maximum.y) - (CGFloat(maximum.y - minimum.y) * normalizedPoint.y)
        let worldPoint = node.convertPosition(SCNVector3(Float(x), Float(y), 0), to: nil)
        let projectedPoint = sceneView.projectPoint(worldPoint)
        return CGPoint(
            x: CGFloat(projectedPoint.x),
            y: sceneView.bounds.height - CGFloat(projectedPoint.y)
        )
    }

    private var screenshotOutputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("READMEAssets", isDirectory: true)
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}

private final class FlippedTestView: NSView {
    override var isFlipped: Bool { true }
}
