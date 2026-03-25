import Foundation
import Testing
@testable import ViewScope
@testable import ViewScopeServer

@Suite(.serialized)
@MainActor
struct ViewTreePresentationBuilderTests {
    @Test func presentationBuilderFiltersSystemWrappersWithoutChangingUnderlyingRoots() throws {
        let capture = makeWrapperCapture()
        let builder = ViewTreePresentationBuilder()

        let hiddenWrapperRoots = builder.buildRoots(
            capture: capture,
            focusedNodeID: nil,
            showsSystemWrappers: false,
            query: ""
        )
        let shownWrapperRoots = builder.buildRoots(
            capture: capture,
            focusedNodeID: nil,
            showsSystemWrappers: true,
            query: ""
        )

        #expect(capture.rootNodeIDs == ["window-0"])
        #expect(hiddenWrapperRoots.first?.node.id == "window-0")
        #expect(hiddenWrapperRoots.first?.children.first?.node.id == "content-view")
        #expect(shownWrapperRoots.first?.children.first?.node.id == "wrapper-view")
    }

    @Test func searchMatchesControllerSuffixIdentifiersAndEventMetadata() throws {
        let capture = makeSearchableCapture()
        let builder = ViewTreePresentationBuilder()
        let queries = ["settingsviewcontroller.view", "settings-root", "applychanges", "settingscoordinator"]

        for query in queries {
            let roots = builder.buildRoots(
                capture: capture,
                focusedNodeID: nil,
                showsSystemWrappers: true,
                query: query
            )
            let nodeIDs = flattenedNodeIDs(from: roots)
            #expect(nodeIDs.contains("settings-view"))
        }
    }

    @Test func selectionSynchronizerSkipsReentrantProgrammaticSelection() {
        let synchronizer = ViewTreeSelectionSynchronizer()
        let item = ViewTreeNodeItem(node: makeNode(id: "selected-node", depth: 0), children: [])

        let ignoredChange = synchronizer.withProgrammaticSelection {
            synchronizer.userSelectionChange(
                selectedRow: 0,
                itemAtRow: { _ in item }
            )
        }
        let userChange = synchronizer.userSelectionChange(
            selectedRow: 0,
            itemAtRow: { _ in item }
        )

        #expect(ignoredChange == .ignored)
        #expect(userChange == .update("selected-node"))
    }

    private func flattenedNodeIDs(from items: [ViewTreeNodeItem]) -> Set<String> {
        var result = Set<String>()

        func visit(_ item: ViewTreeNodeItem) {
            result.insert(item.node.id)
            item.children.forEach(visit)
        }
        items.forEach(visit)

        return result
    }

    private func makeWrapperCapture() -> ViewScopeCapturePayload {
        let window = makeNode(
            id: "window-0",
            parentID: nil,
            kind: .window,
            className: "NSWindow",
            childIDs: ["wrapper-view"],
            depth: 0
        )
        let wrapper = makeNode(
            id: "wrapper-view",
            parentID: "window-0",
            className: "_NSSplitViewItemViewWrapper",
            childIDs: ["content-view"],
            depth: 1
        )
        let content = makeNode(
            id: "content-view",
            parentID: "wrapper-view",
            className: "NSView",
            childIDs: [],
            depth: 2
        )

        return ViewScopeCapturePayload(
            host: SampleFixture.capture().host,
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(
                nodeCount: 3,
                windowCount: 1,
                visibleWindowCount: 1,
                captureDurationMilliseconds: 1
            ),
            rootNodeIDs: ["window-0"],
            nodes: [
                "window-0": window,
                "wrapper-view": wrapper,
                "content-view": content
            ]
        )
    }

    private func makeSearchableCapture() -> ViewScopeCapturePayload {
        let window = makeNode(
            id: "window-0",
            parentID: nil,
            kind: .window,
            className: "NSWindow",
            childIDs: ["settings-view"],
            depth: 0
        )
        let settingsView = makeNode(
            id: "settings-view",
            parentID: "window-0",
            kind: .view,
            className: "NSButton",
            title: "Apply",
            identifier: "settings-root",
            childIDs: [],
            depth: 1,
            rootViewControllerClassName: "Demo.SettingsViewController",
            controlTargetClassName: "Demo.SettingsCoordinator",
            controlActionName: "applyChanges:"
        )

        return ViewScopeCapturePayload(
            host: SampleFixture.capture().host,
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(
                nodeCount: 2,
                windowCount: 1,
                visibleWindowCount: 1,
                captureDurationMilliseconds: 1
            ),
            rootNodeIDs: ["window-0"],
            nodes: [
                "window-0": window,
                "settings-view": settingsView
            ]
        )
    }

    private func makeNode(
        id: String,
        parentID: String? = nil,
        kind: ViewScopeHierarchyNode.Kind = .view,
        className: String = "NSView",
        title: String = "Node",
        identifier: String? = nil,
        childIDs: [String] = [],
        depth: Int,
        rootViewControllerClassName: String? = nil,
        controlTargetClassName: String? = nil,
        controlActionName: String? = nil
    ) -> ViewScopeHierarchyNode {
        ViewScopeHierarchyNode(
            id: id,
            parentID: parentID,
            kind: kind,
            className: className,
            title: title,
            subtitle: nil,
            identifier: identifier,
            address: nil,
            frame: .zero,
            bounds: .zero,
            childIDs: childIDs,
            isHidden: false,
            alphaValue: 1,
            wantsLayer: true,
            isFlipped: true,
            clippingEnabled: false,
            depth: depth,
            rootViewControllerClassName: rootViewControllerClassName,
            controlTargetClassName: controlTargetClassName,
            controlActionName: controlActionName
        )
    }
}
