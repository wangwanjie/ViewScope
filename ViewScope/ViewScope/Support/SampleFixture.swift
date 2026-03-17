import AppKit
import ViewScopeServer

enum SampleFixture {
    static func announcement() -> ViewScopeHostAnnouncement {
        ViewScopeHostAnnouncement(
            identifier: "sample.host.preview",
            authToken: "preview-token",
            displayName: "Sample Notes",
            bundleIdentifier: "cn.vanjay.SampleNotes",
            version: "1.4.2",
            build: "112",
            processIdentifier: 4242,
            port: 0,
            updatedAt: Date(),
            supportsHighlighting: true,
            protocolVersion: viewScopeCurrentProtocolVersion,
            runtimeVersion: viewScopeServerRuntimeVersion
        )
    }

    static func capture() -> ViewScopeCapturePayload {
        let host = ViewScopeHostInfo(
            displayName: "Sample Notes",
            bundleIdentifier: "cn.vanjay.SampleNotes",
            version: "1.4.2",
            build: "112",
            processIdentifier: 4242,
            runtimeVersion: viewScopeServerRuntimeVersion,
            supportsHighlighting: true
        )

        let nodes = makeNodes()
        return ViewScopeCapturePayload(
            host: host,
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 184),
            rootNodeIDs: ["window-0"],
            nodes: nodes
        )
    }

    static func detail(for nodeID: String) -> ViewScopeNodeDetailPayload {
        let host = capture().host
        let image = previewImage()
        let base64 = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])?.base64EncodedString()

        let rects: [String: ViewScopeRect] = [
            "window-0-view-0": ViewScopeRect(x: 0, y: 0, width: 220, height: 640),
            "window-0-view-1": ViewScopeRect(x: 220, y: 0, width: 980, height: 640),
            "window-0-view-1-2": ViewScopeRect(x: 292, y: 152, width: 760, height: 408),
            "window-0-view-1-1": ViewScopeRect(x: 292, y: 92, width: 760, height: 44)
        ]

        let sections = [
            ViewScopePropertySection(title: "Identity", items: [
                ViewScopePropertyItem(title: "Node", value: nodeID),
                ViewScopePropertyItem(title: "Class", value: capture().nodes[nodeID]?.className ?? "NSView"),
                ViewScopePropertyItem(title: "Address", value: "0xfeedbeef")
            ]),
            ViewScopePropertySection(title: "Layout", items: [
                ViewScopePropertyItem(title: "Frame", value: "x 292.0 y 152.0 w 760.0 h 408.0"),
                ViewScopePropertyItem(title: "Intrinsic Size", value: "No intrinsic size"),
                ViewScopePropertyItem(title: "Translates Mask", value: "No")
            ]),
            ViewScopePropertySection(title: "Rendering", items: [
                ViewScopePropertyItem(title: "Hidden", value: "No"),
                ViewScopePropertyItem(title: "Alpha", value: "1.00"),
                ViewScopePropertyItem(title: "Layer Backed", value: "Yes")
            ])
        ]

        return ViewScopeNodeDetailPayload(
            nodeID: nodeID,
            host: host,
            sections: sections,
            constraints: [
                "Sidebar.trailing = Content.leading * 1.00 + 0.00",
                "Chart.leading = Content.leading * 1.00 + 72.00",
                "Chart.trailing = Content.trailing * 1.00 + -72.00"
            ],
            ancestry: ["Sample Notes", "WorkspaceSplitView", "ContentPane", "ChartCard"],
            screenshotPNGBase64: base64,
            screenshotSize: ViewScopeSize(width: Double(image.size.width), height: Double(image.size.height)),
            highlightedRect: rects[nodeID] ?? ViewScopeRect(x: 292, y: 152, width: 760, height: 408)
        )
    }

    private static func makeNodes() -> [String: ViewScopeHierarchyNode] {
        [
            "window-0": ViewScopeHierarchyNode(
                id: "window-0",
                parentID: nil,
                kind: .window,
                className: "NSWindow",
                title: "Sample Notes",
                subtitle: "#32",
                frame: ViewScopeRect(x: 0, y: 0, width: 1200, height: 640),
                bounds: ViewScopeRect(x: 0, y: 0, width: 1200, height: 640),
                childIDs: ["window-0-view-0", "window-0-view-1"],
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
                className: "SidebarPaneView",
                title: "Sidebar",
                subtitle: "Pinned folders",
                frame: ViewScopeRect(x: 0, y: 0, width: 220, height: 640),
                bounds: ViewScopeRect(x: 0, y: 0, width: 220, height: 640),
                childIDs: ["window-0-view-0-0", "window-0-view-0-1"],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: false,
                depth: 1
            ),
            "window-0-view-0-0": ViewScopeHierarchyNode(
                id: "window-0-view-0-0",
                parentID: "window-0-view-0",
                kind: .view,
                className: "NSTextField",
                title: "Projects",
                subtitle: nil,
                frame: ViewScopeRect(x: 24, y: 28, width: 128, height: 28),
                bounds: ViewScopeRect(x: 0, y: 0, width: 128, height: 28),
                childIDs: [],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: false,
                isFlipped: true,
                clippingEnabled: false,
                depth: 2
            ),
            "window-0-view-0-1": ViewScopeHierarchyNode(
                id: "window-0-view-0-1",
                parentID: "window-0-view-0",
                kind: .view,
                className: "NSOutlineView",
                title: "ProjectList",
                subtitle: "Scrollable",
                frame: ViewScopeRect(x: 20, y: 76, width: 180, height: 520),
                bounds: ViewScopeRect(x: 0, y: 0, width: 180, height: 520),
                childIDs: [],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: true,
                depth: 2
            ),
            "window-0-view-1": ViewScopeHierarchyNode(
                id: "window-0-view-1",
                parentID: "window-0",
                kind: .view,
                className: "ContentPaneView",
                title: "ContentPane",
                subtitle: "Chart workspace",
                frame: ViewScopeRect(x: 220, y: 0, width: 980, height: 640),
                bounds: ViewScopeRect(x: 0, y: 0, width: 980, height: 640),
                childIDs: ["window-0-view-1-0", "window-0-view-1-1", "window-0-view-1-2", "window-0-view-1-3"],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: false,
                depth: 1
            ),
            "window-0-view-1-0": ViewScopeHierarchyNode(
                id: "window-0-view-1-0",
                parentID: "window-0-view-1",
                kind: .view,
                className: "NSTextField",
                title: "Sprint Overview",
                subtitle: nil,
                frame: ViewScopeRect(x: 72, y: 28, width: 240, height: 34),
                bounds: ViewScopeRect(x: 0, y: 0, width: 240, height: 34),
                childIDs: [],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: false,
                isFlipped: true,
                clippingEnabled: false,
                depth: 2
            ),
            "window-0-view-1-1": ViewScopeHierarchyNode(
                id: "window-0-view-1-1",
                parentID: "window-0-view-1",
                kind: .view,
                className: "ToolbarCardView",
                title: "InspectorActions",
                subtitle: "Actions",
                frame: ViewScopeRect(x: 292, y: 92, width: 760, height: 44),
                bounds: ViewScopeRect(x: 0, y: 0, width: 760, height: 44),
                childIDs: [],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: false,
                depth: 2
            ),
            "window-0-view-1-2": ViewScopeHierarchyNode(
                id: "window-0-view-1-2",
                parentID: "window-0-view-1",
                kind: .view,
                className: "ChartCardView",
                title: "ChartCard",
                subtitle: "Revenue trend",
                frame: ViewScopeRect(x: 292, y: 152, width: 760, height: 408),
                bounds: ViewScopeRect(x: 0, y: 0, width: 760, height: 408),
                childIDs: [],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: true,
                depth: 2
            ),
            "window-0-view-1-3": ViewScopeHierarchyNode(
                id: "window-0-view-1-3",
                parentID: "window-0-view-1",
                kind: .view,
                className: "NSStackView",
                title: "KeyMetrics",
                subtitle: "3 arranged",
                frame: ViewScopeRect(x: 292, y: 578, width: 760, height: 40),
                bounds: ViewScopeRect(x: 0, y: 0, width: 760, height: 40),
                childIDs: [],
                isHidden: false,
                alphaValue: 1,
                wantsLayer: true,
                isFlipped: true,
                clippingEnabled: false,
                depth: 2
            )
        ]
    }

    private static func previewImage() -> NSImage {
        let size = NSSize(width: 1200, height: 640)
        let image = NSImage(size: size)
        image.lockFocus()

        let canvas = NSRect(origin: .zero, size: size)
        NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1).setFill()
        canvas.fill()

        NSColor(calibratedRed: 0.13, green: 0.19, blue: 0.26, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 220, height: 640)).fill()

        NSColor(calibratedRed: 0.17, green: 0.74, blue: 0.67, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 564, width: 172, height: 34), xRadius: 12, yRadius: 12).fill()

        let headerGradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.86, green: 0.94, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1)
        ])
        headerGradient?.draw(in: NSRect(x: 220, y: 0, width: 980, height: 160), angle: 270)

        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 292, y: 80, width: 760, height: 488), xRadius: 24, yRadius: 24).fill()

        NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.94, alpha: 1).setStroke()
        let chartCard = NSBezierPath(roundedRect: NSRect(x: 292, y: 80, width: 760, height: 488), xRadius: 24, yRadius: 24)
        chartCard.lineWidth = 2
        chartCard.stroke()

        let graphPath = NSBezierPath()
        graphPath.move(to: NSPoint(x: 344, y: 250))
        graphPath.line(to: NSPoint(x: 430, y: 290))
        graphPath.line(to: NSPoint(x: 560, y: 276))
        graphPath.line(to: NSPoint(x: 700, y: 360))
        graphPath.line(to: NSPoint(x: 830, y: 332))
        graphPath.line(to: NSPoint(x: 1008, y: 418))
        graphPath.lineWidth = 6
        graphPath.lineCapStyle = .round
        NSColor(calibratedRed: 0.14, green: 0.63, blue: 0.86, alpha: 1).setStroke()
        graphPath.stroke()

        for point in [NSPoint(x: 430, y: 290), NSPoint(x: 700, y: 360), NSPoint(x: 1008, y: 418)] {
            let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
            NSColor(calibratedRed: 0.17, green: 0.74, blue: 0.67, alpha: 1).setFill()
            dot.fill()
        }

        image.unlockFocus()
        return image
    }
}
