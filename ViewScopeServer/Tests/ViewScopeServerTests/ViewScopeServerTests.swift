import AppKit
import XCTest
@testable import ViewScopeServer

final class ViewScopeServerTests: XCTestCase {
    func testPodspecInjectsBootstrapAnchorIntoHostLinkerFlags() throws {
        for podspecURL in podspecURLs() {
            let contents = try String(contentsOf: podspecURL, encoding: .utf8)

            XCTAssertTrue(contents.contains("user_target_xcconfig"), podspecURL.path)
            XCTAssertTrue(contents.contains("OTHER_LDFLAGS"), podspecURL.path)
            XCTAssertTrue(contents.contains("_ViewScopeServerBootstrapAnchor"), podspecURL.path)
        }
    }

    @MainActor
    func testRuntimeIvarReaderReturnsRawPointersForObjectIvars() throws {
        final class FixtureRootView: NSView {
            unowned(unsafe) var unsafeSubview: NSView?
            weak var weakSubview: NSView?
            var strongSubview: NSView?
        }

        let root = FixtureRootView(frame: .zero)
        let child = NSView(frame: .zero)
        root.addSubview(child)
        root.unsafeSubview = child
        root.weakSubview = child
        root.strongSubview = child

        let expectedPointer = UnsafeRawPointer(Unmanaged.passUnretained(child).toOpaque())

        XCTAssertEqual(
            ViewScopeRuntimeIvarReader.storedObjectPointer(in: root, ivarNamed: "unsafeSubview"),
            expectedPointer
        )
        XCTAssertEqual(
            ViewScopeRuntimeIvarReader.storedObjectPointer(in: root, ivarNamed: "weakSubview"),
            expectedPointer
        )
        XCTAssertEqual(
            ViewScopeRuntimeIvarReader.storedObjectPointer(in: root, ivarNamed: "strongSubview"),
            expectedPointer
        )
    }

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

    func testProtocolV2BridgeMessageRoundTrip() throws {
        let previewBitmap = ViewScopePreviewBitmap(
            rootNodeID: "window-0",
            pngBase64: "abc",
            size: .init(width: 1200, height: 800),
            capturedAt: Date(timeIntervalSince1970: 1_731_110_400),
            scale: 2
        )
        let capture = ViewScopeCapturePayload(
            host: makeHostInfo(),
            capturedAt: Date(timeIntervalSince1970: 1_731_110_400),
            summary: .init(nodeCount: 1, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: ["window-0"],
            nodes: [:],
            captureID: "capture-1",
            previewBitmaps: [previewBitmap]
        )
        let targetReference = ViewScopeRemoteObjectReference(
            captureID: "capture-1",
            objectID: "obj-1",
            kind: .viewController,
            className: "Demo.RootViewController",
            address: "0x123",
            sourceNodeID: "window-0-view-0"
        )
        let targetDescriptor = ViewScopeConsoleTargetDescriptor(
            reference: targetReference,
            title: "<Demo.RootViewController: 0x123>",
            subtitle: "Primary"
        )
        let message = ViewScopeMessage(
            kind: .consoleInvokeResponse,
            requestID: "console",
            capture: capture,
            consoleInvokeResponse: .init(
                submittedExpression: "viewDidAppear",
                target: targetReference,
                resultDescription: "<Demo.RootViewController: 0x123>",
                returnedObject: targetDescriptor,
                errorMessage: nil
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ViewScopeMessage.self, from: data)

        XCTAssertEqual(decoded.kind, .consoleInvokeResponse)
        XCTAssertEqual(decoded.capture?.captureID, "capture-1")
        XCTAssertEqual(decoded.capture?.previewBitmaps.first?.rootNodeID, "window-0")
        XCTAssertEqual(decoded.consoleInvokeResponse?.target.kind, .viewController)
        XCTAssertEqual(decoded.consoleInvokeResponse?.returnedObject?.title, "<Demo.RootViewController: 0x123>")
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
    func testSnapshotBuilderCapturesRootViewControllerMetadata() throws {
        final class FixtureViewController: NSViewController {
            let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let contentLabel = NSTextField(labelWithString: "Controller Content")

            override func loadView() {
                contentLabel.frame = NSRect(x: 20, y: 20, width: 180, height: 24)
                rootView.addSubview(contentLabel)
                view = rootView
            }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "View Controller Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }

        let controller = FixtureViewController()
        window.contentViewController = controller
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
        let controllerRootID = try XCTUnwrap(context.nodeReferences.first(where: { _, reference in
            guard case .view(let capturedView) = reference else { return false }
            return capturedView === controller.view
        })?.key)
        let descendantID = try XCTUnwrap(context.nodeReferences.first(where: { _, reference in
            guard case .view(let capturedView) = reference else { return false }
            return capturedView === controller.contentLabel
        })?.key)
        let node = try XCTUnwrap(capture.nodes[controllerRootID])
        let descendantNode = try XCTUnwrap(capture.nodes[descendantID])
        let detail = try XCTUnwrap(builder.makeDetail(for: controllerRootID, in: context))

        XCTAssertEqual(node.rootViewControllerClassName, NSStringFromClass(FixtureViewController.self))
        XCTAssertNil(descendantNode.rootViewControllerClassName)
        XCTAssertTrue(propertyValue(titled: "View Controller", in: detail.sections)?.contains("FixtureViewController") == true)
    }

    @MainActor
    func testSnapshotBuilderIncludesCapturePreviewBitmapsAndConsoleTargets() throws {
        final class FixtureViewController: NSViewController {
            let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
            let titleLabel = NSTextField(labelWithString: "Hello")

            override func loadView() {
                titleLabel.frame = NSRect(x: 20, y: 20, width: 120, height: 22)
                rootView.addSubview(titleLabel)
                view = rootView
            }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Preview Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }

        let controller = FixtureViewController()
        window.contentViewController = controller
        window.orderFrontRegardless()

        let builder = ViewScopeSnapshotBuilder(hostInfo: makeHostInfo())
        let (capture, context) = builder.makeCapture()

        XCTAssertFalse(capture.captureID.isEmpty)
        XCTAssertEqual(capture.previewBitmaps.count, 1)
        XCTAssertEqual(capture.previewBitmaps.first?.rootNodeID, "window-0")
        XCTAssertEqual(capture.previewBitmaps.first?.size.width, Double(window.contentView?.bounds.width ?? 0))

        let controllerRootID = try XCTUnwrap(context.nodeReferences.first(where: { _, reference in
            guard case .view(let capturedView) = reference else { return false }
            return capturedView === controller.view
        })?.key)
        let detail = try XCTUnwrap(builder.makeDetail(for: controllerRootID, in: context))
        let kinds = detail.consoleTargets.map(\.reference.kind)

        XCTAssertTrue(kinds.contains(.view))
        XCTAssertTrue(kinds.contains(.viewController))
        XCTAssertTrue(detail.consoleTargets.allSatisfy { $0.reference.captureID == capture.captureID })
    }

    @MainActor
    func testSnapshotBuilderIgnoresDanglingUnsafeSubviewIvars() {
        final class FixtureRootView: NSView {
            unowned(unsafe) var danglingSubview: NSView?
            let persistentSubview = NSTextField(labelWithString: "Hello")

            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                persistentSubview.frame = NSRect(x: 20, y: 20, width: 120, height: 22)
                addSubview(persistentSubview)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Unsafe Ivar Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }

        let root = FixtureRootView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        weak var releasedSubview: NSView?
        autoreleasepool {
            let transientSubview = NSView(frame: NSRect(x: 20, y: 60, width: 120, height: 22))
            releasedSubview = transientSubview
            root.addSubview(transientSubview)
            root.danglingSubview = transientSubview
            transientSubview.removeFromSuperview()
        }
        XCTAssertNil(releasedSubview)
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

        XCTAssertTrue(ivarNames.contains("persistentSubview"))
        XCTAssertFalse(ivarNames.contains("danglingSubview"))
    }

    @MainActor
    func testSnapshotBuilderIncludesControlTargetAndActionInDetail() throws {
        final class ControlTarget: NSObject {
            @objc func handlePress(_ sender: Any?) {}
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Control Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }

        let button = NSButton(title: "Press", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 120, height: 32)
        let target = ControlTarget()
        button.target = target
        button.action = #selector(ControlTarget.handlePress(_:))

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
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

        let (_, context) = builder.makeCapture()
        let buttonID = try XCTUnwrap(context.nodeReferences.first(where: { _, reference in
            guard case .view(let capturedView) = reference else { return false }
            return capturedView === button
        })?.key)
        let detail = try XCTUnwrap(builder.makeDetail(for: buttonID, in: context))

        XCTAssertTrue(propertyValue(titled: "Target", in: detail.sections)?.contains("ControlTarget") == true)
        XCTAssertEqual(propertyValue(titled: "Action", in: detail.sections), "handlePress:")
    }

    @MainActor
    func testSnapshotBuilderCapturesEventHandlersForControlsAndGestures() throws {
        final class ControlTarget: NSObject {
            @objc func handlePress(_ sender: Any?) {}
            @objc func handleTap(_ sender: Any?) {}
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Handlers Fixture"
        defer {
            window.orderOut(nil)
            window.close()
        }

        let target = ControlTarget()
        let button = NSButton(title: "Press", target: target, action: #selector(ControlTarget.handlePress(_:)))
        button.frame = NSRect(x: 20, y: 20, width: 120, height: 32)

        let gesture = NSClickGestureRecognizer(target: target, action: #selector(ControlTarget.handleTap(_:)))
        gesture.isEnabled = true
        button.addGestureRecognizer(gesture)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
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

        let (capture, context) = builder.makeCapture()
        let buttonID = try XCTUnwrap(context.nodeReferences.first(where: { _, reference in
            guard case .view(let capturedView) = reference else { return false }
            return capturedView === button
        })?.key)
        let node = try XCTUnwrap(capture.nodes[buttonID])
        let handlers = try XCTUnwrap(node.eventHandlers)

        XCTAssertGreaterThanOrEqual(handlers.count, 2)

        let controlHandler = try XCTUnwrap(handlers.first(where: { $0.kind == .controlAction }))
        XCTAssertEqual(controlHandler.title, "handlePress:")
        XCTAssertEqual(controlHandler.targetActions.first?.actionName, "handlePress:")
        XCTAssertTrue(controlHandler.targetActions.first?.targetClassName?.contains("ControlTarget") == true)

        let gestureHandler = try XCTUnwrap(handlers.first(where: { $0.kind == .gesture }))
        XCTAssertEqual(gestureHandler.title, "NSClickGestureRecognizer")
        XCTAssertEqual(gestureHandler.targetActions.first?.actionName, "handleTap:")
        XCTAssertTrue(gestureHandler.targetActions.first?.targetClassName?.contains("ControlTarget") == true)
        XCTAssertEqual(gestureHandler.isEnabled, true)
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
        guard let node = capture.nodes.values.first(where: { $0.title == "First Second" }) else {
            return XCTFail("Expected a sanitized text node")
        }

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

    private func podspecURLs(filePath: StaticString = #filePath) -> [URL] {
        let packageRootURL = URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let nestedPodspecURL = packageRootURL.appendingPathComponent("ViewScopeServer.podspec")
        let repositoryPodspecURL = packageRootURL
            .deletingLastPathComponent()
            .appendingPathComponent("ViewScopeServer.podspec")

        return [nestedPodspecURL, repositoryPodspecURL].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func propertyValue(titled title: String, in sections: [ViewScopePropertySection]) -> String? {
        sections
            .flatMap(\.items)
            .first(where: { $0.title == title })?
            .value
    }

    private func makeHostInfo() -> ViewScopeHostInfo {
        ViewScopeHostInfo(
            displayName: "Fixture",
            bundleIdentifier: "fixture.tests",
            version: "1.0",
            build: "1",
            processIdentifier: 1,
            runtimeVersion: viewScopeServerRuntimeVersion,
            supportsHighlighting: true
        )
    }
}

private final class FlippedFixtureView: NSView {
    override var isFlipped: Bool {
        true
    }
}
