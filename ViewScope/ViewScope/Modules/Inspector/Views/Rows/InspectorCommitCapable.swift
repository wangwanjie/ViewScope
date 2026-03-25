import AppKit
import SnapKit

protocol InspectorCommitCapable: AnyObject {
    func setEditingEnabled(_ enabled: Bool)
    func resetDisplayedValue()
}

final class InspectorRowTitleLabel: NSTextField {
    init(text: String, width: CGFloat = 88) {
        super.init(frame: .zero)
        stringValue = text.uppercased()
        font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        textColor = .secondaryLabelColor
        isBezeled = false
        isBordered = false
        isEditable = false
        drawsBackground = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        snp.makeConstraints { make in
            make.width.equalTo(width)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class InspectorTextField: NSTextField {
    var onCommit: (() -> Void)?

    init(value: String) {
        super.init(frame: .zero)
        stringValue = value
        font = NSFont.systemFont(ofSize: 12)
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        isBordered = true
        isBezeled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onCommit?()
    }
}

extension NSColor {
    convenience init?(viewScopeHexString: String) {
        let sanitized = viewScopeHexString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6 || sanitized.count == 8,
              let rawValue = UInt64(sanitized, radix: 16) else {
            return nil
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        if sanitized.count == 8 {
            red = CGFloat((rawValue & 0xFF000000) >> 24) / 255
            green = CGFloat((rawValue & 0x00FF0000) >> 16) / 255
            blue = CGFloat((rawValue & 0x0000FF00) >> 8) / 255
            alpha = CGFloat(rawValue & 0x000000FF) / 255
        } else {
            red = CGFloat((rawValue & 0xFF0000) >> 16) / 255
            green = CGFloat((rawValue & 0x00FF00) >> 8) / 255
            blue = CGFloat(rawValue & 0x0000FF) / 255
            alpha = 1
        }

        self.init(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }

    var viewScopeHexString: String {
        guard let rgb = usingColorSpace(.deviceRGB) else {
            return "#000000FF"
        }
        return String(
            format: "#%02X%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255)),
            Int(round(rgb.alphaComponent * 255))
        )
    }
}
