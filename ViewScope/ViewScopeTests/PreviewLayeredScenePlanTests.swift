import CoreGraphics
import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct PreviewLayeredScenePlanTests {
    @Test func layeredScenePlanKeepsSiblingSubviewsOnSamePlaneUntilExpanded() async throws {
        let capture = SampleFixture.capture()

        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 1200, height: 640),
            expandedNodeIDs: []
        )

        #expect(plan.item(for: "window-0")?.depth == 0)
        #expect(plan.item(for: "window-0-view-0")?.depth == 1)
        #expect(plan.item(for: "window-0-view-1")?.depth == 1)
        #expect(plan.item(for: "window-0-view-1-2")?.displayingIndependently == false)
        #expect(plan.planes.map(\.depth) == [0, 1])
    }

    @Test func layeredScenePlanRecursivelyPushesExpandedDescendantsToLaterPlanes() async throws {
        let capture = makeNestedCapture()

        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 600, height: 400),
            expandedNodeIDs: ["root-a", "root-a-1"]
        )

        #expect(plan.item(for: "root")?.depth == 0)
        #expect(plan.item(for: "root-a")?.depth == 1)
        #expect(plan.item(for: "root-b")?.depth == 1)
        #expect(plan.item(for: "root-a-1")?.depth == 2)
        #expect(plan.item(for: "root-a-2")?.depth == 2)
        #expect(plan.item(for: "root-a-1-a")?.depth == 3)
        #expect(plan.item(for: "root-b-1")?.displayingIndependently == false)
        #expect(plan.planes.map(\.depth) == [0, 1, 2, 3])
    }

    @Test func layeredScenePlanPunchesExpandedChildrenOutOfParentContent() async throws {
        let capture = SampleFixture.capture()

        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 1200, height: 640),
            expandedNodeIDs: ["window-0-view-1"]
        )

        let parent = try #require(plan.item(for: "window-0-view-1"))
        #expect(parent.punchedOutRects.count == 4)
        #expect(parent.punchedOutRects.contains(CGRect(x: 72, y: 28, width: 240, height: 34)))
        #expect(parent.punchedOutRects.contains(CGRect(x: 292, y: 92, width: 760, height: 44)))
    }

    @Test func layeredScenePlanUsesLookinStyleOverlapZOrdering() async throws {
        let nodes: [String: ViewScopeHierarchyNode] = [
            "root": makeNode(id: "root", parentID: nil, childIDs: ["a", "b", "c"], frame: CGRect(x: 0, y: 0, width: 600, height: 400), depth: 0),
            "a": makeNode(id: "a", parentID: "root", childIDs: [], frame: CGRect(x: 20, y: 20, width: 240, height: 180), depth: 1),
            "b": makeNode(id: "b", parentID: "root", childIDs: [], frame: CGRect(x: 180, y: 60, width: 240, height: 180), depth: 1),
            "c": makeNode(id: "c", parentID: "root", childIDs: [], frame: CGRect(x: 440, y: 40, width: 120, height: 120), depth: 1)
        ]

        let capture = ViewScopeCapturePayload(
            host: ViewScopeHostInfo(
                displayName: "Fixture Host",
                bundleIdentifier: "cn.vanjay.fixture",
                version: "1.0",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true
            ),
            capturedAt: Date(timeIntervalSinceReferenceDate: 0),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: nodes,
            captureID: "lookin-z-index-fixture",
            previewBitmaps: []
        )

        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 600, height: 400),
            expandedNodeIDs: []
        )

        let itemA = try #require(plan.item(for: "a"))
        let itemB = try #require(plan.item(for: "b"))
        let itemC = try #require(plan.item(for: "c"))

        #expect(itemA.zIndex == 1)
        #expect(itemB.zIndex == 2)
        #expect(itemC.zIndex == 1)
    }

    @Test func layeredScenePlanPunchesHigherZOverlapOutOfLowerSiblingTexture() async throws {
        let nodes: [String: ViewScopeHierarchyNode] = [
            "root": makeNode(id: "root", parentID: nil, childIDs: ["a", "b"], frame: CGRect(x: 0, y: 0, width: 600, height: 400), depth: 0),
            "a": makeNode(id: "a", parentID: "root", childIDs: [], frame: CGRect(x: 20, y: 20, width: 240, height: 180), depth: 1),
            "b": makeNode(id: "b", parentID: "root", childIDs: [], frame: CGRect(x: 180, y: 60, width: 240, height: 180), depth: 1)
        ]

        let capture = ViewScopeCapturePayload(
            host: ViewScopeHostInfo(
                displayName: "Fixture Host",
                bundleIdentifier: "cn.vanjay.fixture",
                version: "1.0",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true
            ),
            capturedAt: Date(timeIntervalSinceReferenceDate: 0),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: nodes,
            captureID: "lookin-overlap-hole-fixture",
            previewBitmaps: []
        )

        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 600, height: 400),
            expandedNodeIDs: []
        )

        let lowerItem = try #require(plan.item(for: "a"))
        let upperItem = try #require(plan.item(for: "b"))

        #expect(lowerItem.zIndex < upperItem.zIndex)
        #expect(lowerItem.punchedOutRects.contains(upperItem.displayRect))
        #expect(upperItem.punchedOutRects.isEmpty)
    }

    @Test func layeredScenePlanCollapsedDescendantsStillContributeInheritedZIndex() async throws {
        let nodes: [String: ViewScopeHierarchyNode] = [
            "root": makeNode(id: "root", parentID: nil, childIDs: ["a", "b"], frame: CGRect(x: 0, y: 0, width: 600, height: 400), depth: 0),
            "a": makeNode(id: "a", parentID: "root", childIDs: ["a-1"], frame: CGRect(x: 20, y: 20, width: 140, height: 120), depth: 1),
            "a-1": makeNode(id: "a-1", parentID: "a", childIDs: [], frame: CGRect(x: 300, y: 60, width: 180, height: 140), depth: 2),
            "b": makeNode(id: "b", parentID: "root", childIDs: [], frame: CGRect(x: 320, y: 80, width: 160, height: 140), depth: 1)
        ]

        let capture = ViewScopeCapturePayload(
            host: ViewScopeHostInfo(
                displayName: "Fixture Host",
                bundleIdentifier: "cn.vanjay.fixture",
                version: "1.0",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true
            ),
            capturedAt: Date(timeIntervalSinceReferenceDate: 0),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: nodes,
            captureID: "lookin-collapsed-z-index-fixture",
            previewBitmaps: []
        )

        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 600, height: 400),
            expandedNodeIDs: []
        )

        let collapsedDescendant = try #require(plan.item(for: "a-1"))
        let sibling = try #require(plan.item(for: "b"))

        #expect(collapsedDescendant.zIndex == 1)
        #expect(sibling.zIndex == 2)
    }

    @Test func layeredScenePlanConvertsFlippedPreviewRootRectsIntoUnifiedCanvasSpace() async throws {
        let nodes: [String: ViewScopeHierarchyNode] = [
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

        let capture = ViewScopeCapturePayload(
            host: ViewScopeHostInfo(
                displayName: "Fixture Host",
                bundleIdentifier: "cn.vanjay.fixture",
                version: "1.0",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true
            ),
            capturedAt: Date(timeIntervalSinceReferenceDate: 0),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: nodes,
            captureID: "mixed-flipped-display-space-fixture",
            previewBitmaps: []
        )

        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 320, height: 120),
            expandedNodeIDs: []
        )

        let button = try #require(plan.item(for: "button"))
        #expect(button.displayRect == CGRect(x: 207.5, y: 96, width: 76, height: 24))
    }

    @Test func layeredScenePlanPunchesExpandedMixedFlippedStackChildrenOutOfParentAndAncestor() async throws {
        let titleRect = CGRect(x: 535, y: 293, width: 338, height: 33)
        let subtitleRect = CGRect(x: 456.5, y: 340, width: 495.5, height: 17)
        let buttonRect = CGRect(x: 666, y: 371, width: 76, height: 24)
        let stackRect = CGRect(x: 458.5, y: 293, width: 491.5, height: 102)
        let workspaceRect = CGRect(x: 228, y: 0, width: 952, height: 688)
        let capture = makeMixedFlippedExpandedStackCapture(
            workspaceRect: workspaceRect,
            stackRect: stackRect,
            titleRect: titleRect,
            subtitleRect: subtitleRect,
            buttonRect: buttonRect
        )

        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 1180, height: 688),
            expandedNodeIDs: ["split", "workspace", "stack", "root"]
        )

        let workspace = try #require(plan.item(for: "workspace"))
        let stack = try #require(plan.item(for: "stack"))

        #expect(workspace.punchedOutRects.contains(stackRect))
        #expect(stack.punchedOutRects.contains(titleRect))
        #expect(stack.punchedOutRects.contains(subtitleRect))
        #expect(stack.punchedOutRects.contains(buttonRect))
    }

    @Test func layeredScenePlanPromotesPresentedChildrenAcrossHiddenSystemWrapperChains() async throws {
        let wrapperRect = CGRect(x: 228, y: 0, width: 952, height: 688)
        let workspaceRect = CGRect(x: 228, y: 0, width: 952, height: 688)
        let stackRect = CGRect(x: 458.5, y: 293, width: 491.5, height: 102)
        let capture = makeWrapperPromotedCapture(
            wrapperRect: wrapperRect,
            workspaceRect: workspaceRect,
            stackRect: stackRect
        )

        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 1180, height: 688),
            expandedNodeIDs: ["split", "workspace", "stack", "root"]
        )

        let split = try #require(plan.item(for: "split"))
        let workspace = try #require(plan.item(for: "workspace"))
        let stack = try #require(plan.item(for: "stack"))

        #expect(plan.item(for: "wrapper") == nil)
        #expect(workspace.displayingIndependently)
        #expect(split.punchedOutRects.contains(workspaceRect))
        #expect(workspace.punchedOutRects.contains(stackRect))
        #expect(stack.displayingIndependently)
    }

    private func makeNestedCapture() -> ViewScopeCapturePayload {
        let nodes: [String: ViewScopeHierarchyNode] = [
            "root": makeNode(id: "root", parentID: nil, childIDs: ["root-a", "root-b"], frame: CGRect(x: 0, y: 0, width: 600, height: 400), depth: 0),
            "root-a": makeNode(id: "root-a", parentID: "root", childIDs: ["root-a-1", "root-a-2"], frame: CGRect(x: 20, y: 20, width: 240, height: 320), depth: 1),
            "root-a-1": makeNode(id: "root-a-1", parentID: "root-a", childIDs: ["root-a-1-a"], frame: CGRect(x: 40, y: 48, width: 160, height: 120), depth: 2),
            "root-a-1-a": makeNode(id: "root-a-1-a", parentID: "root-a-1", childIDs: [], frame: CGRect(x: 56, y: 64, width: 72, height: 44), depth: 3),
            "root-a-2": makeNode(id: "root-a-2", parentID: "root-a", childIDs: [], frame: CGRect(x: 44, y: 204, width: 180, height: 92), depth: 2),
            "root-b": makeNode(id: "root-b", parentID: "root", childIDs: ["root-b-1"], frame: CGRect(x: 300, y: 28, width: 240, height: 280), depth: 1),
            "root-b-1": makeNode(id: "root-b-1", parentID: "root-b", childIDs: [], frame: CGRect(x: 320, y: 56, width: 120, height: 80), depth: 2)
        ]

        return ViewScopeCapturePayload(
            host: ViewScopeHostInfo(
                displayName: "Fixture Host",
                bundleIdentifier: "cn.vanjay.fixture",
                version: "1.0",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true
            ),
            capturedAt: Date(timeIntervalSinceReferenceDate: 0),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: nodes,
            captureID: "layered-scene-plan-fixture",
            previewBitmaps: []
        )
    }

    private func makeNode(
        id: String,
        parentID: String?,
        childIDs: [String],
        frame: CGRect,
        depth: Int,
        isFlipped: Bool = true
    ) -> ViewScopeHierarchyNode {
        ViewScopeHierarchyNode(
            id: id,
            parentID: parentID,
            kind: depth == 0 ? .window : .view,
            className: depth == 0 ? "NSWindow" : "NSView",
            title: id,
            subtitle: nil,
            frame: ViewScopeRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            bounds: ViewScopeRect(x: 0, y: 0, width: frame.width, height: frame.height),
            childIDs: childIDs,
            isHidden: false,
            alphaValue: 1,
            wantsLayer: true,
            isFlipped: isFlipped,
            clippingEnabled: false,
            depth: depth
        )
    }

    private func makeMixedFlippedExpandedStackCapture(
        workspaceRect: CGRect,
        stackRect: CGRect,
        titleRect: CGRect,
        subtitleRect: CGRect,
        buttonRect: CGRect
    ) -> ViewScopeCapturePayload {
        let nodes: [String: ViewScopeHierarchyNode] = [
            "root": makeNode(
                id: "root",
                parentID: nil,
                childIDs: ["split"],
                frame: CGRect(x: 0, y: 0, width: 1180, height: 688),
                depth: 0,
                isFlipped: false
            ),
            "split": makeNode(
                id: "split",
                parentID: "root",
                childIDs: ["sidebar", "workspace"],
                frame: CGRect(x: 0, y: 0, width: 1180, height: 688),
                depth: 1,
                isFlipped: true
            ),
            "sidebar": makeNode(
                id: "sidebar",
                parentID: "split",
                childIDs: [],
                frame: CGRect(x: 0, y: 0, width: 228, height: 688),
                depth: 2,
                isFlipped: true
            ),
            "workspace": makeNode(
                id: "workspace",
                parentID: "split",
                childIDs: ["stack"],
                frame: workspaceRect,
                depth: 2,
                isFlipped: false
            ),
            "stack": makeNode(
                id: "stack",
                parentID: "workspace",
                childIDs: ["title", "subtitle", "button"],
                frame: stackRect,
                depth: 3,
                isFlipped: false
            ),
            "title": makeNode(
                id: "title",
                parentID: "stack",
                childIDs: [],
                frame: titleRect,
                depth: 4,
                isFlipped: true
            ),
            "subtitle": makeNode(
                id: "subtitle",
                parentID: "stack",
                childIDs: [],
                frame: subtitleRect,
                depth: 4,
                isFlipped: true
            ),
            "button": makeNode(
                id: "button",
                parentID: "stack",
                childIDs: [],
                frame: buttonRect,
                depth: 4,
                isFlipped: true
            )
        ]

        return ViewScopeCapturePayload(
            host: ViewScopeHostInfo(
                displayName: "Fixture Host",
                bundleIdentifier: "cn.vanjay.fixture",
                version: "1.0",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true
            ),
            capturedAt: Date(timeIntervalSinceReferenceDate: 0),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: nodes,
            captureID: "mixed-flipped-expanded-stack-fixture",
            previewBitmaps: []
        )
    }

    private func makeWrapperPromotedCapture(
        wrapperRect: CGRect,
        workspaceRect: CGRect,
        stackRect: CGRect
    ) -> ViewScopeCapturePayload {
        let nodes: [String: ViewScopeHierarchyNode] = [
            "root": makeNode(
                id: "root",
                parentID: nil,
                childIDs: ["split"],
                frame: CGRect(x: 0, y: 0, width: 1180, height: 688),
                depth: 0,
                isFlipped: false
            ),
            "split": ViewScopeHierarchyNode(
                id: "split",
                parentID: "root",
                kind: .view,
                className: "NSSplitView",
                title: "split",
                subtitle: nil,
                frame: ViewScopeRect(x: 0, y: 0, width: 1180, height: 688),
                bounds: ViewScopeRect(x: 0, y: 0, width: 1180, height: 688),
                childIDs: ["sidebar", "wrapper"],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: false,
                depth: 1
            ),
            "sidebar": makeNode(
                id: "sidebar",
                parentID: "split",
                childIDs: [],
                frame: CGRect(x: 0, y: 0, width: 228, height: 688),
                depth: 2,
                isFlipped: true
            ),
            "wrapper": ViewScopeHierarchyNode(
                id: "wrapper",
                parentID: "split",
                kind: .view,
                className: "_NSSplitViewItemViewWrapper",
                title: "wrapper",
                subtitle: nil,
                frame: ViewScopeRect(x: wrapperRect.minX, y: wrapperRect.minY, width: wrapperRect.width, height: wrapperRect.height),
                bounds: ViewScopeRect(x: 0, y: 0, width: wrapperRect.width, height: wrapperRect.height),
                childIDs: ["workspace"],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: false,
                depth: 2
            ),
            "workspace": ViewScopeHierarchyNode(
                id: "workspace",
                parentID: "wrapper",
                kind: .view,
                className: "WorkspaceDropView",
                title: "workspace",
                subtitle: nil,
                frame: ViewScopeRect(x: workspaceRect.minX, y: workspaceRect.minY, width: workspaceRect.width, height: workspaceRect.height),
                bounds: ViewScopeRect(x: 0, y: 0, width: workspaceRect.width, height: workspaceRect.height),
                childIDs: ["stack"],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: true,
                isFlipped: false,
                clippingEnabled: false,
                depth: 3
            ),
            "stack": ViewScopeHierarchyNode(
                id: "stack",
                parentID: "workspace",
                kind: .view,
                className: "NSStackView",
                title: "stack",
                subtitle: nil,
                frame: ViewScopeRect(x: stackRect.minX, y: stackRect.minY, width: stackRect.width, height: stackRect.height),
                bounds: ViewScopeRect(x: 0, y: 0, width: stackRect.width, height: stackRect.height),
                childIDs: [],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: true,
                isFlipped: false,
                clippingEnabled: false,
                depth: 4
            )
        ]

        return ViewScopeCapturePayload(
            host: ViewScopeHostInfo(
                displayName: "Fixture Host",
                bundleIdentifier: "cn.vanjay.fixture",
                version: "1.0",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true
            ),
            capturedAt: Date(timeIntervalSinceReferenceDate: 0),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["root"],
            nodes: nodes,
            captureID: "wrapper-promoted-fixture",
            previewBitmaps: []
        )
    }
}
