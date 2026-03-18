import AppKit
import XCTest
@testable import ViewScopeServer

final class ViewScopeServerTests: XCTestCase {
    func testMessageRoundTrip() throws {
        let message = ViewScopeMessage(
            kind: .clientHello,
            requestID: "handshake",
            clientHello: ViewScopeClientHelloPayload(
                authToken: "token",
                clientName: "Tests",
                clientVersion: "1.0",
                protocolVersion: viewScopeCurrentProtocolVersion
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ViewScopeMessage.self, from: data)

        XCTAssertEqual(decoded.kind, .clientHello)
        XCTAssertEqual(decoded.clientHello?.authToken, "token")
    }

    @MainActor
    func testSnapshotBuilderCollectsSubviews() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Snapshot Builder Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let title = NSTextField(labelWithString: "Hello")
        title.frame = NSRect(x: 20, y: 20, width: 120, height: 22)
        let button = NSButton(title: "Inspect", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 60, width: 120, height: 32)
        root.addSubview(title)
        root.addSubview(button)
        window.contentView = root
        window.orderFrontRegardless()

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

        let (capture, _) = builder.makeCapture()
        let rootNode = capture.rootNodeIDs
            .compactMap { capture.nodes[$0] }
            .first(where: { $0.title == window.title })

        XCTAssertGreaterThanOrEqual(capture.summary.nodeCount, 3)
        XCTAssertNotNil(rootNode)
        XCTAssertGreaterThanOrEqual(rootNode?.childIDs.count ?? 0, 1)
    }

    @MainActor
    func testWindowRootUsesContentBoundsAndFlippedState() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Flipped Root Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }
        let root = FlippedFixtureView(frame: NSRect(x: 0, y: 0, width: 480, height: 280))
        window.contentView = root
        window.orderFrontRegardless()

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

        let (capture, _) = builder.makeCapture()
        guard let windowNode = capture.rootNodeIDs
            .compactMap({ capture.nodes[$0] })
            .first(where: { $0.title == window.title }) else {
            return XCTFail("Expected a root window node")
        }
        let contentBounds = window.contentView?.bounds ?? .zero
        let expectedBounds = ViewScopeRect(
            x: Double(contentBounds.origin.x),
            y: Double(contentBounds.origin.y),
            width: Double(contentBounds.width),
            height: Double(contentBounds.height)
        )

        XCTAssertEqual(windowNode.frame, expectedBounds)
        XCTAssertEqual(windowNode.bounds, expectedBounds)
        XCTAssertTrue(windowNode.isFlipped)
    }

    @MainActor
    func testDetailHighlightRectNormalizesToCanvasCoordinates() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Highlight Rect Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let child = NSView(frame: NSRect(x: 12, y: 18, width: 60, height: 24))
        root.addSubview(child)
        window.contentView = root
        window.orderFrontRegardless()

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
        guard let childID = context.nodeReferences.first(where: { _, reference in
            guard case .view(let capturedView) = reference else { return false }
            return capturedView == child
        })?.key else {
            return XCTFail("Expected to capture the child view")
        }
        guard let detail = builder.makeDetail(for: childID, in: context) else {
            return XCTFail("Expected detail payload for child view")
        }
        let expectedY = Double(root.bounds.height - child.frame.maxY)

        XCTAssertEqual(detail.highlightedRect, ViewScopeRect(x: 12, y: expectedY, width: 60, height: 24))
    }
}

private final class FlippedFixtureView: NSView {
    override var isFlipped: Bool {
        true
    }
}
