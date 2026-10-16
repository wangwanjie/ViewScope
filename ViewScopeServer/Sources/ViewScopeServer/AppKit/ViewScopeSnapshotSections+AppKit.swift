#if os(macOS)
import AppKit
import Foundation

/// 枚举型可编辑属性的候选值表；属性面板与 mutation 校验共用，保证“能选的”就是“能设置的”。
@MainActor
enum ViewScopeAppKitEnumOptions {
    typealias Option = (title: String, rawValue: Int)

    static let imageScaling: [Option] = [
        ("scaleProportionallyDown", Int(NSImageScaling.scaleProportionallyDown.rawValue)),
        ("scaleAxesIndependently", Int(NSImageScaling.scaleAxesIndependently.rawValue)),
        ("scaleNone", Int(NSImageScaling.scaleNone.rawValue)),
        ("scaleProportionallyUpOrDown", Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue))
    ]

    static let imageAlignment: [Option] = [
        ("alignCenter", Int(NSImageAlignment.alignCenter.rawValue)),
        ("alignTop", Int(NSImageAlignment.alignTop.rawValue)),
        ("alignTopLeft", Int(NSImageAlignment.alignTopLeft.rawValue)),
        ("alignTopRight", Int(NSImageAlignment.alignTopRight.rawValue)),
        ("alignLeft", Int(NSImageAlignment.alignLeft.rawValue)),
        ("alignBottom", Int(NSImageAlignment.alignBottom.rawValue)),
        ("alignBottomLeft", Int(NSImageAlignment.alignBottomLeft.rawValue)),
        ("alignBottomRight", Int(NSImageAlignment.alignBottomRight.rawValue)),
        ("alignRight", Int(NSImageAlignment.alignRight.rawValue))
    ]

    static let borderType: [Option] = [
        ("noBorder", Int(NSBorderType.noBorder.rawValue)),
        ("lineBorder", Int(NSBorderType.lineBorder.rawValue)),
        ("bezelBorder", Int(NSBorderType.bezelBorder.rawValue)),
        ("grooveBorder", Int(NSBorderType.grooveBorder.rawValue))
    ]

    static let scrollerStyle: [Option] = [
        ("legacy", NSScroller.Style.legacy.rawValue),
        ("overlay", NSScroller.Style.overlay.rawValue)
    ]

    static let scrollerKnobStyle: [Option] = [
        ("default", NSScroller.KnobStyle.default.rawValue),
        ("dark", NSScroller.KnobStyle.dark.rawValue),
        ("light", NSScroller.KnobStyle.light.rawValue)
    ]

    static let tableStyle: [Option] = [
        ("automatic", NSTableView.Style.automatic.rawValue),
        ("fullWidth", NSTableView.Style.fullWidth.rawValue),
        ("inset", NSTableView.Style.inset.rawValue),
        ("sourceList", NSTableView.Style.sourceList.rawValue),
        ("plain", NSTableView.Style.plain.rawValue)
    ]

    static let columnAutoresizingStyle: [Option] = [
        ("noColumnAutoresizing", Int(NSTableView.ColumnAutoresizingStyle.noColumnAutoresizing.rawValue)),
        ("uniformColumnAutoresizingStyle", Int(NSTableView.ColumnAutoresizingStyle.uniformColumnAutoresizingStyle.rawValue)),
        ("sequentialColumnAutoresizingStyle", Int(NSTableView.ColumnAutoresizingStyle.sequentialColumnAutoresizingStyle.rawValue)),
        ("reverseSequentialColumnAutoresizingStyle", Int(NSTableView.ColumnAutoresizingStyle.reverseSequentialColumnAutoresizingStyle.rawValue)),
        ("lastColumnOnlyAutoresizingStyle", Int(NSTableView.ColumnAutoresizingStyle.lastColumnOnlyAutoresizingStyle.rawValue)),
        ("firstColumnOnlyAutoresizingStyle", Int(NSTableView.ColumnAutoresizingStyle.firstColumnOnlyAutoresizingStyle.rawValue))
    ]

    static let selectionHighlightStyle: [Option] = [
        ("none", NSTableView.SelectionHighlightStyle.none.rawValue),
        ("regular", NSTableView.SelectionHighlightStyle.regular.rawValue)
    ]

    static let rowSizeStyle: [Option] = [
        ("default", NSTableView.RowSizeStyle.default.rawValue),
        ("custom", NSTableView.RowSizeStyle.custom.rawValue),
        ("small", NSTableView.RowSizeStyle.small.rawValue),
        ("medium", NSTableView.RowSizeStyle.medium.rawValue),
        ("large", NSTableView.RowSizeStyle.large.rawValue)
    ]

    static let textAlignment: [Option] = [
        ("left", NSTextAlignment.left.rawValue),
        ("center", NSTextAlignment.center.rawValue),
        ("right", NSTextAlignment.right.rawValue),
        ("justified", NSTextAlignment.justified.rawValue),
        ("natural", NSTextAlignment.natural.rawValue)
    ]

    static let textFieldBezelStyle: [Option] = [
        ("squareBezel", Int(NSTextField.BezelStyle.squareBezel.rawValue)),
        ("roundedBezel", Int(NSTextField.BezelStyle.roundedBezel.rawValue))
    ]

    static let buttonType: [Option] = [
        ("momentaryPushIn", Int(NSButton.ButtonType.momentaryPushIn.rawValue)),
        ("momentaryLight", Int(NSButton.ButtonType.momentaryLight.rawValue)),
        ("momentaryChange", Int(NSButton.ButtonType.momentaryChange.rawValue)),
        ("pushOnPushOff", Int(NSButton.ButtonType.pushOnPushOff.rawValue)),
        ("onOff", Int(NSButton.ButtonType.onOff.rawValue)),
        ("toggle", Int(NSButton.ButtonType.toggle.rawValue)),
        ("switch", Int(NSButton.ButtonType.switch.rawValue)),
        ("radio", Int(NSButton.ButtonType.radio.rawValue)),
        ("accelerator", Int(NSButton.ButtonType.accelerator.rawValue)),
        ("multiLevelAccelerator", Int(NSButton.ButtonType.multiLevelAccelerator.rawValue))
    ]

    static var buttonBezelStyle: [Option] {
        var options: [Option] = [
            ("rounded", Int(NSButton.BezelStyle.rounded.rawValue)),
            ("regularSquare", Int(NSButton.BezelStyle.regularSquare.rawValue)),
            ("disclosure", Int(NSButton.BezelStyle.disclosure.rawValue)),
            ("shadowlessSquare", Int(NSButton.BezelStyle.shadowlessSquare.rawValue)),
            ("circular", Int(NSButton.BezelStyle.circular.rawValue)),
            ("texturedSquare", Int(NSButton.BezelStyle.texturedSquare.rawValue)),
            ("helpButton", Int(NSButton.BezelStyle.helpButton.rawValue)),
            ("smallSquare", Int(NSButton.BezelStyle.smallSquare.rawValue)),
            ("texturedRounded", Int(NSButton.BezelStyle.texturedRounded.rawValue)),
            ("roundRect", Int(NSButton.BezelStyle.roundRect.rawValue)),
            ("recessed", Int(NSButton.BezelStyle.recessed.rawValue)),
            ("roundedDisclosure", Int(NSButton.BezelStyle.roundedDisclosure.rawValue)),
            ("inline", Int(NSButton.BezelStyle.inline.rawValue))
        ]
        if #available(macOS 14.0, *) {
            options.insert(("automatic", Int(NSButton.BezelStyle.automatic.rawValue)), at: 0)
        }
        return options
    }

    static var controlSize: [Option] {
        let options: [Option] = [
            ("mini", Int(NSControl.ControlSize.mini.rawValue)),
            ("small", Int(NSControl.ControlSize.small.rawValue)),
            ("regular", Int(NSControl.ControlSize.regular.rawValue)),
            ("large", Int(NSControl.ControlSize.large.rawValue))
        ]
        return options
    }

    static let visualEffectMaterial: [Option] = [
        ("titlebar", NSVisualEffectView.Material.titlebar.rawValue),
        ("selection", NSVisualEffectView.Material.selection.rawValue),
        ("menu", NSVisualEffectView.Material.menu.rawValue),
        ("popover", NSVisualEffectView.Material.popover.rawValue),
        ("sidebar", NSVisualEffectView.Material.sidebar.rawValue),
        ("headerView", NSVisualEffectView.Material.headerView.rawValue),
        ("sheet", NSVisualEffectView.Material.sheet.rawValue),
        ("windowBackground", NSVisualEffectView.Material.windowBackground.rawValue),
        ("hudWindow", NSVisualEffectView.Material.hudWindow.rawValue),
        ("fullScreenUI", NSVisualEffectView.Material.fullScreenUI.rawValue),
        ("toolTip", NSVisualEffectView.Material.toolTip.rawValue),
        ("contentBackground", NSVisualEffectView.Material.contentBackground.rawValue),
        ("underWindowBackground", NSVisualEffectView.Material.underWindowBackground.rawValue),
        ("underPageBackground", NSVisualEffectView.Material.underPageBackground.rawValue)
    ]

    static let visualEffectBlendingMode: [Option] = [
        ("behindWindow", NSVisualEffectView.BlendingMode.behindWindow.rawValue),
        ("withinWindow", NSVisualEffectView.BlendingMode.withinWindow.rawValue)
    ]

    static let visualEffectState: [Option] = [
        ("followsWindowActiveState", NSVisualEffectView.State.followsWindowActiveState.rawValue),
        ("active", NSVisualEffectView.State.active.rawValue),
        ("inactive", NSVisualEffectView.State.inactive.rawValue)
    ]

    static let stackOrientation: [Option] = [
        ("horizontal", NSUserInterfaceLayoutOrientation.horizontal.rawValue),
        ("vertical", NSUserInterfaceLayoutOrientation.vertical.rawValue)
    ]

    static let stackDistribution: [Option] = [
        ("gravityAreas", NSStackView.Distribution.gravityAreas.rawValue),
        ("fill", NSStackView.Distribution.fill.rawValue),
        ("fillEqually", NSStackView.Distribution.fillEqually.rawValue),
        ("fillProportionally", NSStackView.Distribution.fillProportionally.rawValue),
        ("equalSpacing", NSStackView.Distribution.equalSpacing.rawValue),
        ("equalCentering", NSStackView.Distribution.equalCentering.rawValue)
    ]

    /// 水平 stack 的对齐取纵向属性；垂直 stack 取横向属性。
    static func stackAlignment(for orientation: NSUserInterfaceLayoutOrientation) -> [Option] {
        switch orientation {
        case .horizontal:
            return [
                ("top", NSLayoutConstraint.Attribute.top.rawValue),
                ("centerY", NSLayoutConstraint.Attribute.centerY.rawValue),
                ("bottom", NSLayoutConstraint.Attribute.bottom.rawValue),
                ("firstBaseline", NSLayoutConstraint.Attribute.firstBaseline.rawValue),
                ("lastBaseline", NSLayoutConstraint.Attribute.lastBaseline.rawValue)
            ]
        default:
            return [
                ("leading", NSLayoutConstraint.Attribute.leading.rawValue),
                ("centerX", NSLayoutConstraint.Attribute.centerX.rawValue),
                ("trailing", NSLayoutConstraint.Attribute.trailing.rawValue),
                ("left", NSLayoutConstraint.Attribute.left.rawValue),
                ("right", NSLayoutConstraint.Attribute.right.rawValue)
            ]
        }
    }

    /// 两个方向的并集，用于 mutation 校验。
    static var stackAlignmentAll: [Option] {
        stackAlignment(for: .horizontal) + stackAlignment(for: .vertical)
    }

    /// mutation key → 允许的 raw value 集合。
    static func allowedRawValues(forKey key: String) -> Set<Int>? {
        let options: [Option]?
        switch key {
        case "imageView.imageScaling":
            options = imageScaling
        case "imageView.imageAlignment":
            options = imageAlignment
        case "borderType":
            options = borderType
        case "scrollerStyle":
            options = scrollerStyle
        case "scrollerKnobStyle":
            options = scrollerKnobStyle
        case "style":
            options = tableStyle
        case "columnAutoresizingStyle":
            options = columnAutoresizingStyle
        case "selectionHighlightStyle":
            options = selectionHighlightStyle
        case "rowSizeStyle":
            options = rowSizeStyle
        case "textView.alignment", "control.alignment":
            options = textAlignment
        case "textField.bezelStyle":
            options = textFieldBezelStyle
        case "button.buttonType":
            options = buttonType
        case "button.bezelStyle":
            options = buttonBezelStyle
        case "control.controlSize":
            options = controlSize
        case "visualEffect.material":
            options = visualEffectMaterial
        case "visualEffect.blendingMode":
            options = visualEffectBlendingMode
        case "visualEffect.state":
            options = visualEffectState
        case "stack.orientation":
            options = stackOrientation
        case "stack.distribution":
            options = stackDistribution
        case "stack.alignment":
            options = stackAlignmentAll
        default:
            options = nil
        }
        return options.map { Set($0.map(\.rawValue)) }
    }
}

extension ViewScopeSnapshotBuilder {
    // MARK: - 可编辑条目

    func appKitText(_ key: String) -> String {
        interfaceLanguage.text("server.appkit.\(key)")
    }

    func formattedNumber(_ value: Double, decimals: Int) -> String {
        let format = "%.\(decimals)f"
        return String(format: format, locale: interfaceLanguage.locale, ViewScopeNumberConversion.finite(value))
    }

    func editableToggleItem(title: String, key: String, value: Bool) -> ViewScopePropertyItem {
        ViewScopePropertyItem(
            title: title,
            value: value.viewScopeBoolText(interfaceLanguage: interfaceLanguage),
            editable: .toggle(key: key, value: value)
        )
    }

    func editableNumberItem(title: String, key: String, value: Double, decimals: Int) -> ViewScopePropertyItem {
        let finiteValue = ViewScopeNumberConversion.finite(value)
        return ViewScopePropertyItem(
            title: title,
            value: formattedNumber(finiteValue, decimals: decimals),
            editable: .number(key: key, value: finiteValue)
        )
    }

    /// 枚举条目：当前值不在候选表中时，追加一个“原始值”候选，保证客户端下拉框能显示当前状态。
    func editableEnumItem(title: String, key: String, rawValue: Int, options: [ViewScopeAppKitEnumOptions.Option]) -> ViewScopePropertyItem {
        var editableOptions = options.map { ViewScopeEditableOption(title: $0.title, value: Double($0.rawValue)) }
        let currentTitle: String
        if let match = options.first(where: { $0.rawValue == rawValue }) {
            currentTitle = match.title
        } else {
            currentTitle = "\(rawValue)"
            editableOptions.append(ViewScopeEditableOption(title: currentTitle, value: Double(rawValue)))
        }
        return ViewScopePropertyItem(
            title: title,
            value: currentTitle,
            editable: .enumeration(key: key, value: Double(rawValue), options: editableOptions)
        )
    }

    func editableTextItem(title: String, key: String, value: String) -> ViewScopePropertyItem {
        ViewScopePropertyItem(
            title: title,
            value: value,
            editable: .text(key: key, value: value)
        )
    }

    func editableColorItem(title: String, key: String, value: String) -> ViewScopePropertyItem {
        ViewScopePropertyItem(
            title: title,
            value: value,
            editable: .text(key: key, value: value)
        )
    }

    func identityOnlySection(for object: AnyObject) -> ViewScopePropertySection {
        ViewScopePropertySection(
            title: text("server.section.identity"),
            items: [
                ViewScopePropertyItem(
                    title: text("server.item.class"),
                    value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: object)))
                ),
                ViewScopePropertyItem(title: text("server.item.address"), value: ViewScopeNodeIdentity.address(of: object))
            ]
        )
    }

    // MARK: - 窗口

    func windowSections(for window: NSWindow) -> [ViewScopePropertySection] {
        [
            ViewScopePropertySection(
                title: text("server.section.identity"),
                items: [
                    ViewScopePropertyItem(title: text("server.item.class"), value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: window)))),
                    editableTextItem(
                        title: text("server.item.title"),
                        key: "title",
                        value: sanitizedDisplayText(window.title) ?? ""
                    ),
                    ViewScopePropertyItem(title: text("server.item.window_number"), value: String(window.windowNumber)),
                    ViewScopePropertyItem(title: text("server.item.address"), value: window.viewScopeAddress)
                ]
            ),
            ViewScopePropertySection(
                title: text("server.section.state"),
                items: [
                    ViewScopePropertyItem(title: text("server.item.visible"), value: window.isVisible.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
                    ViewScopePropertyItem(title: text("server.item.key"), value: window.isKeyWindow.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
                    ViewScopePropertyItem(title: text("server.item.main"), value: window.isMainWindow.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
                    ViewScopePropertyItem(title: text("server.item.level"), value: String(window.level.rawValue)),
                    editableNumberItem(title: text("server.item.alpha"), key: "alpha", value: Double(window.alphaValue), decimals: 2)
                ]
            ),
            ViewScopePropertySection(
                title: text("server.section.geometry"),
                items: [
                    ViewScopePropertyItem(title: text("server.item.frame"), value: window.frame.viewScopeString),
                    editableNumberItem(title: text("server.item.x"), key: "frame.x", value: Double(window.frame.origin.x), decimals: 1),
                    editableNumberItem(title: text("server.item.y"), key: "frame.y", value: Double(window.frame.origin.y), decimals: 1),
                    editableNumberItem(title: text("server.item.width"), key: "frame.width", value: Double(window.frame.width), decimals: 1),
                    editableNumberItem(title: text("server.item.height"), key: "frame.height", value: Double(window.frame.height), decimals: 1),
                    ViewScopePropertyItem(title: text("server.item.content_layout"), value: window.contentLayoutRect.viewScopeString)
                ]
            )
        ]
    }

    // MARK: - 视图

    func viewSections(for view: NSView) -> [ViewScopePropertySection] {
        var identityItems = [
            ViewScopePropertyItem(title: text("server.item.class"), value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: view)))),
            ViewScopePropertyItem(title: text("server.item.address"), value: view.viewScopeAddress)
        ]
        if let layer = view.layer {
            identityItems.append(
                ViewScopePropertyItem(
                    title: appKitText("item.backing_layer"),
                    value: "\(ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: layer)))) \(layer.viewScopeAddress)"
                )
            )
        }
        if let title = sanitizedDisplayText(view.viewScopeTitle(interfaceLanguage: interfaceLanguage)) {
            identityItems.append(ViewScopePropertyItem(title: text("server.item.title"), value: title))
        }
        if let identifier = view.identifier?.rawValue, !identifier.isEmpty {
            identityItems.append(ViewScopePropertyItem(title: text("server.item.identifier"), value: identifier))
        }
        if let rootViewControllerClassName = view.viewScopeExactRootViewControllerClassName {
            identityItems.append(
                ViewScopePropertyItem(
                    title: text("server.item.view_controller"),
                    value: ViewScopeClassNameFormatter.displayName(for: rootViewControllerClassName)
                )
            )
        }
        identityItems.append(
            editableTextItem(
                title: text("server.item.tooltip"),
                key: "toolTip",
                value: view.toolTip ?? ""
            )
        )

        let layoutItems = [
            ViewScopePropertyItem(title: text("server.item.frame"), value: view.frame.viewScopeString),
            editableNumberItem(title: text("server.item.x"), key: "frame.x", value: Double(view.frame.origin.x), decimals: 1),
            editableNumberItem(title: text("server.item.y"), key: "frame.y", value: Double(view.frame.origin.y), decimals: 1),
            editableNumberItem(title: text("server.item.width"), key: "frame.width", value: Double(view.frame.width), decimals: 1),
            editableNumberItem(title: text("server.item.height"), key: "frame.height", value: Double(view.frame.height), decimals: 1),
            ViewScopePropertyItem(title: text("server.item.bounds"), value: view.bounds.viewScopeString),
            editableNumberItem(title: text("server.item.bounds_x"), key: "bounds.x", value: Double(view.bounds.origin.x), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_y"), key: "bounds.y", value: Double(view.bounds.origin.y), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_width"), key: "bounds.width", value: Double(view.bounds.width), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_height"), key: "bounds.height", value: Double(view.bounds.height), decimals: 1),
            ViewScopePropertyItem(title: text("server.item.intrinsic_size"), value: view.intrinsicContentSize.viewScopeString(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: text("server.item.translates_mask"), value: view.translatesAutoresizingMaskIntoConstraints.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: text("server.item.ambiguous_layout"), value: view.hasAmbiguousLayout.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(
                title: text("server.item.hugging_h"),
                value: String(format: "%.1f", locale: interfaceLanguage.locale, view.contentHuggingPriority(for: .horizontal).rawValue)
            ),
            ViewScopePropertyItem(
                title: text("server.item.hugging_v"),
                value: String(format: "%.1f", locale: interfaceLanguage.locale, view.contentHuggingPriority(for: .vertical).rawValue)
            ),
            ViewScopePropertyItem(
                title: text("server.item.compression_h"),
                value: String(format: "%.1f", locale: interfaceLanguage.locale, view.contentCompressionResistancePriority(for: .horizontal).rawValue)
            ),
            ViewScopePropertyItem(
                title: text("server.item.compression_v"),
                value: String(format: "%.1f", locale: interfaceLanguage.locale, view.contentCompressionResistancePriority(for: .vertical).rawValue)
            )
        ]

        let renderingItems = [
            editableToggleItem(title: text("server.item.hidden"), key: "hidden", value: view.isHidden),
            editableNumberItem(title: text("server.item.alpha"), key: "alpha", value: Double(view.alphaValue), decimals: 2),
            ViewScopePropertyItem(title: text("server.item.layer_backed"), value: view.wantsLayer.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: text("server.item.flipped"), value: view.isFlipped.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: text("server.item.opaque"), value: view.isOpaque.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: text("server.item.subviews"), value: String(view.subviews.count)),
            // 背景色总是可编辑：没有背景色时值为空，设置后会自动开启 wantsLayer。
            editableColorItem(
                title: text("server.item.background"),
                key: "backgroundColor",
                value: view.layer?.backgroundColor?.viewScopeHexString ?? ""
            )
        ]

        var sections = [
            ViewScopePropertySection(title: text("server.section.identity"), items: identityItems),
            ViewScopePropertySection(title: text("server.section.layout"), items: layoutItems),
            ViewScopePropertySection(title: text("server.section.rendering"), items: renderingItems)
        ]

        if let layer = view.layer {
            sections.append(layerSpecificSection(for: layer))
        }

        if let control = view as? NSControl {
            sections.append(controlSection(for: control))
        }

        sections.append(contentsOf: appKitSpecificSections(for: view))
        sections.append(accessibilitySection(for: view))
        return sections
    }

    private func controlSection(for control: NSControl) -> ViewScopePropertySection {
        var controlItems: [ViewScopePropertyItem] = [
            editableToggleItem(title: text("server.item.enabled"), key: "enabled", value: control.isEnabled)
        ]
        // NSButton 的标题由 `button.title` 编辑，这里不再重复给出 control.value。
        if control is NSButton {
            controlItems.append(ViewScopePropertyItem(title: text("server.item.value"), value: control.viewScopeControlValue))
        } else {
            controlItems.append(
                ViewScopePropertyItem(
                    title: text("server.item.value"),
                    value: control.viewScopeControlValue,
                    editable: .text(key: "control.value", value: control.viewScopeControlValue)
                )
            )
        }

        if let button = control as? NSButton, button.allowsMixedState == false {
            controlItems.append(
                editableToggleItem(
                    title: text("server.item.button_state"),
                    key: "button.state",
                    value: button.state == .on
                )
            )
        }

        if let textField = control as? NSTextField {
            controlItems.append(
                editableTextItem(
                    title: text("server.item.placeholder"),
                    key: "textField.placeholderString",
                    value: textField.placeholderString ?? ""
                )
            )
        }

        if let targetClassName = control.viewScopeTargetClassName {
            controlItems.append(
                ViewScopePropertyItem(
                    title: text("server.item.target"),
                    value: ViewScopeClassNameFormatter.displayName(for: targetClassName)
                )
            )
        } else if control.viewScopeActionName != nil {
            controlItems.append(
                ViewScopePropertyItem(
                    title: text("server.item.target"),
                    value: text("server.value.first_responder")
                )
            )
        }

        if let actionName = control.viewScopeActionName {
            controlItems.append(
                ViewScopePropertyItem(
                    title: text("server.item.action"),
                    value: actionName
                )
            )
        }

        if let fontName = control.font?.fontName {
            controlItems.append(ViewScopePropertyItem(title: appKitText("item.font_name"), value: fontName))
        }
        controlItems.append(contentsOf: [
            editableEnumItem(title: appKitText("item.control_size"), key: "control.controlSize", rawValue: Int(control.controlSize.rawValue), options: ViewScopeAppKitEnumOptions.controlSize),
            editableEnumItem(title: appKitText("item.alignment"), key: "control.alignment", rawValue: control.alignment.rawValue, options: ViewScopeAppKitEnumOptions.textAlignment),
            editableNumberItem(title: appKitText("item.font_size"), key: "control.fontSize", value: Double(control.font?.pointSize ?? NSFont.systemFontSize), decimals: 1)
        ])

        return ViewScopePropertySection(title: text("server.section.control"), items: controlItems)
    }

    private func accessibilitySection(for view: NSView) -> ViewScopePropertySection {
        var items: [ViewScopePropertyItem] = [
            ViewScopePropertyItem(title: appKitText("item.accessibility_element"), value: view.isAccessibilityElement().viewScopeBoolText(interfaceLanguage: interfaceLanguage))
        ]
        if let identifier = sanitizedDisplayText(view.accessibilityIdentifier()) {
            items.append(ViewScopePropertyItem(title: appKitText("item.accessibility_identifier"), value: identifier))
        }
        if let label = sanitizedDisplayText(view.accessibilityLabel()) {
            items.append(ViewScopePropertyItem(title: appKitText("item.accessibility_label"), value: label))
        }
        return ViewScopePropertySection(title: appKitText("section.accessibility"), items: items)
    }

    // MARK: - 图层

    /// 纯 CALayer 的分区。
    func layerSections(for layer: CALayer) -> [ViewScopePropertySection] {
        let identityItems = [
            ViewScopePropertyItem(
                title: text("server.item.class"),
                value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: layer)))
            ),
            ViewScopePropertyItem(title: text("server.item.address"), value: layer.viewScopeAddress)
        ]

        let layoutItems = [
            ViewScopePropertyItem(title: text("server.item.frame"), value: layer.frame.viewScopeString),
            editableNumberItem(title: text("server.item.x"), key: "frame.x", value: Double(layer.frame.origin.x), decimals: 1),
            editableNumberItem(title: text("server.item.y"), key: "frame.y", value: Double(layer.frame.origin.y), decimals: 1),
            editableNumberItem(title: text("server.item.width"), key: "frame.width", value: Double(layer.frame.width), decimals: 1),
            editableNumberItem(title: text("server.item.height"), key: "frame.height", value: Double(layer.frame.height), decimals: 1),
            ViewScopePropertyItem(title: text("server.item.bounds"), value: layer.bounds.viewScopeString),
            editableNumberItem(title: text("server.item.bounds_x"), key: "bounds.x", value: Double(layer.bounds.origin.x), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_y"), key: "bounds.y", value: Double(layer.bounds.origin.y), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_width"), key: "bounds.width", value: Double(layer.bounds.width), decimals: 1),
            editableNumberItem(title: text("server.item.bounds_height"), key: "bounds.height", value: Double(layer.bounds.height), decimals: 1)
        ]

        let renderingItems = [
            editableToggleItem(title: text("server.item.hidden"), key: "hidden", value: layer.isHidden),
            editableNumberItem(title: text("server.item.alpha"), key: "alpha", value: Double(layer.opacity), decimals: 2),
            ViewScopePropertyItem(title: text("server.item.flipped"), value: layer.isGeometryFlipped.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            ViewScopePropertyItem(title: text("server.item.opaque"), value: layer.isOpaque.viewScopeBoolText(interfaceLanguage: interfaceLanguage)),
            editableColorItem(
                title: text("server.item.background"),
                key: "backgroundColor",
                value: layer.backgroundColor?.viewScopeHexString ?? ""
            )
        ]

        return [
            ViewScopePropertySection(title: text("server.section.identity"), items: identityItems),
            ViewScopePropertySection(title: text("server.section.layout"), items: layoutItems),
            ViewScopePropertySection(title: text("server.section.rendering"), items: renderingItems),
            layerSpecificSection(for: layer)
        ]
    }

    /// layer 专属项；所有 key 都以 `layer.` 开头，mutation 时直接作用于该 layer。
    func layerSpecificSection(for layer: CALayer) -> ViewScopePropertySection {
        ViewScopePropertySection(
            title: appKitText("section.layer"),
            items: [
                ViewScopePropertyItem(
                    title: text("server.item.class"),
                    value: ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: layer)))
                ),
                editableToggleItem(title: appKitText("item.masks_to_bounds"), key: "layer.masksToBounds", value: layer.masksToBounds),
                editableNumberItem(title: text("server.item.corner_radius"), key: "layer.cornerRadius", value: Double(layer.cornerRadius), decimals: 1),
                editableNumberItem(title: text("server.item.border_width"), key: "layer.borderWidth", value: Double(layer.borderWidth), decimals: 1),
                editableColorItem(title: appKitText("item.border_color"), key: "layer.borderColor", value: layer.borderColor?.viewScopeHexString ?? ""),
                editableNumberItem(title: appKitText("item.shadow_opacity"), key: "layer.shadowOpacity", value: Double(layer.shadowOpacity), decimals: 2),
                editableNumberItem(title: appKitText("item.shadow_radius"), key: "layer.shadowRadius", value: Double(layer.shadowRadius), decimals: 1),
                editableNumberItem(title: appKitText("item.shadow_offset_width"), key: "layer.shadowOffset.width", value: Double(layer.shadowOffset.width), decimals: 1),
                editableNumberItem(title: appKitText("item.shadow_offset_height"), key: "layer.shadowOffset.height", value: Double(layer.shadowOffset.height), decimals: 1),
                editableColorItem(title: appKitText("item.shadow_color"), key: "layer.shadowColor", value: layer.shadowColor?.viewScopeHexString ?? ""),
                ViewScopePropertyItem(title: appKitText("item.sublayers"), value: String(layer.sublayers?.count ?? 0))
            ]
        )
    }

    // MARK: - AppKit 控件专属分区

    func appKitSpecificSections(for view: NSView) -> [ViewScopePropertySection] {
        var sections: [ViewScopePropertySection] = []

        if let imageView = view as? NSImageView {
            var imageItems: [ViewScopePropertyItem] = []
            if let imageName = imageView.image?.name() {
                imageItems.append(ViewScopePropertyItem(title: appKitText("item.image_name"), value: imageName))
            }
            if let image = imageView.image {
                imageItems.append(ViewScopePropertyItem(title: appKitText("item.image_size"), value: image.size.viewScopeString(interfaceLanguage: interfaceLanguage)))
            }
            imageItems.append(contentsOf: [
                editableEnumItem(title: appKitText("item.image_scaling"), key: "imageView.imageScaling", rawValue: Int(imageView.imageScaling.rawValue), options: ViewScopeAppKitEnumOptions.imageScaling),
                editableEnumItem(title: appKitText("item.image_alignment"), key: "imageView.imageAlignment", rawValue: Int(imageView.imageAlignment.rawValue), options: ViewScopeAppKitEnumOptions.imageAlignment),
                editableToggleItem(title: appKitText("item.animates"), key: "imageView.animates", value: imageView.animates)
            ])
            sections.append(ViewScopePropertySection(title: appKitText("section.image_view"), items: imageItems))
        }

        if let scrollView = view as? NSScrollView {
            sections.append(
                ViewScopePropertySection(
                    title: appKitText("section.scroll_view"),
                    items: [
                        editableNumberItem(title: appKitText("item.content_offset_x"), key: "contentOffset.x", value: Double(scrollView.contentView.bounds.origin.x), decimals: 1),
                        editableNumberItem(title: appKitText("item.content_offset_y"), key: "contentOffset.y", value: Double(scrollView.contentView.bounds.origin.y), decimals: 1),
                        editableNumberItem(title: appKitText("item.content_size_width"), key: "contentSize.width", value: Double(scrollView.documentView?.frame.width ?? 0), decimals: 1),
                        editableNumberItem(title: appKitText("item.content_size_height"), key: "contentSize.height", value: Double(scrollView.documentView?.frame.height ?? 0), decimals: 1),
                        editableToggleItem(title: appKitText("item.automatically_adjusts_content_insets"), key: "automaticallyAdjustsContentInsets", value: scrollView.automaticallyAdjustsContentInsets),
                        editableNumberItem(title: appKitText("item.content_insets_top"), key: "contentInsets.top", value: Double(scrollView.contentInsets.top), decimals: 1),
                        editableNumberItem(title: appKitText("item.content_insets_left"), key: "contentInsets.left", value: Double(scrollView.contentInsets.left), decimals: 1),
                        editableNumberItem(title: appKitText("item.content_insets_bottom"), key: "contentInsets.bottom", value: Double(scrollView.contentInsets.bottom), decimals: 1),
                        editableNumberItem(title: appKitText("item.content_insets_right"), key: "contentInsets.right", value: Double(scrollView.contentInsets.right), decimals: 1),
                        editableEnumItem(title: appKitText("item.border_type"), key: "borderType", rawValue: Int(scrollView.borderType.rawValue), options: ViewScopeAppKitEnumOptions.borderType),
                        editableToggleItem(title: appKitText("item.has_horizontal_scroller"), key: "hasHorizontalScroller", value: scrollView.hasHorizontalScroller),
                        editableToggleItem(title: appKitText("item.has_vertical_scroller"), key: "hasVerticalScroller", value: scrollView.hasVerticalScroller),
                        editableToggleItem(title: appKitText("item.autohides_scrollers"), key: "autohidesScrollers", value: scrollView.autohidesScrollers),
                        editableEnumItem(title: appKitText("item.scroller_style"), key: "scrollerStyle", rawValue: scrollView.scrollerStyle.rawValue, options: ViewScopeAppKitEnumOptions.scrollerStyle),
                        editableEnumItem(title: appKitText("item.scroller_knob_style"), key: "scrollerKnobStyle", rawValue: scrollView.scrollerKnobStyle.rawValue, options: ViewScopeAppKitEnumOptions.scrollerKnobStyle),
                        editableToggleItem(title: appKitText("item.scrolls_dynamically"), key: "scrollsDynamically", value: scrollView.scrollsDynamically),
                        editableToggleItem(title: appKitText("item.uses_predominant_axis_scrolling"), key: "usesPredominantAxisScrolling", value: scrollView.usesPredominantAxisScrolling),
                        editableToggleItem(title: appKitText("item.allows_magnification"), key: "allowsMagnification", value: scrollView.allowsMagnification),
                        editableNumberItem(title: appKitText("item.magnification"), key: "magnification", value: Double(scrollView.magnification), decimals: 2),
                        editableNumberItem(title: appKitText("item.max_magnification"), key: "maxMagnification", value: Double(scrollView.maxMagnification), decimals: 2),
                        editableNumberItem(title: appKitText("item.min_magnification"), key: "minMagnification", value: Double(scrollView.minMagnification), decimals: 2)
                    ]
                )
            )
        }

        if let tableView = view as? NSTableView {
            var tableItems: [ViewScopePropertyItem] = [
                editableNumberItem(title: appKitText("item.row_height"), key: "rowHeight", value: Double(tableView.rowHeight), decimals: 1),
                editableToggleItem(title: appKitText("item.uses_automatic_row_heights"), key: "usesAutomaticRowHeights", value: tableView.usesAutomaticRowHeights),
                editableNumberItem(title: appKitText("item.intercell_spacing_width"), key: "intercellSpacing.width", value: Double(tableView.intercellSpacing.width), decimals: 1),
                editableNumberItem(title: appKitText("item.intercell_spacing_height"), key: "intercellSpacing.height", value: Double(tableView.intercellSpacing.height), decimals: 1),
                editableEnumItem(title: appKitText("item.table_style"), key: "style", rawValue: tableView.style.rawValue, options: ViewScopeAppKitEnumOptions.tableStyle),
                editableEnumItem(title: appKitText("item.column_autoresizing"), key: "columnAutoresizingStyle", rawValue: Int(tableView.columnAutoresizingStyle.rawValue), options: ViewScopeAppKitEnumOptions.columnAutoresizingStyle),
                editableNumberItem(title: appKitText("item.grid_style_mask"), key: "gridStyleMask", value: Double(tableView.gridStyleMask.rawValue), decimals: 0),
                editableEnumItem(title: appKitText("item.selection_highlight_style"), key: "selectionHighlightStyle", rawValue: tableView.selectionHighlightStyle.rawValue, options: ViewScopeAppKitEnumOptions.selectionHighlightStyle),
                editableEnumItem(title: appKitText("item.row_size_style"), key: "rowSizeStyle", rawValue: tableView.rowSizeStyle.rawValue, options: ViewScopeAppKitEnumOptions.rowSizeStyle),
                ViewScopePropertyItem(title: appKitText("item.number_of_rows"), value: String(tableView.numberOfRows)),
                ViewScopePropertyItem(title: appKitText("item.number_of_columns"), value: String(tableView.numberOfColumns)),
                editableToggleItem(title: appKitText("item.alternating_row_backgrounds"), key: "usesAlternatingRowBackgroundColors", value: tableView.usesAlternatingRowBackgroundColors),
                editableToggleItem(title: appKitText("item.allows_column_reordering"), key: "allowsColumnReordering", value: tableView.allowsColumnReordering),
                editableToggleItem(title: appKitText("item.allows_column_resizing"), key: "allowsColumnResizing", value: tableView.allowsColumnResizing),
                editableToggleItem(title: appKitText("item.allows_multiple_selection"), key: "allowsMultipleSelection", value: tableView.allowsMultipleSelection),
                editableToggleItem(title: appKitText("item.allows_empty_selection"), key: "allowsEmptySelection", value: tableView.allowsEmptySelection),
                editableToggleItem(title: appKitText("item.allows_column_selection"), key: "allowsColumnSelection", value: tableView.allowsColumnSelection),
                editableToggleItem(title: appKitText("item.allows_type_select"), key: "allowsTypeSelect", value: tableView.allowsTypeSelect),
                editableToggleItem(title: appKitText("item.floats_group_rows"), key: "floatsGroupRows", value: tableView.floatsGroupRows),
                editableToggleItem(title: appKitText("item.vertical_motion_can_begin_drag"), key: "verticalMotionCanBeginDrag", value: tableView.verticalMotionCanBeginDrag)
            ]
            tableItems.append(editableColorItem(title: appKitText("item.grid_color"), key: "gridColor", value: tableView.gridColor.cgColor.viewScopeHexString ?? ""))
            sections.append(ViewScopePropertySection(title: appKitText("section.table_view"), items: tableItems))
        }

        if let textView = view as? NSTextView {
            var textViewItems: [ViewScopePropertyItem] = [
                editableTextItem(title: appKitText("item.string"), key: "textView.string", value: textView.string)
            ]
            if let fontName = textView.font?.fontName {
                textViewItems.append(ViewScopePropertyItem(title: appKitText("item.font_name"), value: fontName))
            }
            textViewItems.append(contentsOf: [
                editableNumberItem(title: appKitText("item.font_size"), key: "textView.fontSize", value: Double(textView.font?.pointSize ?? NSFont.systemFontSize), decimals: 1),
                editableEnumItem(title: appKitText("item.alignment"), key: "textView.alignment", rawValue: textView.alignment.rawValue, options: ViewScopeAppKitEnumOptions.textAlignment),
                editableNumberItem(title: appKitText("item.text_container_inset_width"), key: "textView.textContainerInset.width", value: Double(textView.textContainerInset.width), decimals: 1),
                editableNumberItem(title: appKitText("item.text_container_inset_height"), key: "textView.textContainerInset.height", value: Double(textView.textContainerInset.height), decimals: 1),
                editableNumberItem(title: appKitText("item.max_size_width"), key: "textView.maxSize.width", value: Double(textView.maxSize.width), decimals: 1),
                editableNumberItem(title: appKitText("item.max_size_height"), key: "textView.maxSize.height", value: Double(textView.maxSize.height), decimals: 1),
                editableNumberItem(title: appKitText("item.min_size_width"), key: "textView.minSize.width", value: Double(textView.minSize.width), decimals: 1),
                editableNumberItem(title: appKitText("item.min_size_height"), key: "textView.minSize.height", value: Double(textView.minSize.height), decimals: 1),
                editableToggleItem(title: appKitText("item.editable"), key: "textView.isEditable", value: textView.isEditable),
                editableToggleItem(title: appKitText("item.selectable"), key: "textView.isSelectable", value: textView.isSelectable),
                editableToggleItem(title: appKitText("item.rich_text"), key: "textView.isRichText", value: textView.isRichText),
                editableToggleItem(title: appKitText("item.imports_graphics"), key: "textView.importsGraphics", value: textView.importsGraphics),
                editableToggleItem(title: appKitText("item.horizontally_resizable"), key: "textView.isHorizontallyResizable", value: textView.isHorizontallyResizable),
                editableToggleItem(title: appKitText("item.vertically_resizable"), key: "textView.isVerticallyResizable", value: textView.isVerticallyResizable),
                editableColorItem(title: appKitText("item.text_color"), key: "textView.textColor", value: textView.textColor?.cgColor.viewScopeHexString ?? "")
            ])
            sections.append(ViewScopePropertySection(title: appKitText("section.text_view"), items: textViewItems))
        }

        if let textField = view as? NSTextField {
            let textFieldItems: [ViewScopePropertyItem] = [
                editableToggleItem(title: appKitText("item.bordered"), key: "textField.isBordered", value: textField.isBordered),
                editableToggleItem(title: appKitText("item.bezeled"), key: "textField.isBezeled", value: textField.isBezeled),
                editableEnumItem(title: appKitText("item.bezel_style"), key: "textField.bezelStyle", rawValue: Int(textField.bezelStyle.rawValue), options: ViewScopeAppKitEnumOptions.textFieldBezelStyle),
                editableToggleItem(title: appKitText("item.editable"), key: "textField.isEditable", value: textField.isEditable),
                editableToggleItem(title: appKitText("item.selectable"), key: "textField.isSelectable", value: textField.isSelectable),
                editableToggleItem(title: appKitText("item.draws_background"), key: "textField.drawsBackground", value: textField.drawsBackground),
                editableNumberItem(title: appKitText("item.preferred_max_layout_width"), key: "textField.preferredMaxLayoutWidth", value: Double(textField.preferredMaxLayoutWidth), decimals: 1),
                editableNumberItem(title: appKitText("item.maximum_number_of_lines"), key: "textField.maximumNumberOfLines", value: Double(textField.maximumNumberOfLines), decimals: 0),
                editableToggleItem(title: appKitText("item.allows_default_tightening"), key: "textField.allowsDefaultTighteningForTruncation", value: textField.allowsDefaultTighteningForTruncation),
                editableNumberItem(title: appKitText("item.line_break_strategy"), key: "textField.lineBreakStrategy", value: Double(textField.lineBreakStrategy.rawValue), decimals: 0),
                editableColorItem(title: appKitText("item.text_color"), key: "textField.textColor", value: textField.textColor?.cgColor.viewScopeHexString ?? "")
            ]
            sections.append(ViewScopePropertySection(title: appKitText("section.text_field"), items: textFieldItems))
        }

        if let button = view as? NSButton {
            var buttonItems: [ViewScopePropertyItem] = [
                editableTextItem(title: appKitText("item.title"), key: "button.title", value: button.title),
                editableTextItem(title: appKitText("item.alternate_title"), key: "button.alternateTitle", value: button.alternateTitle),
                editableEnumItem(title: appKitText("item.button_type"), key: "button.buttonType", rawValue: Int(button.viewScopeButtonType.rawValue), options: ViewScopeAppKitEnumOptions.buttonType),
                editableEnumItem(title: appKitText("item.bezel_style"), key: "button.bezelStyle", rawValue: Int(button.bezelStyle.rawValue), options: ViewScopeAppKitEnumOptions.buttonBezelStyle),
                editableToggleItem(title: appKitText("item.bordered"), key: "button.isBordered", value: button.isBordered),
                editableToggleItem(title: appKitText("item.transparent"), key: "button.isTransparent", value: button.isTransparent),
                editableToggleItem(title: appKitText("item.shows_border_only_while_mouse_inside"), key: "button.showsBorderOnlyWhileMouseInside", value: button.showsBorderOnlyWhileMouseInside),
                editableToggleItem(title: appKitText("item.spring_loaded"), key: "button.isSpringLoaded", value: button.isSpringLoaded)
            ]
            buttonItems.append(editableColorItem(title: appKitText("item.bezel_color"), key: "button.bezelColor", value: button.bezelColor?.cgColor.viewScopeHexString ?? ""))
            buttonItems.append(editableColorItem(title: appKitText("item.content_tint_color"), key: "button.contentTintColor", value: button.contentTintColor?.cgColor.viewScopeHexString ?? ""))
            sections.append(ViewScopePropertySection(title: appKitText("section.button"), items: buttonItems))
        }

        if let visualEffectView = view as? NSVisualEffectView {
            sections.append(
                ViewScopePropertySection(
                    title: appKitText("section.visual_effect"),
                    items: [
                        editableEnumItem(title: appKitText("item.material"), key: "visualEffect.material", rawValue: visualEffectView.material.rawValue, options: ViewScopeAppKitEnumOptions.visualEffectMaterial),
                        ViewScopePropertyItem(title: appKitText("item.interior_background_style"), value: String(visualEffectView.interiorBackgroundStyle.rawValue)),
                        editableEnumItem(title: appKitText("item.blending_mode"), key: "visualEffect.blendingMode", rawValue: visualEffectView.blendingMode.rawValue, options: ViewScopeAppKitEnumOptions.visualEffectBlendingMode),
                        editableEnumItem(title: appKitText("item.state"), key: "visualEffect.state", rawValue: visualEffectView.state.rawValue, options: ViewScopeAppKitEnumOptions.visualEffectState),
                        editableToggleItem(title: appKitText("item.emphasized"), key: "visualEffect.isEmphasized", value: visualEffectView.isEmphasized)
                    ]
                )
            )
        }

        if let stackView = view as? NSStackView {
            sections.append(
                ViewScopePropertySection(
                    title: appKitText("section.stack_view"),
                    items: [
                        editableEnumItem(title: appKitText("item.orientation"), key: "stack.orientation", rawValue: stackView.orientation.rawValue, options: ViewScopeAppKitEnumOptions.stackOrientation),
                        editableNumberItem(title: appKitText("item.edge_insets_top"), key: "stack.edgeInsets.top", value: Double(stackView.edgeInsets.top), decimals: 1),
                        editableNumberItem(title: appKitText("item.edge_insets_left"), key: "stack.edgeInsets.left", value: Double(stackView.edgeInsets.left), decimals: 1),
                        editableNumberItem(title: appKitText("item.edge_insets_bottom"), key: "stack.edgeInsets.bottom", value: Double(stackView.edgeInsets.bottom), decimals: 1),
                        editableNumberItem(title: appKitText("item.edge_insets_right"), key: "stack.edgeInsets.right", value: Double(stackView.edgeInsets.right), decimals: 1),
                        editableToggleItem(title: appKitText("item.detaches_hidden_views"), key: "stack.detachesHiddenViews", value: stackView.detachesHiddenViews),
                        editableEnumItem(title: appKitText("item.distribution"), key: "stack.distribution", rawValue: stackView.distribution.rawValue, options: ViewScopeAppKitEnumOptions.stackDistribution),
                        editableEnumItem(title: appKitText("item.alignment"), key: "stack.alignment", rawValue: stackView.alignment.rawValue, options: ViewScopeAppKitEnumOptions.stackAlignment(for: stackView.orientation)),
                        editableNumberItem(title: appKitText("item.spacing"), key: "stack.spacing", value: Double(stackView.spacing), decimals: 1)
                    ]
                )
            )
        }

        return sections
    }

    // MARK: - Traits

    func windowTraits(for window: NSWindow) -> ViewScopeNodeTraits {
        ViewScopeNodeTraits(
            isUserInteractionEnabled: window.ignoresMouseEvents == false,
            isOpaque: window.isOpaque,
            backgroundAlpha: window.backgroundColor.flatMap { Double($0.alphaComponent) },
            frameInSuperview: window.frame.viewScopeRect,
            displayScale: Double(window.backingScaleFactor)
        )
    }

    /// 视图（或带宿主视图的 layer）节点的诊断信息。
    func viewTraits(for view: NSView, layer: CALayer?) -> ViewScopeNodeTraits {
        let intrinsicSize = view.intrinsicContentSize
        var imageSize: ViewScopeSize?
        var imageScale: Double?
        if let image = (view as? NSImageView)?.image, image.size.width > 0 {
            imageSize = image.size.viewScopeSize
            let pixelsWide = image.representations.map(\.pixelsWide).max() ?? 0
            if pixelsWide > 0 {
                imageScale = Double(pixelsWide) / Double(image.size.width)
            }
        }
        return ViewScopeNodeTraits(
            isUserInteractionEnabled: view.isHidden == false,
            hasAmbiguousLayout: view.hasAmbiguousLayout,
            translatesAutoresizingMaskIntoConstraints: view.translatesAutoresizingMaskIntoConstraints,
            isOpaque: view.isOpaque || (layer?.isOpaque ?? false),
            backgroundAlpha: layer?.backgroundColor.map { Double($0.alpha) },
            frameInSuperview: view.frame.viewScopeRect,
            displayScale: Double(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1),
            intrinsicContentSize: intrinsicSize.viewScopeHasIntrinsicMetric ? intrinsicSize.viewScopeSize : nil,
            constraintCount: relatedConstraints(for: view).count,
            accessibilityIdentifier: sanitizedDisplayText(view.accessibilityIdentifier()),
            accessibilityLabel: sanitizedDisplayText(view.accessibilityLabel()),
            isAccessibilityElement: view.isAccessibilityElement(),
            isInteractiveControl: view is NSControl || view.gestureRecognizers.isEmpty == false,
            isTextTruncated: (view as? NSTextField).flatMap { $0.viewScopeIsTextTruncated },
            imageSize: imageSize,
            imageScale: imageScale
        )
    }

    func layerTraits(for layer: CALayer) -> ViewScopeNodeTraits {
        ViewScopeNodeTraits(
            isUserInteractionEnabled: layer.isHidden == false,
            isOpaque: layer.isOpaque,
            backgroundAlpha: layer.backgroundColor.map { Double($0.alpha) },
            frameInSuperview: layer.frame.viewScopeRect,
            displayScale: Double(layer.contentsScale)
        )
    }
}

private extension NSTextField {
    /// 文本是否被截断：单行比较完整宽度，多行比较完整高度。
    @MainActor
    var viewScopeIsTextTruncated: Bool? {
        guard let cell, bounds.width > 0, bounds.height > 0, stringValue.isEmpty == false else {
            return nil
        }
        let isSingleLine = maximumNumberOfLines == 1 || cell.wraps == false
        if isSingleLine {
            let fullSize = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: bounds.height))
            return fullSize.width > bounds.width + 0.5
        }
        let fullSize = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: CGFloat.greatestFiniteMagnitude))
        return fullSize.height > bounds.height + 0.5
    }
}

extension NSButton {
    /// 读取按钮类型：公开 API 没有 getter，这里用受保护的 KVC 读取私有 `_buttonType`（A10）。
    ///
    /// 仅当 cell 确实声明了该 ivar 时才读取，读取失败回退 `.momentaryPushIn`。
    @MainActor
    var viewScopeButtonType: NSButton.ButtonType {
        guard let cell,
              ViewScopeButtonTypeReader.hasButtonTypeIvar(cell) else {
            return .momentaryPushIn
        }
        if let rawValue = ViewScopeButtonTypeReader.readButtonType(from: cell),
           let buttonType = NSButton.ButtonType(rawValue: rawValue) {
            return buttonType
        }
        return .momentaryPushIn
    }
}

enum ViewScopeButtonTypeReader {
    static func hasButtonTypeIvar(_ cell: NSCell) -> Bool {
        var currentClass: AnyClass? = type(of: cell)
        while let targetClass = currentClass {
            if class_getInstanceVariable(targetClass, "_buttonType") != nil {
                return true
            }
            currentClass = class_getSuperclass(targetClass)
        }
        return false
    }

    /// 只在 ivar 为整数类型时直接读取原始值，避免 KVC 抛出 NSUnknownKeyException。
    static func readButtonType(from cell: NSCell) -> UInt? {
        var currentClass: AnyClass? = type(of: cell)
        while let targetClass = currentClass {
            if let ivar = class_getInstanceVariable(targetClass, "_buttonType"),
               let encodingPointer = ivar_getTypeEncoding(ivar) {
                let encoding = String(cString: encodingPointer)
                let base = UnsafeRawPointer(Unmanaged.passUnretained(cell).toOpaque()).advanced(by: ivar_getOffset(ivar))
                switch encoding {
                case "Q", "L":
                    return UInt(base.load(as: UInt64.self))
                case "q", "l":
                    let value = base.load(as: Int64.self)
                    return value >= 0 ? UInt(value) : nil
                case "I":
                    return UInt(base.load(as: UInt32.self))
                case "i":
                    let value = base.load(as: Int32.self)
                    return value >= 0 ? UInt(value) : nil
                default:
                    return nil
                }
            }
            currentClass = class_getSuperclass(targetClass)
        }
        return nil
    }
}
#endif
