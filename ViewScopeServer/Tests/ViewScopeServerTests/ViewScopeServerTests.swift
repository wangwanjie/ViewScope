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

    func testMutationMessageRoundTrip() throws {
        let message = ViewScopeMessage(
            kind: .mutationRequest,
            requestID: "mutation",
            mutationRequest: ViewScopeMutationRequestPayload(
                nodeID: "node-1",
                property: .number(key: "frame.x", value: 42)
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ViewScopeMessage.self, from: data)

        XCTAssertEqual(decoded.kind, .mutationRequest)
        XCTAssertEqual(decoded.mutationRequest?.nodeID, "node-1")
        XCTAssertEqual(decoded.mutationRequest?.property.key, "frame.x")
        XCTAssertEqual(decoded.mutationRequest?.property.numberValue, 42)
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
    func testSnapshotBuilderCapturesSubviewIvarTraces() {
        final class FixtureRootView: NSView {
            let titleLabel = NSTextField(labelWithString: "Hello")
            let actionButton = NSButton(title: "Inspect", target: nil, action: nil)

            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                addSubview(titleLabel)
                addSubview(actionButton)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Ivar Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }

        let root = FixtureRootView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
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
        let ivarNames = capture.nodes.values
            .filter { $0.parentID != nil }
            .flatMap(\.ivarTraces)
            .map(\.ivarName)

        XCTAssertTrue(ivarNames.contains("titleLabel"))
        XCTAssertTrue(ivarNames.contains("actionButton"))
    }

    @MainActor
    func testSnapshotBuilderCapturesVisibleTableRowContentViews() throws {
        guard ProcessInfo.processInfo.environment["VIEWSCOPE_RUN_TABLE_SNAPSHOT_TEST"] == "1" else {
            throw XCTSkip("NSTableView snapshot coverage is unstable under the SwiftPM AppKit test host; client preview geometry tests cover the shipped behavior.")
        }

        final class TableFixtureDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
            let items = ["Alpha", "Beta"]

            func numberOfRows(in tableView: NSTableView) -> Int {
                items.count
            }

            func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
                let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
                let container = NSView(frame: cell.bounds)
                let textField = NSTextField(labelWithString: items[row])
                textField.frame = NSRect(x: 8, y: 2, width: 180, height: 20)
                container.addSubview(textField)
                cell.addSubview(container)
                cell.textField = textField
                return cell
            }
        }

        let dataSource = TableFixtureDataSource()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Table Fixture"

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        let tableView = NSTableView(frame: scrollView.bounds)
        defer {
            tableView.delegate = nil
            tableView.dataSource = nil
            scrollView.documentView = nil
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 260
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = .zero
        tableView.delegate = dataSource
        tableView.dataSource = dataSource
        scrollView.documentView = tableView

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        root.addSubview(scrollView)
        window.contentView = root
        window.orderFrontRegardless()
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
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

        let (capture, _) = builder.makeCapture()
        let titles = Set(capture.nodes.values.map(\.title))

        XCTAssertTrue(titles.contains("Alpha"))
        XCTAssertTrue(titles.contains("Beta"))

        let rowNode = capture.nodes.values.first {
            $0.className.contains("NSTableRowView") && $0.title.contains("Row")
        }
        let cellNode = capture.nodes.values.first {
            $0.className.contains("NSTableCellView") && $0.title == "Alpha"
        }

        XCTAssertNotNil(rowNode)
        XCTAssertNotNil(cellNode)
        if let rowNode, let cellNode {
            XCTAssertGreaterThanOrEqual(cellNode.frame.x, rowNode.frame.x)
            XCTAssertGreaterThanOrEqual(cellNode.frame.y, rowNode.frame.y)
            XCTAssertLessThanOrEqual(cellNode.frame.x + cellNode.frame.width, rowNode.frame.x + rowNode.frame.width)
            XCTAssertLessThanOrEqual(cellNode.frame.y + cellNode.frame.height, rowNode.frame.y + rowNode.frame.height)
            XCTAssertFalse(cellNode.childIDs.isEmpty)
            let cellChildClassNames = Set(
                cellNode.childIDs.compactMap { capture.nodes[$0]?.className }
            )
            XCTAssertTrue(cellChildClassNames.contains { $0.contains("NSTextField") })
        }
    }

    func testClassNameFormatterFlattensPrivateSwiftContext() {
        let formatted = ViewScopeClassNameFormatter.displayName(
            for: "_TtC6AppKitP33_72EBFCF981BE77E1C6F26FD717D0893922NSTextFieldSimpleLabel"
        )

        XCTAssertEqual(formatted, "AppKit.NSTextFieldSimpleLabel _72EBFCF981BE77E1C6F26FD717D08939")
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

    @MainActor
    func testCaptureFrameNormalizesToCanvasCoordinates() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Capture Frame Fixture"
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

        let (capture, context) = builder.makeCapture()
        guard let childID = context.nodeReferences.first(where: { _, reference in
            guard case .view(let capturedView) = reference else { return false }
            return capturedView == child
        })?.key else {
            return XCTFail("Expected to capture the child view")
        }
        guard let childNode = capture.nodes[childID] else {
            return XCTFail("Expected captured node for child view")
        }
        let expectedY = Double(root.bounds.height - child.frame.maxY)

        XCTAssertEqual(childNode.frame, ViewScopeRect(x: 12, y: expectedY, width: 60, height: 24))
    }

    @MainActor
    func testDetailSanitizesMultilineTitlesAndExposesEditableItems() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Editable Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 140))
        let label = NSTextField(labelWithString: "First\nSecond")
        label.frame = NSRect(x: 20, y: 30, width: 120, height: 22)
        root.addSubview(label)
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

        let (capture, context) = builder.makeCapture()
        guard let node = capture.nodes.values.first(where: { $0.className.contains("NSTextField") }) else {
            return XCTFail("Expected an NSTextField node")
        }
        XCTAssertEqual(node.title, "First Second")

        guard let detail = builder.makeDetail(for: node.id, in: context) else {
            return XCTFail("Expected detail payload")
        }

        let editableKeys = detail.sections
            .flatMap(\.items)
            .compactMap { $0.editable?.key }

        XCTAssertTrue(editableKeys.contains("hidden"))
        XCTAssertTrue(editableKeys.contains("alpha"))
        XCTAssertTrue(editableKeys.contains("frame.x"))
        XCTAssertTrue(editableKeys.contains("frame.width"))
    }

    @MainActor
    func testDetailHighlightRectNormalizesMixedFlippedHierarchyIntoTopLeftCanvasSpace() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Mixed Flip Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }

        let root = FlippedFixtureView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let container = NSView(frame: root.bounds)
        let child = NSView(frame: NSRect(x: 12, y: 18, width: 60, height: 24))
        container.addSubview(child)
        root.addSubview(container)
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
            return XCTFail("Expected to capture the mixed-flip child view")
        }
        guard let detail = builder.makeDetail(for: childID, in: context) else {
            return XCTFail("Expected detail payload for mixed-flip child view")
        }

        let expectedRect = child.convert(child.bounds, to: root)
        XCTAssertEqual(
            detail.highlightedRect,
            ViewScopeRect(
                x: expectedRect.origin.x,
                y: expectedRect.origin.y,
                width: expectedRect.width,
                height: expectedRect.height
            )
        )
    }
}

private final class FlippedFixtureView: NSView {
    override var isFlipped: Bool {
        true
    }
}
