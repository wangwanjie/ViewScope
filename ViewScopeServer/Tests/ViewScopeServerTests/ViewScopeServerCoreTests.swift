#if os(macOS)
import AppKit
import Darwin
import Network
import XCTest
@testable import ViewScopeServer

/// 共享核心（数值转换、console、协议处理、端口监听）与 AppKit 路由相关的测试。
final class ViewScopeServerCoreTests: XCTestCase {
    // MARK: - 数值与颜色

    func testNumberConversionRejectsNonFiniteAndOutOfRangeValues() {
        XCTAssertThrowsError(try ViewScopeNumberConversion.int(nil))
        XCTAssertThrowsError(try ViewScopeNumberConversion.int(.nan))
        XCTAssertThrowsError(try ViewScopeNumberConversion.int(.infinity))
        XCTAssertThrowsError(try ViewScopeNumberConversion.int(1e30))
        XCTAssertThrowsError(try ViewScopeNumberConversion.int(-1e30))
        XCTAssertThrowsError(try ViewScopeNumberConversion.uint(-1))
        XCTAssertThrowsError(try ViewScopeNumberConversion.uint(1e30))
        XCTAssertThrowsError(try ViewScopeNumberConversion.cgFloat(.nan))
        XCTAssertThrowsError(try ViewScopeNumberConversion.cgFloat(1e30))
        XCTAssertEqual(try ViewScopeNumberConversion.int(3), 3)
        XCTAssertEqual(try ViewScopeNumberConversion.int(-2.4), -2)
        XCTAssertEqual(try ViewScopeNumberConversion.uint(7), 7)
        XCTAssertEqual(try ViewScopeNumberConversion.cgFloat(12.5), 12.5)
        XCTAssertEqual(try ViewScopeNumberConversion.unitInterval(4), 1)
        XCTAssertEqual(ViewScopeNumberConversion.finite(.nan), 0)
    }

    func testColorParsingRoundTrip() throws {
        let rgba = try XCTUnwrap(ViewScopeColorParsing.rgba(fromHex: "#FF000080"))
        XCTAssertEqual(rgba.red, 1, accuracy: 0.001)
        XCTAssertEqual(rgba.green, 0, accuracy: 0.001)
        XCTAssertEqual(rgba.alpha, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertNotNil(ViewScopeColorParsing.rgba(fromHex: "336699"))
        XCTAssertNil(ViewScopeColorParsing.rgba(fromHex: "#12"))
        XCTAssertNil(ViewScopeColorParsing.rgba(fromHex: "#GGGGGG"))
        XCTAssertEqual(ViewScopeColorParsing.hexString(red: 1, green: 0.5, blue: 0, alpha: 1), "#FF8000FF")
        let color = try XCTUnwrap(ViewScopeColorParsing.cgColor(fromHex: "#336699CC"))
        XCTAssertEqual(ViewScopeColorParsing.hexString(from: color), "#336699CC")
    }

    @MainActor
    func testEnumMutationsRejectTrappingAndUnknownValues() {
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        for value in [-1, 1e30, .nan, 99] as [Double] {
            XCTAssertThrowsError(
                try ViewScopeMutationApplier.apply(.number(key: "imageView.imageScaling", value: value), to: imageView as NSView)
            ) { error in
                XCTAssertEqual(error as? ViewScopeMutationError, .invalidValue)
            }
        }
        XCTAssertNoThrow(
            try ViewScopeMutationApplier.apply(
                .number(key: "imageView.imageScaling", value: Double(NSImageScaling.scaleNone.rawValue)),
                to: imageView as NSView
            )
        )
        XCTAssertEqual(imageView.imageScaling, .scaleNone)

        let textField = NSTextField(frame: .zero)
        XCTAssertThrowsError(try ViewScopeMutationApplier.apply(.number(key: "textField.maximumNumberOfLines", value: .infinity), to: textField as NSView))
        XCTAssertThrowsError(try ViewScopeMutationApplier.apply(.number(key: "frame.x", value: .nan), to: textField as NSView))
    }

    // MARK: - 节点 ID 与弱引用

    func testNodeIdentityUsesKindAndLowercaseAddress() {
        let object = NSObject()
        let address = ViewScopeNodeIdentity.address(of: object)
        XCTAssertTrue(address.hasPrefix("0x"))
        XCTAssertEqual(address, address.lowercased())
        XCTAssertEqual(ViewScopeNodeIdentity.nodeID(kind: .layer, object: object), "layer-\(address)")
        XCTAssertEqual(ViewScopeNodeIdentity.parseAddress("0x0000" + address.dropFirst(2)), ViewScopeNodeIdentity.parseAddress(address))
        XCTAssertTrue(ViewScopeNodeIdentity.address(address, matches: object))
        XCTAssertFalse(ViewScopeNodeIdentity.address("0x1", matches: object))
    }

    @MainActor
    func testCaptureNodeIDsAreStableAcrossCaptures() throws {
        let fixture = makeWindowFixture()
        defer {
            fixture.close()
        }

        let builder = ViewScopeSnapshotBuilder(hostInfo: makeHostInfo())
        // 窗口第一次显示后 AppKit 才会把视图 layer-backing，节点会从 view 变成 layer；先抓一次预热。
        _ = builder.makeCapture()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let (first, _) = builder.makeCapture()
        let (second, _) = builder.makeCapture()
        let markerLayer = try XCTUnwrap(fixture.button.layer)
        let expectedID = ViewScopeNodeIdentity.nodeID(kind: .layer, object: markerLayer)

        XCTAssertNotNil(first.nodes[expectedID])
        XCTAssertNotNil(second.nodes[expectedID])
        // 夹具窗口子树里的节点 ID 在两次抓取间完全一致。
        let windowID = ViewScopeNodeIdentity.nodeID(kind: .window, object: fixture.window)
        func subtree(_ capture: ViewScopeCapturePayload) -> Set<String> {
            var result = Set<String>()
            var pending = [windowID]
            while let next = pending.popLast() {
                guard let node = capture.nodes[next], result.insert(next).inserted else {
                    continue
                }
                pending.append(contentsOf: node.childIDs)
            }
            return result
        }
        XCTAssertGreaterThan(subtree(first).count, 2)
        XCTAssertEqual(subtree(first), subtree(second))
        XCTAssertTrue(first.rootNodeIDs.allSatisfy { $0.hasPrefix("window-0x") })
    }

    @MainActor
    func testReferenceContextDoesNotRetainCapturedObjects() {
        weak var releasedView: NSView?
        var context = ViewScopeSnapshotBuilder.ReferenceContext(nodeReferences: [:], rootNodeIDs: [], captureID: "weak")
        autoreleasepool {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            releasedView = view
            context.nodeReferences["node"] = .view(view)
        }

        XCTAssertNil(releasedView)
        XCTAssertNil(context.nodeReferences["node"]?.resolvedObject)
        let builder = ViewScopeSnapshotBuilder(hostInfo: makeHostInfo())
        XCTAssertNil(builder.makeDetail(for: "node", in: context))
        XCTAssertThrowsError(try ViewScopeMutationApplier.apply(.toggle(key: "hidden", value: true), to: context.nodeReferences["node"]!)) { error in
            XCTAssertEqual(error as? ViewScopeMutationError, .targetDeallocated)
        }
    }

    // MARK: - 带宿主视图的 layer 节点（B1 / B2）

    @MainActor
    func testHostedLayerNodeUsesHostViewSectionsAndRoutesMutations() throws {
        let fixture = makeWindowFixture()
        defer {
            fixture.close()
        }
        let layer = try XCTUnwrap(fixture.button.layer)
        let reference = ViewScopeInspectableReference.layer(layer)
        let context = ViewScopeSnapshotBuilder.ReferenceContext(nodeReferences: ["button": reference], rootNodeIDs: [], captureID: "routing")
        let builder = ViewScopeSnapshotBuilder(hostInfo: makeHostInfo())
        let detail = try XCTUnwrap(builder.makeDetail(for: "button", in: context))
        let keys = Set(detail.sections.flatMap(\.items).compactMap { $0.editable?.key })

        // 宿主视图的控件分区与 layer 专属项同时出现。
        XCTAssertTrue(keys.contains("button.title"))
        XCTAssertTrue(keys.contains("enabled"))
        XCTAssertTrue(keys.contains("layer.masksToBounds"))
        XCTAssertTrue(keys.contains("layer.shadowOpacity"))
        XCTAssertTrue(keys.contains("layer.borderColor"))
        // 约束取自宿主视图。
        XCTAssertTrue(detail.constraints.contains(where: { $0.contains("width") }))
        // 枚举项带候选值。
        let bezelItem = try XCTUnwrap(detail.sections.flatMap(\.items).first(where: { $0.editable?.key == "button.bezelStyle" }))
        XCTAssertFalse(bezelItem.editable?.options?.isEmpty ?? true)

        // 视图级 key 路由到宿主视图，layer.* 作用于 layer。
        try ViewScopeMutationApplier.apply(.toggle(key: "hidden", value: true), to: reference)
        try ViewScopeMutationApplier.apply(.number(key: "alpha", value: 0.5), to: reference)
        try ViewScopeMutationApplier.apply(.text(key: "button.title", value: "Routed"), to: reference)
        try ViewScopeMutationApplier.apply(.number(key: "layer.cornerRadius", value: 7), to: reference)
        try ViewScopeMutationApplier.apply(.toggle(key: "layer.masksToBounds", value: true), to: reference)
        try ViewScopeMutationApplier.apply(.number(key: "layer.shadowOpacity", value: 0.3), to: reference)
        try ViewScopeMutationApplier.apply(.text(key: "layer.borderColor", value: "#FF0000FF"), to: reference)

        XCTAssertTrue(fixture.button.isHidden)
        XCTAssertEqual(fixture.button.alphaValue, 0.5, accuracy: 0.001)
        XCTAssertEqual(fixture.button.title, "Routed")
        XCTAssertEqual(layer.cornerRadius, 7, accuracy: 0.001)
        XCTAssertTrue(layer.masksToBounds)
        XCTAssertEqual(layer.shadowOpacity, 0.3, accuracy: 0.001)
        XCTAssertEqual(ViewScopeColorParsing.hexString(from: layer.borderColor), "#FF0000FF")
    }

    @MainActor
    func testBackgroundColorCanBeSetFromNone() throws {
        let fixture = makeWindowFixture()
        defer {
            fixture.close()
        }
        let plain = fixture.plainView
        XCTAssertNil(plain.layer?.backgroundColor)

        let builder = ViewScopeSnapshotBuilder(hostInfo: makeHostInfo())
        let context = ViewScopeSnapshotBuilder.ReferenceContext(nodeReferences: ["plain": .view(plain)], rootNodeIDs: [], captureID: "bg")
        let detail = try XCTUnwrap(builder.makeDetail(for: "plain", in: context))
        XCTAssertTrue(detail.sections.flatMap(\.items).contains(where: { $0.editable?.key == "backgroundColor" }))

        try ViewScopeMutationApplier.apply(.text(key: "backgroundColor", value: "#00FF00FF"), to: plain)
        XCTAssertEqual(ViewScopeColorParsing.hexString(from: plain.layer?.backgroundColor), "#00FF00FF")
        try ViewScopeMutationApplier.apply(.text(key: "backgroundColor", value: ""), to: plain)
        XCTAssertNil(plain.layer?.backgroundColor)
    }

    @MainActor
    func testScrollViewDetailExposesContentInsets() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let builder = ViewScopeSnapshotBuilder(hostInfo: makeHostInfo())
        let context = ViewScopeSnapshotBuilder.ReferenceContext(nodeReferences: ["scroll": .view(scrollView)], rootNodeIDs: [], captureID: "insets")
        let detail = try XCTUnwrap(builder.makeDetail(for: "scroll", in: context))
        let keys = Set(detail.sections.flatMap(\.items).compactMap { $0.editable?.key })
        XCTAssertTrue(keys.isSuperset(of: ["contentInsets.top", "contentInsets.left", "contentInsets.bottom", "contentInsets.right"]))
    }

    @MainActor
    func testLocalizedSectionTitlesUsePlatformTable() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let builder = ViewScopeSnapshotBuilder(hostInfo: makeHostInfo(), interfaceLanguage: .simplifiedChinese)
        let context = ViewScopeSnapshotBuilder.ReferenceContext(nodeReferences: ["scroll": .view(scrollView)], rootNodeIDs: [], captureID: "l10n")
        let detail = try XCTUnwrap(builder.makeDetail(for: "scroll", in: context))
        XCTAssertTrue(detail.sections.contains(where: { $0.title == "滚动视图" }))
        XCTAssertFalse(detail.sections.flatMap(\.items).contains(where: { $0.title.hasPrefix("server.") }))
        XCTAssertEqual(ViewScopeInterfaceLanguage.english.text("server.item.bounds_width"), "Bounds Width")
    }

    // MARK: - Console 解析

    func testConsoleParserParsesSupportedGrammar() throws {
        XCTAssertEqual(
            try ViewScopeConsoleParser.parse("frame"),
            ViewScopeConsoleExpression(keyPath: [], selector: "frame", arguments: [])
        )
        XCTAssertEqual(
            try ViewScopeConsoleParser.parse("layer.superlayer.setCornerRadius:4.5"),
            ViewScopeConsoleExpression(keyPath: ["layer", "superlayer"], selector: "setCornerRadius:", arguments: [.number(4.5)])
        )
        XCTAssertEqual(
            try ViewScopeConsoleParser.parse("insertSubview:@0x1234 atIndex:-1"),
            ViewScopeConsoleExpression(keyPath: [], selector: "insertSubview:atIndex:", arguments: [.objectReference("0x1234"), .number(-1)])
        )
        XCTAssertEqual(
            try ViewScopeConsoleParser.parse("setFrame:{0, 0, 100, 40};"),
            ViewScopeConsoleExpression(keyPath: [], selector: "setFrame:", arguments: [.structValue([0, 0, 100, 40])])
        )
        XCTAssertEqual(
            try ViewScopeConsoleParser.parse(#"setTitle:"a \"b\" \\ c""#).arguments,
            [.string(#"a "b" \ c"#)]
        )
        XCTAssertEqual(try ViewScopeConsoleParser.parse("setHidden:YES").arguments, [.bool(true)])
        XCTAssertEqual(try ViewScopeConsoleParser.parse("setHidden:false").arguments, [.bool(false)])
        XCTAssertEqual(try ViewScopeConsoleParser.parse("setDelegate:nil").arguments, [.null])
        XCTAssertEqual(try ViewScopeConsoleParser.parse("setTag:0x10").arguments, [.number(16)])
        XCTAssertEqual(try ViewScopeConsoleParser.parse("setAlphaValue:1e-1").arguments, [.number(0.1)])
        XCTAssertEqual(
            try ViewScopeConsoleParser.parse("setBackgroundColor:#FF000080").arguments,
            [.color(red: 1, green: 0, blue: 0, alpha: 128.0 / 255.0)]
        )
    }

    func testConsoleParserReportsErrors() {
        for expression in ["", "setHidden:", "foo bar", "setFrame:{1, 2, 3}", "setTitle:\"open", "setColor:#12", "a..b", "set:YES extra"] {
            XCTAssertThrowsError(try ViewScopeConsoleParser.parse(expression), expression)
        }
    }

    @MainActor
    func testConsoleDenylistFollowsOwnershipNaming() {
        for selector in ["dealloc", "release", "retain", "autorelease", "retainCount", "zone", "init", "initWithFrame:", "new", "newObject", "copy", "copyWithZone:", "mutableCopy", "performSelector:withObject:"] {
            XCTAssertTrue(ViewScopeConsoleEvaluator.isDenied(selector: selector), selector)
        }
        for selector in ["self", "frame", "initialFirstResponder", "copyright", "newline", "setHidden:"] {
            XCTAssertFalse(ViewScopeConsoleEvaluator.isDenied(selector: selector), selector)
        }
    }

    // MARK: - Console 执行

    @MainActor
    func testConsoleEvaluatorInvokesMethodsWithArgumentsAndKeyPaths() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let child = NSView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
        child.wantsLayer = true
        root.addSubview(child)
        window.contentView = root
        defer {
            window.contentView = nil
        }

        let nodeID = ViewScopeNodeIdentity.nodeID(kind: .view, object: child)
        let context = ViewScopeSnapshotBuilder.ReferenceContext(nodeReferences: [nodeID: .view(child)], rootNodeIDs: [], captureID: "console")
        let target = ViewScopeRemoteObjectReference(
            captureID: "console",
            objectID: ViewScopeNodeIdentity.address(of: child),
            kind: .view,
            className: "NSView",
            sourceNodeID: nodeID
        )
        let evaluator = ViewScopeConsoleEvaluator()

        func run(_ expression: String, on reference: ViewScopeRemoteObjectReference? = nil) -> ViewScopeConsoleInvokeResponsePayload {
            evaluator.evaluate(
                ViewScopeConsoleInvokeRequestPayload(target: reference ?? target, expression: expression),
                context: context,
                language: .english
            )
        }

        XCTAssertEqual(run("setHidden:YES").resultDescription, "void")
        XCTAssertTrue(child.isHidden)
        XCTAssertEqual(run("isHidden").resultDescription, "YES")
        XCTAssertEqual(run("setFrame:{1, 2, 30, 40}").resultDescription, "void")
        XCTAssertEqual(child.frame, NSRect(x: 1, y: 2, width: 30, height: 40))
        XCTAssertEqual(run("frame").resultDescription, "(CGRect) {{1, 2}, {30, 40}}")
        XCTAssertEqual(run("layer.setCornerRadius:6").resultDescription, "void")
        XCTAssertEqual(child.layer?.cornerRadius ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(run("setToolTip:\"tip\"").resultDescription, "void")
        XCTAssertEqual(child.toolTip, "tip")
        XCTAssertEqual(run("toolTip").resultDescription, "\"tip\"")

        // 返回对象进入缓存，可以作为后续 target 与 @ 引用。
        let superviewResponse = run("superview")
        let returned = try XCTUnwrap(superviewResponse.returnedObject)
        XCTAssertEqual(returned.reference.kind, .returnedObject)
        XCTAssertEqual(returned.reference.objectID, ViewScopeNodeIdentity.address(of: root))
        XCTAssertEqual(run("subviews.count", on: returned.reference).resultDescription, "1")
        XCTAssertNil(run("addSubview:@\(ViewScopeNodeIdentity.address(of: child))", on: returned.reference).errorMessage)

        // 错误都通过 errorMessage 返回，不会让宿主崩溃。
        XCTAssertNotNil(run("dealloc").errorMessage)
        XCTAssertNotNil(run("noSuchMethod").errorMessage)
        XCTAssertNotNil(run("setHidden:").errorMessage)
        XCTAssertNotNil(run("addSubview:@0x1").errorMessage)
        XCTAssertNotNil(run("setFrame:\"oops\"").errorMessage)
        XCTAssertNotNil(run("objectAtIndex:0", on: returned.reference).errorMessage)
        let missingTarget = ViewScopeRemoteObjectReference(captureID: "console", objectID: "0x1", kind: .returnedObject, className: "NSView")
        XCTAssertNotNil(run("frame", on: missingTarget).errorMessage)
    }

    @MainActor
    func testConsoleCatchesObjectiveCExceptions() {
        let array = NSArray(array: [1, 2])
        let evaluator = ViewScopeConsoleEvaluator()
        let objectID = evaluator.cacheObject(array)
        let reference = ViewScopeRemoteObjectReference(captureID: "x", objectID: objectID, kind: .returnedObject, className: "NSArray")
        let response = evaluator.evaluate(
            ViewScopeConsoleInvokeRequestPayload(target: reference, expression: "objectAtIndex:10"),
            context: .init(nodeReferences: [:], rootNodeIDs: [], captureID: "x"),
            language: .english
        )
        XCTAssertTrue(response.errorMessage?.contains("NSRangeException") ?? false, response.errorMessage ?? "nil")
    }

    @MainActor
    func testConsoleDescribesBooleansAndNumbersDistinctly() {
        XCTAssertEqual(ViewScopeConsoleEvaluator.describe(NSNumber(value: 1)), "1")
        XCTAssertEqual(ViewScopeConsoleEvaluator.describe(NSNumber(value: 0)), "0")
        XCTAssertEqual(ViewScopeConsoleEvaluator.describe(kCFBooleanTrue), "true")
        XCTAssertEqual(ViewScopeConsoleEvaluator.describe("text" as NSString), "\"text\"")
    }

    @MainActor
    func testConsoleCacheIsBoundedLRU() {
        let evaluator = ViewScopeConsoleEvaluator()
        var objects: [NSObject] = []
        for _ in 0 ..< 70 {
            let object = NSObject()
            objects.append(object)
            evaluator.cacheObject(object)
        }
        XCTAssertEqual(evaluator.cachedObjectCount, ViewScopeConsoleEvaluator.cacheLimit)
        XCTAssertNil(evaluator.cachedObject(for: ViewScopeNodeIdentity.address(of: objects[0])))
        XCTAssertNotNil(evaluator.cachedObject(for: ViewScopeNodeIdentity.address(of: objects[69])))
        evaluator.reset()
        XCTAssertEqual(evaluator.cachedObjectCount, 0)
    }

    @MainActor
    func testConsoleCompletionsListPropertiesFirstAndFilterByPrefix() {
        let button = NSButton(title: "Title", target: nil, action: nil)
        let completions = ViewScopeConsoleEvaluator.completions(for: button, prefix: "TIT", limit: 500)
        XCTAssertTrue(completions.contains(where: { $0.name == "title" && $0.isProperty }))
        XCTAssertTrue(completions.allSatisfy { $0.name.lowercased().hasPrefix("tit") })
        if let firstMethod = completions.firstIndex(where: { $0.isProperty == false }),
           let lastProperty = completions.lastIndex(where: { $0.isProperty }) {
            XCTAssertLessThan(lastProperty, firstMethod)
        }
        let setters = ViewScopeConsoleEvaluator.completions(for: button, prefix: "setTitle", limit: 500)
        XCTAssertTrue(setters.contains(where: { $0.name == "setTitle:" && $0.signature.contains("NSString") == false }))
        XCTAssertFalse(ViewScopeConsoleEvaluator.completions(for: button, prefix: nil, limit: 500).contains(where: { $0.name == "dealloc" }))
        XCTAssertLessThanOrEqual(ViewScopeConsoleEvaluator.completions(for: button, prefix: nil, limit: 500).count, 500)
    }

    // MARK: - 消息处理（认证、发现、版本协商、恰好一条响应）

    @MainActor
    func testUnauthenticatedChannelOnlyAllowsHelloDiscoveryAndPing() throws {
        let inspector = makeInspector()
        let channel = MockChannel()

        inspector.handle(message: ViewScopeMessage(kind: .captureRequest, requestID: "c1"), from: channel)
        inspector.handle(message: ViewScopeMessage(kind: .ping, requestID: "p1"), from: channel)
        inspector.handle(message: ViewScopeMessage(kind: .discoveryRequest, requestID: "d1"), from: channel)

        XCTAssertEqual(channel.sent.map(\.kind), [.error, .ack, .discoveryResponse])
        XCTAssertEqual(channel.sent.map(\.requestID), ["c1", "p1", "d1"])
        XCTAssertEqual(channel.sent[2].announcement?.authToken, "token")
        XCTAssertFalse(channel.isCancelled)
    }

    @MainActor
    func testHandshakeNegotiatesVersionAndRejectsBadClients() throws {
        let inspector = makeInspector()

        let legacy = MockChannel()
        inspector.handle(message: hello(token: "token", version: 2, requestID: "h2"), from: legacy)
        let legacyHello = try XCTUnwrap(legacy.sent.first?.serverHello)
        XCTAssertEqual(legacyHello.protocolVersion, 2)
        XCTAssertEqual(legacyHello.host.protocolVersion, 2)
        XCTAssertEqual(legacyHello.host.platform, .macOS)
        XCTAssertTrue(legacy.isAuthenticated)

        let tooOld = MockChannel()
        inspector.handle(message: hello(token: "token", version: 1, requestID: "h1"), from: tooOld)
        XCTAssertEqual(tooOld.sent.map(\.kind), [.error])
        XCTAssertTrue(tooOld.isCancelled)
        XCTAssertFalse(legacy.isCancelled)

        let wrongToken = MockChannel()
        inspector.handle(message: hello(token: "nope", version: 3, requestID: "hx"), from: wrongToken)
        XCTAssertEqual(wrongToken.sent.map(\.kind), [.error])
        XCTAssertTrue(wrongToken.isCancelled)
        XCTAssertFalse(legacy.isCancelled)
    }

    @MainActor
    func testProbeConnectionDoesNotReplaceSessionButNewAuthenticatedOneDoes() {
        let inspector = makeInspector()
        let first = MockChannel()
        inspector.handle(message: hello(token: "token", version: 3, requestID: "a"), from: first)
        XCTAssertTrue(inspector.activeSession === first)

        let probe = MockChannel()
        inspector.handle(message: ViewScopeMessage(kind: .discoveryRequest, requestID: "probe"), from: probe)
        XCTAssertTrue(inspector.activeSession === first)
        XCTAssertFalse(first.isCancelled)

        let second = MockChannel()
        inspector.handle(message: hello(token: "token", version: 3, requestID: "b"), from: second)
        XCTAssertTrue(inspector.activeSession === second)
        XCTAssertTrue(first.isCancelled)
        XCTAssertEqual(second.sent.first?.serverHello?.protocolVersion, 3)
    }

    @MainActor
    func testEveryRequestGetsExactlyOneResponse() {
        let inspector = makeInspector()
        let channel = MockChannel()
        inspector.handle(message: hello(token: "token", version: 3, requestID: "hello"), from: channel)
        channel.sent.removeAll()

        let requests: [ViewScopeMessage] = [
            ViewScopeMessage(kind: .nodeDetailRequest, requestID: "1"),
            ViewScopeMessage(kind: .nodeDetailRequest, requestID: "2", nodeRequest: .init(nodeID: "missing")),
            ViewScopeMessage(kind: .highlightRequest, requestID: "3", highlightRequest: .init(nodeID: "missing", duration: 1)),
            ViewScopeMessage(kind: .mutationRequest, requestID: "4", mutationRequest: .init(nodeID: "missing", property: .toggle(key: "hidden", value: true))),
            ViewScopeMessage(kind: .consoleInvokeRequest, requestID: "5"),
            ViewScopeMessage(kind: .consoleCompletionRequest, requestID: "6"),
            ViewScopeMessage(kind: .ack, requestID: "7"),
            ViewScopeMessage(kind: .serverHello, requestID: "8"),
            ViewScopeMessage(kind: .ping, requestID: "9"),
            ViewScopeMessage(
                kind: .consoleInvokeRequest,
                requestID: "10",
                consoleInvokeRequest: .init(
                    target: .init(captureID: "", objectID: "0x1", kind: .view, className: "NSView", sourceNodeID: "missing"),
                    expression: "frame"
                )
            )
        ]
        for request in requests {
            inspector.handle(message: request, from: channel)
        }

        XCTAssertEqual(channel.sent.map(\.requestID), requests.map(\.requestID))
        XCTAssertEqual(channel.sent.map(\.kind), [.error, .error, .error, .error, .error, .error, .error, .error, .ack, .consoleInvokeResponse])
        XCTAssertNotNil(channel.sent.last?.consoleInvokeResponse?.errorMessage)
    }

    @MainActor
    func testAnnouncementCarriesPlatformMetadata() {
        let inspector = Inspector()
        let announcement = inspector.makeAnnouncement(port: 47300)
        XCTAssertEqual(announcement.port, 47300)
        XCTAssertEqual(announcement.platform, .macOS)
        XCTAssertEqual(announcement.isSimulator, false)
        XCTAssertNotNil(announcement.osVersion)
        XCTAssertNotNil(announcement.deviceModel)
        XCTAssertEqual(announcement.protocolVersion, viewScopeCurrentProtocolVersion)
    }

    // MARK: - 编解码

    func testEncodingSanitizesNonFiniteNumbers() throws {
        let node = ViewScopeHierarchyNode(
            id: "n",
            parentID: nil,
            kind: .view,
            className: "NSView",
            title: "n",
            subtitle: nil,
            frame: ViewScopeRect(x: .nan, y: .infinity, width: 1, height: 2),
            bounds: .zero,
            childIDs: [],
            isHidden: false,
            alphaValue: .nan,
            wantsLayer: false,
            isFlipped: false,
            clippingEnabled: false,
            depth: 0
        )
        let capture = ViewScopeCapturePayload(
            host: makeHostInfo(),
            capturedAt: Date(),
            summary: .init(nodeCount: 1, windowCount: 0, visibleWindowCount: 0, captureDurationMilliseconds: 0),
            rootNodeIDs: ["n"],
            nodes: ["n": node]
        )
        let data = try XCTUnwrap(ViewScopeMessageCoding.encode(ViewScopeMessage(kind: .captureResponse, requestID: "r", capture: capture)))
        let decoded = try ViewScopeMessageCoding.decode(data)
        XCTAssertEqual(decoded.capture?.nodes["n"]?.frame.x, 0)
        XCTAssertEqual(decoded.capture?.nodes["n"]?.frame.y, 0)
        XCTAssertEqual(decoded.capture?.nodes["n"]?.frame.height, 2)
        XCTAssertEqual(decoded.capture?.nodes["n"]?.alphaValue, 0)
    }

    func testRequestIDIsExtractedFromUndecodableLines() {
        XCTAssertEqual(ViewScopeMessageCoding.extractRequestID(from: Data(#"{"kind":"bogus","requestID":"abc"}"#.utf8)), "abc")
        XCTAssertNil(ViewScopeMessageCoding.extractRequestID(from: Data("not json".utf8)))
        XCTAssertThrowsError(try ViewScopeMessageCoding.decode(Data(#"{"kind":"bogus","requestID":"abc"}"#.utf8)))
    }

    // MARK: - 端口段监听

    @MainActor
    func testPortRangeListenerSkipsOccupiedPorts() async throws {
        let basePort = UInt16(48_000 + Int.random(in: 0 ..< 500) * 2)
        let blocker = try XCTUnwrap(Self.occupyLoopbackPort(basePort))
        defer {
            close(blocker)
        }

        let ready = expectation(description: "listener ready")
        var boundPort: UInt16?
        let listener = ViewScopePortRangeListener(
            ports: basePort ... basePort + 1,
            fallback: .none,
            newConnectionHandler: { connection in
                connection.cancel()
            },
            onReady: { port in
                boundPort = port
                ready.fulfill()
            },
            onFailure: {
                ready.fulfill()
            }
        )
        listener.start()
        await fulfillment(of: [ready], timeout: 10)
        listener.cancel()
        XCTAssertEqual(boundPort, basePort + 1)
    }

    /// 用 BSD socket 占住 127.0.0.1 上的端口。
    private static func occupyLoopbackPort(_ port: UInt16) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return nil
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    // MARK: - 工具

    @MainActor
    private func makeInspector() -> Inspector {
        let inspector = Inspector()
        inspector.configureForTesting(announcement: inspector.makeAnnouncement(port: 47300).withToken("token"))
        return inspector
    }

    private func hello(token: String, version: Int, requestID: String) -> ViewScopeMessage {
        ViewScopeMessage(
            kind: .clientHello,
            requestID: requestID,
            clientHello: ViewScopeClientHelloPayload(authToken: token, clientName: "Tests", clientVersion: "1", protocolVersion: version)
        )
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

    @MainActor
    private func makeWindowFixture() -> CoreWindowFixture {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        root.wantsLayer = true
        let button = NSButton(title: "Press", target: nil, action: nil)
        button.wantsLayer = true
        button.translatesAutoresizingMaskIntoConstraints = false
        let plainView = NSView(frame: NSRect(x: 200, y: 20, width: 40, height: 40))
        root.addSubview(button)
        root.addSubview(plainView)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            button.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            button.widthAnchor.constraint(equalToConstant: 120)
        ])
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        return CoreWindowFixture(window: window, button: button, plainView: plainView)
    }
}

@MainActor
private struct CoreWindowFixture {
    let window: NSWindow
    let button: NSButton
    let plainView: NSView

    func close() {
        window.contentView = nil
        CATransaction.flush()
        window.orderOut(nil)
        CATransaction.flush()
        serverWindowPool.append(window)
    }
}

/// 记录发送内容的假连接。
@MainActor
private final class MockChannel: ViewScopeMessageChannel {
    var isAuthenticated = false
    var negotiatedProtocolVersion = viewScopeCurrentProtocolVersion
    var interfaceLanguage = ViewScopeInterfaceLanguage.english
    var sent: [ViewScopeMessage] = []
    var isCancelled = false

    func send(_ message: ViewScopeMessage) {
        sent.append(message)
    }

    func cancel() {
        isCancelled = true
    }
}

private extension ViewScopeHostAnnouncement {
    func withToken(_ token: String) -> ViewScopeHostAnnouncement {
        var copy = self
        copy.authToken = token
        return copy
    }
}
#endif
