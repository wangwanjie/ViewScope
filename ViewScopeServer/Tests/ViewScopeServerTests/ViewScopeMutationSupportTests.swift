import AppKit
import XCTest
@testable import ViewScopeServer

// Windows ordered-out by mutation fixtures stay here for the process lifetime so the
// NSWindow objects (and their CA layers) remain alive whenever the render server sends
// its async completion callback for _NSWindowTransformAnimation (macOS 26 beta bug).
// Keeping the pool alive (never releasing it) means the acks can fire at any point
// during the server test RunLoop drains without accessing freed memory.
nonisolated(unsafe) var mutationFixtureWindowPool: [NSWindow] = []

final class ViewScopeMutationSupportTests: XCTestCase {
    @MainActor
    func testDetailPayloadMarksCurrentEditableProperties() throws {
        let fixture = makeFixture()
        defer { fixture.close() }

        let builder = makeBuilder()
        let context = makeReferenceContext(for: fixture)

        let inspectedDetail = try XCTUnwrap(builder.makeDetail(for: "inspected", in: context))
        let scrollDetail = try XCTUnwrap(builder.makeDetail(for: "scroll", in: context))
        let textFieldDetail = try XCTUnwrap(builder.makeDetail(for: "textField", in: context))

        let keys = editableKeys(in: [inspectedDetail, scrollDetail, textFieldDetail])

        XCTAssertTrue(keys.contains("hidden"))
        XCTAssertTrue(keys.contains("alpha"))
        XCTAssertTrue(keys.contains("frame.x"))
        XCTAssertTrue(keys.contains("frame.y"))
        XCTAssertTrue(keys.contains("frame.width"))
        XCTAssertTrue(keys.contains("frame.height"))
        XCTAssertTrue(keys.contains("bounds.x"))
        XCTAssertTrue(keys.contains("bounds.y"))
        XCTAssertTrue(keys.contains("bounds.width"))
        XCTAssertTrue(keys.contains("bounds.height"))
        XCTAssertTrue(keys.contains("contentInsets.top"))
        XCTAssertTrue(keys.contains("contentInsets.left"))
        XCTAssertTrue(keys.contains("contentInsets.bottom"))
        XCTAssertTrue(keys.contains("contentInsets.right"))
        XCTAssertTrue(keys.contains("backgroundColor"))
        XCTAssertTrue(keys.contains("control.value"))
    }

    @MainActor
    func testMutationsApplyForCurrentEditableProperties() throws {
        let fixture = makeFixture()
        defer { fixture.close() }

        try ViewScopeMutationApplier.apply(.toggle(key: "hidden", value: true), to: fixture.inspectedView)
        try ViewScopeMutationApplier.apply(.number(key: "alpha", value: 0.35), to: fixture.inspectedView)
        try ViewScopeMutationApplier.apply(.number(key: "frame.x", value: 18), to: fixture.inspectedView)
        try ViewScopeMutationApplier.apply(.number(key: "bounds.width", value: 210), to: fixture.inspectedView)
        try ViewScopeMutationApplier.apply(.number(key: "contentInsets.top", value: 14), to: fixture.scrollView)
        try ViewScopeMutationApplier.apply(.text(key: "backgroundColor", value: "#334455FF"), to: fixture.inspectedView)
        try ViewScopeMutationApplier.apply(.text(key: "control.value", value: "Changed"), to: fixture.textField)

        XCTAssertTrue(fixture.inspectedView.isHidden)
        XCTAssertEqual(fixture.inspectedView.alphaValue, 0.35, accuracy: 0.001)
        XCTAssertEqual(fixture.inspectedView.frame.origin.x, 18, accuracy: 0.001)
        XCTAssertEqual(fixture.inspectedView.bounds.width, 210, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.contentInsets.top, 14, accuracy: 0.001)
        XCTAssertEqual(hexString(for: fixture.inspectedView.layer?.backgroundColor), "#334455FF")
        XCTAssertEqual(fixture.textField.stringValue, "Changed")
    }

    @MainActor
    func testDetailPayloadMarksNewLowRiskEditableProperties() throws {
        let fixture = makeFixture()
        defer { fixture.close() }

        let builder = makeBuilder()
        let context = makeReferenceContext(for: fixture)

        let windowDetail = try XCTUnwrap(builder.makeDetail(for: "window", in: context))
        let inspectedDetail = try XCTUnwrap(builder.makeDetail(for: "inspected", in: context))
        let textFieldDetail = try XCTUnwrap(builder.makeDetail(for: "textField", in: context))
        let buttonDetail = try XCTUnwrap(builder.makeDetail(for: "button", in: context))

        let keys = editableKeys(in: [windowDetail, inspectedDetail, textFieldDetail, buttonDetail])

        XCTAssertTrue(keys.contains("title"))
        XCTAssertTrue(keys.contains("toolTip"))
        XCTAssertTrue(keys.contains("enabled"))
        XCTAssertTrue(keys.contains("button.state"))
        XCTAssertTrue(keys.contains("textField.placeholderString"))
        XCTAssertTrue(keys.contains("layer.cornerRadius"))
        XCTAssertTrue(keys.contains("layer.borderWidth"))
    }

    @MainActor
    func testMutationsApplyForNewLowRiskEditableProperties() throws {
        let fixture = makeFixture()
        defer { fixture.close() }

        try ViewScopeMutationApplier.apply(.text(key: "title", value: "Updated Window"), to: fixture.window)
        try ViewScopeMutationApplier.apply(.text(key: "toolTip", value: "Updated Tip"), to: fixture.inspectedView)
        try ViewScopeMutationApplier.apply(.toggle(key: "enabled", value: false), to: fixture.textField)
        try ViewScopeMutationApplier.apply(.toggle(key: "button.state", value: true), to: fixture.button)
        try ViewScopeMutationApplier.apply(.text(key: "textField.placeholderString", value: "Updated Placeholder"), to: fixture.textField)
        try ViewScopeMutationApplier.apply(.number(key: "layer.cornerRadius", value: 16), to: fixture.inspectedView)
        try ViewScopeMutationApplier.apply(.number(key: "layer.borderWidth", value: 3), to: fixture.inspectedView)

        XCTAssertEqual(fixture.window.title, "Updated Window")
        XCTAssertEqual(fixture.inspectedView.toolTip, "Updated Tip")
        XCTAssertFalse(fixture.textField.isEnabled)
        XCTAssertEqual(fixture.button.state, .on)
        XCTAssertEqual(fixture.textField.placeholderString, "Updated Placeholder")
        XCTAssertEqual(Double(fixture.inspectedView.layer?.cornerRadius ?? 0), 16, accuracy: 0.001)
        XCTAssertEqual(Double(fixture.inspectedView.layer?.borderWidth ?? 0), 3, accuracy: 0.001)
    }

    @MainActor
    func testDetailPayloadMarksLayerNodeEditablePropertiesAndConsoleTargets() throws {
        let fixture = makeFixture()
        defer { fixture.close() }

        let builder = makeBuilder()
        let context = makeReferenceContext(for: fixture)

        let detail = try XCTUnwrap(builder.makeDetail(for: "inspectedLayer", in: context))
        let keys = editableKeys(in: [detail])
        let targetKinds = Set(detail.consoleTargets.map(\.reference.kind))

        XCTAssertTrue(keys.contains("hidden"))
        XCTAssertTrue(keys.contains("alpha"))
        XCTAssertTrue(keys.contains("frame.x"))
        XCTAssertTrue(keys.contains("frame.y"))
        XCTAssertTrue(keys.contains("frame.width"))
        XCTAssertTrue(keys.contains("frame.height"))
        XCTAssertTrue(keys.contains("bounds.x"))
        XCTAssertTrue(keys.contains("bounds.y"))
        XCTAssertTrue(keys.contains("bounds.width"))
        XCTAssertTrue(keys.contains("bounds.height"))
        XCTAssertTrue(keys.contains("backgroundColor"))
        XCTAssertTrue(keys.contains("layer.cornerRadius"))
        XCTAssertTrue(keys.contains("layer.borderWidth"))
        XCTAssertTrue(targetKinds.contains(.layer))
        XCTAssertTrue(targetKinds.contains(.view))
    }

    @MainActor
    func testMutationsApplyForLayerNodeEditableProperties() throws {
        let fixture = makeFixture()
        defer { fixture.close() }

        let layer = try XCTUnwrap(fixture.inspectedView.layer)

        try ViewScopeMutationApplier.apply(.toggle(key: "hidden", value: true), to: .layer(layer))
        try ViewScopeMutationApplier.apply(.number(key: "alpha", value: 0.42), to: .layer(layer))
        try ViewScopeMutationApplier.apply(.number(key: "frame.x", value: 36), to: .layer(layer))
        try ViewScopeMutationApplier.apply(.number(key: "bounds.width", value: 180), to: .layer(layer))
        try ViewScopeMutationApplier.apply(.text(key: "backgroundColor", value: "#446688FF"), to: .layer(layer))
        try ViewScopeMutationApplier.apply(.number(key: "layer.cornerRadius", value: 18), to: .layer(layer))
        try ViewScopeMutationApplier.apply(.number(key: "layer.borderWidth", value: 4), to: .layer(layer))

        XCTAssertTrue(layer.isHidden)
        XCTAssertEqual(Double(layer.opacity), 0.42, accuracy: 0.001)
        XCTAssertEqual(layer.frame.origin.x, 36, accuracy: 0.001)
        XCTAssertEqual(layer.bounds.width, 180, accuracy: 0.001)
        XCTAssertEqual(hexString(for: layer.backgroundColor), "#446688FF")
        XCTAssertEqual(Double(layer.cornerRadius), 18, accuracy: 0.001)
        XCTAssertEqual(Double(layer.borderWidth), 4, accuracy: 0.001)
    }

    @MainActor
    func testDetailPayloadMarksExpandedAppKitEditableProperties() throws {
        let fixture = makeFixture()
        defer { fixture.close() }

        let builder = makeBuilder()
        let context = makeReferenceContext(for: fixture)

        let scrollDetail = try XCTUnwrap(builder.makeDetail(for: "scroll", in: context))
        let tableDetail = try XCTUnwrap(builder.makeDetail(for: "table", in: context))
        let textViewDetail = try XCTUnwrap(builder.makeDetail(for: "textView", in: context))
        let textFieldDetail = try XCTUnwrap(builder.makeDetail(for: "textField", in: context))
        let pushButtonDetail = try XCTUnwrap(builder.makeDetail(for: "pushButton", in: context))
        let visualEffectDetail = try XCTUnwrap(builder.makeDetail(for: "visualEffect", in: context))
        let stackDetail = try XCTUnwrap(builder.makeDetail(for: "stack", in: context))

        let keys = editableKeys(in: [
            scrollDetail,
            tableDetail,
            textViewDetail,
            textFieldDetail,
            pushButtonDetail,
            visualEffectDetail,
            stackDetail
        ])

        XCTAssertTrue(keys.contains("contentOffset.x"))
        XCTAssertTrue(keys.contains("contentSize.height"))
        XCTAssertTrue(keys.contains("automaticallyAdjustsContentInsets"))
        XCTAssertTrue(keys.contains("borderType"))
        XCTAssertTrue(keys.contains("hasVerticalScroller"))
        XCTAssertTrue(keys.contains("allowsMagnification"))
        XCTAssertTrue(keys.contains("magnification"))
        XCTAssertTrue(keys.contains("rowHeight"))
        XCTAssertTrue(keys.contains("intercellSpacing.width"))
        XCTAssertTrue(keys.contains("gridColor"))
        XCTAssertTrue(keys.contains("usesAlternatingRowBackgroundColors"))
        XCTAssertTrue(keys.contains("textView.string"))
        XCTAssertTrue(keys.contains("textView.fontSize"))
        XCTAssertTrue(keys.contains("textView.textColor"))
        XCTAssertTrue(keys.contains("textView.alignment"))
        XCTAssertTrue(keys.contains("textView.textContainerInset.width"))
        XCTAssertTrue(keys.contains("textView.maxSize.width"))
        XCTAssertTrue(keys.contains("textField.textColor"))
        XCTAssertTrue(keys.contains("textField.isBordered"))
        XCTAssertTrue(keys.contains("textField.maximumNumberOfLines"))
        XCTAssertTrue(keys.contains("button.title"))
        XCTAssertTrue(keys.contains("button.alternateTitle"))
        XCTAssertTrue(keys.contains("button.buttonType"))
        XCTAssertTrue(keys.contains("button.bezelStyle"))
        XCTAssertTrue(keys.contains("button.isTransparent"))
        XCTAssertTrue(keys.contains("button.bezelColor"))
        XCTAssertTrue(keys.contains("button.contentTintColor"))
        XCTAssertTrue(keys.contains("control.controlSize"))
        XCTAssertTrue(keys.contains("control.alignment"))
        XCTAssertTrue(keys.contains("control.fontSize"))
        XCTAssertTrue(keys.contains("visualEffect.material"))
        XCTAssertTrue(keys.contains("visualEffect.blendingMode"))
        XCTAssertTrue(keys.contains("visualEffect.state"))
        XCTAssertTrue(keys.contains("visualEffect.isEmphasized"))
        XCTAssertTrue(keys.contains("stack.orientation"))
        XCTAssertTrue(keys.contains("stack.edgeInsets.top"))
        XCTAssertTrue(keys.contains("stack.detachesHiddenViews"))
        XCTAssertTrue(keys.contains("stack.distribution"))
        XCTAssertTrue(keys.contains("stack.alignment"))
        XCTAssertTrue(keys.contains("stack.spacing"))
    }

    @MainActor
    func testMutationsApplyForExpandedAppKitEditableProperties() throws {
        let fixture = makeFixture()
        defer { fixture.close() }

        try ViewScopeMutationApplier.apply(.number(key: "contentSize.width", value: 360), to: fixture.scrollView)
        try ViewScopeMutationApplier.apply(.toggle(key: "automaticallyAdjustsContentInsets", value: false), to: fixture.scrollView)
        try ViewScopeMutationApplier.apply(.number(key: "borderType", value: Double(NSBorderType.bezelBorder.rawValue)), to: fixture.scrollView)
        try ViewScopeMutationApplier.apply(.toggle(key: "hasHorizontalScroller", value: false), to: fixture.scrollView)
        try ViewScopeMutationApplier.apply(.toggle(key: "allowsMagnification", value: true), to: fixture.scrollView)
        try ViewScopeMutationApplier.apply(.number(key: "magnification", value: 1.6), to: fixture.scrollView)
        try ViewScopeMutationApplier.apply(.number(key: "contentOffset.x", value: 18), to: fixture.scrollView)
        try ViewScopeMutationApplier.apply(.number(key: "contentOffset.y", value: 26), to: fixture.scrollView)

        try ViewScopeMutationApplier.apply(.number(key: "rowHeight", value: 36), to: fixture.tableView)
        try ViewScopeMutationApplier.apply(.number(key: "intercellSpacing.width", value: 12), to: fixture.tableView)
        try ViewScopeMutationApplier.apply(.text(key: "gridColor", value: "#CC8844FF"), to: fixture.tableView)
        try ViewScopeMutationApplier.apply(.toggle(key: "usesAlternatingRowBackgroundColors", value: true), to: fixture.tableView)

        try ViewScopeMutationApplier.apply(.text(key: "textView.string", value: "Edited text view"), to: fixture.textView)
        try ViewScopeMutationApplier.apply(.number(key: "textView.fontSize", value: 19), to: fixture.textView)
        try ViewScopeMutationApplier.apply(.text(key: "textView.textColor", value: "#224466FF"), to: fixture.textView)
        try ViewScopeMutationApplier.apply(.number(key: "textView.alignment", value: Double(NSTextAlignment.right.rawValue)), to: fixture.textView)
        try ViewScopeMutationApplier.apply(.number(key: "textView.textContainerInset.width", value: 14), to: fixture.textView)
        try ViewScopeMutationApplier.apply(.number(key: "textView.maxSize.width", value: 480), to: fixture.textView)

        try ViewScopeMutationApplier.apply(.toggle(key: "textField.isBordered", value: false), to: fixture.textField)
        try ViewScopeMutationApplier.apply(.toggle(key: "textField.drawsBackground", value: false), to: fixture.textField)
        try ViewScopeMutationApplier.apply(.number(key: "textField.maximumNumberOfLines", value: 3), to: fixture.textField)
        try ViewScopeMutationApplier.apply(.text(key: "textField.textColor", value: "#118833FF"), to: fixture.textField)

        try ViewScopeMutationApplier.apply(.text(key: "button.title", value: "Updated Button"), to: fixture.pushButton)
        try ViewScopeMutationApplier.apply(.text(key: "button.alternateTitle", value: "Alt Button"), to: fixture.pushButton)
        try ViewScopeMutationApplier.apply(.number(key: "button.buttonType", value: Double(NSButton.ButtonType.toggle.rawValue)), to: fixture.pushButton)
        try ViewScopeMutationApplier.apply(.number(key: "button.bezelStyle", value: Double(NSButton.BezelStyle.rounded.rawValue)), to: fixture.pushButton)
        try ViewScopeMutationApplier.apply(.toggle(key: "button.isTransparent", value: true), to: fixture.pushButton)
        try ViewScopeMutationApplier.apply(.text(key: "button.bezelColor", value: "#993355FF"), to: fixture.pushButton)
        try ViewScopeMutationApplier.apply(.text(key: "button.contentTintColor", value: "#3355CCFF"), to: fixture.pushButton)
        try ViewScopeMutationApplier.apply(.number(key: "control.controlSize", value: Double(NSControl.ControlSize.large.rawValue)), to: fixture.pushButton)
        try ViewScopeMutationApplier.apply(.number(key: "control.alignment", value: Double(NSTextAlignment.center.rawValue)), to: fixture.pushButton)
        try ViewScopeMutationApplier.apply(.number(key: "control.fontSize", value: 17), to: fixture.pushButton)

        try ViewScopeMutationApplier.apply(.number(key: "visualEffect.material", value: Double(NSVisualEffectView.Material.selection.rawValue)), to: fixture.visualEffectView)
        try ViewScopeMutationApplier.apply(.number(key: "visualEffect.blendingMode", value: Double(NSVisualEffectView.BlendingMode.withinWindow.rawValue)), to: fixture.visualEffectView)
        try ViewScopeMutationApplier.apply(.number(key: "visualEffect.state", value: Double(NSVisualEffectView.State.active.rawValue)), to: fixture.visualEffectView)
        try ViewScopeMutationApplier.apply(.toggle(key: "visualEffect.isEmphasized", value: true), to: fixture.visualEffectView)

        try ViewScopeMutationApplier.apply(.number(key: "stack.orientation", value: Double(NSUserInterfaceLayoutOrientation.vertical.rawValue)), to: fixture.stackView)
        try ViewScopeMutationApplier.apply(.number(key: "stack.edgeInsets.top", value: 10), to: fixture.stackView)
        try ViewScopeMutationApplier.apply(.toggle(key: "stack.detachesHiddenViews", value: true), to: fixture.stackView)
        try ViewScopeMutationApplier.apply(.number(key: "stack.distribution", value: Double(NSStackView.Distribution.fillEqually.rawValue)), to: fixture.stackView)
        try ViewScopeMutationApplier.apply(.number(key: "stack.alignment", value: Double(NSLayoutConstraint.Attribute.centerX.rawValue)), to: fixture.stackView)
        try ViewScopeMutationApplier.apply(.number(key: "stack.spacing", value: 22), to: fixture.stackView)

        XCTAssertEqual(fixture.scrollView.contentView.bounds.origin.x, 18, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.contentView.bounds.origin.y, 26, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.documentView?.frame.width ?? 0, 360, accuracy: 0.001)
        XCTAssertFalse(fixture.scrollView.automaticallyAdjustsContentInsets)
        XCTAssertEqual(fixture.scrollView.borderType, .bezelBorder)
        XCTAssertFalse(fixture.scrollView.hasHorizontalScroller)
        XCTAssertTrue(fixture.scrollView.allowsMagnification)
        XCTAssertEqual(fixture.scrollView.magnification, 1.6, accuracy: 0.001)

        XCTAssertEqual(fixture.tableView.rowHeight, 36, accuracy: 0.001)
        XCTAssertEqual(fixture.tableView.intercellSpacing.width, 12, accuracy: 0.001)
        XCTAssertEqual(hexString(for: fixture.tableView.gridColor.cgColor), "#CC8844FF")
        XCTAssertTrue(fixture.tableView.usesAlternatingRowBackgroundColors)

        XCTAssertEqual(fixture.textView.string, "Edited text view")
        XCTAssertEqual(fixture.textView.font?.pointSize ?? 0, 19, accuracy: 0.001)
        XCTAssertEqual(hexString(for: fixture.textView.textColor?.cgColor), "#224466FF")
        XCTAssertEqual(fixture.textView.alignment, .right)
        XCTAssertEqual(fixture.textView.textContainerInset.width, 14, accuracy: 0.001)
        XCTAssertEqual(fixture.textView.maxSize.width, 480, accuracy: 0.001)

        XCTAssertFalse(fixture.textField.isBordered)
        XCTAssertFalse(fixture.textField.drawsBackground)
        XCTAssertEqual(fixture.textField.maximumNumberOfLines, 3)
        XCTAssertEqual(hexString(for: fixture.textField.textColor?.cgColor), "#118833FF")

        XCTAssertEqual(fixture.pushButton.title, "Updated Button")
        XCTAssertEqual(fixture.pushButton.alternateTitle, "Alt Button")
        XCTAssertEqual(fixture.pushButton.bezelStyle, .rounded)
        XCTAssertTrue(fixture.pushButton.isTransparent)
        XCTAssertEqual(hexString(for: fixture.pushButton.bezelColor?.cgColor), "#993355FF")
        XCTAssertEqual(hexString(for: fixture.pushButton.contentTintColor?.cgColor), "#3355CCFF")
        XCTAssertEqual(fixture.pushButton.controlSize, .large)
        XCTAssertEqual(fixture.pushButton.alignment, .center)
        XCTAssertEqual(fixture.pushButton.font?.pointSize ?? 0, 17, accuracy: 0.001)

        XCTAssertEqual(fixture.visualEffectView.material, .selection)
        XCTAssertEqual(fixture.visualEffectView.blendingMode, .withinWindow)
        XCTAssertEqual(fixture.visualEffectView.state, .active)
        XCTAssertTrue(fixture.visualEffectView.isEmphasized)

        XCTAssertEqual(fixture.stackView.orientation, .vertical)
        XCTAssertEqual(fixture.stackView.edgeInsets.top, 10, accuracy: 0.001)
        XCTAssertTrue(fixture.stackView.detachesHiddenViews)
        XCTAssertEqual(fixture.stackView.distribution, .fillEqually)
        XCTAssertEqual(fixture.stackView.alignment, .centerX)
        XCTAssertEqual(fixture.stackView.spacing, 22, accuracy: 0.001)
    }

    @MainActor
    private func makeBuilder() -> ViewScopeSnapshotBuilder {
        ViewScopeSnapshotBuilder(
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
    }

    @MainActor
    private func editableKeys(in details: [ViewScopeNodeDetailPayload]) -> Set<String> {
        Set(details.flatMap { detail in
            detail.sections.flatMap { section in
                section.items.compactMap { $0.editable?.key }
            }
        })
    }

    @MainActor
    private func makeReferenceContext(for fixture: Fixture) -> ViewScopeSnapshotBuilder.ReferenceContext {
        ViewScopeSnapshotBuilder.ReferenceContext(
            nodeReferences: [
                "window": .window(fixture.window),
                "root": .view(fixture.rootView),
                "inspected": .view(fixture.inspectedView),
                "inspectedLayer": .layer(try! XCTUnwrap(fixture.inspectedView.layer)),
                "scroll": .view(fixture.scrollView),
                "table": .view(fixture.tableView),
                "textView": .view(fixture.textView),
                "textField": .view(fixture.textField),
                "button": .view(fixture.button),
                "pushButton": .view(fixture.pushButton),
                "visualEffect": .view(fixture.visualEffectView),
                "stack": .view(fixture.stackView)
            ],
            rootNodeIDs: ["window"],
            captureID: "test-capture"
        )
    }

    @MainActor
    private func makeFixture() -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Fixture Window"

        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 760))
        let inspectedView = NSView(frame: NSRect(x: 20, y: 20, width: 240, height: 160))
        inspectedView.wantsLayer = true
        inspectedView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        inspectedView.layer?.cornerRadius = 8
        inspectedView.layer?.borderWidth = 1
        inspectedView.toolTip = "Initial Tip"

        let scrollView = NSScrollView(frame: NSRect(x: 280, y: 20, width: 220, height: 160))
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 4, bottom: 6, right: 8)
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.borderType = .lineBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.allowsMagnification = true
        scrollView.magnification = 1.1
        scrollView.maxMagnification = 2.4
        scrollView.minMagnification = 0.5
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))

        let tableScrollView = NSScrollView(frame: NSRect(x: 520, y: 20, width: 220, height: 180))
        let tableView = NSTableView(frame: tableScrollView.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 200
        tableView.addTableColumn(column)
        tableView.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 4, height: 6)
        tableView.gridColor = .systemGray
        tableView.usesAlternatingRowBackgroundColors = false
        tableScrollView.documentView = tableView

        let textField = NSTextField(frame: NSRect(x: 20, y: 220, width: 220, height: 28))
        textField.stringValue = "Initial"
        textField.placeholderString = "Placeholder"
        textField.textColor = .systemPurple

        let textView = NSTextView(frame: NSRect(x: 20, y: 280, width: 260, height: 120))
        textView.string = "Text View"
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .systemOrange
        textView.alignment = .left
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.maxSize = NSSize(width: 320, height: 280)
        textView.minSize = NSSize(width: 120, height: 60)

        let visualEffectView = NSVisualEffectView(frame: NSRect(x: 300, y: 220, width: 180, height: 120))
        visualEffectView.material = .sidebar
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .followsWindowActiveState
        visualEffectView.isEmphasized = false

        let stackView = NSStackView(frame: NSRect(x: 520, y: 240, width: 240, height: 120))
        stackView.orientation = .horizontal
        stackView.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 6, right: 8)
        stackView.detachesHiddenViews = false
        stackView.distribution = .gravityAreas
        stackView.alignment = .leading
        stackView.spacing = 9
        let stackA = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let stackB = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        stackView.addArrangedSubview(stackA)
        stackView.addArrangedSubview(stackB)

        let button = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 270, width: 120, height: 24)
        button.allowsMixedState = false
        button.state = .off

        let pushButton = NSButton(title: "Primary", target: nil, action: nil)
        pushButton.frame = NSRect(x: 300, y: 370, width: 160, height: 32)
        pushButton.alternateTitle = "Alt"
        pushButton.setButtonType(.momentaryPushIn)
        pushButton.bezelStyle = .texturedRounded
        pushButton.isBordered = true
        pushButton.isTransparent = false
        pushButton.bezelColor = .systemRed
        pushButton.contentTintColor = .systemBlue
        pushButton.controlSize = .regular
        pushButton.alignment = .left
        pushButton.font = .systemFont(ofSize: 14)

        rootView.addSubview(inspectedView)
        rootView.addSubview(scrollView)
        rootView.addSubview(tableScrollView)
        rootView.addSubview(textField)
        rootView.addSubview(textView)
        rootView.addSubview(button)
        rootView.addSubview(pushButton)
        rootView.addSubview(visualEffectView)
        rootView.addSubview(stackView)
        window.contentView = rootView
        window.orderFrontRegardless()

        return Fixture(
            window: window,
            rootView: rootView,
            inspectedView: inspectedView,
            scrollView: scrollView,
            tableView: tableView,
            textView: textView,
            textField: textField,
            button: button,
            pushButton: pushButton,
            visualEffectView: visualEffectView,
            stackView: stackView
        )
    }
}

@MainActor
private struct Fixture {
    let window: NSWindow
    let rootView: NSView
    let inspectedView: NSView
    let scrollView: NSScrollView
    let tableView: NSTableView
    let textView: NSTextView
    let textField: NSTextField
    let button: NSButton
    let pushButton: NSButton
    let visualEffectView: NSVisualEffectView
    let stackView: NSStackView

    func close() {
        // Switch NSVisualEffectView off behindWindow BEFORE clearing content so it
        // disconnects from the desktop compositor first.
        visualEffectView.blendingMode = .withinWindow
        CATransaction.flush()
        // Remove all subviews to silence NSTextField cursor-blink, NSScrollView
        // indicator animations, etc. that would otherwise flood the RunLoop with
        // CA callbacks while the window sits in the pool, preventing the server
        // tests' 50 ms RunLoop drains from reaching the BeforeWaiting observer.
        window.contentView = nil
        CATransaction.flush()
        window.orderOut(nil)
        CATransaction.flush()
        // Keep window alive in the pool so _NSWindowTransformAnimation's weak ref
        // is non-nil when its dealloc fires (macOS 26 beta bug: no nil-check at +32).
        mutationFixtureWindowPool.append(window)
    }
}

private func hexString(for color: CGColor?) -> String? {
    guard let color,
          let rgb = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else {
        return nil
    }
    return String(
        format: "#%02X%02X%02X%02X",
        Int(round(rgb.redComponent * 255)),
        Int(round(rgb.greenComponent * 255)),
        Int(round(rgb.blueComponent * 255)),
        Int(round(rgb.alphaComponent * 255))
    )
}
