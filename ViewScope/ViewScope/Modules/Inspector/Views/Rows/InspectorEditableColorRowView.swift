import AppKit
import SnapKit

final class InspectorEditableColorRowView: NSView, InspectorCommitCapable {
    /// 颜色面板拖动时连续触发 action，停止变化 150ms 后才提交一次。
    static let colorWellDebounceInterval: TimeInterval = 0.15

    private let colorWell = NSColorWell()
    private let textField: InspectorTextField
    private let originalValue: String
    private var pendingColorCommit: DispatchWorkItem?
    private var colorPanelObserver: NSObjectProtocol?

    var commitHandler: ((String) -> Void)?

    init(title: String, hexValue: String) {
        self.originalValue = hexValue
        self.textField = InspectorTextField(value: hexValue)
        super.init(frame: .zero)

        let titleLabel = InspectorRowTitleLabel(text: title)
        colorWell.target = self
        colorWell.action = #selector(handleColorWell(_:))
        colorWell.color = NSColor(viewScopeHexString: hexValue) ?? .clear
        textField.onCommit = { [weak self] in
            self?.commitHandler?(self?.textField.stringValue ?? "")
        }

        let controls = NSStackView(views: [colorWell, textField])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let stack = NSStackView(views: [titleLabel, controls])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        textField.snp.makeConstraints { make in
            make.width.equalTo(110)
            make.height.equalTo(26)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else {
            return
        }
        // 行被移出界面（面板重建）时，先把未发送的颜色提交掉，再移除监听
        if let pending = pendingColorCommit {
            pending.cancel()
            flushPendingColorCommit(textField.stringValue)
        }
        if let colorPanelObserver {
            NotificationCenter.default.removeObserver(colorPanelObserver)
            self.colorPanelObserver = nil
        }
    }

    func setEditingEnabled(_ enabled: Bool) {
        colorWell.isEnabled = enabled
        textField.isEnabled = enabled
    }

    func resetDisplayedValue() {
        textField.stringValue = originalValue
        colorWell.color = NSColor(viewScopeHexString: originalValue) ?? .clear
    }

    @objc private func handleColorWell(_ sender: NSColorWell) {
        let hex = sender.color.viewScopeHexString
        textField.stringValue = hex
        scheduleColorCommit(hex)
        observeColorPanelCloseIfNeeded()
    }

    /// 防抖：连续变化时只保留最后一次。
    private func scheduleColorCommit(_ hex: String) {
        pendingColorCommit?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingColorCommit(hex)
        }
        pendingColorCommit = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.colorWellDebounceInterval, execute: workItem)
    }

    private func flushPendingColorCommit(_ hex: String) {
        pendingColorCommit = nil
        commitHandler?(hex)
    }

    /// 关闭颜色面板时立即提交尚未发送的颜色。
    private func observeColorPanelCloseIfNeeded() {
        guard colorPanelObserver == nil else {
            return
        }
        colorPanelObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: NSColorPanel.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let pending = self.pendingColorCommit else {
                    return
                }
                pending.cancel()
                self.flushPendingColorCommit(self.textField.stringValue)
            }
        }
    }
}
