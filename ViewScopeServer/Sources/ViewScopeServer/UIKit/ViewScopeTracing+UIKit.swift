#if os(iOS)
import Foundation
import ObjectiveC.runtime
import UIKit

/// UIKit 版 ivar 追踪：记录“哪个对象的哪个成员变量引用了这个视图 / layer / VC / 手势”。
///
/// 与旧版 AppKit 实现的区别（对应审计 A7 / A8）：
/// - 只遍历应用自身镜像里的类，`class_getImageName` 位于 `/System/Library/`、`/usr/lib/` 的系统类直接停止，
///   不读取 UIKit 私有类里可能悬挂的 assign ivar；
/// - Swift 存储属性通过 `Mirror` 读取，不再把空类型编码的 ivar 当作对象指针解引用，也不做额外 retain；
/// - ObjC ivar 只读取类型编码明确为 `@"类名"` 且类名属于视图 / layer / VC / 手势的成员；
/// - 结果保存在本次抓取私有的字典里，不再给系统对象挂关联对象。
@MainActor
final class ViewScopeUIKitTraceStore {
    private var ivarTraces: [ObjectIdentifier: Set<ViewScopeIvarTrace>] = [:]
    private var specialTraces: [ObjectIdentifier: String] = [:]
    /// 已经遍历过 ivar 的宿主对象，避免同一对象重复标记。
    private var visitedHosts = Set<ObjectIdentifier>()

    /// 重新遍历给定窗口，生成 ivar 追踪与特殊标记（VC.view、cell 的 indexPath 等）。
    func reload(windows: [UIWindow], isExcluded: (AnyObject) -> Bool) {
        ivarTraces.removeAll()
        specialTraces.removeAll()
        visitedHosts.removeAll()

        for window in windows {
            traverse(view: window, isExcluded: isExcluded)
        }
    }

    /// 节点使用的 ivar 追踪：对象自身 + 对象的 layer（若是视图）+ 精确拥有该视图的 VC。
    func traces(forNodeObject object: AnyObject) -> [ViewScopeIvarTrace] {
        var result = ivarTraces[ObjectIdentifier(object)] ?? []
        if let view = object as? UIView {
            result.formUnion(ivarTraces[ObjectIdentifier(view.layer)] ?? [])
            if let controller = view.kg_viewScopeExactViewController {
                result.formUnion(ivarTraces[ObjectIdentifier(controller)] ?? [])
            }
        }
        return result.sorted { left, right in
            if left.hostClassName == right.hostClassName {
                return left.ivarName < right.ivarName
            }
            return left.hostClassName < right.hostClassName
        }
    }

    func specialTrace(for object: AnyObject) -> String? {
        specialTraces[ObjectIdentifier(object)]
    }

    // MARK: - 遍历

    private func traverse(view: UIView, isExcluded: (AnyObject) -> Bool) {
        guard isExcluded(view) == false else {
            return
        }
        markIvars(of: view)
        if let controller = view.kg_viewScopeExactViewController {
            markIvars(of: controller)
        }
        buildSpecialTrace(for: view)
        traversePureLayers(under: view.layer, isExcluded: isExcluded)

        for subview in view.subviews {
            traverse(view: subview, isExcluded: isExcluded)
        }
    }

    /// 只处理不承载 UIView 的纯 CALayer；承载视图的 layer 由视图遍历负责。
    private func traversePureLayers(under layer: CALayer, isExcluded: (AnyObject) -> Bool) {
        for sublayer in layer.sublayers ?? [] {
            guard sublayer.kg_viewScopeHostView == nil, isExcluded(sublayer) == false else {
                continue
            }
            markIvars(of: sublayer)
            traversePureLayers(under: sublayer, isExcluded: isExcluded)
        }
    }

    private func buildSpecialTrace(for view: UIView) {
        if let controller = view.kg_viewScopeExactViewController {
            let name = ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: controller)))
            specialTraces[ObjectIdentifier(view)] = "\(name).view"
            return
        }

        if let tableView = view as? UITableView {
            if let header = tableView.tableHeaderView {
                specialTraces[ObjectIdentifier(header)] = "tableHeaderView"
            }
            if let footer = tableView.tableFooterView {
                specialTraces[ObjectIdentifier(footer)] = "tableFooterView"
            }
            for cell in tableView.visibleCells {
                if let indexPath = tableView.indexPath(for: cell) {
                    specialTraces[ObjectIdentifier(cell)] = "{ sec: \(indexPath.section), row: \(indexPath.row) }"
                }
            }
            for section in 0 ..< tableView.numberOfSections {
                if let header = tableView.headerView(forSection: section) {
                    specialTraces[ObjectIdentifier(header)] = "sectionHeader { sec: \(section) }"
                }
                if let footer = tableView.footerView(forSection: section) {
                    specialTraces[ObjectIdentifier(footer)] = "sectionFooter { sec: \(section) }"
                }
            }
        } else if let collectionView = view as? UICollectionView {
            for indexPath in collectionView.indexPathsForVisibleItems {
                if let cell = collectionView.cellForItem(at: indexPath) {
                    specialTraces[ObjectIdentifier(cell)] = "{ item: \(indexPath.item), sec: \(indexPath.section) }"
                }
            }
        }
    }

    // MARK: - ivar 标记

    private func markIvars(of host: NSObject) {
        guard visitedHosts.insert(ObjectIdentifier(host)).inserted else {
            return
        }
        let dynamicClass: AnyClass = type(of: host)
        // 绝大多数节点是纯系统类，直接跳过，避免为它们构造 Mirror。
        guard Self.isSystemClass(dynamicClass) == false else {
            return
        }

        // 预先建立“类 → 该层 Mirror”的映射；Swift 类的存储属性从 Mirror 读取。
        var mirrorsByClass: [ObjectIdentifier: Mirror] = [:]
        var mirror: Mirror? = Mirror(reflecting: host)
        while let currentMirror = mirror {
            if let levelClass = currentMirror.subjectType as? AnyClass {
                mirrorsByClass[ObjectIdentifier(levelClass)] = currentMirror
            }
            mirror = currentMirror.superclassMirror
        }

        var currentClass: AnyClass? = dynamicClass
        while let levelClass = currentClass {
            if Self.isSystemClass(levelClass) {
                // 系统类之上不可能再出现应用自身的类，直接停止。
                break
            }
            let hostClassName = Self.makeDisplayClassName(levelClass: levelClass, dynamicClass: dynamicClass)
            if let levelMirror = mirrorsByClass[ObjectIdentifier(levelClass)],
               levelMirror.children.isEmpty == false {
                markSwiftProperties(of: host, mirror: levelMirror, hostClassName: hostClassName)
            } else {
                markObjCIvars(of: host, levelClass: levelClass, hostClassName: hostClassName)
            }
            currentClass = class_getSuperclass(levelClass)
        }
    }

    /// Swift 存储属性：`Mirror` 读取的是属性值的拷贝（弱引用会被正确加载），不需要手工处理指针。
    ///
    /// 注意：`unowned(unsafe)` 指向已释放对象时仍可能出错，这与宿主自身访问该属性的行为一致。
    private func markSwiftProperties(of host: NSObject, mirror: Mirror, hostClassName: String) {
        for child in mirror.children {
            guard let label = child.label else {
                continue
            }
            let ivarName = label.replacingOccurrences(of: "$__lazy_storage_$_", with: "")
            guard ivarName.isEmpty == false,
                  let target = Self.traceableObject(from: child.value) else {
                continue
            }
            record(trace: ViewScopeIvarTrace(
                relation: Self.relation(host: host, target: target),
                hostClassName: hostClassName,
                ivarName: ivarName
            ), for: target)
        }
    }

    /// ObjC ivar：只读取类型编码为 `@"类名"` 且类名属于可追踪类型的成员。
    private func markObjCIvars(of host: NSObject, levelClass: AnyClass, hostClassName: String) {
        var count: UInt32 = 0
        guard let ivars = class_copyIvarList(levelClass, &count) else {
            return
        }
        defer {
            free(ivars)
        }

        for index in 0 ..< Int(count) {
            let ivar = ivars[index]
            guard let encodingPointer = ivar_getTypeEncoding(ivar),
                  let namePointer = ivar_getName(ivar) else {
                continue
            }
            let encoding = String(cString: encodingPointer)
            guard let declaredClass = Self.declaredClass(fromEncoding: encoding),
                  Self.isTraceableClass(declaredClass) else {
                continue
            }
            // object_getIvar 会按 ivar 的内存管理语义（strong / weak）读取对象。
            guard let value = object_getIvar(host, ivar),
                  let target = Self.traceableObject(from: value) else {
                continue
            }
            record(trace: ViewScopeIvarTrace(
                relation: Self.relation(host: host, target: target),
                hostClassName: hostClassName,
                ivarName: String(cString: namePointer)
            ), for: target)
        }
    }

    private func record(trace: ViewScopeIvarTrace, for target: NSObject) {
        ivarTraces[ObjectIdentifier(target), default: []].insert(trace)
    }

    // MARK: - 工具

    /// 解析 `@"UIView"` / `@"UILabel<Protocol>"` 这类编码对应的类。
    private static func declaredClass(fromEncoding encoding: String) -> AnyClass? {
        guard encoding.hasPrefix("@\""), encoding.hasSuffix("\""), encoding.count > 3 else {
            return nil
        }
        var name = String(encoding.dropFirst(2).dropLast())
        if let protocolStart = name.firstIndex(of: "<") {
            name = String(name[..<protocolStart])
        }
        guard name.isEmpty == false else {
            return nil
        }
        return NSClassFromString(name)
    }

    private static func isTraceableClass(_ targetClass: AnyClass) -> Bool {
        targetClass is UIView.Type ||
            targetClass is CALayer.Type ||
            targetClass is UIViewController.Type ||
            targetClass is UIGestureRecognizer.Type
    }

    private static func traceableObject(from value: Any) -> NSObject? {
        switch value {
        case let view as UIView:
            return view
        case let layer as CALayer:
            return layer
        case let controller as UIViewController:
            return controller
        case let recognizer as UIGestureRecognizer:
            return recognizer
        default:
            return nil
        }
    }

    /// 系统镜像里的类（UIKit、Foundation、Swift 运行时等）不参与追踪。
    static func isSystemClass(_ targetClass: AnyClass) -> Bool {
        guard let imageName = class_getImageName(targetClass) else {
            // 运行时动态生成的类（例如 KVO 子类）没有镜像名，本身也没有可读的 ivar，继续向上即可。
            return false
        }
        let path = String(cString: imageName)
        return path.contains("/System/Library/") || path.contains("/usr/lib/")
    }

    private static func relation(host: NSObject, target: NSObject) -> String? {
        if host === target {
            return "self"
        }
        guard let hostView = host as? UIView else {
            return nil
        }
        let targetLayer: CALayer?
        if let layer = target as? CALayer {
            targetLayer = layer
        } else if let view = target as? UIView {
            targetLayer = view.layer
        } else {
            targetLayer = nil
        }
        if let targetLayer, targetLayer.superlayer === hostView.layer {
            return "superview"
        }
        return nil
    }

    private static func makeDisplayClassName(levelClass: AnyClass, dynamicClass: AnyClass) -> String {
        let levelName = ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(levelClass))
        let dynamicName = ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(dynamicClass))
        return dynamicName == levelName ? levelName : "\(dynamicName) : \(levelName)"
    }
}

@MainActor
extension CALayer {
    /// 承载该 layer 的 UIView（`view.layer === self`）；纯 CALayer 返回 nil。
    var kg_viewScopeHostView: UIView? {
        guard let view = delegate as? UIView, view.layer === self else {
            return nil
        }
        return view
    }

    /// 沿 superlayer 向上找到所在窗口。
    var kg_viewScopeWindow: UIWindow? {
        var current: CALayer? = self
        while let layer = current {
            if let hostView = layer.kg_viewScopeHostView {
                if let window = hostView as? UIWindow {
                    return window
                }
                if let window = hostView.window {
                    return window
                }
            }
            current = layer.superlayer
        }
        return nil
    }
}

@MainActor
extension UIView {
    /// 精确拥有该视图的 VC（`controller.view === self`）。UIKit 把 VC 设为其根视图的 next responder。
    var kg_viewScopeExactViewController: UIViewController? {
        guard let controller = next as? UIViewController,
              controller.viewIfLoaded === self else {
            return nil
        }
        return controller
    }
}
#endif
