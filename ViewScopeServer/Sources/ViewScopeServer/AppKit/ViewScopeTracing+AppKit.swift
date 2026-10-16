#if os(macOS)
import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime

@MainActor private var viewScopeIvarTracesAssociationKey: UInt8 = 0
@MainActor private var viewScopeSpecialTraceAssociationKey: UInt8 = 0
@MainActor private let viewScopeTrackedTraceObjects = NSHashTable<NSObject>.weakObjects()

/// 直接读取 ivar 槽位里的原始指针，不做 retain，也不解引用。
enum ViewScopeRuntimeIvarReader {
    static func storedObjectPointer(in object: AnyObject, ivarNamed name: String) -> UnsafeRawPointer? {
        var currentClass: AnyClass? = type(of: object)

        while let targetClass = currentClass {
            if let ivar = class_getInstanceVariable(targetClass, name) {
                return storedObjectPointer(in: object, ivar: ivar)
            }
            currentClass = class_getSuperclass(targetClass)
        }

        return nil
    }

    static func storedObjectPointer(in object: AnyObject, ivar: Ivar) -> UnsafeRawPointer? {
        guard mayStoreObjectReference(ivar) else {
            return nil
        }

        let basePointer = UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
        let slotPointer = basePointer
            .advanced(by: ivar_getOffset(ivar))
            .assumingMemoryBound(to: Optional<UnsafeRawPointer>.self)
        return slotPointer.pointee
    }

    /// 只有 `@` 开头（ObjC 对象）或空编码（Swift 存储属性）的 ivar 才可能存放对象指针。
    static func mayStoreObjectReference(_ ivar: Ivar) -> Bool {
        guard let encodingPointer = ivar_getTypeEncoding(ivar) else {
            return true
        }

        let encoding = String(cString: encodingPointer)
        return encoding.isEmpty || encoding.hasPrefix("@")
    }
}

@MainActor
extension NSObject {
    var viewScopeStoredIvarTraces: [ViewScopeIvarTrace] {
        get {
            objc_getAssociatedObject(self, &viewScopeIvarTracesAssociationKey) as? [ViewScopeIvarTrace] ?? []
        }
        set {
            viewScopeTrackedTraceObjects.add(self)
            objc_setAssociatedObject(
                self,
                &viewScopeIvarTracesAssociationKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    var viewScopeStoredSpecialTrace: String? {
        get {
            objc_getAssociatedObject(self, &viewScopeSpecialTraceAssociationKey) as? String
        }
        set {
            viewScopeTrackedTraceObjects.add(self)
            objc_setAssociatedObject(
                self,
                &viewScopeSpecialTraceAssociationKey,
                newValue,
                .OBJC_ASSOCIATION_COPY_NONATOMIC
            )
        }
    }
}

/// ivar 追踪：找出“哪个对象的哪个 ivar 指向了这个视图/图层”。
///
/// 安全策略（修复 A7 / A8）：
/// - 先遍历视图树收集所有“已知存活”的界面对象（视图、图层、精确拥有视图的 VC、手势），按地址建索引；
/// - 读取 ivar 时只取槽位里的原始指针值，与索引比对，命中才认为是对象引用；
///   不会 retain / 解引用任意指针，悬挂的 assign / unowned(unsafe) ivar 与非对象的 Swift 存储都不会造成崩溃或泄漏；
/// - 跳过系统镜像（/System、/usr/lib）里的类，避免进入 AppKit 私有 ivar。
enum ViewScopeTraceManager {
    @MainActor
    static func reload(windows: [NSWindow]) {
        for object in viewScopeTrackedTraceObjects.allObjects {
            object.viewScopeStoredIvarTraces = []
            object.viewScopeStoredSpecialTrace = nil
        }

        var index = KnownObjectIndex()
        for window in windows {
            index.insert(window)
            if let rootView = window.viewScopeRootView {
                collectKnownObjects(in: rootView, index: &index)
            }
        }

        var marked = Set<ObjectIdentifier>()
        for window in windows {
            markIVarsInAllClassLevels(of: window, index: index, marked: &marked)
            if let rootView = window.viewScopeRootView {
                addTrace(for: rootView, index: index, marked: &marked)
            }
        }
    }

    /// 地址 → 对象 的索引；索引持有的都是当前视图树中确实存活的对象。
    struct KnownObjectIndex {
        private(set) var objectsByAddress: [UInt: NSObject] = [:]

        mutating func insert(_ object: NSObject) {
            objectsByAddress[UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())] = object
        }

        func object(at pointer: UnsafeRawPointer) -> NSObject? {
            objectsByAddress[UInt(bitPattern: pointer)]
        }
    }

    @MainActor
    private static func collectKnownObjects(in view: NSView, index: inout KnownObjectIndex) {
        index.insert(view)
        if let controller = view.viewScopeExactRootOwningViewController {
            index.insert(controller)
        }
        for recognizer in view.gestureRecognizers {
            index.insert(recognizer)
        }
        if let layer = view.layer {
            collectKnownLayers(in: layer, index: &index)
        }
        for subview in view.subviews {
            collectKnownObjects(in: subview, index: &index)
        }
    }

    @MainActor
    private static func collectKnownLayers(in layer: CALayer, index: inout KnownObjectIndex) {
        index.insert(layer)
        for sublayer in layer.sublayers ?? [] where sublayer.viewScopeHostView == nil {
            collectKnownLayers(in: sublayer, index: &index)
        }
    }

    /// 只沿视图树遍历一次：每个视图标记自身 ivar、精确 VC 的 ivar，以及其图层下的纯 CALayer。
    @MainActor
    private static func addTrace(for view: NSView, index: KnownObjectIndex, marked: inout Set<ObjectIdentifier>) {
        markIVarsInAllClassLevels(of: view, index: index, marked: &marked)
        if let controller = view.viewScopeExactRootOwningViewController {
            markIVarsInAllClassLevels(of: controller, index: index, marked: &marked)
        }
        buildSpecialTrace(for: view)
        if let layer = view.layer {
            addTraceForPlainLayers(under: layer, index: index, marked: &marked)
        }
        for subview in view.subviews {
            addTrace(for: subview, index: index, marked: &marked)
        }
    }

    @MainActor
    private static func addTraceForPlainLayers(under layer: CALayer, index: KnownObjectIndex, marked: inout Set<ObjectIdentifier>) {
        for sublayer in layer.sublayers ?? [] where sublayer.viewScopeHostView == nil {
            markIVarsInAllClassLevels(of: sublayer, index: index, marked: &marked)
            addTraceForPlainLayers(under: sublayer, index: index, marked: &marked)
        }
    }

    @MainActor
    private static func buildSpecialTrace(for view: NSView) {
        if let controller = view.viewScopeExactRootOwningViewController {
            view.viewScopeStoredSpecialTrace = "\(ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(type(of: controller)))).view"
            return
        }

        if let tableView = view as? NSTableView {
            tableView.headerView?.viewScopeStoredSpecialTrace = "tableView.headerView"
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            if visibleRows.length > 0 {
                for row in visibleRows.location ..< NSMaxRange(visibleRows) {
                    let rowView = tableView.rowView(atRow: row, makeIfNecessary: false)
                    let level: Int? = (tableView as? NSOutlineView).map { outlineView in
                        outlineView.level(forRow: row)
                    }
                    if let level {
                        rowView?.viewScopeStoredSpecialTrace = "{ level: \(level), row: \(row) }"
                    } else {
                        rowView?.viewScopeStoredSpecialTrace = "{ row: \(row) }"
                    }

                    let numberOfColumns = tableView.numberOfColumns
                    for column in 0 ..< numberOfColumns {
                        let cellView = rowView?.view(atColumn: column) as? NSObject
                        if let level {
                            cellView?.viewScopeStoredSpecialTrace = "{ level: \(level), row: \(row), column: \(column) }"
                        } else {
                            cellView?.viewScopeStoredSpecialTrace = "{ row: \(row), column: \(column) }"
                        }
                    }
                }
            }
        } else if let collectionView = view as? NSCollectionView {
            for indexPath in collectionView.indexPathsForVisibleItems() {
                collectionView.item(at: indexPath)?.viewScopeStoredSpecialTrace = "{ item: \(indexPath.item), sec: \(indexPath.section) }"
            }
        }
    }

    /// 判断类是否来自系统镜像；系统类的 ivar 不追踪。
    static func isSystemClass(_ targetClass: AnyClass) -> Bool {
        guard let imageNamePointer = class_getImageName(targetClass) else {
            return false
        }
        let imageName = String(cString: imageNamePointer)
        return imageName.hasPrefix("/System/") || imageName.hasPrefix("/usr/lib/")
    }

    @MainActor
    private static func markIVarsInAllClassLevels(of hostObject: NSObject, index: KnownObjectIndex, marked: inout Set<ObjectIdentifier>) {
        // 每个宿主对象只标记一次，避免重复遍历（B12）。
        guard marked.insert(ObjectIdentifier(hostObject)).inserted else {
            return
        }
        let initialClass: AnyClass = type(of: hostObject)
        var currentClass: AnyClass? = initialClass

        while let targetClass = currentClass {
            if isSystemClass(targetClass) {
                // 系统类的父类也必然是系统类，直接结束。
                break
            }

            var count: UInt32 = 0
            if let ivars = class_copyIvarList(targetClass, &count) {
                for offset in 0 ..< Int(count) {
                    markIVar(ivars[offset], of: hostObject, declaringClass: targetClass, initialClass: initialClass, index: index)
                }
                free(ivars)
            }
            currentClass = class_getSuperclass(targetClass)
        }
    }

    @MainActor
    private static func markIVar(
        _ ivar: Ivar,
        of hostObject: NSObject,
        declaringClass: AnyClass,
        initialClass: AnyClass,
        index: KnownObjectIndex
    ) {
        guard let rawPointer = ViewScopeRuntimeIvarReader.storedObjectPointer(in: hostObject, ivar: ivar),
              let ivarObject = index.object(at: rawPointer),
              let namePointer = ivar_getName(ivar) else {
            return
        }
        let rawName = String(cString: namePointer)
        let ivarName = rawName.replacingOccurrences(of: "$__lazy_storage_$_", with: "")
        guard ivarName.isEmpty == false else {
            return
        }

        let trace = ViewScopeIvarTrace(
            relation: relation(hostObject: hostObject, ivarObject: ivarObject),
            hostClassName: makeDisplayClassName(superClass: declaringClass, childClass: initialClass),
            ivarName: ivarName
        )
        guard invalidTraces.contains(trace) == false else {
            return
        }

        let existing = ivarObject.viewScopeStoredIvarTraces
        if existing.contains(trace) == false {
            ivarObject.viewScopeStoredIvarTraces = existing + [trace]
        }
    }

    @MainActor
    static func relation(hostObject: NSObject, ivarObject: NSObject) -> String? {
        if hostObject === ivarObject {
            return "self"
        }
        guard let hostView = hostObject as? NSView else {
            return nil
        }

        let ivarLayer: CALayer?
        if let layer = ivarObject as? CALayer {
            ivarLayer = layer
        } else if let view = ivarObject as? NSView {
            ivarLayer = view.layer
        } else {
            ivarLayer = nil
        }

        if let ivarLayer,
           ivarLayer.superlayer === hostView.layer {
            return "superview"
        }
        return nil
    }

    static func makeDisplayClassName(superClass: AnyClass, childClass: AnyClass?) -> String {
        let superName = ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(superClass))
        guard let childClass else {
            return superName
        }
        let childName = ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(childClass))
        return childName == superName ? superName : "\(childName) : \(superName)"
    }

    static let invalidTraces: Set<ViewScopeIvarTrace> = [
        ViewScopeIvarTrace(hostClassName: "NSView", ivarName: "_window"),
        ViewScopeIvarTrace(hostClassName: "NSViewController", ivarName: "_view"),
        ViewScopeIvarTrace(hostClassName: "NSViewController", ivarName: "_parentViewController")
    ]
}

@MainActor
extension NSView {
    var viewScopeIvarTracesForNode: [ViewScopeIvarTrace] {
        viewScopeStoredIvarTraces.viewScopeUniquedAndSorted
    }
}

@MainActor
extension CALayer {
    var viewScopeHostView: NSView? {
        guard let delegate = delegate as? NSView,
              delegate.layer === self else {
            return nil
        }
        return delegate
    }

    var viewScopeWindow: NSWindow? {
        var currentLayer: CALayer? = self
        while let layer = currentLayer {
            if let window = layer.viewScopeHostView?.window {
                return window
            }
            currentLayer = layer.superlayer
        }
        return nil
    }

    var viewScopeAddress: String {
        ViewScopeNodeIdentity.address(of: self)
    }

    var viewScopeFrameInWindow: NSRect? {
        if let hostView = viewScopeHostView,
           hostView.window != nil {
            return hostView.convert(hostView.bounds, to: nil)
        }
        // 纯 CALayer：找到最近的带宿主视图的祖先 layer，先转换到其坐标，再由宿主视图转换到窗口。
        var ancestor = superlayer
        while let candidate = ancestor {
            if let hostView = candidate.viewScopeHostView, hostView.window != nil {
                let rectInHostLayer = candidate.convert(bounds, from: self)
                return hostView.convert(rectInHostLayer, to: nil)
            }
            ancestor = candidate.superlayer
        }
        return nil
    }

    var viewScopeSpecialTraceForNode: String? {
        if let hostView = viewScopeHostView {
            return hostView.viewScopeStoredSpecialTrace
        }
        return viewScopeStoredSpecialTrace
    }

    /// 节点 ivar trace：带宿主视图时取宿主视图自身与“精确拥有它”的 VC 的 trace（B4）。
    var viewScopeIvarTracesForNode: [ViewScopeIvarTrace] {
        if let hostView = viewScopeHostView {
            var traces = hostView.viewScopeStoredIvarTraces
            traces.append(contentsOf: viewScopeStoredIvarTraces)
            if let controller = hostView.viewScopeExactRootOwningViewController {
                traces.append(contentsOf: controller.viewScopeStoredIvarTraces)
            }
            return traces.viewScopeUniquedAndSorted
        }
        return viewScopeStoredIvarTraces.viewScopeUniquedAndSorted
    }
}

private extension Array where Element == ViewScopeIvarTrace {
    var viewScopeUniquedAndSorted: [ViewScopeIvarTrace] {
        Array(Set(self)).sorted {
            if $0.hostClassName == $1.hostClassName {
                return $0.ivarName < $1.ivarName
            }
            return $0.hostClassName < $1.hostClassName
        }
    }
}
#endif
