import Foundation

/// 弱引用包装。
///
/// 抓取结果里的节点引用全部通过它持有，避免 `lastReferenceContext` 强持有整棵视图树，
/// 关闭的窗口、被移除的视图可以正常释放。
final class ViewScopeWeakReference<Object: AnyObject> {
    weak var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}

/// 节点 ID 生成工具：使用对象地址生成跨抓取稳定的 ID。
enum ViewScopeNodeIdentity {
    /// 生成形如 `layer-0x600001234560` 的节点 ID。
    static func nodeID(kind: ViewScopeHierarchyNode.Kind, object: AnyObject) -> String {
        "\(kind.rawValue)-\(address(of: object))"
    }

    /// 对象地址，小写十六进制并带 `0x` 前缀。
    static func address(of object: AnyObject) -> String {
        let rawValue = UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
        return "0x" + String(rawValue, radix: 16, uppercase: false)
    }

    /// 解析 "0x..." 十六进制地址（兼容带前导零的旧格式），无法解析返回 nil。
    static func parseAddress(_ string: String) -> UInt? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("0x") else {
            return nil
        }
        return UInt(trimmed.dropFirst(2), radix: 16)
    }

    /// objectID 与对象地址是否一致；objectID 不是地址形式时视为一致（不做校验）。
    static func address(_ objectID: String, matches object: AnyObject) -> Bool {
        guard let expected = parseAddress(objectID) else {
            return true
        }
        return expected == UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
    }
}
