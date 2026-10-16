import AppKit

/// 层级树使用的 NSOutlineView：增加鼠标悬停追踪与 Cmd+F 快捷键。
final class ViewTreeOutlineView: NSOutlineView {
    /// 悬停行变化；-1 表示鼠标离开。
    var onHoverRowChanged: ((Int) -> Void)?
    /// 在树上按下 Cmd+F 时请求聚焦搜索框。
    var onFindRequested: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var lastHoveredRow = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredRow(row(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHoveredRow(-1)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFindRequested?()
            return
        }
        super.keyDown(with: event)
    }

    /// 重新加载数据后行号会变化，需要清空缓存的悬停行。
    func resetHoverTracking() {
        lastHoveredRow = -1
    }

    private func updateHoveredRow(_ row: Int) {
        guard row != lastHoveredRow else {
            return
        }
        lastHoveredRow = row
        onHoverRowChanged?(row)
    }
}

/// 支持悬停着色的行视图（选中态仍由系统绘制）。
final class ViewTreeRowView: NSTableRowView {
    var isHovered = false {
        didSet {
            guard oldValue != isHovered else {
                return
            }
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, isSelected == false else {
            return
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
    }
}
