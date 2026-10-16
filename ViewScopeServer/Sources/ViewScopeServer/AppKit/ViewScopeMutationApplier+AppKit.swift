#if os(macOS)
import AppKit
import QuartzCore

/// AppKit 实时修改。
///
/// 路由规则（B1 / B2）：
/// - 带宿主视图的 layer 节点：`layer.*` key 作用于 layer，其余（hidden、alpha、frame.*、bounds.*、backgroundColor、控件专属 key）作用于宿主视图；
/// - 纯 CALayer：全部作用于 layer；
/// - 所有数值都经过 `ViewScopeNumberConversion`，非有限数/越界值抛 `invalidValue` 而不是让宿主崩溃（A4）。
@MainActor
enum ViewScopeMutationApplier {
    /// 失败时抛出 ViewScopeMutationError。
    static func apply(_ property: ViewScopeEditableProperty, to reference: ViewScopeInspectableReference) throws {
        guard let resolved = ViewScopeResolvedReference(reference) else {
            throw ViewScopeMutationError.targetDeallocated
        }
        switch resolved {
        case .window(let window):
            try apply(property, to: window)
        case .view(let view):
            // 已经脱离窗口的视图视为失效，避免对不可见对象修改后仍然 ack（A9）。
            guard view.window != nil else {
                throw ViewScopeMutationError.targetDeallocated
            }
            try apply(property, to: view)
        case .layer(let layer):
            guard layer.viewScopeWindow != nil else {
                throw ViewScopeMutationError.targetDeallocated
            }
            if let hostView = layer.viewScopeHostView, property.key.hasPrefix("layer.") == false {
                try apply(property, to: hostView)
            } else {
                try apply(property, to: layer)
            }
        case .viewController, .object:
            throw ViewScopeMutationError.unsupportedProperty
        }
    }

    // MARK: - 取值工具

    private static func boolValue(_ property: ViewScopeEditableProperty) throws -> Bool {
        guard let value = property.boolValue else {
            throw ViewScopeMutationError.invalidValue
        }
        return value
    }

    private static func textValue(_ property: ViewScopeEditableProperty) throws -> String {
        guard let value = property.textValue else {
            throw ViewScopeMutationError.invalidValue
        }
        return value
    }

    private static func number(_ property: ViewScopeEditableProperty) throws -> Double {
        Double(try ViewScopeNumberConversion.cgFloat(property.numberValue))
    }

    private static func cgFloat(_ property: ViewScopeEditableProperty) throws -> CGFloat {
        try ViewScopeNumberConversion.cgFloat(property.numberValue)
    }

    private static func nonNegative(_ property: ViewScopeEditableProperty) throws -> CGFloat {
        try ViewScopeNumberConversion.nonNegativeCGFloat(property.numberValue)
    }

    /// 枚举值：必须是候选表中的 raw value。
    private static func enumRawValue(_ property: ViewScopeEditableProperty) throws -> Int {
        let rawValue = try ViewScopeNumberConversion.int(property.numberValue)
        if let allowed = ViewScopeAppKitEnumOptions.allowedRawValues(forKey: property.key),
           allowed.contains(rawValue) == false {
            throw ViewScopeMutationError.invalidValue
        }
        return rawValue
    }

    private static func enumUIntValue(_ property: ViewScopeEditableProperty) throws -> UInt {
        let rawValue = try enumRawValue(property)
        guard let result = UInt(exactly: rawValue) else {
            throw ViewScopeMutationError.invalidValue
        }
        return result
    }

    /// 必填颜色。
    private static func color(_ property: ViewScopeEditableProperty) throws -> NSColor {
        guard let color = NSColor.kg_viewScopeColor(hexString: try textValue(property)) else {
            throw ViewScopeMutationError.invalidValue
        }
        return color
    }

    /// 可选颜色：空字符串表示清除。
    private static func optionalColor(_ property: ViewScopeEditableProperty) throws -> NSColor? {
        let value = try textValue(property).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }
        guard let color = NSColor.kg_viewScopeColor(hexString: value) else {
            throw ViewScopeMutationError.invalidValue
        }
        return color
    }

    /// 关闭隐式动画执行 layer 修改。
    private static func withoutImplicitAnimations(_ body: () throws -> Void) rethrows {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
        }
        try body()
    }

    // MARK: - 窗口

    static func apply(_ property: ViewScopeEditableProperty, to window: NSWindow) throws {
        switch property.key {
        case "title":
            window.title = try textValue(property)
        case "alpha":
            window.alphaValue = try ViewScopeNumberConversion.unitInterval(property.numberValue)
        case "frame.x":
            var frame = window.frame
            frame.origin.x = try cgFloat(property)
            window.setFrame(frame, display: true)
        case "frame.y":
            var frame = window.frame
            frame.origin.y = try cgFloat(property)
            window.setFrame(frame, display: true)
        case "frame.width":
            var frame = window.frame
            frame.size.width = try nonNegative(property)
            window.setFrame(frame, display: true)
        case "frame.height":
            var frame = window.frame
            frame.size.height = try nonNegative(property)
            window.setFrame(frame, display: true)
        default:
            throw ViewScopeMutationError.unsupportedProperty
        }
    }

    // MARK: - 视图

    static func apply(_ property: ViewScopeEditableProperty, to view: NSView) throws {
        if property.key.hasPrefix("layer.") {
            // 视图节点上的 layer.* key：作用于其 backing layer，必要时开启 wantsLayer。
            view.wantsLayer = true
            guard let layer = view.layer else {
                throw ViewScopeMutationError.unsupportedProperty
            }
            try applyLayerSpecific(property, to: layer)
            view.needsDisplay = true
            return
        }
        if try applyAppKitSpecificMutation(property, to: view) {
            return
        }
        switch property.key {
        case "hidden":
            view.isHidden = try boolValue(property)
        case "alpha":
            view.alphaValue = try ViewScopeNumberConversion.unitInterval(property.numberValue)
        case "frame.x":
            var frame = view.frame
            frame.origin.x = try cgFloat(property)
            setFrame(frame, of: view)
        case "frame.y":
            var frame = view.frame
            frame.origin.y = try cgFloat(property)
            setFrame(frame, of: view)
        case "frame.width":
            var frame = view.frame
            frame.size.width = try nonNegative(property)
            setFrame(frame, of: view)
        case "frame.height":
            var frame = view.frame
            frame.size.height = try nonNegative(property)
            setFrame(frame, of: view)
        case "bounds.x":
            var bounds = view.bounds
            bounds.origin.x = try cgFloat(property)
            setBounds(bounds, of: view)
        case "bounds.y":
            var bounds = view.bounds
            bounds.origin.y = try cgFloat(property)
            setBounds(bounds, of: view)
        case "bounds.width":
            var bounds = view.bounds
            bounds.size.width = try nonNegative(property)
            setBounds(bounds, of: view)
        case "bounds.height":
            var bounds = view.bounds
            bounds.size.height = try nonNegative(property)
            setBounds(bounds, of: view)
        case "contentInsets.top", "contentInsets.left", "contentInsets.bottom", "contentInsets.right":
            try mutateScrollViewInsets(view, key: property.key, value: try cgFloat(property))
        case "backgroundColor":
            // 允许从“无背景色”设置，也允许传空字符串清除。
            let color = try optionalColor(property)
            view.wantsLayer = true
            withoutImplicitAnimations {
                view.layer?.backgroundColor = color?.cgColor
            }
            view.needsDisplay = true
        case "control.value":
            try applyControlValue(try textValue(property), to: view)
        case "toolTip":
            view.toolTip = try textValue(property)
        case "enabled":
            guard let control = view as? NSControl else {
                throw ViewScopeMutationError.unsupportedProperty
            }
            control.isEnabled = try boolValue(property)
        case "button.state":
            guard let button = view as? NSButton, button.allowsMixedState == false else {
                throw ViewScopeMutationError.unsupportedProperty
            }
            button.state = try boolValue(property) ? .on : .off
        case "textField.placeholderString":
            guard let textField = view as? NSTextField else {
                throw ViewScopeMutationError.unsupportedProperty
            }
            textField.placeholderString = try textValue(property)
        default:
            throw ViewScopeMutationError.unsupportedProperty
        }
    }

    /// 设置 frame。不再立刻对 superview 强制布局（B13）：
    /// Auto Layout 管理的视图会在下一次布局时按约束复位，强制布局只会让修改瞬间被还原。
    private static func setFrame(_ frame: NSRect, of view: NSView) {
        view.frame = frame
        view.needsLayout = true
        view.needsDisplay = true
    }

    private static func setBounds(_ bounds: NSRect, of view: NSView) {
        view.bounds = bounds
        view.needsLayout = true
        view.needsDisplay = true
    }

    // MARK: - 图层

    static func apply(_ property: ViewScopeEditableProperty, to layer: CALayer) throws {
        if property.key.hasPrefix("layer.") {
            try applyLayerSpecific(property, to: layer)
            layer.viewScopeNearestHostView?.needsDisplay = true
            return
        }
        try withoutImplicitAnimations {
            switch property.key {
            case "hidden":
                layer.isHidden = try boolValue(property)
            case "alpha":
                layer.opacity = Float(try ViewScopeNumberConversion.unitInterval(property.numberValue))
            case "frame.x":
                layer.frame.origin.x = try cgFloat(property)
            case "frame.y":
                layer.frame.origin.y = try cgFloat(property)
            case "frame.width":
                layer.frame.size.width = try nonNegative(property)
            case "frame.height":
                layer.frame.size.height = try nonNegative(property)
            case "bounds.x":
                layer.bounds.origin.x = try cgFloat(property)
            case "bounds.y":
                layer.bounds.origin.y = try cgFloat(property)
            case "bounds.width":
                layer.bounds.size.width = try nonNegative(property)
            case "bounds.height":
                layer.bounds.size.height = try nonNegative(property)
            case "backgroundColor":
                layer.backgroundColor = try optionalColor(property)?.cgColor
            default:
                throw ViewScopeMutationError.unsupportedProperty
            }
        }
        layer.setNeedsDisplay()
        layer.viewScopeNearestHostView?.needsDisplay = true
    }

    /// `layer.*` 专属 key。
    private static func applyLayerSpecific(_ property: ViewScopeEditableProperty, to layer: CALayer) throws {
        try withoutImplicitAnimations {
            switch property.key {
            case "layer.cornerRadius":
                layer.cornerRadius = try nonNegative(property)
            case "layer.borderWidth":
                layer.borderWidth = try nonNegative(property)
            case "layer.borderColor":
                layer.borderColor = try optionalColor(property)?.cgColor
            case "layer.masksToBounds":
                layer.masksToBounds = try boolValue(property)
            case "layer.shadowOpacity":
                layer.shadowOpacity = Float(try ViewScopeNumberConversion.unitInterval(property.numberValue))
            case "layer.shadowRadius":
                layer.shadowRadius = try nonNegative(property)
            case "layer.shadowOffset.width":
                layer.shadowOffset.width = try cgFloat(property)
            case "layer.shadowOffset.height":
                layer.shadowOffset.height = try cgFloat(property)
            case "layer.shadowColor":
                layer.shadowColor = try optionalColor(property)?.cgColor
            default:
                throw ViewScopeMutationError.unsupportedProperty
            }
        }
        layer.setNeedsDisplay()
    }

    // MARK: - AppKit 控件

    private static func requireView<T: NSView>(_ view: NSView, as type: T.Type) throws -> T {
        guard let typed = view as? T else {
            throw ViewScopeMutationError.unsupportedProperty
        }
        return typed
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func applyAppKitSpecificMutation(_ property: ViewScopeEditableProperty, to view: NSView) throws -> Bool {
        switch property.key {
        case "imageView.imageScaling":
            let imageView = try requireView(view, as: NSImageView.self)
            guard let scaling = NSImageScaling(rawValue: try enumUIntValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            imageView.imageScaling = scaling
        case "imageView.imageAlignment":
            let imageView = try requireView(view, as: NSImageView.self)
            guard let alignment = NSImageAlignment(rawValue: try enumUIntValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            imageView.imageAlignment = alignment
        case "imageView.animates":
            try requireView(view, as: NSImageView.self).animates = try boolValue(property)
        case "contentOffset.x", "contentOffset.y":
            let scrollView = try requireView(view, as: NSScrollView.self)
            var origin = scrollView.contentView.bounds.origin
            if property.key == "contentOffset.x" {
                origin.x = try cgFloat(property)
            } else {
                origin.y = try cgFloat(property)
            }
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        case "contentSize.width", "contentSize.height":
            let scrollView = try requireView(view, as: NSScrollView.self)
            guard let documentView = scrollView.documentView else {
                throw ViewScopeMutationError.unsupportedProperty
            }
            var size = documentView.frame.size
            if property.key == "contentSize.width" {
                size.width = try nonNegative(property)
            } else {
                size.height = try nonNegative(property)
            }
            documentView.setFrameSize(size)
        case "automaticallyAdjustsContentInsets":
            try requireView(view, as: NSScrollView.self).automaticallyAdjustsContentInsets = try boolValue(property)
        case "borderType":
            let scrollView = try requireView(view, as: NSScrollView.self)
            guard let borderType = NSBorderType(rawValue: try enumUIntValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            scrollView.borderType = borderType
        case "hasHorizontalScroller":
            try requireView(view, as: NSScrollView.self).hasHorizontalScroller = try boolValue(property)
        case "hasVerticalScroller":
            try requireView(view, as: NSScrollView.self).hasVerticalScroller = try boolValue(property)
        case "autohidesScrollers":
            try requireView(view, as: NSScrollView.self).autohidesScrollers = try boolValue(property)
        case "scrollerStyle":
            let scrollView = try requireView(view, as: NSScrollView.self)
            guard let style = NSScroller.Style(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            scrollView.scrollerStyle = style
        case "scrollerKnobStyle":
            let scrollView = try requireView(view, as: NSScrollView.self)
            guard let style = NSScroller.KnobStyle(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            scrollView.scrollerKnobStyle = style
        case "scrollsDynamically":
            try requireView(view, as: NSScrollView.self).scrollsDynamically = try boolValue(property)
        case "usesPredominantAxisScrolling":
            try requireView(view, as: NSScrollView.self).usesPredominantAxisScrolling = try boolValue(property)
        case "allowsMagnification":
            try requireView(view, as: NSScrollView.self).allowsMagnification = try boolValue(property)
        case "magnification":
            let scrollView = try requireView(view, as: NSScrollView.self)
            scrollView.setMagnification(try nonNegative(property), centeredAt: .zero)
        case "maxMagnification":
            try requireView(view, as: NSScrollView.self).maxMagnification = try nonNegative(property)
        case "minMagnification":
            try requireView(view, as: NSScrollView.self).minMagnification = try nonNegative(property)
        case "rowHeight":
            try requireView(view, as: NSTableView.self).rowHeight = try nonNegative(property)
        case "usesAutomaticRowHeights":
            try requireView(view, as: NSTableView.self).usesAutomaticRowHeights = try boolValue(property)
        case "intercellSpacing.width":
            let tableView = try requireView(view, as: NSTableView.self)
            var spacing = tableView.intercellSpacing
            spacing.width = try nonNegative(property)
            tableView.intercellSpacing = spacing
        case "intercellSpacing.height":
            let tableView = try requireView(view, as: NSTableView.self)
            var spacing = tableView.intercellSpacing
            spacing.height = try nonNegative(property)
            tableView.intercellSpacing = spacing
        case "style":
            let tableView = try requireView(view, as: NSTableView.self)
            guard let style = NSTableView.Style(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            tableView.style = style
        case "columnAutoresizingStyle":
            let tableView = try requireView(view, as: NSTableView.self)
            guard let style = NSTableView.ColumnAutoresizingStyle(rawValue: try enumUIntValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            tableView.columnAutoresizingStyle = style
        case "gridStyleMask":
            let tableView = try requireView(view, as: NSTableView.self)
            tableView.gridStyleMask = NSTableView.GridLineStyle(rawValue: try ViewScopeNumberConversion.uint(property.numberValue))
        case "selectionHighlightStyle":
            let tableView = try requireView(view, as: NSTableView.self)
            guard let style = NSTableView.SelectionHighlightStyle(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            tableView.selectionHighlightStyle = style
        case "gridColor":
            try requireView(view, as: NSTableView.self).gridColor = try color(property)
        case "rowSizeStyle":
            let tableView = try requireView(view, as: NSTableView.self)
            guard let style = NSTableView.RowSizeStyle(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            tableView.rowSizeStyle = style
        case "usesAlternatingRowBackgroundColors":
            try requireView(view, as: NSTableView.self).usesAlternatingRowBackgroundColors = try boolValue(property)
        case "allowsColumnReordering":
            try requireView(view, as: NSTableView.self).allowsColumnReordering = try boolValue(property)
        case "allowsColumnResizing":
            try requireView(view, as: NSTableView.self).allowsColumnResizing = try boolValue(property)
        case "allowsMultipleSelection":
            try requireView(view, as: NSTableView.self).allowsMultipleSelection = try boolValue(property)
        case "allowsEmptySelection":
            try requireView(view, as: NSTableView.self).allowsEmptySelection = try boolValue(property)
        case "allowsColumnSelection":
            try requireView(view, as: NSTableView.self).allowsColumnSelection = try boolValue(property)
        case "allowsTypeSelect":
            try requireView(view, as: NSTableView.self).allowsTypeSelect = try boolValue(property)
        case "floatsGroupRows":
            try requireView(view, as: NSTableView.self).floatsGroupRows = try boolValue(property)
        case "verticalMotionCanBeginDrag":
            try requireView(view, as: NSTableView.self).verticalMotionCanBeginDrag = try boolValue(property)
        case "textView.string":
            try requireView(view, as: NSTextView.self).string = try textValue(property)
        case "textView.fontSize":
            let textView = try requireView(view, as: NSTextView.self)
            let size = try nonNegative(property)
            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            textView.font = font.withSize(max(size, 1))
        case "textView.textColor":
            try requireView(view, as: NSTextView.self).textColor = try optionalColor(property)
        case "textView.alignment":
            let textView = try requireView(view, as: NSTextView.self)
            guard let alignment = NSTextAlignment(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            textView.alignment = alignment
        case "textView.textContainerInset.width":
            let textView = try requireView(view, as: NSTextView.self)
            var inset = textView.textContainerInset
            inset.width = try nonNegative(property)
            textView.textContainerInset = inset
        case "textView.textContainerInset.height":
            let textView = try requireView(view, as: NSTextView.self)
            var inset = textView.textContainerInset
            inset.height = try nonNegative(property)
            textView.textContainerInset = inset
        case "textView.maxSize.width":
            let textView = try requireView(view, as: NSTextView.self)
            var size = textView.maxSize
            size.width = try nonNegative(property)
            textView.maxSize = size
        case "textView.maxSize.height":
            let textView = try requireView(view, as: NSTextView.self)
            var size = textView.maxSize
            size.height = try nonNegative(property)
            textView.maxSize = size
        case "textView.minSize.width":
            let textView = try requireView(view, as: NSTextView.self)
            var size = textView.minSize
            size.width = try nonNegative(property)
            textView.minSize = size
        case "textView.minSize.height":
            let textView = try requireView(view, as: NSTextView.self)
            var size = textView.minSize
            size.height = try nonNegative(property)
            textView.minSize = size
        case "textView.isEditable":
            try requireView(view, as: NSTextView.self).isEditable = try boolValue(property)
        case "textView.isSelectable":
            try requireView(view, as: NSTextView.self).isSelectable = try boolValue(property)
        case "textView.isRichText":
            try requireView(view, as: NSTextView.self).isRichText = try boolValue(property)
        case "textView.importsGraphics":
            try requireView(view, as: NSTextView.self).importsGraphics = try boolValue(property)
        case "textView.isHorizontallyResizable":
            try requireView(view, as: NSTextView.self).isHorizontallyResizable = try boolValue(property)
        case "textView.isVerticallyResizable":
            try requireView(view, as: NSTextView.self).isVerticallyResizable = try boolValue(property)
        case "textField.isBordered":
            try requireView(view, as: NSTextField.self).isBordered = try boolValue(property)
        case "textField.isBezeled":
            try requireView(view, as: NSTextField.self).isBezeled = try boolValue(property)
        case "textField.bezelStyle":
            let textField = try requireView(view, as: NSTextField.self)
            guard let style = NSTextField.BezelStyle(rawValue: try enumUIntValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            textField.bezelStyle = style
        case "textField.isEditable":
            try requireView(view, as: NSTextField.self).isEditable = try boolValue(property)
        case "textField.isSelectable":
            try requireView(view, as: NSTextField.self).isSelectable = try boolValue(property)
        case "textField.drawsBackground":
            try requireView(view, as: NSTextField.self).drawsBackground = try boolValue(property)
        case "textField.preferredMaxLayoutWidth":
            try requireView(view, as: NSTextField.self).preferredMaxLayoutWidth = try nonNegative(property)
        case "textField.maximumNumberOfLines":
            let textField = try requireView(view, as: NSTextField.self)
            textField.maximumNumberOfLines = max(0, try ViewScopeNumberConversion.int(property.numberValue))
        case "textField.allowsDefaultTighteningForTruncation":
            try requireView(view, as: NSTextField.self).allowsDefaultTighteningForTruncation = try boolValue(property)
        case "textField.lineBreakStrategy":
            let textField = try requireView(view, as: NSTextField.self)
            textField.lineBreakStrategy = NSParagraphStyle.LineBreakStrategy(rawValue: try ViewScopeNumberConversion.uint(property.numberValue))
        case "textField.textColor":
            try requireView(view, as: NSTextField.self).textColor = try optionalColor(property)
        case "button.title":
            try requireView(view, as: NSButton.self).title = try textValue(property)
        case "button.alternateTitle":
            try requireView(view, as: NSButton.self).alternateTitle = try textValue(property)
        case "button.buttonType":
            let button = try requireView(view, as: NSButton.self)
            guard let buttonType = NSButton.ButtonType(rawValue: try enumUIntValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            button.setButtonType(buttonType)
        case "button.bezelStyle":
            let button = try requireView(view, as: NSButton.self)
            guard let bezelStyle = NSButton.BezelStyle(rawValue: try enumUIntValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            button.bezelStyle = bezelStyle
        case "button.isBordered":
            try requireView(view, as: NSButton.self).isBordered = try boolValue(property)
        case "button.isTransparent":
            try requireView(view, as: NSButton.self).isTransparent = try boolValue(property)
        case "button.bezelColor":
            try requireView(view, as: NSButton.self).bezelColor = try optionalColor(property)
        case "button.contentTintColor":
            try requireView(view, as: NSButton.self).contentTintColor = try optionalColor(property)
        case "button.showsBorderOnlyWhileMouseInside":
            try requireView(view, as: NSButton.self).showsBorderOnlyWhileMouseInside = try boolValue(property)
        case "button.isSpringLoaded":
            try requireView(view, as: NSButton.self).isSpringLoaded = try boolValue(property)
        case "control.controlSize":
            let control = try requireView(view, as: NSControl.self)
            guard let size = NSControl.ControlSize(rawValue: try enumUIntValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            control.controlSize = size
        case "control.alignment":
            let control = try requireView(view, as: NSControl.self)
            guard let alignment = NSTextAlignment(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            control.alignment = alignment
        case "control.fontSize":
            let control = try requireView(view, as: NSControl.self)
            let size = try nonNegative(property)
            let font = control.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            control.font = font.withSize(max(size, 1))
        case "visualEffect.material":
            let visualEffectView = try requireView(view, as: NSVisualEffectView.self)
            guard let material = NSVisualEffectView.Material(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            visualEffectView.material = material
        case "visualEffect.blendingMode":
            let visualEffectView = try requireView(view, as: NSVisualEffectView.self)
            guard let blendingMode = NSVisualEffectView.BlendingMode(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            visualEffectView.blendingMode = blendingMode
        case "visualEffect.state":
            let visualEffectView = try requireView(view, as: NSVisualEffectView.self)
            guard let state = NSVisualEffectView.State(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            visualEffectView.state = state
        case "visualEffect.isEmphasized":
            try requireView(view, as: NSVisualEffectView.self).isEmphasized = try boolValue(property)
        case "stack.orientation":
            let stackView = try requireView(view, as: NSStackView.self)
            guard let orientation = NSUserInterfaceLayoutOrientation(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            stackView.orientation = orientation
        case "stack.edgeInsets.top", "stack.edgeInsets.left", "stack.edgeInsets.bottom", "stack.edgeInsets.right":
            let stackView = try requireView(view, as: NSStackView.self)
            var insets = stackView.edgeInsets
            let value = try cgFloat(property)
            switch property.key {
            case "stack.edgeInsets.top":
                insets.top = value
            case "stack.edgeInsets.left":
                insets.left = value
            case "stack.edgeInsets.bottom":
                insets.bottom = value
            default:
                insets.right = value
            }
            stackView.edgeInsets = insets
        case "stack.detachesHiddenViews":
            try requireView(view, as: NSStackView.self).detachesHiddenViews = try boolValue(property)
        case "stack.distribution":
            let stackView = try requireView(view, as: NSStackView.self)
            guard let distribution = NSStackView.Distribution(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            stackView.distribution = distribution
        case "stack.alignment":
            let stackView = try requireView(view, as: NSStackView.self)
            guard let alignment = NSLayoutConstraint.Attribute(rawValue: try enumRawValue(property)) else {
                throw ViewScopeMutationError.invalidValue
            }
            stackView.alignment = alignment
        case "stack.spacing":
            try requireView(view, as: NSStackView.self).spacing = try cgFloat(property)
        default:
            return false
        }
        return true
    }

    private static func mutateScrollViewInsets(_ view: NSView, key: String, value: CGFloat) throws {
        let scrollView = try requireView(view, as: NSScrollView.self)
        var insets = scrollView.contentInsets
        switch key {
        case "contentInsets.top":
            insets.top = value
        case "contentInsets.left":
            insets.left = value
        case "contentInsets.bottom":
            insets.bottom = value
        default:
            insets.right = value
        }
        // 手动设置 insets 时必须关闭自动调整，否则会被系统覆盖。
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = insets
        scrollView.needsLayout = true
    }

    private static func applyControlValue(_ value: String, to view: NSView) throws {
        if let button = view as? NSButton {
            // 兼容旧客户端：NSButton 的 control.value 仍然修改标题。
            button.title = value
            return
        }
        if let control = view as? NSControl {
            control.stringValue = value
            return
        }
        throw ViewScopeMutationError.unsupportedProperty
    }
}
#endif
