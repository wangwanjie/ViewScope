import CoreGraphics
import Foundation
import ViewScopeServer
@testable import ViewScope

/// 诊断、测量、预览相关测试共用的节点构造工具。
enum DiagnosticsTestFixtures {
    static func node(
        _ id: String,
        parent: String?,
        children: [String] = [],
        frame: CGRect,
        kind: ViewScopeHierarchyNode.Kind = .view,
        className: String = "UIView",
        isHidden: Bool = false,
        alpha: Double = 1,
        clips: Bool = false,
        depth: Int = 0,
        traits: ViewScopeNodeTraits? = nil
    ) -> ViewScopeHierarchyNode {
        ViewScopeHierarchyNode(
            id: id,
            parentID: parent,
            kind: kind,
            className: className,
            title: id,
            subtitle: nil,
            frame: ViewScopeRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            bounds: ViewScopeRect(x: 0, y: 0, width: frame.width, height: frame.height),
            childIDs: children,
            isHidden: isHidden,
            alphaValue: alpha,
            wantsLayer: true,
            isFlipped: true,
            clippingEnabled: clips,
            depth: depth,
            traits: traits
        )
    }

    static func capture(
        nodes: [ViewScopeHierarchyNode],
        rootNodeIDs: [String],
        platform: ViewScopePlatform? = .iOS,
        screenScale: Double? = 3,
        captureID: String = UUID().uuidString
    ) -> ViewScopeCapturePayload {
        var nodeMap: [String: ViewScopeHierarchyNode] = [:]
        for node in nodes {
            nodeMap[node.id] = node
        }
        return ViewScopeCapturePayload(
            host: ViewScopeHostInfo(
                displayName: "Fixture",
                bundleIdentifier: "cn.vanjay.fixture",
                version: "1.0",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true,
                platform: platform,
                screenScale: screenScale
            ),
            capturedAt: Date(timeIntervalSinceReferenceDate: 0),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: rootNodeIDs,
            nodes: nodeMap,
            captureID: captureID
        )
    }
}
