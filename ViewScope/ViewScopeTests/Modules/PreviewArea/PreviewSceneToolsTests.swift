import AppKit
import CoreGraphics
import Foundation
import SceneKit
import Testing
import ViewScopeServer
@testable import ViewScope

/// 预览增量更新、命中测试、裁剪、相机交互、取色等回归测试。
@Suite(.serialized)
@MainActor
struct PreviewSceneToolsTests {
    private typealias F = DiagnosticsTestFixtures

    // MARK: - 计划

    @Test func planLookupUsesDictionaryAndExposesPlaneOwners() throws {
        let capture = SampleFixture.capture()
        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 1200, height: 640),
            expandedNodeIDs: ["window-0-view-1"]
        )
        let collapsed = try #require(plan.item(for: "window-0-view-0-0"))
        let expandedChild = try #require(plan.item(for: "window-0-view-1-0"))
        #expect(collapsed.displayingIndependently == false)
        #expect(collapsed.planeOwnerNodeID == "window-0-view-0")
        #expect(expandedChild.displayingIndependently)
        #expect(expandedChild.planeOwnerNodeID == "window-0-view-1-0")
        #expect(plan.item(for: "missing") == nil)
    }

    @Test func planClipsChildrenToClippingAncestors() throws {
        let capture = F.capture(
            nodes: [
                F.node("root", parent: nil, children: ["clipper"], frame: CGRect(x: 0, y: 0, width: 300, height: 300), clips: true),
                F.node("clipper", parent: "root", children: ["child"], frame: CGRect(x: 0, y: 0, width: 100, height: 100), clips: true),
                F.node("child", parent: "clipper", frame: CGRect(x: 50, y: 50, width: 100, height: 100))
            ],
            rootNodeIDs: ["root"]
        )
        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 300, height: 300),
            expandedNodeIDs: ["clipper"]
        )
        let child = try #require(plan.item(for: "child"))
        #expect(child.displayRect == CGRect(x: 50, y: 50, width: 100, height: 100))
        #expect(child.visibleRect == CGRect(x: 50, y: 50, width: 50, height: 50))
        // 父纹理只挖掉子节点实际可见的部分。
        let clipper = try #require(plan.item(for: "clipper"))
        #expect(clipper.punchedOutRects.contains(CGRect(x: 50, y: 50, width: 50, height: 50)))
    }

    @Test func focusIsolatesSubtreeButKeepsAncestorClipping() throws {
        let capture = F.capture(
            nodes: [
                F.node("root", parent: nil, children: ["clipper", "other"], frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
                F.node("clipper", parent: "root", children: ["focus"], frame: CGRect(x: 0, y: 0, width: 100, height: 100), clips: true),
                F.node("focus", parent: "clipper", children: ["leaf"], frame: CGRect(x: 50, y: 50, width: 100, height: 100)),
                F.node("leaf", parent: "focus", frame: CGRect(x: 60, y: 60, width: 10, height: 10)),
                F.node("other", parent: "root", frame: CGRect(x: 200, y: 200, width: 50, height: 50))
            ],
            rootNodeIDs: ["root"]
        )
        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 300, height: 300),
            expandedNodeIDs: [],
            previewRootNodeID: "root",
            isolatedRootNodeID: "focus"
        )
        #expect(Set(plan.items.map(\.nodeID)) == ["focus", "leaf"])
        let focus = try #require(plan.item(for: "focus"))
        #expect(focus.displayingIndependently)
        #expect(focus.visibleRect == CGRect(x: 50, y: 50, width: 50, height: 50))
        // 聚焦根自动展开，子节点独立成层（与层级树里聚焦根默认展开一致）。
        #expect(plan.item(for: "leaf")?.displayingIndependently == true)
    }

    @Test func planIsIndependentOfLayerSpacingAndBorders() {
        // 计划的输入不包含层间距与边框，相同结构输入得到相同计划。
        let capture = SampleFixture.capture()
        let first = PreviewLayeredScenePlan.make(capture: capture, canvasSize: CGSize(width: 1200, height: 640), expandedNodeIDs: ["window-0-view-1"])
        let second = PreviewLayeredScenePlan.make(capture: capture, canvasSize: CGSize(width: 1200, height: 640), expandedNodeIDs: ["window-0-view-1"])
        #expect(first == second)
    }

    @Test func planBuildsLargeHierarchiesQuickly() {
        var nodes: [ViewScopeHierarchyNode] = []
        var rootChildren: [String] = []
        for row in 0..<50 {
            let rowID = "row-\(row)"
            rootChildren.append(rowID)
            var cellIDs: [String] = []
            for column in 0..<40 {
                let cellID = "cell-\(row)-\(column)"
                cellIDs.append(cellID)
                nodes.append(F.node(cellID, parent: rowID, frame: CGRect(x: CGFloat(column) * 25, y: CGFloat(row) * 20, width: 24, height: 18)))
            }
            nodes.append(F.node(rowID, parent: "root", children: cellIDs, frame: CGRect(x: 0, y: CGFloat(row) * 20, width: 1000, height: 18)))
        }
        nodes.append(F.node("root", parent: nil, children: rootChildren, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000)))
        let capture = F.capture(nodes: nodes, rootNodeIDs: ["root"])
        let start = Date()
        let plan = PreviewLayeredScenePlan.make(
            capture: capture,
            canvasSize: CGSize(width: 1000, height: 1000),
            expandedNodeIDs: Set(rootChildren)
        )
        #expect(plan.items.count == nodes.count)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    // MARK: - 命中测试

    @Test func hitResolverPicksFrontMostCollapsedNodeInsidePlane() {
        let capture = SampleFixture.capture()
        let plan = PreviewLayeredScenePlan.make(capture: capture, canvasSize: CGSize(width: 1200, height: 640), expandedNodeIDs: [])
        let resolver = PreviewHitTestResolver(plan: plan, capture: capture)
        // window-0-view-0-0 是折叠节点，没有独立平面，但仍应能被点中。
        let nodeID = resolver.nodeID(for: [
            PreviewHitTestResolver.PlaneHit(planeNodeID: "window-0-view-0", canvasPoint: CGPoint(x: 40, y: 40))
        ])
        #expect(nodeID == "window-0-view-0-0")
    }

    @Test func hitResolverDeprioritizesTransparentContainers() {
        let transparentTraits = ViewScopeNodeTraits(isOpaque: false, backgroundAlpha: nil)
        let capture = F.capture(
            nodes: [
                F.node("root", parent: nil, children: ["content", "overlay"], frame: CGRect(x: 0, y: 0, width: 200, height: 200), traits: ViewScopeNodeTraits(backgroundAlpha: 1)),
                F.node("content", parent: "root", frame: CGRect(x: 20, y: 20, width: 100, height: 100)),
                F.node("overlay", parent: "root", children: ["badge"], frame: CGRect(x: 0, y: 0, width: 200, height: 200), traits: transparentTraits),
                F.node("badge", parent: "overlay", frame: CGRect(x: 150, y: 150, width: 20, height: 20))
            ],
            rootNodeIDs: ["root"]
        )
        let plan = PreviewLayeredScenePlan.make(capture: capture, canvasSize: CGSize(width: 200, height: 200), expandedNodeIDs: [])
        let resolver = PreviewHitTestResolver(plan: plan, capture: capture)
        #expect(resolver.nodeID(atCanvasPoint: CGPoint(x: 50, y: 50)) == "content")
        #expect(resolver.nodeID(atCanvasPoint: CGPoint(x: 155, y: 155)) == "badge")
        // 透明容器的空白处：命中其后方真正可见的根视图。
        #expect(resolver.nodeID(atCanvasPoint: CGPoint(x: 190, y: 10)) == "root")
        // 后方没有其它可见节点时，才退回透明容器本身。
        #expect(resolver.nodeID(for: [PreviewHitTestResolver.PlaneHit(planeNodeID: "overlay", canvasPoint: CGPoint(x: 190, y: 10))]) == "overlay")
    }

    @Test func geometryHitTestingRespectsClipping() {
        let capture = F.capture(
            nodes: [
                F.node("root", parent: nil, children: ["clipper"], frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
                F.node("clipper", parent: "root", children: ["child"], frame: CGRect(x: 0, y: 0, width: 100, height: 100), clips: true),
                F.node("child", parent: "clipper", frame: CGRect(x: 50, y: 50, width: 100, height: 100))
            ],
            rootNodeIDs: ["root"]
        )
        let geometry = ViewHierarchyGeometry()
        #expect(geometry.deepestNodeID(at: CGPoint(x: 75, y: 75), in: capture) == "child")
        #expect(geometry.deepestNodeID(at: CGPoint(x: 120, y: 120), in: capture) == "root")
    }

    // MARK: - 场景增量更新

    private func makeSceneView(expanded: Set<String> = ["window-0-view-1"]) throws -> PreviewLayeredSceneView {
        let capture = SampleFixture.capture()
        let bitmap = try #require(capture.previewBitmaps.first)
        let data = try #require(Data(base64Encoded: bitmap.pngBase64))
        let image = try #require(NSImage(data: data))
        let sceneView = PreviewLayeredSceneView(frame: NSRect(x: 0, y: 0, width: 1320, height: 900))
        sceneView.applyRenderState(
            capture: capture,
            image: image,
            canvasSize: CGSize(width: 1200, height: 640),
            selectedNodeID: nil,
            focusedNodeID: nil,
            highlightedCanvasRect: nil,
            previewRootNodeID: nil,
            geometryMode: .directGlobalCanvasRect,
            displayMode: .layered,
            zoomScale: 1,
            previewLayerSpacing: 22,
            previewShowsLayerBorders: true,
            previewExpandedNodeIDs: expanded,
            showsSystemWrapperViews: false
        )
        return sceneView
    }

    private func stage(_ sceneView: PreviewLayeredSceneView) throws -> SCNNode {
        try #require(sceneView.scene?.rootNode.childNode(withName: "stage", recursively: false))
    }

    private func texture(_ stageNode: SCNNode, _ nodeID: String) -> NSImage? {
        let displayNode = stageNode.childNode(withName: "display-\(nodeID)", recursively: false)
        let contentNode = displayNode?.childNode(withName: nodeID, recursively: true)
        return (contentNode?.geometry as? SCNPlane)?.firstMaterial?.diffuse.contents as? NSImage
    }

    @Test func collapsedNodesDoNotGetScenePlanes() throws {
        let sceneView = try makeSceneView()
        let stageNode = try stage(sceneView)
        #expect(stageNode.childNode(withName: "display-window-0-view-1-0", recursively: false) != nil)
        // 未展开父节点下的子节点只存在于计划里（用于命中测试），不创建平面和纹理。
        #expect(stageNode.childNode(withName: "display-window-0-view-0-0", recursively: false) == nil)
        #expect(sceneView.plan?.item(for: "window-0-view-0-0") != nil)
    }

    @Test func layerSpacingChangeOnlyMovesPlanes() throws {
        let sceneView = try makeSceneView()
        let stageNode = try stage(sceneView)
        let displayNode = try #require(stageNode.childNode(withName: "display-window-0-view-1-0", recursively: false))
        let textureBefore = try #require(texture(stageNode, "window-0-view-1-0"))
        let zBefore = displayNode.position.z

        sceneView.previewLayerSpacing = 120

        let displayNodeAfter = try #require(stageNode.childNode(withName: "display-window-0-view-1-0", recursively: false))
        #expect(displayNodeAfter === displayNode)
        #expect(texture(stageNode, "window-0-view-1-0") === textureBefore)
        #expect(abs(displayNodeAfter.position.z) > abs(zBefore))
    }

    @Test func layerSpacingRangeIsLinearAcrossWholeSlider() {
        let low = PreviewLayeredSceneConstants.depthStep(displayMode: .layered, layerSpacing: 10)
        let mid = PreviewLayeredSceneConstants.depthStep(displayMode: .layered, layerSpacing: 16)
        #expect(mid > low)
        #expect(PreviewLayeredSceneConstants.depthStep(displayMode: .flat, layerSpacing: 150) == PreviewLayeredSceneConstants.flatDepthStep)
    }

    @Test func bordersToggleAndDisplayModeKeepTexturesAndPlanes() throws {
        let sceneView = try makeSceneView()
        let stageNode = try stage(sceneView)
        let textureBefore = try #require(texture(stageNode, "window-0-view-1"))
        let nodeBefore = try #require(stageNode.childNode(withName: "display-window-0-view-1", recursively: false))

        sceneView.previewShowsLayerBorders = false
        sceneView.setDimension(.flat, animated: false)
        sceneView.selectedNodeID = "window-0-view-1"

        #expect(texture(stageNode, "window-0-view-1") === textureBefore)
        #expect(stageNode.childNode(withName: "display-window-0-view-1", recursively: false) === nodeBefore)
        #expect(abs(CGFloat(stageNode.eulerAngles.y)) < 0.0001)
    }

    @Test func refreshingSameCaptureReusesTexturesOfUnchangedPlanes() throws {
        let sceneView = try makeSceneView(expanded: ["window-0-view-1"])
        let stageNode = try stage(sceneView)
        let untouchedTexture = try #require(texture(stageNode, "window-0-view-1"))
        let changedTexture = try #require(texture(stageNode, "window-0-view-0"))

        // 展开另一个节点只影响它自己（需要挖掉子节点）及其子节点的纹理。
        sceneView.previewExpandedNodeIDs = ["window-0-view-1", "window-0-view-0"]
        #expect(texture(stageNode, "window-0-view-1") === untouchedTexture)
        #expect(texture(stageNode, "window-0-view-0") !== changedTexture)
        #expect(stageNode.childNode(withName: "display-window-0-view-0-0", recursively: false) != nil)
    }

    @Test func selectionOverlayRendersAboveAllPlanes() throws {
        let sceneView = try makeSceneView()
        sceneView.highlightedCanvasRect = CGRect(x: 72, y: 28, width: 240, height: 34)
        sceneView.selectedNodeID = "window-0-view-1-0"
        let stageNode = try stage(sceneView)
        let overlay = try #require(stageNode.childNode(withName: "selection-overlay", recursively: false))
        let fill = try #require(overlay.childNodes.first)
        let maxPlaneOrder = stageNode.childNodes
            .filter { $0.name?.hasPrefix("display-") == true }
            .flatMap(\.childNodes)
            .map(\.renderingOrder)
            .max() ?? 0
        #expect(overlay.isHidden == false)
        #expect(fill.renderingOrder > maxPlaneOrder)
    }

    @Test func hoverAndDiagnosticsOverlaysFollowState() throws {
        let sceneView = try makeSceneView()
        let stageNode = try stage(sceneView)
        let hoverNode = try #require(stageNode.childNode(withName: "hover-overlay", recursively: false))
        #expect(hoverNode.geometry == nil)
        sceneView.hoveredNodeID = "window-0-view-0-0"
        #expect(hoverNode.geometry != nil)
        sceneView.hoveredNodeID = nil
        #expect(hoverNode.geometry == nil)

        let diagnosticsNode = try #require(stageNode.childNode(withName: "diagnostics-overlay", recursively: false))
        sceneView.diagnosticSeverities = ["window-0-view-1-0": .error, "window-0-view-0-0": .info]
        // info 不描边，error 描红。
        #expect(diagnosticsNode.childNodes.map(\.name) == ["diagnostics-2"])
        sceneView.showsDiagnostics = false
        #expect(diagnosticsNode.childNodes.isEmpty)
    }

    @Test func centeringMovesPivotInsteadOfTranslation() throws {
        let sceneView = try makeSceneView()
        sceneView.centerOnNode("window-0-view-1-0")
        let stageNode = try stage(sceneView)
        let item = try #require(sceneView.plan?.item(for: "window-0-view-1-0"))
        let expectedX = (item.visibleRect.midX - 600) * PreviewLayeredSceneConstants.unitScale
        #expect(abs(CGFloat(stageNode.pivot.m41) - expectedX) < 0.0001)
        #expect(abs(CGFloat(stageNode.position.x)) < 0.0001)

        sceneView.resetView(animated: false)
        #expect(abs(CGFloat(stageNode.pivot.m41)) < 0.0001)
        #expect(abs(CGFloat(stageNode.eulerAngles.y) - PreviewLayeredSceneConstants.defaultYaw) < 0.0001)
    }

    @Test func flatProjectionMapsCanvasRectsBackToView() throws {
        let sceneView = try makeSceneView()
        sceneView.setDimension(.flat, animated: false)
        let rect = try #require(sceneView.viewRect(forCanvasRect: CGRect(x: 0, y: 0, width: 1200, height: 640), nodeID: nil))
        // 默认缩放下画布占视图 70%，并居中。
        #expect(abs(rect.midX - 660) < 2)
        #expect(abs(rect.midY - 450) < 2)
        #expect(abs(rect.width - 1320 * 0.7) < 4, "\(rect)")
    }

    // MARK: - 交互数学

    @Test func pitchIsClampedWhileYawWraps() {
        let rotation = PreviewLayeredSceneInteraction.updatedRotation(current: .zero, delta: CGPoint(x: 0, y: -2000))
        #expect(abs(rotation.x - PreviewLayeredSceneConstants.maximumPitch) < 0.0001)
        let yaw = PreviewLayeredSceneInteraction.updatedRotation(current: .zero, delta: CGPoint(x: 700, y: 0))
        #expect(yaw.y > -.pi && yaw.y < .pi)
    }

    @Test func zoomAnchorKeepsCursorPointFixed() {
        let cursorOffset = CGPoint(x: 100, y: -40)
        let before: CGFloat = 0.02
        let after: CGFloat = 0.01
        let translation = PreviewLayeredSceneInteraction.anchoredTranslation(
            translation: CGPoint(x: 1, y: 2),
            cursorOffset: cursorOffset,
            unitsPerPointBefore: before,
            unitsPerPointAfter: after
        )
        // 光标下的内容点 = 光标偏移 × 单位换算 - 平移，缩放前后应保持不变。
        let contentBefore = CGPoint(x: cursorOffset.x * before - 1, y: cursorOffset.y * before - 2)
        let contentAfter = CGPoint(x: cursorOffset.x * after - translation.x, y: cursorOffset.y * after - translation.y)
        #expect(abs(contentBefore.x - contentAfter.x) < 0.0001)
        #expect(abs(contentBefore.y - contentAfter.y) < 0.0001)
    }

    @Test func panIsClampedNearContent() {
        let clamped = PreviewLayeredSceneInteraction.clampedTranslation(
            CGPoint(x: 100, y: -100),
            contentSize: CGSize(width: 10, height: 6),
            viewportSize: CGSize(width: 4, height: 4)
        )
        #expect(clamped == CGPoint(x: 7, y: -5))
    }

    // MARK: - 取色

    @Test func colorSamplerMapsCanvasPointsToPixelsAtHostScale() {
        let pixel = PreviewColorSampler.pixelCoordinate(for: CGPoint(x: 10.5, y: 20.2), canvasSize: CGSize(width: 100, height: 100), pixelsWide: 300, pixelsHigh: 300)
        #expect(pixel?.x == 31)
        #expect(pixel?.y == 60)
        #expect(PreviewColorSampler.pixelCoordinate(for: CGPoint(x: 100, y: 0), canvasSize: CGSize(width: 100, height: 100), pixelsWide: 300, pixelsHigh: 300) == nil)
    }

    @Test func colorSamplerReadsTopLeftOrientedPixels() throws {
        // 上半部分红色、下半部分蓝色的 3x sRGB 位图（CGContext 原点在左下角）。
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: 30,
            height: 30,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 30, height: 15))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 15, width: 30, height: 15))
        let cgImage = try #require(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.addRepresentation(rep)
        var sampler = PreviewColorSampler()
        let sampledTop = sampler.color(at: CGPoint(x: 5, y: 1), in: image, canvasSize: CGSize(width: 10, height: 10))
        let sampledBottom = sampler.color(at: CGPoint(x: 5, y: 9), in: image, canvasSize: CGSize(width: 10, height: 10))
        let top = try #require(sampledTop)
        let bottom = try #require(sampledBottom)
        #expect(PreviewColorSampler.hexString(for: top) == "#FF0000", "\(top)")
        #expect(top.redComponent > 0.9)
        #expect(bottom.blueComponent > 0.9)
        #expect(PreviewColorSampler.hexString(for: NSColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 0.5)) == "#0080FF80")
    }

    @Test func croppedTexturesStayUprightAndKeepHostPixelDensity() throws {
        // 100x100 pt 的 @3x 截图：上半部分红色、下半部分蓝色。
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: 300,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 150))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 150, width: 300, height: 150))
        let rootImage = NSImage(size: NSSize(width: 100, height: 100))
        rootImage.addRepresentation(NSBitmapImageRep(cgImage: try #require(context.makeImage())))

        let canvasSize = CGSize(width: 100, height: 100)
        let scale = PreviewLayeredSceneSnapshotFactory.pixelScale(of: rootImage, canvasSize: canvasSize)
        #expect(scale == 3)
        let working = PreviewLayeredSceneSnapshotFactory.makeTopLeftWorkingImage(from: rootImage, size: canvasSize)
        let item = PreviewLayeredScenePlan.Item(
            nodeID: "item",
            parentNodeID: nil,
            depth: 0,
            zIndex: 0,
            displayOrder: 0,
            displayingIndependently: true,
            displayRect: CGRect(x: 10, y: 30, width: 40, height: 40),
            punchedOutRects: [CGRect(x: 10, y: 60, width: 10, height: 10)],
            clipRect: nil,
            planeOwnerNodeID: "item"
        )
        let texture = PreviewLayeredSceneSnapshotFactory.makeTextureImage(for: item, rootImage: working, canvasSize: canvasSize, pixelScale: scale)
        var proposedRect = CGRect(origin: .zero, size: texture.size)
        let cgTexture = try #require(texture.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil))
        #expect(cgTexture.width == 120)
        // 纹理顶部（画布 y=31）应为红色，底部（画布 y=69，x=40）应为蓝色；左下角 punch-out 区域透明。
        let top = try #require(PreviewColorSampler.srgbColor(of: cgTexture, x: 60, y: 3))
        let bottom = try #require(PreviewColorSampler.srgbColor(of: cgTexture, x: 90, y: 115))
        let punched = try #require(PreviewColorSampler.srgbColor(of: cgTexture, x: 10, y: 115))
        #expect(top.redComponent > 0.9 && top.blueComponent < 0.1)
        #expect(bottom.blueComponent > 0.9 && bottom.redComponent < 0.1)
        #expect(punched.alphaComponent < 0.05)
    }

    // MARK: - 截图选择

    @Test func previewSelectionIsHiddenWhenScreenshotFallsBackToAnotherWindow() {
        let window1 = F.node("w1", parent: nil, children: ["r1"], frame: CGRect(x: 0, y: 0, width: 100, height: 100), kind: .window)
        let root1 = F.node("r1", parent: "w1", children: [], frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window2 = F.node("w2", parent: nil, children: ["r2"], frame: CGRect(x: 0, y: 0, width: 100, height: 100), kind: .window)
        let root2 = F.node("r2", parent: "w2", children: ["v2"], frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view2 = F.node("v2", parent: "r2", frame: CGRect(x: 10, y: 10, width: 10, height: 10))
        var capture = F.capture(nodes: [window1, root1, window2, root2, view2], rootNodeIDs: ["w1", "w2"])
        capture.previewBitmaps = [
            ViewScopePreviewBitmap(rootNodeID: "r1", pngBase64: "AA==", size: ViewScopeSize(width: 100, height: 100), capturedAt: Date())
        ]
        let (context, _) = PreviewRenderContextBuilder().makeContext(
            capture: capture,
            detail: nil,
            selectedNodeID: "v2",
            focusedNodeID: nil,
            cache: .empty
        )
        #expect(context.previewRootNodeID == "r1")
        #expect(context.selectionRect == nil)
    }
}
