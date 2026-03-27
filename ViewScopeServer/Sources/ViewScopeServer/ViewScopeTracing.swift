import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime

@MainActor private var viewScopeIvarTracesAssociationKey: UInt8 = 0
@MainActor private var viewScopeSpecialTraceAssociationKey: UInt8 = 0
@MainActor private let viewScopeTrackedTraceObjects = NSHashTable<NSObject>.weakObjects()

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

enum ViewScopeTraceManager {
    @MainActor
    static func reload(windows: [NSWindow]) {
        var tracedLayers = Set<ObjectIdentifier>()

        for object in viewScopeTrackedTraceObjects.allObjects {
            object.viewScopeStoredIvarTraces = []
            object.viewScopeStoredSpecialTrace = nil
        }
        for window in windows {
            markIVarsInAllClassLevels(of: window)
            if let rootView = window.viewScopeRootView {
                addTraceForInterfaceObject(rootView, tracedLayers: &tracedLayers)
            }
        }
    }

    @MainActor
    private static func addTraceForInterfaceObject(
        _ interfaceObject: AnyObject,
        tracedLayers: inout Set<ObjectIdentifier>
    ) {
        switch interfaceObject {
        case let view as NSView:
            markIVarsInAllClassLevels(of: view)
            if let controller = view.viewScopeExactRootOwningViewController {
                markIVarsInAllClassLevels(of: controller)
            }
            buildSpecialTrace(for: view)
            if let layer = view.layer {
                if view.viewScopeHostsBackingLayerNode {
                    addTraceForLayerTree(layer, tracedLayers: &tracedLayers)
                } else {
                    markIVarsInAllClassLevels(of: layer)
                }
            }
            for subview in view.subviews {
                addTraceForInterfaceObject(subview, tracedLayers: &tracedLayers)
            }
        case let layer as CALayer:
            addTraceForLayerTree(layer, tracedLayers: &tracedLayers)
        case let window as NSWindow:
            markIVarsInAllClassLevels(of: window)
            if let rootView = window.viewScopeRootView {
                addTraceForInterfaceObject(rootView, tracedLayers: &tracedLayers)
            }
        default:
            break
        }
    }

    @MainActor
    private static func addTraceForLayerTree(
        _ layer: CALayer,
        tracedLayers: inout Set<ObjectIdentifier>
    ) {
        guard tracedLayers.insert(ObjectIdentifier(layer)).inserted else {
            return
        }
        if let hostView = layer.viewScopeHostView {
            markIVarsInAllClassLevels(of: hostView)
            if let controller = hostView.viewScopeOwningViewController {
                markIVarsInAllClassLevels(of: controller)
            }
            buildSpecialTrace(for: hostView)
        } else {
            markIVarsInAllClassLevels(of: layer)
        }

        for sublayer in layer.sublayers ?? [] {
            addTraceForLayerTree(sublayer, tracedLayers: &tracedLayers)
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
            if #available(macOS 10.11, *) {
                for indexPath in collectionView.indexPathsForVisibleItems() {
                    collectionView.item(at: indexPath)?.viewScopeStoredSpecialTrace = "{ item: \(indexPath.item), sec: \(indexPath.section) }"
                }
            }
        }
    }

    @MainActor
    private static func markIVarsInAllClassLevels(of object: NSObject) {
        markIVars(of: object, class: type(of: object))
        ViewScopeSwiftTraceManager.markIVars(of: object)
    }

    @MainActor
    private static func markIVars(of hostObject: NSObject, class targetClass: AnyClass?) {
        guard let targetClass else {
            return
        }

        let className = NSStringFromClass(targetClass)
        // 停在 AppKit 的基础类（精确匹配），避免进入框架内部 ivar；
        // 用 hasPrefix 仅对 NSObject/NSResponder 这类真正的根类，
        // NSControl/NSButton 只做精确匹配，让子类仍能被追踪。
        let exactTerminators: Set<String> = ["NSObject", "NSResponder", "NSView", "NSControl", "NSButton"]
        if exactTerminators.contains(className) {
            return
        }

        var count: UInt32 = 0
        guard let ivars = class_copyIvarList(targetClass, &count) else {
            markIVars(of: hostObject, class: class_getSuperclass(targetClass))
            return
        }
        defer { free(ivars) }

        for index in 0 ..< Int(count) {
            let ivar = ivars[index]
            guard let ivarObject = objectForTraceableIvar(in: hostObject, ivar: ivar),
                  let ivarNamePointer = ivar_getName(ivar) else {
                continue
            }

            let ivarName = String(cString: ivarNamePointer)
            let trace = ViewScopeIvarTrace(
                relation: relation(hostObject: hostObject, ivarObject: ivarObject),
                hostClassName: makeDisplayClassName(superClass: targetClass, childClass: type(of: hostObject)),
                ivarName: ivarName
            )

            guard invalidTraces.contains(trace) == false else {
                continue
            }

            let existing = ivarObject.viewScopeStoredIvarTraces
            if existing.contains(trace) == false {
                ivarObject.viewScopeStoredIvarTraces = existing + [trace]
            }
        }

        markIVars(of: hostObject, class: class_getSuperclass(targetClass))
    }

    @MainActor
    private static func objectForTraceableIvar(in hostObject: NSObject, ivar: Ivar) -> NSObject? {
        guard let encodingPointer = ivar_getTypeEncoding(ivar) else {
            return nil
        }
        let ivarType = String(cString: encodingPointer)
        guard ivarType.hasPrefix("@"), ivarType.count > 3 else {
            return nil
        }

        let startIndex = ivarType.index(ivarType.startIndex, offsetBy: 2)
        let endIndex = ivarType.index(before: ivarType.endIndex)
        guard startIndex < endIndex else {
            return nil
        }

        let className = String(ivarType[startIndex ..< endIndex])
        guard let ivarClass = NSClassFromString(className) else {
            return nil
        }
        guard ivarClass is NSView.Type ||
            ivarClass is CALayer.Type ||
            ivarClass is NSViewController.Type ||
            ivarClass is NSGestureRecognizer.Type else {
            return nil
        }

        guard let rawObject = object_getIvar(hostObject, ivar) else {
            return nil
        }

        switch rawObject {
        case let object as NSView:
            return object
        case let object as CALayer:
            return object
        case let object as NSViewController:
            return object
        case let object as NSGestureRecognizer:
            return object
        default:
            return nil
        }
    }

    @MainActor
    fileprivate static func relation(hostObject: NSObject, ivarObject: NSObject) -> String? {
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

    fileprivate static func makeDisplayClassName(superClass: AnyClass, childClass: AnyClass?) -> String {
        let superName = ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(superClass))
        guard let childClass else {
            return superName
        }
        let childName = ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(childClass))
        return childName == superName ? superName : "\(childName) : \(superName)"
    }

    fileprivate static let invalidTraces: Set<ViewScopeIvarTrace> = [
        ViewScopeIvarTrace(hostClassName: "NSView", ivarName: "_window"),
        ViewScopeIvarTrace(hostClassName: "NSViewController", ivarName: "_view"),
        ViewScopeIvarTrace(hostClassName: "NSViewController", ivarName: "_parentViewController")
    ]
}

enum ViewScopeSwiftTraceManager {
    @MainActor
    static func markIVars(of hostObject: NSObject) {
        var currentClass: AnyClass? = type(of: hostObject)
        let initialClass: AnyClass? = currentClass

        while let unwrappedCurrentClass = currentClass {
            let className = NSStringFromClass(unwrappedCurrentClass)
            let exactTerminators: Set<String> = ["NSObject", "NSResponder", "NSView", "NSControl", "NSButton"]
            if exactTerminators.contains(className) { break }

            var ivarCount: UInt32 = 0
            guard let ivars = class_copyIvarList(unwrappedCurrentClass, &ivarCount) else {
                currentClass = class_getSuperclass(unwrappedCurrentClass)
                continue
            }
            defer { free(ivars) }

            for i in 0 ..< Int(ivarCount) {
                let ivar = ivars[i]

                // Only handle Swift-style ivars (empty ObjC type encoding).
                // ObjC-typed ivars (e.g. @"NSView") are handled by the ObjC markIVars
                // path and must not be double-counted here.
                guard let encodingPtr = ivar_getTypeEncoding(ivar),
                      String(cString: encodingPtr).isEmpty else { continue }

                guard let namePtr = ivar_getName(ivar) else { continue }
                let rawName = String(cString: namePtr)
                let ivarName = rawName.replacingOccurrences(of: "$__lazy_storage_$_", with: "")
                guard ivarName.isEmpty == false else { continue }

                // Read the raw pointer value WITHOUT retaining it. This is safe even for
                // `unowned(unsafe)` dangling pointers because we do not dereference it here.
                guard let rawPtr = ViewScopeRuntimeIvarReader.storedObjectPointer(
                    in: hostObject, ivar: ivar
                ) else { continue }

                // Verify the pointer is a live heap allocation before dereferencing.
                // `malloc_size` returns 0 for freed blocks and non-heap addresses.
                // A dangling `unowned(unsafe)` pointer after the object is freed
                // consistently returns 0 here; live strong/weak references return > 0.
                guard malloc_size(rawPtr) > 0 else { continue }

                // Safe to promote to a managed reference. We explicitly retain (+1) then
                // let ARC release at scope exit (-1) for a net-zero refcount change.
                let ivarObject = Unmanaged<NSObject>.fromOpaque(rawPtr).retain().takeUnretainedValue()
                guard ivarObject is NSView ||
                      ivarObject is CALayer ||
                      ivarObject is NSViewController ||
                      ivarObject is NSGestureRecognizer else { continue }

                let trace = ViewScopeIvarTrace(
                    relation: ViewScopeTraceManager.relation(hostObject: hostObject, ivarObject: ivarObject),
                    hostClassName: ViewScopeTraceManager.makeDisplayClassName(
                        superClass: unwrappedCurrentClass, childClass: initialClass
                    ),
                    ivarName: ivarName
                )
                guard ViewScopeTraceManager.invalidTraces.contains(trace) == false else { continue }

                let existing = ivarObject.viewScopeStoredIvarTraces
                if existing.contains(trace) == false {
                    ivarObject.viewScopeStoredIvarTraces = existing + [trace]
                }
            }

            currentClass = class_getSuperclass(unwrappedCurrentClass)
        }
    }
}

@MainActor
extension NSView {
    var viewScopeIvarTracesForNode: [ViewScopeIvarTrace] {
        viewScopeStoredIvarTraces.uniquedAndSortedForViewScope
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
        String(describing: Unmanaged.passUnretained(self).toOpaque())
    }

    var viewScopeFrameInWindow: NSRect? {
        if let hostView = viewScopeHostView,
           hostView.window != nil {
            return hostView.convert(hostView.bounds, to: nil)
        }
        guard let window = viewScopeWindow,
              let rootView = window.viewScopeRootView,
              let rootLayer = rootView.layer else {
            return nil
        }
        let rectInRoot = rootLayer.convert(bounds, from: self)
        return rootView.convert(rectInRoot, to: nil)
    }

    var viewScopeSpecialTraceForNode: String? {
        if let hostView = viewScopeHostView {
            return hostView.viewScopeStoredSpecialTrace
        }
        return viewScopeStoredSpecialTrace
    }

    var viewScopeIvarTracesForNode: [ViewScopeIvarTrace] {
        if let hostView = viewScopeHostView {
            var traces = hostView.viewScopeStoredIvarTraces
            if let controller = hostView.viewScopeOwningViewController {
                traces.append(contentsOf: controller.viewScopeStoredIvarTraces)
            }
            return traces.uniquedAndSortedForViewScope
        }
        return viewScopeStoredIvarTraces.uniquedAndSortedForViewScope
    }
}

private extension NSView {
    var viewScopeHostsBackingLayerNode: Bool {
        layer != nil
    }
}

private extension Array where Element == ViewScopeIvarTrace {
    var uniquedAndSortedForViewScope: [ViewScopeIvarTrace] {
        Array(Set(self)).sorted {
            if $0.hostClassName == $1.hostClassName {
                return $0.ivarName < $1.ivarName
            }
            return $0.hostClassName < $1.hostClassName
        }
    }
}
