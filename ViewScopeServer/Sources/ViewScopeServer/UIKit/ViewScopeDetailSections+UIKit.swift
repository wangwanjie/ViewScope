#if os(iOS)
import Foundation
import UIKit

/// 生成 UIKit 节点 detail 的属性分区。
///
/// 可编辑 key 与 `ViewScopeMutationApplier`（UIKit 版）一一对应：
/// - 视图级 key（`hidden`、`alpha`、`frame.*`、`bounds.*`、`backgroundColor`、各控件专属 key）作用于宿主视图；
/// - `layer.*` key 作用于 layer；
/// - 纯 CALayer 节点的 `hidden` / `alpha` / `frame.*` / `bounds.*` / `backgroundColor` 作用于 layer 本身。
@MainActor
struct ViewScopeUIKitDetailSectionBuilder {
    let language: ViewScopeInterfaceLanguage

    // MARK: - 视图

    func viewSections(for view: UIView) -> [ViewScopePropertySection] {
        var sections = [
            identitySection(for: view),
            layoutSection(for: view),
            renderingSection(for: view)
        ]
        sections.append(contentsOf: specificSections(for: view))
        return sections
    }

    private func identitySection(for view: UIView) -> ViewScopePropertySection {
        var items = [
            readonly("server.item.class", className(of: view)),
            readonly("server.item.address", ViewScopeNodeIdentity.address(of: view)),
            readonly("server.uikit.item.layer_class", className(of: view.layer)),
            readonly("server.uikit.item.layer_address", ViewScopeNodeIdentity.address(of: view.layer))
        ]
        if let title = ViewScopeUIKitViewDescriber.title(for: view, language: language) {
            items.append(readonly("server.item.title", title))
        }
        if let identifier = view.accessibilityIdentifier, identifier.isEmpty == false {
            items.append(readonly("server.uikit.item.accessibility_identifier", identifier))
        }
        if let label = view.accessibilityLabel, label.isEmpty == false {
            items.append(readonly("server.uikit.item.accessibility_label", label))
        }
        items.append(readonly("server.uikit.item.accessibility_element", boolText(view.isAccessibilityElement)))
        if let controller = view.kg_viewScopeExactViewController {
            items.append(readonly("server.item.view_controller", className(of: controller)))
        }
        return ViewScopePropertySection(title: text("server.section.identity"), items: items)
    }

    private func layoutSection(for view: UIView) -> ViewScopePropertySection {
        let frame = view.frame
        let bounds = view.bounds
        let margins = view.layoutMargins
        var items = [
            readonly("server.item.frame", rectText(frame)),
            number("server.item.x", key: "frame.x", value: frame.origin.x),
            number("server.item.y", key: "frame.y", value: frame.origin.y),
            number("server.item.width", key: "frame.width", value: frame.width),
            number("server.item.height", key: "frame.height", value: frame.height),
            readonly("server.item.bounds", rectText(bounds)),
            number("server.uikit.item.bounds_x", key: "bounds.x", value: bounds.origin.x),
            number("server.uikit.item.bounds_y", key: "bounds.y", value: bounds.origin.y),
            number("server.uikit.item.bounds_width", key: "bounds.width", value: bounds.width),
            number("server.uikit.item.bounds_height", key: "bounds.height", value: bounds.height),
            readonly("server.uikit.item.center", pointText(view.center)),
            readonly("server.uikit.item.transform", transformText(view.transform)),
            readonly("server.uikit.item.autoresizing", autoresizingText(view.autoresizingMask)),
            readonly("server.item.intrinsic_size", intrinsicSizeText(view.intrinsicContentSize)),
            readonly("server.item.translates_mask", boolText(view.translatesAutoresizingMaskIntoConstraints)),
            readonly("server.item.hugging_h", priorityText(view.contentHuggingPriority(for: .horizontal))),
            readonly("server.item.hugging_v", priorityText(view.contentHuggingPriority(for: .vertical))),
            readonly("server.item.compression_h", priorityText(view.contentCompressionResistancePriority(for: .horizontal))),
            readonly("server.item.compression_v", priorityText(view.contentCompressionResistancePriority(for: .vertical))),
            readonly("server.uikit.item.safe_area_insets", insetsText(view.safeAreaInsets)),
            number("server.uikit.item.margin_top", key: "layoutMargins.top", value: margins.top),
            number("server.uikit.item.margin_left", key: "layoutMargins.left", value: margins.left),
            number("server.uikit.item.margin_bottom", key: "layoutMargins.bottom", value: margins.bottom),
            number("server.uikit.item.margin_right", key: "layoutMargins.right", value: margins.right)
        ]
        if view.translatesAutoresizingMaskIntoConstraints == false {
            items.append(readonly("server.uikit.item.ambiguous_layout", boolText(view.hasAmbiguousLayout)))
        }
        return ViewScopePropertySection(title: text("server.section.layout"), items: items)
    }

    private func renderingSection(for view: UIView) -> ViewScopePropertySection {
        var items = [
            toggle("server.item.hidden", key: "hidden", value: view.isHidden),
            number("server.item.alpha", key: "alpha", value: view.alpha, decimals: 2),
            toggle("server.uikit.item.opaque", key: "opaque", value: view.isOpaque),
            toggle("server.uikit.item.clips_to_bounds", key: "clipsToBounds", value: view.clipsToBounds),
            color("server.item.background", key: "backgroundColor", color: view.backgroundColor, traits: view.traitCollection),
            color("server.uikit.item.tint_color", key: "tintColor", color: view.tintColor, traits: view.traitCollection),
            enumeration("server.uikit.item.content_mode", key: "contentMode", value: view.contentMode.rawValue, options: Self.contentModeOptions),
            toggle("server.uikit.item.user_interaction", key: "userInteractionEnabled", value: view.isUserInteractionEnabled),
            number("server.uikit.item.tag", key: "tag", value: CGFloat(view.tag), decimals: 0),
            readonly("server.item.subviews", String(view.subviews.count)),
            readonly("server.uikit.item.content_scale", formatted(view.contentScaleFactor, decimals: 1))
        ]
        items.append(contentsOf: layerRenderingItems(for: view.layer))
        return ViewScopePropertySection(title: text("server.section.rendering"), items: items)
    }

    /// layer 专属的渲染项（`layer.*` key），视图节点与纯 layer 节点共用。
    private func layerRenderingItems(for layer: CALayer) -> [ViewScopePropertyItem] {
        [
            number("server.item.corner_radius", key: "layer.cornerRadius", value: layer.cornerRadius),
            number("server.item.border_width", key: "layer.borderWidth", value: layer.borderWidth),
            cgColor("server.uikit.item.border_color", key: "layer.borderColor", color: layer.borderColor),
            toggle("server.uikit.item.masks_to_bounds", key: "layer.masksToBounds", value: layer.masksToBounds),
            number("server.uikit.item.shadow_opacity", key: "layer.shadowOpacity", value: CGFloat(layer.shadowOpacity), decimals: 2),
            number("server.uikit.item.shadow_radius", key: "layer.shadowRadius", value: layer.shadowRadius),
            number("server.uikit.item.shadow_offset_x", key: "layer.shadowOffset.width", value: layer.shadowOffset.width),
            number("server.uikit.item.shadow_offset_y", key: "layer.shadowOffset.height", value: layer.shadowOffset.height),
            cgColor("server.uikit.item.shadow_color", key: "layer.shadowColor", color: layer.shadowColor)
        ]
    }

    // MARK: - 纯 CALayer

    func layerSections(for layer: CALayer) -> [ViewScopePropertySection] {
        var identityItems = [
            readonly("server.item.class", className(of: layer)),
            readonly("server.item.address", ViewScopeNodeIdentity.address(of: layer))
        ]
        if let name = layer.name, name.isEmpty == false {
            identityItems.append(readonly("server.uikit.item.layer_name", name))
        }
        if let delegate = layer.delegate {
            identityItems.append(readonly("server.uikit.item.layer_delegate", className(of: delegate)))
        }

        let frame = layer.frame
        let bounds = layer.bounds
        let layoutItems = [
            readonly("server.item.frame", rectText(frame)),
            number("server.item.x", key: "frame.x", value: frame.origin.x),
            number("server.item.y", key: "frame.y", value: frame.origin.y),
            number("server.item.width", key: "frame.width", value: frame.width),
            number("server.item.height", key: "frame.height", value: frame.height),
            readonly("server.item.bounds", rectText(bounds)),
            number("server.uikit.item.bounds_x", key: "bounds.x", value: bounds.origin.x),
            number("server.uikit.item.bounds_y", key: "bounds.y", value: bounds.origin.y),
            number("server.uikit.item.bounds_width", key: "bounds.width", value: bounds.width),
            number("server.uikit.item.bounds_height", key: "bounds.height", value: bounds.height),
            readonly("server.uikit.item.position", pointText(layer.position)),
            readonly("server.uikit.item.anchor_point", pointText(layer.anchorPoint)),
            number("server.uikit.item.z_position", key: "layer.zPosition", value: layer.zPosition),
            readonly("server.uikit.item.transform", transformText(layer.affineTransform()))
        ]

        var renderingItems = [
            toggle("server.item.hidden", key: "hidden", value: layer.isHidden),
            number("server.item.alpha", key: "alpha", value: CGFloat(layer.opacity), decimals: 2),
            toggle("server.uikit.item.opaque", key: "layer.isOpaque", value: layer.isOpaque),
            cgColor("server.item.background", key: "backgroundColor", color: layer.backgroundColor),
            readonly("server.uikit.item.sublayers", String(layer.sublayers?.count ?? 0)),
            readonly("server.uikit.item.content_scale", formatted(layer.contentsScale, decimals: 1)),
            readonly("server.uikit.item.has_contents", boolText(layer.contents != nil))
        ]
        renderingItems.append(contentsOf: layerRenderingItems(for: layer))

        var sections = [
            ViewScopePropertySection(title: text("server.section.identity"), items: identityItems),
            ViewScopePropertySection(title: text("server.section.layout"), items: layoutItems),
            ViewScopePropertySection(title: text("server.section.rendering"), items: renderingItems)
        ]
        if let shapeLayer = layer as? CAShapeLayer {
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.shape_layer"),
                items: [
                    cgColor("server.uikit.item.fill_color", key: "shape.fillColor", color: shapeLayer.fillColor),
                    cgColor("server.uikit.item.stroke_color", key: "shape.strokeColor", color: shapeLayer.strokeColor),
                    number("server.uikit.item.line_width", key: "shape.lineWidth", value: shapeLayer.lineWidth),
                    number("server.uikit.item.stroke_start", key: "shape.strokeStart", value: shapeLayer.strokeStart, decimals: 2),
                    number("server.uikit.item.stroke_end", key: "shape.strokeEnd", value: shapeLayer.strokeEnd, decimals: 2)
                ]
            ))
        }
        if let gradientLayer = layer as? CAGradientLayer {
            let colors = (gradientLayer.colors ?? []).compactMap { value -> String? in
                // CAGradientLayer.colors 里是 CGColor（以 AnyObject 形式存放）。
                let object = value as CFTypeRef
                guard CFGetTypeID(object) == CGColor.typeID else {
                    return nil
                }
                return ViewScopeColorParsing.hexString(from: unsafeDowncast(object, to: CGColor.self))
            }
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.gradient_layer"),
                items: [
                    readonly("server.uikit.item.colors", colors.joined(separator: ", ")),
                    readonly("server.uikit.item.start_point", pointText(gradientLayer.startPoint)),
                    readonly("server.uikit.item.end_point", pointText(gradientLayer.endPoint)),
                    readonly("server.uikit.item.gradient_type", gradientLayer.type.rawValue)
                ]
            ))
        }
        if let textLayer = layer as? CATextLayer {
            let string: String
            if let plain = textLayer.string as? String {
                string = plain
            } else if let attributed = textLayer.string as? NSAttributedString {
                string = attributed.string
            } else {
                string = ""
            }
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.text_layer"),
                items: [
                    readonly("server.uikit.item.text", string),
                    number("server.uikit.item.font_size", key: "textLayer.fontSize", value: textLayer.fontSize)
                ]
            ))
        }
        return sections
    }

    // MARK: - 窗口节点

    func windowSections(for window: UIWindow) -> [ViewScopePropertySection] {
        viewSections(for: window)
    }

    // MARK: - 控件专属分区

    private func specificSections(for view: UIView) -> [ViewScopePropertySection] {
        var sections: [ViewScopePropertySection] = []
        let traits = view.traitCollection

        if let window = view as? UIWindow {
            var items = [
                number("server.uikit.item.window_level", key: "window.windowLevel", value: window.windowLevel.rawValue, decimals: 0),
                readonly("server.uikit.item.key_window", boolText(window.isKeyWindow)),
                readonly("server.uikit.item.screen_scale", formatted(window.screen.scale, decimals: 1))
            ]
            if let rootViewController = window.rootViewController {
                items.append(readonly("server.uikit.item.root_view_controller", className(of: rootViewController)))
            }
            if let scene = window.windowScene {
                items.append(readonly("server.uikit.item.scene_state", sceneStateText(scene.activationState)))
            }
            sections.append(ViewScopePropertySection(title: text("server.uikit.section.window"), items: items))
        }

        if let label = view as? UILabel {
            var items = [
                textField("server.uikit.item.text", key: "label.text", value: label.text ?? ""),
                readonly("server.uikit.item.font", label.font.map(fontText) ?? "-"),
                number("server.uikit.item.font_size", key: "label.fontSize", value: label.font?.pointSize ?? UIFont.labelFontSize),
                color("server.uikit.item.text_color", key: "label.textColor", color: label.textColor, traits: traits),
                number("server.uikit.item.number_of_lines", key: "label.numberOfLines", value: CGFloat(label.numberOfLines), decimals: 0),
                enumeration("server.uikit.item.text_alignment", key: "label.textAlignment", value: label.textAlignment.rawValue, options: Self.textAlignmentOptions),
                enumeration("server.uikit.item.line_break_mode", key: "label.lineBreakMode", value: label.lineBreakMode.rawValue, options: Self.lineBreakModeOptions),
                toggle("server.uikit.item.adjusts_font_size", key: "label.adjustsFontSizeToFitWidth", value: label.adjustsFontSizeToFitWidth)
            ]
            if let truncated = ViewScopeUIKitViewDescriber.isTextTruncated(label) {
                items.append(readonly("server.uikit.item.truncated", boolText(truncated)))
            }
            sections.append(ViewScopePropertySection(title: text("server.uikit.section.label"), items: items))
        }

        if let control = view as? UIControl {
            var items = [
                toggle("server.item.enabled", key: "control.isEnabled", value: control.isEnabled),
                toggle("server.uikit.item.selected", key: "control.isSelected", value: control.isSelected),
                toggle("server.uikit.item.highlighted", key: "control.isHighlighted", value: control.isHighlighted),
                enumeration(
                    "server.uikit.item.horizontal_alignment",
                    key: "control.contentHorizontalAlignment",
                    value: control.contentHorizontalAlignment.rawValue,
                    options: Self.horizontalAlignmentOptions
                ),
                enumeration(
                    "server.uikit.item.vertical_alignment",
                    key: "control.contentVerticalAlignment",
                    value: control.contentVerticalAlignment.rawValue,
                    options: Self.verticalAlignmentOptions
                )
            ]
            for handler in ViewScopeUIKitViewDescriber.controlEventHandlers(for: control, idPrefix: "detail") {
                for targetAction in handler.targetActions {
                    let target = targetAction.targetClassName.map { ViewScopeClassNameFormatter.displayName(for: $0) }
                        ?? text("server.value.first_responder")
                    let action = targetAction.actionName ?? "-"
                    let events = handler.subtitle.map { " (\($0))" } ?? ""
                    items.append(readonly("server.item.action", "\(target) · \(action)\(events)"))
                }
            }
            sections.append(ViewScopePropertySection(title: text("server.section.control"), items: items))
        }

        if let button = view as? UIButton {
            sections.append(buttonSection(for: button, traits: traits))
        }

        if let imageView = view as? UIImageView {
            var items: [ViewScopePropertyItem] = []
            if let image = imageView.image {
                items.append(readonly("server.uikit.item.image_size", sizeText(image.size)))
                items.append(readonly("server.uikit.item.image_scale", formatted(image.scale, decimals: 1)))
                items.append(readonly("server.uikit.item.rendering_mode", renderingModeText(image.renderingMode)))
            } else {
                items.append(readonly("server.uikit.item.image_size", "-"))
            }
            items.append(toggle("server.uikit.item.highlighted", key: "imageView.isHighlighted", value: imageView.isHighlighted))
            items.append(readonly("server.uikit.item.animating", boolText(imageView.isAnimating)))
            sections.append(ViewScopePropertySection(title: text("server.uikit.section.image_view"), items: items))
        }

        if let textField = view as? UITextField {
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.text_field"),
                items: [
                    self.textField("server.uikit.item.text", key: "textField.text", value: textField.text ?? ""),
                    self.textField("server.item.placeholder", key: "textField.placeholder", value: textField.placeholder ?? ""),
                    number("server.uikit.item.font_size", key: "textField.fontSize", value: textField.font?.pointSize ?? UIFont.systemFontSize),
                    color("server.uikit.item.text_color", key: "textField.textColor", color: textField.textColor, traits: traits),
                    enumeration("server.uikit.item.text_alignment", key: "textField.textAlignment", value: textField.textAlignment.rawValue, options: Self.textAlignmentOptions),
                    enumeration("server.uikit.item.border_style", key: "textField.borderStyle", value: textField.borderStyle.rawValue, options: Self.borderStyleOptions),
                    toggle("server.uikit.item.secure_entry", key: "textField.isSecureTextEntry", value: textField.isSecureTextEntry),
                    readonly("server.uikit.item.editing", boolText(textField.isEditing))
                ]
            ))
        }

        if let textView = view as? UITextView {
            let inset = textView.textContainerInset
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.text_view"),
                items: [
                    self.textField("server.uikit.item.text", key: "textView.text", value: textView.text ?? ""),
                    toggle("server.uikit.item.editable", key: "textView.isEditable", value: textView.isEditable),
                    toggle("server.uikit.item.selectable", key: "textView.isSelectable", value: textView.isSelectable),
                    number("server.uikit.item.font_size", key: "textView.fontSize", value: textView.font?.pointSize ?? UIFont.systemFontSize),
                    color("server.uikit.item.text_color", key: "textView.textColor", color: textView.textColor, traits: traits),
                    enumeration("server.uikit.item.text_alignment", key: "textView.textAlignment", value: textView.textAlignment.rawValue, options: Self.textAlignmentOptions),
                    number("server.uikit.item.inset_top", key: "textView.textContainerInset.top", value: inset.top),
                    number("server.uikit.item.inset_left", key: "textView.textContainerInset.left", value: inset.left),
                    number("server.uikit.item.inset_bottom", key: "textView.textContainerInset.bottom", value: inset.bottom),
                    number("server.uikit.item.inset_right", key: "textView.textContainerInset.right", value: inset.right)
                ]
            ))
        }

        if let scrollView = view as? UIScrollView {
            sections.append(scrollViewSection(for: scrollView))
        }

        if let tableView = view as? UITableView {
            var rowCount = 0
            for section in 0 ..< tableView.numberOfSections {
                rowCount += tableView.numberOfRows(inSection: section)
            }
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.table_view"),
                items: [
                    readonly("server.uikit.item.table_style", tableStyleText(tableView.style)),
                    readonly("server.uikit.item.sections", String(tableView.numberOfSections)),
                    readonly("server.uikit.item.rows", String(rowCount)),
                    number("server.uikit.item.row_height", key: "tableView.rowHeight", value: tableView.rowHeight),
                    number("server.uikit.item.estimated_row_height", key: "tableView.estimatedRowHeight", value: tableView.estimatedRowHeight),
                    number("server.uikit.item.section_header_height", key: "tableView.sectionHeaderHeight", value: tableView.sectionHeaderHeight),
                    number("server.uikit.item.section_footer_height", key: "tableView.sectionFooterHeight", value: tableView.sectionFooterHeight),
                    enumeration("server.uikit.item.separator_style", key: "tableView.separatorStyle", value: tableView.separatorStyle.rawValue, options: Self.separatorStyleOptions),
                    color("server.uikit.item.separator_color", key: "tableView.separatorColor", color: tableView.separatorColor, traits: traits),
                    readonly("server.uikit.item.separator_inset", insetsText(tableView.separatorInset))
                ]
            ))
        }

        if let collectionView = view as? UICollectionView {
            sections.append(collectionViewSection(for: collectionView))
        }

        if let stackView = view as? UIStackView {
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.stack_view"),
                items: [
                    enumeration("server.uikit.item.axis", key: "stack.axis", value: stackView.axis.rawValue, options: Self.axisOptions),
                    enumeration("server.uikit.item.distribution", key: "stack.distribution", value: stackView.distribution.rawValue, options: Self.distributionOptions),
                    enumeration("server.uikit.item.alignment", key: "stack.alignment", value: stackView.alignment.rawValue, options: Self.stackAlignmentOptions),
                    number("server.uikit.item.spacing", key: "stack.spacing", value: stackView.spacing),
                    toggle("server.uikit.item.margins_relative", key: "stack.isLayoutMarginsRelativeArrangement", value: stackView.isLayoutMarginsRelativeArrangement),
                    toggle("server.uikit.item.baseline_relative", key: "stack.isBaselineRelativeArrangement", value: stackView.isBaselineRelativeArrangement),
                    readonly("server.uikit.item.arranged_subviews", String(stackView.arrangedSubviews.count))
                ]
            ))
        }

        if let toggleSwitch = view as? UISwitch {
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.switch"),
                items: [
                    toggle("server.uikit.item.on", key: "switch.isOn", value: toggleSwitch.isOn),
                    color("server.uikit.item.on_tint_color", key: "switch.onTintColor", color: toggleSwitch.onTintColor, traits: traits)
                ]
            ))
        }

        if let slider = view as? UISlider {
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.slider"),
                items: [
                    number("server.item.value", key: "slider.value", value: CGFloat(slider.value), decimals: 2),
                    number("server.uikit.item.minimum_value", key: "slider.minimumValue", value: CGFloat(slider.minimumValue), decimals: 2),
                    number("server.uikit.item.maximum_value", key: "slider.maximumValue", value: CGFloat(slider.maximumValue), decimals: 2),
                    toggle("server.uikit.item.continuous", key: "slider.isContinuous", value: slider.isContinuous)
                ]
            ))
        }

        if let segmented = view as? UISegmentedControl {
            var options = [ViewScopeEditableOption(title: text("server.uikit.value.none"), value: Double(UISegmentedControl.noSegment))]
            for index in 0 ..< segmented.numberOfSegments {
                let title = segmented.titleForSegment(at: index) ?? "#\(index)"
                options.append(ViewScopeEditableOption(title: title, value: Double(index)))
            }
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.segmented_control"),
                items: [
                    readonly("server.uikit.item.segments", String(segmented.numberOfSegments)),
                    ViewScopePropertyItem(
                        title: text("server.uikit.item.selected_segment"),
                        value: String(segmented.selectedSegmentIndex),
                        editable: .enumeration(
                            key: "segmented.selectedSegmentIndex",
                            value: Double(segmented.selectedSegmentIndex),
                            options: options
                        )
                    )
                ]
            ))
        }

        if let progressView = view as? UIProgressView {
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.progress_view"),
                items: [
                    number("server.uikit.item.progress", key: "progress.progress", value: CGFloat(progressView.progress), decimals: 2),
                    color("server.uikit.item.progress_tint_color", key: "progress.progressTintColor", color: progressView.progressTintColor, traits: traits)
                ]
            ))
        }

        if let activityView = view as? UIActivityIndicatorView {
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.activity_indicator"),
                items: [
                    toggle("server.uikit.item.animating", key: "activity.isAnimating", value: activityView.isAnimating),
                    toggle("server.uikit.item.hides_when_stopped", key: "activity.hidesWhenStopped", value: activityView.hidesWhenStopped),
                    color("server.uikit.item.color", key: "activity.color", color: activityView.color, traits: traits)
                ]
            ))
        }

        if let effectView = view as? UIVisualEffectView {
            let effectText = effectView.effect.map { className(of: $0) } ?? "-"
            sections.append(ViewScopePropertySection(
                title: text("server.uikit.section.visual_effect"),
                items: [
                    readonly("server.uikit.item.effect", effectText)
                ]
            ))
        }

        return sections
    }

    private func buttonSection(for button: UIButton, traits: UITraitCollection) -> ViewScopePropertySection {
        var items = [
            textField("server.item.title", key: "button.title", value: button.title(for: .normal) ?? ""),
            color("server.uikit.item.title_color", key: "button.titleColor", color: button.titleColor(for: .normal), traits: traits),
            readonly("server.uikit.item.button_type", buttonTypeText(button.buttonType))
        ]
        if let image = button.currentImage {
            items.append(readonly("server.uikit.item.image_size", sizeText(image.size)))
        }

        // iOS 15 起使用 UIButton.Configuration 的按钮会忽略 contentEdgeInsets，改为展示 configuration 的内容边距。
        var usesConfiguration = false
        if #available(iOS 15.0, *), let configuration = button.configuration {
            usesConfiguration = true
            let insets = configuration.contentInsets
            items.append(readonly("server.uikit.item.configuration", boolText(true)))
            items.append(number("server.uikit.item.inset_top", key: "button.contentEdgeInsets.top", value: insets.top))
            items.append(number("server.uikit.item.inset_left", key: "button.contentEdgeInsets.left", value: insets.leading))
            items.append(number("server.uikit.item.inset_bottom", key: "button.contentEdgeInsets.bottom", value: insets.bottom))
            items.append(number("server.uikit.item.inset_right", key: "button.contentEdgeInsets.right", value: insets.trailing))
        }
        if usesConfiguration == false {
            let insets = ViewScopeUIKitViewDescriber.legacyContentEdgeInsets(of: button)
            items.append(number("server.uikit.item.inset_top", key: "button.contentEdgeInsets.top", value: insets.top))
            items.append(number("server.uikit.item.inset_left", key: "button.contentEdgeInsets.left", value: insets.left))
            items.append(number("server.uikit.item.inset_bottom", key: "button.contentEdgeInsets.bottom", value: insets.bottom))
            items.append(number("server.uikit.item.inset_right", key: "button.contentEdgeInsets.right", value: insets.right))
        }
        return ViewScopePropertySection(title: text("server.uikit.section.button"), items: items)
    }

    private func scrollViewSection(for scrollView: UIScrollView) -> ViewScopePropertySection {
        let offset = scrollView.contentOffset
        let size = scrollView.contentSize
        let inset = scrollView.contentInset
        return ViewScopePropertySection(
            title: text("server.uikit.section.scroll_view"),
            items: [
                number("server.uikit.item.content_offset_x", key: "contentOffset.x", value: offset.x),
                number("server.uikit.item.content_offset_y", key: "contentOffset.y", value: offset.y),
                number("server.uikit.item.content_size_width", key: "contentSize.width", value: size.width),
                number("server.uikit.item.content_size_height", key: "contentSize.height", value: size.height),
                number("server.uikit.item.inset_top", key: "contentInset.top", value: inset.top),
                number("server.uikit.item.inset_left", key: "contentInset.left", value: inset.left),
                number("server.uikit.item.inset_bottom", key: "contentInset.bottom", value: inset.bottom),
                number("server.uikit.item.inset_right", key: "contentInset.right", value: inset.right),
                readonly("server.uikit.item.adjusted_content_inset", insetsText(scrollView.adjustedContentInset)),
                enumeration(
                    "server.uikit.item.inset_adjustment",
                    key: "scrollView.contentInsetAdjustmentBehavior",
                    value: scrollView.contentInsetAdjustmentBehavior.rawValue,
                    options: Self.insetAdjustmentOptions
                ),
                toggle("server.uikit.item.scroll_enabled", key: "scrollView.isScrollEnabled", value: scrollView.isScrollEnabled),
                toggle("server.uikit.item.bounces", key: "scrollView.bounces", value: scrollView.bounces),
                toggle("server.uikit.item.paging_enabled", key: "scrollView.isPagingEnabled", value: scrollView.isPagingEnabled),
                toggle("server.uikit.item.shows_vertical_indicator", key: "scrollView.showsVerticalScrollIndicator", value: scrollView.showsVerticalScrollIndicator),
                toggle("server.uikit.item.shows_horizontal_indicator", key: "scrollView.showsHorizontalScrollIndicator", value: scrollView.showsHorizontalScrollIndicator),
                number("server.uikit.item.zoom_scale", key: "scrollView.zoomScale", value: scrollView.zoomScale, decimals: 2),
                number("server.uikit.item.minimum_zoom_scale", key: "scrollView.minimumZoomScale", value: scrollView.minimumZoomScale, decimals: 2),
                number("server.uikit.item.maximum_zoom_scale", key: "scrollView.maximumZoomScale", value: scrollView.maximumZoomScale, decimals: 2)
            ]
        )
    }

    private func collectionViewSection(for collectionView: UICollectionView) -> ViewScopePropertySection {
        let layout = collectionView.collectionViewLayout
        var items = [
            readonly("server.uikit.item.layout_class", className(of: layout)),
            readonly("server.uikit.item.sections", String(collectionView.numberOfSections)),
            readonly("server.uikit.item.visible_items", String(collectionView.indexPathsForVisibleItems.count))
        ]
        if let flowLayout = layout as? UICollectionViewFlowLayout {
            let inset = flowLayout.sectionInset
            items.append(contentsOf: [
                number("server.uikit.item.item_width", key: "collection.itemSize.width", value: flowLayout.itemSize.width),
                number("server.uikit.item.item_height", key: "collection.itemSize.height", value: flowLayout.itemSize.height),
                number("server.uikit.item.minimum_line_spacing", key: "collection.minimumLineSpacing", value: flowLayout.minimumLineSpacing),
                number("server.uikit.item.minimum_interitem_spacing", key: "collection.minimumInteritemSpacing", value: flowLayout.minimumInteritemSpacing),
                number("server.uikit.item.inset_top", key: "collection.sectionInset.top", value: inset.top),
                number("server.uikit.item.inset_left", key: "collection.sectionInset.left", value: inset.left),
                number("server.uikit.item.inset_bottom", key: "collection.sectionInset.bottom", value: inset.bottom),
                number("server.uikit.item.inset_right", key: "collection.sectionInset.right", value: inset.right),
                enumeration(
                    "server.uikit.item.scroll_direction",
                    key: "collection.scrollDirection",
                    value: flowLayout.scrollDirection.rawValue,
                    options: Self.scrollDirectionOptions
                )
            ])
        }
        return ViewScopePropertySection(title: text("server.uikit.section.collection_view"), items: items)
    }

    // MARK: - 视图控制器 / 其他对象

    func controllerSections(for controller: UIViewController) -> [ViewScopePropertySection] {
        var items = [
            readonly("server.item.class", className(of: controller)),
            readonly("server.item.address", ViewScopeNodeIdentity.address(of: controller))
        ]
        if let title = controller.title, title.isEmpty == false {
            items.append(readonly("server.item.title", title))
        }
        if let parent = controller.parent {
            items.append(readonly("server.uikit.item.parent_view_controller", className(of: parent)))
        }
        return [ViewScopePropertySection(title: text("server.section.identity"), items: items)]
    }

    func objectSections(for object: AnyObject) -> [ViewScopePropertySection] {
        [
            ViewScopePropertySection(
                title: text("server.section.identity"),
                items: [
                    readonly("server.item.class", className(of: object)),
                    readonly("server.item.address", ViewScopeNodeIdentity.address(of: object))
                ]
            )
        ]
    }

    // MARK: - 约束

    /// 视图自身持有的约束 + 父视图中引用该视图的约束，带 identifier 与优先级。
    func constraintDescriptions(for view: UIView) -> [String] {
        var constraints = view.constraints
        if let superview = view.superview {
            constraints.append(contentsOf: superview.constraints.filter { constraint in
                Self.constraint(constraint, references: view)
            })
        }

        let descriptions = constraints.map { constraint -> String in
            let first = constraintItemText(constraint.firstItem, attribute: constraint.firstAttribute, relativeTo: view)
            let relation = relationSymbol(constraint.relation)
            let constant = formatted(constraint.constant, decimals: 2)
            var description: String
            if constraint.secondAttribute == .notAnAttribute || constraint.secondItem == nil {
                description = "\(first) \(relation) \(constant)"
            } else {
                let second = constraintItemText(constraint.secondItem, attribute: constraint.secondAttribute, relativeTo: view)
                let multiplier = formatted(constraint.multiplier, decimals: 2)
                description = "\(first) \(relation) \(second) * \(multiplier) + \(constant)"
            }
            if constraint.priority != .required {
                description += " @\(formatted(CGFloat(constraint.priority.rawValue), decimals: 0))"
            }
            if constraint.isActive == false {
                description += " [inactive]"
            }
            if let identifier = constraint.identifier, identifier.isEmpty == false {
                description += " (\(identifier))"
            }
            return description
        }
        return descriptions.isEmpty ? [text("server.value.no_active_constraints")] : descriptions
    }

    /// 约束 item 是否指向该视图（含视图自身的 layout guide）。
    static func constraint(_ constraint: NSLayoutConstraint, references view: UIView) -> Bool {
        func matches(_ item: AnyObject?) -> Bool {
            guard let item else {
                return false
            }
            if item === view {
                return true
            }
            if let guide = item as? UILayoutGuide, guide.owningView === view {
                return true
            }
            return false
        }
        return matches(constraint.firstItem) || matches(constraint.secondItem)
    }

    private func constraintItemText(_ item: AnyObject?, attribute: NSLayoutConstraint.Attribute, relativeTo view: UIView) -> String {
        let name: String
        if let item {
            if item === view {
                name = "self"
            } else if let guide = item as? UILayoutGuide {
                let owner = guide.owningView.map { $0 === view ? "self" : ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: $0))) } ?? "?"
                let guideName = guide.identifier.isEmpty ? "layoutGuide" : guide.identifier
                name = "\(owner).\(guideName)"
            } else if view.superview === item {
                name = "superview"
            } else {
                name = className(of: item)
            }
        } else {
            name = "nil"
        }
        return "\(name).\(attributeName(attribute))"
    }

    // MARK: - 枚举候选项

    static let contentModeOptions = options([
        ("scaleToFill", 0), ("scaleAspectFit", 1), ("scaleAspectFill", 2), ("redraw", 3), ("center", 4),
        ("top", 5), ("bottom", 6), ("left", 7), ("right", 8),
        ("topLeft", 9), ("topRight", 10), ("bottomLeft", 11), ("bottomRight", 12)
    ])
    static let textAlignmentOptions = options([
        ("left", NSTextAlignment.left.rawValue), ("center", NSTextAlignment.center.rawValue),
        ("right", NSTextAlignment.right.rawValue), ("justified", NSTextAlignment.justified.rawValue),
        ("natural", NSTextAlignment.natural.rawValue)
    ])
    static let lineBreakModeOptions = options([
        ("byWordWrapping", 0), ("byCharWrapping", 1), ("byClipping", 2),
        ("byTruncatingHead", 3), ("byTruncatingTail", 4), ("byTruncatingMiddle", 5)
    ])
    static let horizontalAlignmentOptions = options([
        ("center", 0), ("left", 1), ("right", 2), ("fill", 3), ("leading", 4), ("trailing", 5)
    ])
    static let verticalAlignmentOptions = options([
        ("center", 0), ("top", 1), ("bottom", 2), ("fill", 3)
    ])
    static let borderStyleOptions = options([
        ("none", 0), ("line", 1), ("bezel", 2), ("roundedRect", 3)
    ])
    static let separatorStyleOptions = options([
        ("none", 0), ("singleLine", 1)
    ])
    static let insetAdjustmentOptions = options([
        ("automatic", 0), ("scrollableAxes", 1), ("never", 2), ("always", 3)
    ])
    static let scrollDirectionOptions = options([
        ("vertical", 0), ("horizontal", 1)
    ])
    static let axisOptions = options([
        ("horizontal", 0), ("vertical", 1)
    ])
    static let distributionOptions = options([
        ("fill", 0), ("fillEqually", 1), ("fillProportionally", 2), ("equalSpacing", 3), ("equalCentering", 4)
    ])
    static let stackAlignmentOptions = options([
        ("fill", 0), ("leading / top", 1), ("firstBaseline", 2), ("center", 3), ("trailing / bottom", 4), ("lastBaseline", 5)
    ])

    private static func options(_ pairs: [(String, Int)]) -> [ViewScopeEditableOption] {
        pairs.map { ViewScopeEditableOption(title: $0.0, value: Double($0.1)) }
    }

    // MARK: - 条目构造

    private func text(_ key: String, _ arguments: CVarArg...) -> String {
        language.text(key, arguments: arguments)
    }

    private func readonly(_ titleKey: String, _ value: String) -> ViewScopePropertyItem {
        ViewScopePropertyItem(title: text(titleKey), value: value)
    }

    private func toggle(_ titleKey: String, key: String, value: Bool) -> ViewScopePropertyItem {
        ViewScopePropertyItem(title: text(titleKey), value: boolText(value), editable: .toggle(key: key, value: value))
    }

    private func number(_ titleKey: String, key: String, value: CGFloat, decimals: Int = 1) -> ViewScopePropertyItem {
        let finite = ViewScopeNumberConversion.finite(Double(value))
        return ViewScopePropertyItem(
            title: text(titleKey),
            value: formatted(CGFloat(finite), decimals: decimals),
            editable: .number(key: key, value: finite)
        )
    }

    private func textField(_ titleKey: String, key: String, value: String) -> ViewScopePropertyItem {
        ViewScopePropertyItem(title: text(titleKey), value: value, editable: .text(key: key, value: value))
    }

    private func enumeration(_ titleKey: String, key: String, value: Int, options: [ViewScopeEditableOption]) -> ViewScopePropertyItem {
        let display = options.first(where: { $0.value == Double(value) })?.title ?? String(value)
        return ViewScopePropertyItem(
            title: text(titleKey),
            value: display,
            editable: .enumeration(key: key, value: Double(value), options: options)
        )
    }

    /// 颜色项始终可编辑；没有颜色时显示 `#00000000`，客户端填入新值即可从无到有设置。
    private func color(_ titleKey: String, key: String, color: UIColor?, traits: UITraitCollection) -> ViewScopePropertyItem {
        let resolved = color?.resolvedColor(with: traits)
        let value = ViewScopeColorParsing.hexString(from: resolved?.cgColor) ?? "#00000000"
        return ViewScopePropertyItem(title: text(titleKey), value: value, editable: .text(key: key, value: value))
    }

    private func cgColor(_ titleKey: String, key: String, color: CGColor?) -> ViewScopePropertyItem {
        let value = ViewScopeColorParsing.hexString(from: color) ?? "#00000000"
        return ViewScopePropertyItem(title: text(titleKey), value: value, editable: .text(key: key, value: value))
    }

    // MARK: - 文本格式化

    private func className(of object: AnyObject) -> String {
        ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: object)))
    }

    private func boolText(_ value: Bool) -> String {
        value ? text("server.value.yes") : text("server.value.no")
    }

    private func formatted(_ value: CGFloat, decimals: Int) -> String {
        let finite = ViewScopeNumberConversion.finite(Double(value))
        return String(format: "%.\(decimals)f", locale: language.locale, finite)
    }

    private func rectText(_ rect: CGRect) -> String {
        "x \(formatted(rect.origin.x, decimals: 1)) y \(formatted(rect.origin.y, decimals: 1)) w \(formatted(rect.width, decimals: 1)) h \(formatted(rect.height, decimals: 1))"
    }

    private func pointText(_ point: CGPoint) -> String {
        "x \(formatted(point.x, decimals: 1)) y \(formatted(point.y, decimals: 1))"
    }

    private func sizeText(_ size: CGSize) -> String {
        "w \(formatted(size.width, decimals: 1)) h \(formatted(size.height, decimals: 1))"
    }

    private func insetsText(_ insets: UIEdgeInsets) -> String {
        "t \(formatted(insets.top, decimals: 1)) l \(formatted(insets.left, decimals: 1)) b \(formatted(insets.bottom, decimals: 1)) r \(formatted(insets.right, decimals: 1))"
    }

    private func transformText(_ transform: CGAffineTransform) -> String {
        if transform.isIdentity {
            return "identity"
        }
        return "[\(formatted(transform.a, decimals: 2)), \(formatted(transform.b, decimals: 2)), \(formatted(transform.c, decimals: 2)), \(formatted(transform.d, decimals: 2)), \(formatted(transform.tx, decimals: 1)), \(formatted(transform.ty, decimals: 1))]"
    }

    private func priorityText(_ priority: UILayoutPriority) -> String {
        formatted(CGFloat(priority.rawValue), decimals: 0)
    }

    private func intrinsicSizeText(_ size: CGSize) -> String {
        let noMetric = UIView.noIntrinsicMetric
        if size.width == noMetric, size.height == noMetric {
            return text("server.value.no_intrinsic_size")
        }
        let width = size.width == noMetric ? "-" : formatted(size.width, decimals: 1)
        let height = size.height == noMetric ? "-" : formatted(size.height, decimals: 1)
        return "w \(width) h \(height)"
    }

    private func fontText(_ font: UIFont) -> String {
        "\(font.fontName) \(formatted(font.pointSize, decimals: 1))"
    }

    private func autoresizingText(_ mask: UIView.AutoresizingMask) -> String {
        let mappings: [(UIView.AutoresizingMask, String)] = [
            (.flexibleLeftMargin, "LM"),
            (.flexibleWidth, "W"),
            (.flexibleRightMargin, "RM"),
            (.flexibleTopMargin, "TM"),
            (.flexibleHeight, "H"),
            (.flexibleBottomMargin, "BM")
        ]
        let names = mappings.compactMap { mask.contains($0.0) ? $0.1 : nil }
        return names.isEmpty ? "none" : names.joined(separator: " | ")
    }

    private func relationSymbol(_ relation: NSLayoutConstraint.Relation) -> String {
        switch relation {
        case .equal:
            return "="
        case .greaterThanOrEqual:
            return ">="
        case .lessThanOrEqual:
            return "<="
        @unknown default:
            return "?"
        }
    }

    private func attributeName(_ attribute: NSLayoutConstraint.Attribute) -> String {
        switch attribute {
        case .left:
            return "left"
        case .right:
            return "right"
        case .top:
            return "top"
        case .bottom:
            return "bottom"
        case .leading:
            return "leading"
        case .trailing:
            return "trailing"
        case .width:
            return "width"
        case .height:
            return "height"
        case .centerX:
            return "centerX"
        case .centerY:
            return "centerY"
        case .lastBaseline:
            return "lastBaseline"
        case .firstBaseline:
            return "firstBaseline"
        case .leftMargin:
            return "leftMargin"
        case .rightMargin:
            return "rightMargin"
        case .topMargin:
            return "topMargin"
        case .bottomMargin:
            return "bottomMargin"
        case .leadingMargin:
            return "leadingMargin"
        case .trailingMargin:
            return "trailingMargin"
        case .centerXWithinMargins:
            return "centerXWithinMargins"
        case .centerYWithinMargins:
            return "centerYWithinMargins"
        case .notAnAttribute:
            return "notAnAttribute"
        @unknown default:
            return String(attribute.rawValue)
        }
    }

    private func buttonTypeText(_ type: UIButton.ButtonType) -> String {
        switch type {
        case .custom:
            return "custom"
        case .system:
            return "system"
        case .detailDisclosure:
            return "detailDisclosure"
        case .infoLight:
            return "infoLight"
        case .infoDark:
            return "infoDark"
        case .contactAdd:
            return "contactAdd"
        case .close:
            return "close"
        @unknown default:
            return String(type.rawValue)
        }
    }

    private func tableStyleText(_ style: UITableView.Style) -> String {
        switch style {
        case .plain:
            return "plain"
        case .grouped:
            return "grouped"
        case .insetGrouped:
            return "insetGrouped"
        @unknown default:
            return String(style.rawValue)
        }
    }

    private func renderingModeText(_ mode: UIImage.RenderingMode) -> String {
        switch mode {
        case .automatic:
            return "automatic"
        case .alwaysOriginal:
            return "alwaysOriginal"
        case .alwaysTemplate:
            return "alwaysTemplate"
        @unknown default:
            return String(mode.rawValue)
        }
    }

    private func sceneStateText(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .unattached:
            return "unattached"
        case .foregroundActive:
            return "foregroundActive"
        case .foregroundInactive:
            return "foregroundInactive"
        case .background:
            return "background"
        @unknown default:
            return String(state.rawValue)
        }
    }
}
#endif
