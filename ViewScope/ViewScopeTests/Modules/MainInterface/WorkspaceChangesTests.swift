import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

/// 修改记录、导出代码与抓取对比的纯逻辑测试。
@Suite(.serialized)
@MainActor
struct WorkspaceChangesTests {
    // MARK: - 抓取对比

    @Test func diffEngineDetectsAllCategoriesByAddress() throws {
        let baseline = makeCapture(nodes: [
            makeNode(id: "window", parentID: nil, className: "NSWindow", address: "0x1", kind: .window, childIDs: ["root"]),
            makeNode(id: "root", parentID: "window", className: "NSView", address: "0x2", childIDs: ["a", "b", "c", "gone"]),
            makeNode(id: "a", parentID: "root", className: "NSButton", address: "0xa", frame: .init(x: 0, y: 0, width: 10, height: 10)),
            makeNode(id: "b", parentID: "root", className: "NSTextField", address: "0xb", isHidden: false, alpha: 1),
            makeNode(id: "c", parentID: "root", className: "NSView", address: "0xc", childIDs: []),
            makeNode(id: "gone", parentID: "root", className: "NSImageView", address: "0xd")
        ])
        let current = makeCapture(nodes: [
            makeNode(id: "window", parentID: nil, className: "NSWindow", address: "0x1", kind: .window, childIDs: ["root"]),
            makeNode(id: "root", parentID: "window", className: "NSView", address: "0x2", childIDs: ["a", "c", "new"]),
            makeNode(id: "a", parentID: "root", className: "NSButton", address: "0xa", frame: .init(x: 5, y: 0, width: 10, height: 20)),
            // b 被挪到 c 下面，同时被隐藏
            makeNode(id: "c", parentID: "root", className: "NSStackView", address: "0xc", childIDs: ["b"]),
            makeNode(id: "b", parentID: "c", className: "NSTextField", address: "0xb", isHidden: true, alpha: 0.5),
            makeNode(id: "new", parentID: "root", className: "NSSlider", address: "0xe")
        ])

        let result = CaptureDiffEngine.diff(baseline: baseline, current: current)

        #expect(result.count(of: .added) == 1)
        #expect(result.entries(in: .added).first?.currentNodeID == "new")
        #expect(result.count(of: .removed) == 1)
        #expect(result.entries(in: .removed).first?.baselineNodeID == "gone")
        #expect(result.entries(in: .removed).first?.currentNodeID == nil)

        let frameEntry = try #require(result.entries(in: .frameChanged).first)
        #expect(frameEntry.currentNodeID == "a")
        #expect(frameEntry.frameDelta == ViewScopeRect(x: 5, y: 0, width: 0, height: 10))

        let visibility = try #require(result.entries(in: .visibilityChanged).first)
        #expect(visibility.currentNodeID == "b")
        #expect(visibility.detail.contains("hidden"))
        #expect(visibility.detail.contains("alpha"))

        #expect(result.entries(in: .classChanged).map(\.currentNodeID) == ["c"])
        #expect(result.entries(in: .reparented).map(\.currentNodeID) == ["b"])
    }

    @Test func diffEngineFallsBackToClassAndPathWhenAddressesChange() {
        // 宿主重启后所有地址都变了，但结构相同：不应报告新增/删除
        let baseline = makeCapture(nodes: [
            makeNode(id: "w1", parentID: nil, className: "NSWindow", address: "0x100", kind: .window, childIDs: ["v1"]),
            makeNode(id: "v1", parentID: "w1", className: "NSView", address: "0x101", childIDs: ["b1"]),
            makeNode(id: "b1", parentID: "v1", className: "NSButton", address: "0x102", frame: .init(x: 0, y: 0, width: 50, height: 20))
        ])
        let current = makeCapture(nodes: [
            makeNode(id: "w2", parentID: nil, className: "NSWindow", address: "0x900", kind: .window, childIDs: ["v2"]),
            makeNode(id: "v2", parentID: "w2", className: "NSView", address: "0x901", childIDs: ["b2"]),
            makeNode(id: "b2", parentID: "v2", className: "NSButton", address: "0x902", frame: .init(x: 0, y: 0, width: 60, height: 20))
        ])

        let result = CaptureDiffEngine.diff(baseline: baseline, current: current)

        #expect(result.count(of: .added) == 0)
        #expect(result.count(of: .removed) == 0)
        #expect(result.count(of: .reparented) == 0)
        #expect(result.entries(in: .frameChanged).map(\.currentNodeID) == ["b2"])
    }

    @Test func diffEngineMatchesViewThatBecameLayerBackedNode() {
        // 视图首次显示前是 view 节点，之后变成带宿主视图的 layer 节点：不应报告新增/删除/类变化
        let baseline = makeCapture(nodes: [
            makeNode(id: "window-0x1", parentID: nil, className: "NSWindow", address: "0x1", kind: .window, childIDs: ["view-0x2"]),
            makeNode(id: "view-0x2", parentID: "window-0x1", className: "NSButton", address: "0x2")
        ])
        let current = makeCapture(nodes: [
            makeNode(id: "window-0x1", parentID: nil, className: "NSWindow", address: "0x1", kind: .window, childIDs: ["layer-0x3"]),
            makeNode(id: "layer-0x3", parentID: "window-0x1", className: "_NSViewBackingLayer", address: "0x3", kind: .layer, hostViewClassName: "NSButton")
        ])

        let result = CaptureDiffEngine.diff(baseline: baseline, current: current)

        #expect(result.entries.isEmpty)
    }

    @Test func diffEngineReportsNoChangesForIdenticalCaptures() {
        let capture = makeCapture(nodes: [
            makeNode(id: "w", parentID: nil, className: "NSWindow", address: "0x1", kind: .window, childIDs: ["v"]),
            makeNode(id: "v", parentID: "w", className: "NSView", address: "0x2")
        ])
        #expect(CaptureDiffEngine.diff(baseline: capture, current: capture).entries.isEmpty)
    }

    // MARK: - 导出代码

    @Test func codeGeneratorProducesAppKitStatementsGroupedByObject() {
        let records = [
            makeRecord(platform: .macOS, nodeID: "layer-0xa", address: "0xa", className: "CALayer", hostViewClassName: "NSButton", ivarName: "confirmButton", key: "alpha", old: .number(key: "alpha", value: 1), new: .number(key: "alpha", value: 0.8)),
            makeRecord(platform: .macOS, nodeID: "layer-0xa", address: "0xa", className: "CALayer", hostViewClassName: "NSButton", ivarName: "confirmButton", key: "frame.x", old: .number(key: "frame.x", value: 0), new: .number(key: "frame.x", value: 12)),
            makeRecord(platform: .macOS, nodeID: "layer-0xa", address: "0xa", className: "CALayer", hostViewClassName: "NSButton", ivarName: "confirmButton", key: "layer.cornerRadius", old: .number(key: "layer.cornerRadius", value: 0), new: .number(key: "layer.cornerRadius", value: 8)),
            // 同一 key 多次修改只保留最终值
            makeRecord(platform: .macOS, nodeID: "layer-0xa", address: "0xa", className: "CALayer", hostViewClassName: "NSButton", ivarName: "confirmButton", key: "alpha", old: .number(key: "alpha", value: 0.8), new: .number(key: "alpha", value: 0.5)),
            makeRecord(platform: .macOS, nodeID: "view-0xb", address: "0xb", className: "NSView", key: "backgroundColor", old: nil, new: .text(key: "backgroundColor", value: "#FF000080")),
            makeRecord(platform: .macOS, nodeID: "view-0xb", address: "0xb", className: "NSView", key: "mystery.key.value", old: nil, new: .number(key: "mystery.key.value", value: 3))
        ]

        let code = WorkspaceModificationCodeGenerator.generate(records: records)

        #expect(code.contains("// <NSButton 0xa>  (confirmButton)"))
        #expect(code.contains("view.alphaValue = 0.5"))
        #expect(code.contains("view.alphaValue = 0.8") == false)
        #expect(code.contains("view.frame.origin.x = 12"))
        #expect(code.contains("view.layer?.cornerRadius = 8"))
        #expect(code.contains("// <NSView 0xb>"))
        #expect(code.contains("view.layer?.backgroundColor = NSColor(red: 1, green: 0, blue: 0, alpha: 0.502).cgColor"))
        // 无法识别的 key 输出为注释
        #expect(code.contains("// TODO: mystery.key.value = 3"))
        // 同一对象只出现一次分组标题
        #expect(code.components(separatedBy: "// <NSButton 0xa>").count == 2)
    }

    @Test func codeGeneratorProducesUIKitStatementsAndSkipsUndoneRecords() {
        var undone = makeRecord(platform: .iOS, nodeID: "layer-0x1", address: "0x1", className: "CALayer", hostViewClassName: "UILabel", key: "hidden", old: .toggle(key: "hidden", value: false), new: .toggle(key: "hidden", value: true))
        undone.state = .undone
        let records = [
            makeRecord(platform: .iOS, nodeID: "layer-0x1", address: "0x1", className: "CALayer", hostViewClassName: "UILabel", key: "alpha", old: .number(key: "alpha", value: 1), new: .number(key: "alpha", value: 0.5)),
            makeRecord(platform: .iOS, nodeID: "layer-0x1", address: "0x1", className: "CALayer", hostViewClassName: "UILabel", key: "layer.cornerRadius", old: nil, new: .number(key: "layer.cornerRadius", value: 4)),
            makeRecord(platform: .iOS, nodeID: "layer-0x1", address: "0x1", className: "CALayer", hostViewClassName: "UILabel", key: "backgroundColor", old: nil, new: .text(key: "backgroundColor", value: "#00FF00")),
            makeRecord(platform: .iOS, nodeID: "layer-0x1", address: "0x1", className: "CALayer", hostViewClassName: "UILabel", key: "layer.borderColor", old: nil, new: .text(key: "layer.borderColor", value: "#0000FFFF")),
            makeRecord(platform: .iOS, nodeID: "layer-0x1", address: "0x1", className: "CALayer", hostViewClassName: "UILabel", key: "contentInset.top", old: nil, new: .number(key: "contentInset.top", value: 16)),
            undone
        ]

        let code = WorkspaceModificationCodeGenerator.generate(records: records)

        #expect(code.contains("(UIKit)"))
        #expect(code.contains("view.alpha = 0.5"))
        #expect(code.contains("view.layer.cornerRadius = 4"))
        #expect(code.contains("view.backgroundColor = UIColor(red: 0, green: 1, blue: 0, alpha: 1)"))
        #expect(code.contains("view.layer.borderColor = UIColor(red: 0, green: 0, blue: 1, alpha: 1).cgColor"))
        #expect(code.contains("view.contentInset.top = 16"))
        #expect(code.contains("isHidden") == false)
    }

    @Test func codeGeneratorHandlesPureLayersAndEnumerations() {
        let options = [ViewScopeEditableOption(title: "Fill", value: 0), ViewScopeEditableOption(title: "Equal Spacing", value: 3)]
        let records = [
            makeRecord(platform: .macOS, nodeID: "layer-0x5", address: "0x5", className: "CAShapeLayer", key: "alpha", old: nil, new: .number(key: "alpha", value: 0.25)),
            makeRecord(platform: .macOS, nodeID: "view-0x6", address: "0x6", className: "NSStackView", key: "stack.distribution", old: nil, new: .enumeration(key: "stack.distribution", value: 3, options: options))
        ]

        let code = WorkspaceModificationCodeGenerator.generate(records: records)

        #expect(code.contains("layer.opacity = 0.25"))
        #expect(code.contains("view.distribution = .init(rawValue: 3)! // Equal Spacing"))
    }

    // MARK: - 撤销栈

    @Test func modificationLogUndoRedoStackFollowsAppendOrder() throws {
        let log = WorkspaceModificationLog()
        let first = makeRecord(platform: .macOS, nodeID: "n", address: nil, className: "NSView", key: "alpha", old: .number(key: "alpha", value: 1), new: .number(key: "alpha", value: 0.5))
        let second = makeRecord(platform: .macOS, nodeID: "n", address: nil, className: "NSView", key: "hidden", old: .toggle(key: "hidden", value: false), new: .toggle(key: "hidden", value: true))
        log.append(first)
        log.append(second)

        #expect(log.canUndo)
        #expect(log.canRedo == false)
        #expect(log.nextUndoRecord?.id == second.id)

        log.markUndone(second.id)
        #expect(log.nextUndoRecord?.id == first.id)
        #expect(log.nextRedoRecord?.id == second.id)
        #expect(log.record(withID: second.id)?.state == .undone)

        log.markRedone(second.id)
        #expect(log.nextUndoRecord?.id == second.id)
        #expect(log.record(withID: second.id)?.state == .applied)

        // 新修改会清空重做栈
        log.markUndone(second.id)
        let third = makeRecord(platform: .macOS, nodeID: "n", address: nil, className: "NSView", key: "alpha", old: .number(key: "alpha", value: 0.5), new: .number(key: "alpha", value: 0.2))
        log.append(third)
        #expect(log.canRedo == false)

        log.invalidateUndoHistory()
        #expect(log.canUndo == false)
        #expect(log.records.count == 3)

        log.clear()
        #expect(log.records.isEmpty)
    }

    @Test func valueFormatterUsesOptionTitlesAndCompactNumbers() {
        let options = [ViewScopeEditableOption(title: "Center", value: 2)]
        #expect(WorkspaceModificationValueFormatter.displayString(for: .enumeration(key: "k", value: 2, options: options)) == "Center")
        #expect(WorkspaceModificationValueFormatter.compactNumber(12) == "12")
        #expect(WorkspaceModificationValueFormatter.compactNumber(0.5) == "0.5")
        #expect(WorkspaceModificationValueFormatter.compactNumber(1.0 / 3.0) == "0.3333")
        #expect(WorkspaceModificationValueFormatter.compactNumber(.nan) == "0")
    }

    // MARK: - Console 输入辅助

    @Test func consoleHistoryBrowsesBackwardsAndRestoresDraft() {
        var history = ConsoleInputHistory(capacity: 3)
        history.record("frame")
        history.record("frame")
        history.record("bounds")
        history.record("superview")
        history.record("window")

        // 容量 3，连续重复只记一次
        #expect(history.entries == ["bounds", "superview", "window"])
        #expect(history.previous(currentInput: "dra") == "window")
        #expect(history.previous(currentInput: "ignored") == "superview")
        #expect(history.previous(currentInput: "ignored") == "bounds")
        #expect(history.previous(currentInput: "ignored") == "bounds")
        #expect(history.next() == "superview")
        #expect(history.next() == "window")
        #expect(history.next() == "dra")
        #expect(history.next() == nil)
    }

    @Test func consoleCompletionTokenReplacesCurrentIdentifier() {
        let text = "layer.corn"
        let token = ConsoleCompletionToken.token(in: text, cursorLocation: (text as NSString).length)
        #expect(token.prefix == "corn")
        let applied = token.applying("cornerRadius", to: text)
        #expect(applied.text == "layer.cornerRadius")
        #expect(applied.cursorLocation == ("layer.cornerRadius" as NSString).length)

        let keywordText = "setHidden:YES setAl"
        let keywordToken = ConsoleCompletionToken.token(in: keywordText, cursorLocation: (keywordText as NSString).length)
        #expect(keywordToken.prefix == "setAl")
    }

    // MARK: - 宿主展示

    @Test func hostPresentationGroupsHostsByDeviceAndRecognizesSameApplication() {
        let mac = makeAnnouncement(id: "mac-1", bundleID: "com.demo.mac", platform: .macOS, deviceName: "MacBook", isSimulator: false)
        let simA = makeAnnouncement(id: "sim-1", bundleID: "com.demo.ios", platform: .iOS, deviceName: "iPhone 15", isSimulator: true)
        let simB = makeAnnouncement(id: "sim-2", bundleID: "com.demo.other", platform: .iOS, deviceName: "iPhone 15", isSimulator: true)
        var device = makeAnnouncement(id: "SERIAL|dev-1", bundleID: "com.demo.ios", platform: .iOS, deviceName: "Van's iPhone", isSimulator: false)
        device.transport = ViewScopeHostTransport(kind: .usbmux, deviceID: 3, deviceSerial: "SERIAL", connectionType: "USB")

        let groups = WorkspaceHostPresentation.groupedByDevice([simA, device, mac, simB])

        #expect(groups.count == 3)
        #expect(groups.first?.hosts.map(\.identifier) == ["mac-1"])
        #expect(groups.contains(where: { $0.hosts.count == 2 }))
        #expect(WorkspaceHostPresentation.deviceKind(of: device) == .device(connectionType: "USB"))
        #expect(WorkspaceHostPresentation.isSameApplication(simA, device) == false)

        var relaunched = simA
        relaunched.identifier = "sim-1-relaunched"
        relaunched.processIdentifier = 999
        #expect(WorkspaceHostPresentation.isSameApplication(simA, relaunched))

        let hints = WorkspaceHostPresentation.devicesWithoutHosts(
            devices: [
                WorkspaceConnectedDevice(serial: "SERIAL", name: "Van's iPhone", connectionType: "USB"),
                WorkspaceConnectedDevice(serial: "OTHER", name: "iPad", connectionType: "Network")
            ],
            hosts: [device]
        )
        #expect(hints.map(\.serial) == ["OTHER"])
        #expect(WorkspaceHostPresentation.connectionTypeTitle("Network") == "Wi‑Fi")
    }

    // MARK: - 辅助方法

    private func makeNode(
        id: String,
        parentID: String?,
        className: String,
        address: String?,
        kind: ViewScopeHierarchyNode.Kind = .view,
        hostViewClassName: String? = nil,
        frame: ViewScopeRect = .zero,
        childIDs: [String] = [],
        isHidden: Bool = false,
        alpha: Double = 1
    ) -> ViewScopeHierarchyNode {
        ViewScopeHierarchyNode(
            id: id,
            parentID: parentID,
            kind: kind,
            className: className,
            hostViewClassName: hostViewClassName,
            title: id,
            subtitle: nil,
            address: address,
            frame: frame,
            bounds: .zero,
            childIDs: childIDs,
            isHidden: isHidden,
            alphaValue: alpha,
            wantsLayer: true,
            isFlipped: true,
            clippingEnabled: false,
            depth: 0
        )
    }

    private func makeCapture(nodes: [ViewScopeHierarchyNode]) -> ViewScopeCapturePayload {
        let roots = nodes.filter { $0.parentID == nil }.map(\.id)
        return ViewScopeCapturePayload(
            host: ViewScopeHostInfo(
                displayName: "Demo",
                bundleIdentifier: "com.demo",
                version: "1",
                build: "1",
                processIdentifier: 1,
                runtimeVersion: viewScopeServerRuntimeVersion,
                supportsHighlighting: true
            ),
            capturedAt: Date(),
            summary: ViewScopeCaptureSummary(nodeCount: nodes.count, windowCount: 1, visibleWindowCount: 1, captureDurationMilliseconds: 1),
            rootNodeIDs: roots,
            nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        )
    }

    private func makeRecord(
        platform: ViewScopePlatform,
        nodeID: String,
        address: String?,
        className: String,
        hostViewClassName: String? = nil,
        ivarName: String? = nil,
        key: String,
        old: ViewScopeEditableProperty?,
        new: ViewScopeEditableProperty
    ) -> WorkspaceModificationRecord {
        let kind: ViewScopeHierarchyNode.Kind = nodeID.hasPrefix("layer-") ? .layer : .view
        return WorkspaceModificationRecord(
            hostIdentifier: "host",
            hostDisplayName: "Demo",
            platform: platform,
            nodeID: nodeID,
            nodeKind: kind,
            nodeAddress: address,
            className: className,
            hostViewClassName: hostViewClassName,
            ivarName: ivarName,
            key: key,
            title: key,
            oldValue: old,
            newValue: new
        )
    }

    private func makeAnnouncement(
        id: String,
        bundleID: String,
        platform: ViewScopePlatform,
        deviceName: String,
        isSimulator: Bool
    ) -> ViewScopeHostAnnouncement {
        ViewScopeHostAnnouncement(
            identifier: id,
            authToken: "t",
            displayName: bundleID,
            bundleIdentifier: bundleID,
            version: "1.0",
            build: "1",
            processIdentifier: 1,
            port: 47300,
            updatedAt: Date(),
            supportsHighlighting: true,
            protocolVersion: viewScopeCurrentProtocolVersion,
            runtimeVersion: viewScopeServerRuntimeVersion,
            platform: platform,
            osVersion: "17.0",
            deviceName: deviceName,
            isSimulator: isSimulator
        )
    }
}
