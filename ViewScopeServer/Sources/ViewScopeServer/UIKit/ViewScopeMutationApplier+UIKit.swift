#if os(iOS)
import UIKit

/// UIKit 实时修改。
///
/// 路由规则：
/// - 带宿主视图的 layer 节点：`layer.*` key 作用于 layer，其余 key 作用于宿主视图；
/// - 纯 CALayer 节点：所有 key 作用于 layer；
/// - 窗口节点：按 UIView 处理（UIWindow 是 UIView 子类）。
///
/// 几何修改说明：修改 frame / bounds 后只对目标视图自身执行 `setNeedsLayout` + `layoutIfNeeded`，
/// 让它的子视图按新尺寸重新布局；不会立即触发父视图布局，否则受 Auto Layout 约束的视图会被瞬间还原（审计 B13）。
/// 受约束管理的视图在之后父视图的下一次布局中仍会回到约束计算出的位置，这是 Auto Layout 的预期行为。
///
/// 所有数值都经过 `ViewScopeNumberConversion` 校验，NaN / Inf / 越界值抛出 `invalidValue`，不会让宿主 trap（审计 A4）。
@MainActor
enum ViewScopeMutationApplier {
    static func apply(_ property: ViewScopeEditableProperty, to reference: ViewScopeInspectableReference) throws {
        guard let object = reference.resolvedObject else {
            throw ViewScopeMutationError.targetDeallocated
        }

        // 禁用隐式动画，修改立即生效（审计 B9）。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
        }

        switch object {
        case let view as UIView:
            try ensureAttached(view)
            try apply(property, toView: view)
        case let layer as CALayer:
            if let hostView = layer.kg_viewScopeHostView {
                try ensureAttached(hostView)
                if try applyLayerKey(property, to: layer) {
                    return
                }
                try apply(property, toView: hostView)
            } else {
                guard layer.kg_viewScopeWindow != nil else {
                    // 已经脱离窗口的 layer 修改没有意义，按“节点已不存在”处理（审计 A9）。
                    throw ViewScopeMutationError.targetDeallocated
                }
                try applyPureLayer(property, to: layer)
            }
        default:
            throw ViewScopeMutationError.unsupportedProperty
        }
    }

    /// 视图必须仍在窗口中；窗口本身视为在屏。
    private static func ensureAttached(_ view: UIView) throws {
        if view is UIWindow {
            return
        }
        guard view.window != nil else {
            throw ViewScopeMutationError.targetDeallocated
        }
    }

    // MARK: - 视图

    private static func apply(_ property: ViewScopeEditableProperty, toView view: UIView) throws {
        if try applyLayerKey(property, to: view.layer) {
            return
        }
        if try applyCommonViewKey(property, to: view) {
            return
        }
        if try applySpecificKey(property, to: view) {
            return
        }
        throw ViewScopeMutationError.unsupportedProperty
    }

    private static func applyCommonViewKey(_ property: ViewScopeEditableProperty, to view: UIView) throws -> Bool {
        switch property.key {
        case "hidden":
            view.isHidden = try bool(property)
        case "alpha":
            view.alpha = try ViewScopeNumberConversion.unitInterval(property.numberValue)
        case "frame.x", "frame.y", "frame.width", "frame.height":
            try mutateFrame(of: view, key: property.key, value: try ViewScopeNumberConversion.cgFloat(property.numberValue))
        case "bounds.x", "bounds.y", "bounds.width", "bounds.height":
            try mutateBounds(of: view, key: property.key, value: try ViewScopeNumberConversion.cgFloat(property.numberValue))
        case "layoutMargins.top", "layoutMargins.left", "layoutMargins.bottom", "layoutMargins.right":
            view.layoutMargins = try mutatedInsets(view.layoutMargins, key: property.key, property: property)
            view.setNeedsLayout()
        case "backgroundColor":
            view.backgroundColor = try color(property)
        case "tintColor":
            // 传空字符串时恢复为继承父视图的 tintColor。
            view.tintColor = try color(property)
        case "opaque":
            view.isOpaque = try bool(property)
        case "clipsToBounds":
            view.clipsToBounds = try bool(property)
        case "userInteractionEnabled":
            view.isUserInteractionEnabled = try bool(property)
        case "tag":
            view.tag = try ViewScopeNumberConversion.int(property.numberValue)
        case "contentMode":
            guard let mode = UIView.ContentMode(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.contentModeOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            view.contentMode = mode
            view.setNeedsDisplay()
        default:
            return false
        }
        return true
    }

    /// 修改 frame 的单个分量。带非恒等 transform 时 frame 无定义，改为调整 center / bounds。
    private static func mutateFrame(of view: UIView, key: String, value: CGFloat) throws {
        if view.transform.isIdentity {
            var frame = view.frame
            switch key {
            case "frame.x":
                frame.origin.x = value
            case "frame.y":
                frame.origin.y = value
            case "frame.width":
                frame.size.width = max(0, value)
            default:
                frame.size.height = max(0, value)
            }
            view.frame = frame
        } else {
            let frame = view.frame
            switch key {
            case "frame.x":
                view.center.x += value - frame.origin.x
            case "frame.y":
                view.center.y += value - frame.origin.y
            case "frame.width":
                view.bounds.size.width = max(0, value)
            default:
                view.bounds.size.height = max(0, value)
            }
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private static func mutateBounds(of view: UIView, key: String, value: CGFloat) throws {
        var bounds = view.bounds
        switch key {
        case "bounds.x":
            bounds.origin.x = value
        case "bounds.y":
            bounds.origin.y = value
        case "bounds.width":
            bounds.size.width = max(0, value)
        default:
            bounds.size.height = max(0, value)
        }
        view.bounds = bounds
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    // MARK: - 控件专属

    private static func applySpecificKey(_ property: ViewScopeEditableProperty, to view: UIView) throws -> Bool {
        let key = property.key

        if key.hasPrefix("window."), let window = view as? UIWindow {
            switch key {
            case "window.windowLevel":
                window.windowLevel = UIWindow.Level(rawValue: try ViewScopeNumberConversion.cgFloat(property.numberValue))
                return true
            default:
                return false
            }
        }

        if key.hasPrefix("label."), let label = view as? UILabel {
            return try applyLabelKey(property, to: label)
        }
        if key.hasPrefix("control."), let control = view as? UIControl {
            return try applyControlKey(property, to: control)
        }
        if key.hasPrefix("button."), let button = view as? UIButton {
            return try applyButtonKey(property, to: button)
        }
        if key.hasPrefix("imageView."), let imageView = view as? UIImageView {
            switch key {
            case "imageView.isHighlighted":
                imageView.isHighlighted = try bool(property)
                return true
            default:
                return false
            }
        }
        if key.hasPrefix("textField."), let textField = view as? UITextField {
            return try applyTextFieldKey(property, to: textField)
        }
        if key.hasPrefix("textView."), let textView = view as? UITextView {
            return try applyTextViewKey(property, to: textView)
        }
        if key.hasPrefix("tableView."), let tableView = view as? UITableView {
            return try applyTableViewKey(property, to: tableView)
        }
        if key.hasPrefix("collection."), let collectionView = view as? UICollectionView {
            return try applyCollectionViewKey(property, to: collectionView)
        }
        if let scrollView = view as? UIScrollView,
           key.hasPrefix("scrollView.") || key.hasPrefix("contentOffset.") || key.hasPrefix("contentSize.") || key.hasPrefix("contentInset.") {
            return try applyScrollViewKey(property, to: scrollView)
        }
        if key.hasPrefix("stack."), let stackView = view as? UIStackView {
            return try applyStackViewKey(property, to: stackView)
        }
        if key.hasPrefix("switch."), let toggleSwitch = view as? UISwitch {
            switch key {
            case "switch.isOn":
                toggleSwitch.setOn(try bool(property), animated: false)
            case "switch.onTintColor":
                toggleSwitch.onTintColor = try color(property)
            default:
                return false
            }
            return true
        }
        if key.hasPrefix("slider."), let slider = view as? UISlider {
            switch key {
            case "slider.value":
                slider.setValue(try float(property), animated: false)
            case "slider.minimumValue":
                slider.minimumValue = try float(property)
            case "slider.maximumValue":
                slider.maximumValue = try float(property)
            case "slider.isContinuous":
                slider.isContinuous = try bool(property)
            default:
                return false
            }
            return true
        }
        if key.hasPrefix("segmented."), let segmented = view as? UISegmentedControl {
            switch key {
            case "segmented.selectedSegmentIndex":
                let index = try ViewScopeNumberConversion.int(property.numberValue)
                guard index == UISegmentedControl.noSegment || (0 ..< segmented.numberOfSegments).contains(index) else {
                    throw ViewScopeMutationError.invalidValue
                }
                segmented.selectedSegmentIndex = index
                return true
            default:
                return false
            }
        }
        if key.hasPrefix("progress."), let progressView = view as? UIProgressView {
            switch key {
            case "progress.progress":
                progressView.setProgress(Float(try ViewScopeNumberConversion.unitInterval(property.numberValue)), animated: false)
            case "progress.progressTintColor":
                progressView.progressTintColor = try color(property)
            default:
                return false
            }
            return true
        }
        if key.hasPrefix("activity."), let activityView = view as? UIActivityIndicatorView {
            switch key {
            case "activity.isAnimating":
                if try bool(property) {
                    activityView.startAnimating()
                } else {
                    activityView.stopAnimating()
                }
            case "activity.hidesWhenStopped":
                activityView.hidesWhenStopped = try bool(property)
            case "activity.color":
                activityView.color = try color(property) ?? .gray
            default:
                return false
            }
            return true
        }
        return false
    }

    private static func applyLabelKey(_ property: ViewScopeEditableProperty, to label: UILabel) throws -> Bool {
        switch property.key {
        case "label.text":
            label.text = try text(property)
        case "label.fontSize":
            let size = try positiveFontSize(property)
            label.font = (label.font ?? UIFont.systemFont(ofSize: size)).withSize(size)
        case "label.textColor":
            label.textColor = try color(property)
        case "label.numberOfLines":
            let lines = try ViewScopeNumberConversion.int(property.numberValue)
            guard lines >= 0 else {
                throw ViewScopeMutationError.invalidValue
            }
            label.numberOfLines = lines
        case "label.textAlignment":
            label.textAlignment = try textAlignment(property)
        case "label.lineBreakMode":
            guard let mode = NSLineBreakMode(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.lineBreakModeOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            label.lineBreakMode = mode
        case "label.adjustsFontSizeToFitWidth":
            label.adjustsFontSizeToFitWidth = try bool(property)
        default:
            return false
        }
        // 文本内容变化会改变固有尺寸；只标记父视图需要布局（下一轮 runloop 生效），不立即强制布局。
        label.invalidateIntrinsicContentSize()
        label.superview?.setNeedsLayout()
        return true
    }

    private static func applyControlKey(_ property: ViewScopeEditableProperty, to control: UIControl) throws -> Bool {
        switch property.key {
        case "control.isEnabled":
            control.isEnabled = try bool(property)
        case "control.isSelected":
            control.isSelected = try bool(property)
        case "control.isHighlighted":
            control.isHighlighted = try bool(property)
        case "control.contentHorizontalAlignment":
            guard let alignment = UIControl.ContentHorizontalAlignment(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.horizontalAlignmentOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            control.contentHorizontalAlignment = alignment
        case "control.contentVerticalAlignment":
            guard let alignment = UIControl.ContentVerticalAlignment(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.verticalAlignmentOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            control.contentVerticalAlignment = alignment
        default:
            return false
        }
        return true
    }

    private static func applyButtonKey(_ property: ViewScopeEditableProperty, to button: UIButton) throws -> Bool {
        switch property.key {
        case "button.title":
            button.setTitle(try text(property), for: .normal)
        case "button.titleColor":
            button.setTitleColor(try color(property), for: .normal)
        case "button.contentEdgeInsets.top", "button.contentEdgeInsets.left", "button.contentEdgeInsets.bottom", "button.contentEdgeInsets.right":
            let value = try ViewScopeNumberConversion.cgFloat(property.numberValue)
            if #available(iOS 15.0, *), var configuration = button.configuration {
                // Configuration 按钮使用方向性边距：left / right 分别对应 leading / trailing。
                var insets = configuration.contentInsets
                switch property.key {
                case "button.contentEdgeInsets.top":
                    insets.top = value
                case "button.contentEdgeInsets.left":
                    insets.leading = value
                case "button.contentEdgeInsets.bottom":
                    insets.bottom = value
                default:
                    insets.trailing = value
                }
                configuration.contentInsets = insets
                button.configuration = configuration
            } else {
                var insets = ViewScopeUIKitViewDescriber.legacyContentEdgeInsets(of: button)
                switch property.key {
                case "button.contentEdgeInsets.top":
                    insets.top = value
                case "button.contentEdgeInsets.left":
                    insets.left = value
                case "button.contentEdgeInsets.bottom":
                    insets.bottom = value
                default:
                    insets.right = value
                }
                ViewScopeUIKitViewDescriber.setLegacyContentEdgeInsets(insets, on: button)
            }
        default:
            return false
        }
        button.invalidateIntrinsicContentSize()
        button.superview?.setNeedsLayout()
        return true
    }

    private static func applyTextFieldKey(_ property: ViewScopeEditableProperty, to textField: UITextField) throws -> Bool {
        switch property.key {
        case "textField.text":
            textField.text = try text(property)
        case "textField.placeholder":
            let placeholder = try text(property)
            textField.placeholder = placeholder.isEmpty ? nil : placeholder
        case "textField.fontSize":
            let size = try positiveFontSize(property)
            textField.font = (textField.font ?? UIFont.systemFont(ofSize: size)).withSize(size)
        case "textField.textColor":
            textField.textColor = try color(property)
        case "textField.textAlignment":
            textField.textAlignment = try textAlignment(property)
        case "textField.borderStyle":
            guard let style = UITextField.BorderStyle(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.borderStyleOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            textField.borderStyle = style
        case "textField.isSecureTextEntry":
            textField.isSecureTextEntry = try bool(property)
        default:
            return false
        }
        textField.invalidateIntrinsicContentSize()
        return true
    }

    private static func applyTextViewKey(_ property: ViewScopeEditableProperty, to textView: UITextView) throws -> Bool {
        switch property.key {
        case "textView.text":
            textView.text = try text(property)
        case "textView.isEditable":
            textView.isEditable = try bool(property)
        case "textView.isSelectable":
            textView.isSelectable = try bool(property)
        case "textView.fontSize":
            let size = try positiveFontSize(property)
            textView.font = (textView.font ?? UIFont.systemFont(ofSize: size)).withSize(size)
        case "textView.textColor":
            textView.textColor = try color(property)
        case "textView.textAlignment":
            textView.textAlignment = try textAlignment(property)
        case "textView.textContainerInset.top", "textView.textContainerInset.left", "textView.textContainerInset.bottom", "textView.textContainerInset.right":
            textView.textContainerInset = try mutatedInsets(textView.textContainerInset, key: property.key, property: property)
        default:
            return false
        }
        return true
    }

    private static func applyScrollViewKey(_ property: ViewScopeEditableProperty, to scrollView: UIScrollView) throws -> Bool {
        switch property.key {
        case "contentOffset.x":
            var offset = scrollView.contentOffset
            offset.x = try ViewScopeNumberConversion.cgFloat(property.numberValue)
            scrollView.setContentOffset(offset, animated: false)
        case "contentOffset.y":
            var offset = scrollView.contentOffset
            offset.y = try ViewScopeNumberConversion.cgFloat(property.numberValue)
            scrollView.setContentOffset(offset, animated: false)
        case "contentSize.width":
            scrollView.contentSize.width = try ViewScopeNumberConversion.nonNegativeCGFloat(property.numberValue)
        case "contentSize.height":
            scrollView.contentSize.height = try ViewScopeNumberConversion.nonNegativeCGFloat(property.numberValue)
        case "contentInset.top", "contentInset.left", "contentInset.bottom", "contentInset.right":
            scrollView.contentInset = try mutatedInsets(scrollView.contentInset, key: property.key, property: property)
        case "scrollView.contentInsetAdjustmentBehavior":
            guard let behavior = UIScrollView.ContentInsetAdjustmentBehavior(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.insetAdjustmentOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            scrollView.contentInsetAdjustmentBehavior = behavior
        case "scrollView.isScrollEnabled":
            scrollView.isScrollEnabled = try bool(property)
        case "scrollView.bounces":
            scrollView.bounces = try bool(property)
        case "scrollView.isPagingEnabled":
            scrollView.isPagingEnabled = try bool(property)
        case "scrollView.showsVerticalScrollIndicator":
            scrollView.showsVerticalScrollIndicator = try bool(property)
        case "scrollView.showsHorizontalScrollIndicator":
            scrollView.showsHorizontalScrollIndicator = try bool(property)
        case "scrollView.zoomScale":
            let scale = try ViewScopeNumberConversion.cgFloat(property.numberValue)
            guard scale > 0 else {
                throw ViewScopeMutationError.invalidValue
            }
            scrollView.setZoomScale(scale, animated: false)
        case "scrollView.minimumZoomScale":
            let scale = try ViewScopeNumberConversion.cgFloat(property.numberValue)
            guard scale > 0 else {
                throw ViewScopeMutationError.invalidValue
            }
            scrollView.minimumZoomScale = scale
        case "scrollView.maximumZoomScale":
            let scale = try ViewScopeNumberConversion.cgFloat(property.numberValue)
            guard scale > 0 else {
                throw ViewScopeMutationError.invalidValue
            }
            scrollView.maximumZoomScale = scale
        default:
            return false
        }
        return true
    }

    private static func applyTableViewKey(_ property: ViewScopeEditableProperty, to tableView: UITableView) throws -> Bool {
        var needsHeightUpdate = false
        switch property.key {
        case "tableView.rowHeight":
            tableView.rowHeight = try dimension(property)
            needsHeightUpdate = true
        case "tableView.estimatedRowHeight":
            tableView.estimatedRowHeight = try dimension(property)
            needsHeightUpdate = true
        case "tableView.sectionHeaderHeight":
            tableView.sectionHeaderHeight = try dimension(property)
            needsHeightUpdate = true
        case "tableView.sectionFooterHeight":
            tableView.sectionFooterHeight = try dimension(property)
            needsHeightUpdate = true
        case "tableView.separatorStyle":
            guard let style = UITableViewCell.SeparatorStyle(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.separatorStyleOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            tableView.separatorStyle = style
        case "tableView.separatorColor":
            tableView.separatorColor = try color(property)
        default:
            return false
        }
        if needsHeightUpdate {
            // beginUpdates/endUpdates 会重新计算行高但不重建 cell；关闭动画避免闪动。
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
        return true
    }

    private static func applyCollectionViewKey(_ property: ViewScopeEditableProperty, to collectionView: UICollectionView) throws -> Bool {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else {
            throw ViewScopeMutationError.unsupportedProperty
        }
        switch property.key {
        case "collection.itemSize.width":
            layout.itemSize.width = try ViewScopeNumberConversion.nonNegativeCGFloat(property.numberValue)
        case "collection.itemSize.height":
            layout.itemSize.height = try ViewScopeNumberConversion.nonNegativeCGFloat(property.numberValue)
        case "collection.minimumLineSpacing":
            layout.minimumLineSpacing = try ViewScopeNumberConversion.cgFloat(property.numberValue)
        case "collection.minimumInteritemSpacing":
            layout.minimumInteritemSpacing = try ViewScopeNumberConversion.cgFloat(property.numberValue)
        case "collection.sectionInset.top", "collection.sectionInset.left", "collection.sectionInset.bottom", "collection.sectionInset.right":
            layout.sectionInset = try mutatedInsets(layout.sectionInset, key: property.key, property: property)
        case "collection.scrollDirection":
            guard let direction = UICollectionView.ScrollDirection(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.scrollDirectionOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            layout.scrollDirection = direction
        default:
            return false
        }
        layout.invalidateLayout()
        return true
    }

    private static func applyStackViewKey(_ property: ViewScopeEditableProperty, to stackView: UIStackView) throws -> Bool {
        switch property.key {
        case "stack.axis":
            guard let axis = NSLayoutConstraint.Axis(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.axisOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            stackView.axis = axis
        case "stack.distribution":
            guard let distribution = UIStackView.Distribution(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.distributionOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            stackView.distribution = distribution
        case "stack.alignment":
            guard let alignment = UIStackView.Alignment(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.stackAlignmentOptions)) else {
                throw ViewScopeMutationError.invalidValue
            }
            stackView.alignment = alignment
        case "stack.spacing":
            stackView.spacing = try ViewScopeNumberConversion.cgFloat(property.numberValue)
        case "stack.isLayoutMarginsRelativeArrangement":
            stackView.isLayoutMarginsRelativeArrangement = try bool(property)
        case "stack.isBaselineRelativeArrangement":
            stackView.isBaselineRelativeArrangement = try bool(property)
        default:
            return false
        }
        return true
    }

    // MARK: - Layer

    /// `layer.*` / `shape.*` / `textLayer.*` key；不认识的 key 返回 false。
    private static func applyLayerKey(_ property: ViewScopeEditableProperty, to layer: CALayer) throws -> Bool {
        switch property.key {
        case "layer.cornerRadius":
            layer.cornerRadius = try ViewScopeNumberConversion.nonNegativeCGFloat(property.numberValue)
        case "layer.borderWidth":
            layer.borderWidth = try ViewScopeNumberConversion.nonNegativeCGFloat(property.numberValue)
        case "layer.borderColor":
            layer.borderColor = try cgColor(property)
        case "layer.masksToBounds":
            layer.masksToBounds = try bool(property)
        case "layer.shadowOpacity":
            layer.shadowOpacity = Float(try ViewScopeNumberConversion.unitInterval(property.numberValue))
        case "layer.shadowRadius":
            layer.shadowRadius = try ViewScopeNumberConversion.nonNegativeCGFloat(property.numberValue)
        case "layer.shadowOffset.width":
            layer.shadowOffset.width = try ViewScopeNumberConversion.cgFloat(property.numberValue)
        case "layer.shadowOffset.height":
            layer.shadowOffset.height = try ViewScopeNumberConversion.cgFloat(property.numberValue)
        case "layer.shadowColor":
            layer.shadowColor = try cgColor(property)
        case "layer.zPosition":
            layer.zPosition = try ViewScopeNumberConversion.cgFloat(property.numberValue)
        case "layer.isOpaque":
            layer.isOpaque = try bool(property)
        case "shape.fillColor", "shape.strokeColor", "shape.lineWidth", "shape.strokeStart", "shape.strokeEnd":
            guard let shapeLayer = layer as? CAShapeLayer else {
                throw ViewScopeMutationError.unsupportedProperty
            }
            switch property.key {
            case "shape.fillColor":
                shapeLayer.fillColor = try cgColor(property)
            case "shape.strokeColor":
                shapeLayer.strokeColor = try cgColor(property)
            case "shape.lineWidth":
                shapeLayer.lineWidth = try ViewScopeNumberConversion.nonNegativeCGFloat(property.numberValue)
            case "shape.strokeStart":
                shapeLayer.strokeStart = try ViewScopeNumberConversion.unitInterval(property.numberValue)
            default:
                shapeLayer.strokeEnd = try ViewScopeNumberConversion.unitInterval(property.numberValue)
            }
        case "textLayer.fontSize":
            guard let textLayer = layer as? CATextLayer else {
                throw ViewScopeMutationError.unsupportedProperty
            }
            textLayer.fontSize = try positiveFontSize(property)
        default:
            return false
        }
        return true
    }

    /// 纯 CALayer：通用 key 直接作用于 layer。
    private static func applyPureLayer(_ property: ViewScopeEditableProperty, to layer: CALayer) throws {
        if try applyLayerKey(property, to: layer) {
            return
        }
        switch property.key {
        case "hidden":
            layer.isHidden = try bool(property)
        case "alpha":
            layer.opacity = Float(try ViewScopeNumberConversion.unitInterval(property.numberValue))
        case "frame.x", "frame.y", "frame.width", "frame.height":
            let value = try ViewScopeNumberConversion.cgFloat(property.numberValue)
            var frame = layer.frame
            switch property.key {
            case "frame.x":
                frame.origin.x = value
            case "frame.y":
                frame.origin.y = value
            case "frame.width":
                frame.size.width = max(0, value)
            default:
                frame.size.height = max(0, value)
            }
            layer.frame = frame
        case "bounds.x", "bounds.y", "bounds.width", "bounds.height":
            let value = try ViewScopeNumberConversion.cgFloat(property.numberValue)
            var bounds = layer.bounds
            switch property.key {
            case "bounds.x":
                bounds.origin.x = value
            case "bounds.y":
                bounds.origin.y = value
            case "bounds.width":
                bounds.size.width = max(0, value)
            default:
                bounds.size.height = max(0, value)
            }
            layer.bounds = bounds
        case "backgroundColor":
            layer.backgroundColor = try cgColor(property)
        default:
            throw ViewScopeMutationError.unsupportedProperty
        }
    }

    // MARK: - 取值工具

    private static func bool(_ property: ViewScopeEditableProperty) throws -> Bool {
        guard let value = property.boolValue else {
            throw ViewScopeMutationError.invalidValue
        }
        return value
    }

    private static func text(_ property: ViewScopeEditableProperty) throws -> String {
        guard let value = property.textValue else {
            throw ViewScopeMutationError.invalidValue
        }
        return value
    }

    private static func float(_ property: ViewScopeEditableProperty) throws -> Float {
        let value = try ViewScopeNumberConversion.cgFloat(property.numberValue)
        return Float(value)
    }

    /// 字号必须为正数且在合理范围内。
    private static func positiveFontSize(_ property: ViewScopeEditableProperty) throws -> CGFloat {
        let size = try ViewScopeNumberConversion.cgFloat(property.numberValue)
        guard size > 0, size <= 1000 else {
            throw ViewScopeMutationError.invalidValue
        }
        return size
    }

    /// 行高等尺寸：允许 `UITableView.automaticDimension`（-1），其余必须非负。
    private static func dimension(_ property: ViewScopeEditableProperty) throws -> CGFloat {
        let value = try ViewScopeNumberConversion.cgFloat(property.numberValue)
        if value == UITableView.automaticDimension {
            return value
        }
        guard value >= 0 else {
            throw ViewScopeMutationError.invalidValue
        }
        return value
    }

    private static func textAlignment(_ property: ViewScopeEditableProperty) throws -> NSTextAlignment {
        guard let alignment = NSTextAlignment(rawValue: try enumRawValue(property, options: ViewScopeUIKitDetailSectionBuilder.textAlignmentOptions)) else {
            throw ViewScopeMutationError.invalidValue
        }
        return alignment
    }

    /// 枚举原始值：ObjC 导入的枚举 `init(rawValue:)` 不校验取值范围，必须对照候选项显式校验。
    private static func enumRawValue(_ property: ViewScopeEditableProperty, options: [ViewScopeEditableOption]) throws -> Int {
        let rawValue = try ViewScopeNumberConversion.int(property.numberValue)
        guard options.contains(where: { $0.value == Double(rawValue) }) else {
            throw ViewScopeMutationError.invalidValue
        }
        return rawValue
    }

    /// 解析颜色；空字符串表示清除（nil）。
    private static func color(_ property: ViewScopeEditableProperty) throws -> UIColor? {
        let value = try text(property).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }
        guard let rgba = ViewScopeColorParsing.rgba(fromHex: value) else {
            throw ViewScopeMutationError.invalidValue
        }
        // UIColor(red:green:blue:alpha:) 在 iOS 10+ 使用 extended sRGB，0...1 区间与 sRGB 一致。
        return UIColor(red: CGFloat(rgba.red), green: CGFloat(rgba.green), blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha))
    }

    private static func cgColor(_ property: ViewScopeEditableProperty) throws -> CGColor? {
        let value = try text(property).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }
        guard let color = ViewScopeColorParsing.cgColor(fromHex: value) else {
            throw ViewScopeMutationError.invalidValue
        }
        return color
    }

    /// 按 key 的最后一段（top / left / bottom / right）修改边距。
    private static func mutatedInsets(_ insets: UIEdgeInsets, key: String, property: ViewScopeEditableProperty) throws -> UIEdgeInsets {
        let value = try ViewScopeNumberConversion.cgFloat(property.numberValue)
        var result = insets
        if key.hasSuffix(".top") {
            result.top = value
        } else if key.hasSuffix(".left") {
            result.left = value
        } else if key.hasSuffix(".bottom") {
            result.bottom = value
        } else if key.hasSuffix(".right") {
            result.right = value
        } else {
            throw ViewScopeMutationError.unsupportedProperty
        }
        return result
    }
}
#endif
