import AppKit
import XCTest
@testable import ViewScopeServer

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
                "scroll": .view(fixture.scrollView),
                "textField": .view(fixture.textField),
                "button": .view(fixture.button)
            ],
            rootNodeIDs: ["window"],
            captureID: "test-capture"
        )
    }

    @MainActor
    private func makeFixture() -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Fixture Window"

        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        let inspectedView = NSView(frame: NSRect(x: 20, y: 20, width: 240, height: 160))
        inspectedView.wantsLayer = true
        inspectedView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        inspectedView.layer?.cornerRadius = 8
        inspectedView.layer?.borderWidth = 1
        inspectedView.toolTip = "Initial Tip"

        let scrollView = NSScrollView(frame: NSRect(x: 280, y: 20, width: 220, height: 160))
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 4, bottom: 6, right: 8)
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))

        let textField = NSTextField(frame: NSRect(x: 20, y: 220, width: 220, height: 28))
        textField.stringValue = "Initial"
        textField.placeholderString = "Placeholder"

        let button = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 270, width: 120, height: 24)
        button.allowsMixedState = false
        button.state = .off

        rootView.addSubview(inspectedView)
        rootView.addSubview(scrollView)
        rootView.addSubview(textField)
        rootView.addSubview(button)
        window.contentView = rootView
        window.orderFrontRegardless()

        return Fixture(
            window: window,
            rootView: rootView,
            inspectedView: inspectedView,
            scrollView: scrollView,
            textField: textField,
            button: button
        )
    }
}

@MainActor
private struct Fixture {
    let window: NSWindow
    let rootView: NSView
    let inspectedView: NSView
    let scrollView: NSScrollView
    let textField: NSTextField
    let button: NSButton

    func close() {
        window.orderOut(nil)
        window.close()
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
