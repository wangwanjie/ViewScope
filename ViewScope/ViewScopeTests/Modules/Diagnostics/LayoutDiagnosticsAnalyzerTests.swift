import CoreGraphics
import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct LayoutDiagnosticsAnalyzerTests {
    private typealias F = DiagnosticsTestFixtures

    /// 屏幕根视图 + 若干子节点；根视图父节点是窗口。
    private func analyze(
        _ children: [ViewScopeHierarchyNode],
        rootChildren: [String]? = nil,
        rootClips: Bool = true,
        platform: ViewScopePlatform = .iOS,
        screenScale: Double = 3
    ) -> [String: [LayoutDiagnosticIssue]] {
        let window = F.node("window", parent: nil, children: ["root"], frame: CGRect(x: 0, y: 0, width: 390, height: 844), kind: .window, className: "UIWindow")
        let root = F.node("root", parent: "window", children: rootChildren ?? children.filter { $0.parentID == "root" }.map(\.id), frame: CGRect(x: 0, y: 0, width: 390, height: 844), clips: rootClips, depth: 1)
        let capture = F.capture(nodes: [window, root] + children, rootNodeIDs: ["window"], platform: platform, screenScale: screenScale)
        return LayoutDiagnosticsAnalyzer.analyze(capture: capture, platform: platform)
    }

    private func kinds(_ issues: [String: [LayoutDiagnosticIssue]], _ nodeID: String) -> Set<LayoutDiagnosticIssue.Kind> {
        Set((issues[nodeID] ?? []).map(\.kind))
    }

    @Test func cleanHierarchyHasNoIssues() {
        let issues = analyze([
            F.node("a", parent: "root", frame: CGRect(x: 10, y: 10, width: 100, height: 50), traits: ViewScopeNodeTraits(isUserInteractionEnabled: true))
        ])
        #expect(issues.isEmpty)
    }

    @Test func ambiguousLayoutIsReportedAsError() {
        let issues = analyze([
            F.node("a", parent: "root", frame: CGRect(x: 10, y: 10, width: 100, height: 50), traits: ViewScopeNodeTraits(hasAmbiguousLayout: true))
        ])
        #expect(kinds(issues, "a") == [.ambiguousLayout])
        #expect(issues["a"]?.first?.severity == .error)
    }

    @Test func partiallyClippedNodeIsReported() {
        let issues = analyze([
            F.node("a", parent: "root", frame: CGRect(x: 340, y: 10, width: 100, height: 50))
        ])
        #expect(kinds(issues, "a") == [.clippedByAncestor])
        #expect(issues["a"]?.first?.message.contains("50") == true)
    }

    @Test func nodeCompletelyOutsideClippingAncestorIsInvisible() {
        let issues = analyze([
            F.node("a", parent: "root", frame: CGRect(x: 500, y: 10, width: 100, height: 50))
        ])
        #expect(kinds(issues, "a") == [.outsideParentBounds])
        #expect(issues["a"]?.first?.severity == .warning)
    }

    @Test func scrollViewClippingIsIgnored() {
        let issues = analyze([
            F.node("scroll", parent: "root", children: ["content"], frame: CGRect(x: 0, y: 0, width: 390, height: 400), className: "UIScrollView", clips: true),
            F.node("content", parent: "scroll", frame: CGRect(x: 0, y: 0, width: 390, height: 1200))
        ], rootClips: false)
        #expect(kinds(issues, "content").isEmpty)
    }

    @Test func childOutsideNonClippingParentIsInfoUnlessInteractiveOnTouchPlatforms() {
        let parent = F.node("parent", parent: "root", children: ["label", "button"], frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let label = F.node("label", parent: "parent", frame: CGRect(x: 150, y: 0, width: 40, height: 20))
        let button = F.node("button", parent: "parent", frame: CGRect(x: 150, y: 50, width: 60, height: 60), traits: ViewScopeNodeTraits(isInteractiveControl: true))
        let issues = analyze([parent, label, button], rootClips: false)
        #expect(issues["label"]?.first?.kind == .outsideParentBounds)
        #expect(issues["label"]?.first?.severity == .info)
        #expect(issues["button"]?.first(where: { $0.kind == .outsideParentBounds })?.severity == .warning)
    }

    @Test func zeroSizeContainerWithVisibleChildren() {
        let issues = analyze([
            F.node("container", parent: "root", children: ["child"], frame: CGRect(x: 10, y: 10, width: 0, height: 40)),
            F.node("child", parent: "container", frame: CGRect(x: 10, y: 10, width: 30, height: 30))
        ], rootClips: false)
        #expect(kinds(issues, "container").contains(.zeroSizeWithVisibleChildren))
    }

    @Test func misalignedFramesDependOnDisplayScale() {
        let issuesAt3x = analyze([
            F.node("aligned", parent: "root", frame: CGRect(x: 10 + 1.0 / 3.0, y: 10, width: 100, height: 50)),
            F.node("misaligned", parent: "root", frame: CGRect(x: 10.25, y: 10, width: 100, height: 50))
        ])
        #expect(kinds(issuesAt3x, "aligned").isEmpty)
        #expect(kinds(issuesAt3x, "misaligned") == [.misalignedToPixels])

        let issuesAt2x = analyze([
            F.node("half", parent: "root", frame: CGRect(x: 10.5, y: 10, width: 100, height: 50))
        ], platform: .macOS, screenScale: 2)
        #expect(kinds(issuesAt2x, "half").isEmpty)
    }

    @Test func transformedNodesSkipPixelAlignment() {
        let issues = analyze([
            F.node(
                "rotated",
                parent: "root",
                frame: CGRect(x: 10.37, y: 10.11, width: 120.3, height: 80.7),
                traits: ViewScopeNodeTraits(frameInSuperview: ViewScopeRect(x: 10, y: 10, width: 100, height: 60))
            )
        ])
        #expect(kinds(issues, "rotated").isEmpty)
    }

    @Test func invisibleButInteractiveNode() {
        let issues = analyze([
            F.node("ghost", parent: "root", frame: CGRect(x: 0, y: 0, width: 200, height: 200), alpha: 0, traits: ViewScopeNodeTraits(isUserInteractionEnabled: true)),
            F.node("disabledGhost", parent: "root", frame: CGRect(x: 0, y: 300, width: 200, height: 200), alpha: 0, traits: ViewScopeNodeTraits(isUserInteractionEnabled: false))
        ])
        #expect(kinds(issues, "ghost").contains(.invisibleButInteractive))
        #expect(kinds(issues, "disabledGhost").contains(.invisibleButInteractive) == false)
    }

    @Test func laterOpaqueSiblingFullyOccludesEarlierNode() {
        let issues = analyze([
            F.node("hidden-behind", parent: "root", children: ["inner"], frame: CGRect(x: 20, y: 20, width: 100, height: 100)),
            F.node("inner", parent: "hidden-behind", frame: CGRect(x: 30, y: 30, width: 20, height: 20)),
            F.node("cover", parent: "root", frame: CGRect(x: 0, y: 0, width: 200, height: 200), traits: ViewScopeNodeTraits(backgroundAlpha: 1)),
            F.node("transparentCover", parent: "root", frame: CGRect(x: 0, y: 300, width: 200, height: 200), traits: ViewScopeNodeTraits(backgroundAlpha: 0.5)),
            F.node("partially", parent: "root", frame: CGRect(x: 150, y: 150, width: 100, height: 100))
        ])
        #expect(kinds(issues, "hidden-behind") == [.occludedBySibling])
        // 后代不重复报告；部分遮挡、半透明遮挡都不算。
        #expect(kinds(issues, "inner").isEmpty)
        #expect(kinds(issues, "partially").isEmpty)
        #expect(issues["hidden-behind"]?.first?.message.contains("UIView") == true)
    }

    @Test func parentIsNeverOccludedByItsOwnChild() {
        let issues = analyze([
            F.node("parent", parent: "root", children: ["child"], frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            F.node("child", parent: "parent", frame: CGRect(x: 0, y: 0, width: 100, height: 100), traits: ViewScopeNodeTraits(isOpaque: true))
        ])
        #expect(kinds(issues, "parent").isEmpty)
    }

    @Test func truncatedTextAndUpscaledImages() {
        let issues = analyze([
            F.node("label", parent: "root", frame: CGRect(x: 0, y: 0, width: 100, height: 20), traits: ViewScopeNodeTraits(isTextTruncated: true)),
            F.node(
                "blurry",
                parent: "root",
                frame: CGRect(x: 0, y: 100, width: 100, height: 100),
                traits: ViewScopeNodeTraits(displayScale: 3, imageSize: ViewScopeSize(width: 100, height: 100), imageScale: 1)
            ),
            F.node(
                "sharp",
                parent: "root",
                frame: CGRect(x: 0, y: 300, width: 100, height: 100),
                traits: ViewScopeNodeTraits(displayScale: 3, imageSize: ViewScopeSize(width: 100, height: 100), imageScale: 3)
            )
        ])
        #expect(kinds(issues, "label") == [.textTruncated])
        #expect(kinds(issues, "blurry") == [.imageUpscaled])
        #expect(kinds(issues, "sharp").isEmpty)
    }

    @Test func smallTapTargetsOnlyOnTouchPlatforms() {
        let button = F.node("button", parent: "root", frame: CGRect(x: 0, y: 0, width: 30, height: 30), traits: ViewScopeNodeTraits(isInteractiveControl: true))
        #expect(kinds(analyze([button]), "button") == [.smallTapTarget])
        #expect(kinds(analyze([button], platform: .macOS, screenScale: 2), "button").isEmpty)
    }

    @Test func excessiveDepthIsReportedOnceAtThreshold() {
        var nodes: [ViewScopeHierarchyNode] = []
        var parentID = "root"
        for index in 0..<45 {
            let id = "deep-\(index)"
            let childID = index < 44 ? "deep-\(index + 1)" : nil
            nodes.append(F.node(id, parent: parentID, children: childID.map { [$0] } ?? [], frame: CGRect(x: 0, y: 0, width: 300, height: 300)))
            parentID = id
        }
        let issues = analyze(nodes, rootChildren: ["deep-0"])
        let flagged = issues.filter { $0.value.contains { $0.kind == .excessiveDepth } }.map(\.key)
        #expect(flagged.count == 1)
        #expect(issues[flagged.first ?? ""]?.first(where: { $0.kind == .excessiveDepth })?.severity == .info)
    }

    @Test func hiddenSubtreesAndMissingTraitsAreSkipped() {
        let issues = analyze([
            F.node("hiddenParent", parent: "root", children: ["child"], frame: CGRect(x: 500, y: 0, width: 10, height: 10), isHidden: true),
            F.node("child", parent: "hiddenParent", frame: CGRect(x: 500, y: 0, width: 10, height: 10), traits: ViewScopeNodeTraits(hasAmbiguousLayout: true)),
            // 旧宿主：没有 traits，不能误报任何依赖 traits 的规则。
            F.node("legacy", parent: "root", frame: CGRect(x: 0, y: 0, width: 20, height: 20), alpha: 0)
        ])
        #expect(issues["hiddenParent"] == nil)
        #expect(issues["child"] == nil)
        #expect(issues["legacy"] == nil)
    }

    @Test func reportAggregatesCountsAndTooltips() {
        let issues = analyze([
            F.node("a", parent: "root", frame: CGRect(x: 10, y: 10, width: 100, height: 50), traits: ViewScopeNodeTraits(hasAmbiguousLayout: true, isTextTruncated: true))
        ])
        let report = LayoutDiagnosticsReport(issuesByNodeID: issues)
        #expect(report.countsBySeverity[.error] == 1)
        #expect(report.countsBySeverity[.warning] == 1)
        #expect(report.maximumSeverity(for: "a") == .error)
        #expect(report.allIssues.first?.kind == .ambiguousLayout)
        #expect(report.tooltip(for: "a")?.split(separator: "\n").count == 2)
    }

    @Test func analyzerHandlesLargeHierarchiesQuickly() {
        var nodes: [ViewScopeHierarchyNode] = []
        var rootChildren: [String] = []
        for row in 0..<60 {
            let rowID = "row-\(row)"
            rootChildren.append(rowID)
            var cellIDs: [String] = []
            for column in 0..<40 {
                let cellID = "cell-\(row)-\(column)"
                cellIDs.append(cellID)
                nodes.append(F.node(cellID, parent: rowID, frame: CGRect(x: CGFloat(column) * 9, y: CGFloat(row) * 14, width: 8, height: 12), traits: ViewScopeNodeTraits(backgroundAlpha: 1)))
            }
            nodes.append(F.node(rowID, parent: "root", children: cellIDs, frame: CGRect(x: 0, y: CGFloat(row) * 14, width: 390, height: 12)))
        }
        let start = Date()
        _ = analyze(nodes, rootChildren: rootChildren)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
