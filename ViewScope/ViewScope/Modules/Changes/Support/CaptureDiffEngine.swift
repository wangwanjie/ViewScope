import Foundation
import ViewScopeServer

/// 两次抓取之间的一条差异。
struct CaptureDiffEntry: Identifiable, Equatable {
    enum Category: String, CaseIterable, Equatable {
        case added
        case removed
        case frameChanged
        case visibilityChanged
        case classChanged
        case reparented
    }

    let id: String
    let category: Category
    /// 当前抓取中的节点 ID；`removed` 时为 nil。
    let currentNodeID: String?
    /// 基线抓取中的节点 ID；`added` 时为 nil。
    let baselineNodeID: String?
    let className: String
    let title: String
    let address: String?
    /// 差异的简短描述，例如 frame 增量、hidden/alpha 前后值。
    let detail: String
    /// frame 变化量（仅 `frameChanged`）。
    let frameDelta: ViewScopeRect?
}

struct CaptureDiffResult: Equatable {
    var entries: [CaptureDiffEntry]

    static let empty = CaptureDiffResult(entries: [])

    func count(of category: CaptureDiffEntry.Category) -> Int {
        entries.filter { $0.category == category }.count
    }

    func entries(in category: CaptureDiffEntry.Category?) -> [CaptureDiffEntry] {
        guard let category else {
            return entries
        }
        return entries.filter { $0.category == category }
    }
}

/// 抓取对比引擎。
///
/// 匹配规则：
/// 1. 优先按“节点类型 + 对象地址”匹配（地址跨抓取稳定）；
/// 2. 仍未匹配的节点，再按“类名 + 层级路径”匹配（应对宿主重启后地址全部变化的情况）。
enum CaptureDiffEngine {
    /// frame 比较容差，单位 point。
    static let frameTolerance = 0.5
    /// alpha 比较容差。
    static let alphaTolerance = 0.001

    static func diff(baseline: ViewScopeCapturePayload, current: ViewScopeCapturePayload) -> CaptureDiffResult {
        let baselinePaths = structuralPaths(in: baseline)
        let currentPaths = structuralPaths(in: current)

        // baselineID -> currentID
        var matches: [String: String] = [:]
        var matchedCurrentIDs = Set<String>()

        // 第一轮：地址匹配
        var currentByAddress: [String: String] = [:]
        for (nodeID, node) in current.nodes {
            if let key = addressKey(for: node) {
                currentByAddress[key] = nodeID
            }
        }
        for nodeID in orderedNodeIDs(in: baseline) {
            guard let node = baseline.nodes[nodeID], let key = addressKey(for: node) else {
                continue
            }
            if let currentID = currentByAddress[key], matchedCurrentIDs.contains(currentID) == false {
                matches[nodeID] = currentID
                matchedCurrentIDs.insert(currentID)
            }
        }

        // 第二轮：类名 + 路径匹配
        var currentByPath: [String: String] = [:]
        for (nodeID, path) in currentPaths where matchedCurrentIDs.contains(nodeID) == false {
            currentByPath[path] = nodeID
        }
        for nodeID in orderedNodeIDs(in: baseline) where matches[nodeID] == nil {
            guard let path = baselinePaths[nodeID], let currentID = currentByPath[path],
                  matchedCurrentIDs.contains(currentID) == false else {
                continue
            }
            matches[nodeID] = currentID
            matchedCurrentIDs.insert(currentID)
        }

        var entries: [CaptureDiffEntry] = []

        // 匹配上的节点：比较类名、父节点、frame、hidden/alpha
        for baselineID in orderedNodeIDs(in: baseline) {
            guard let currentID = matches[baselineID],
                  let oldNode = baseline.nodes[baselineID],
                  let newNode = current.nodes[currentID] else {
                continue
            }

            if pathClassName(of: oldNode) != pathClassName(of: newNode) {
                entries.append(
                    makeEntry(
                        category: .classChanged,
                        baselineID: baselineID,
                        currentID: currentID,
                        node: newNode,
                        detail: "\(displayName(pathClassName(of: oldNode))) → \(displayName(pathClassName(of: newNode)))"
                    )
                )
            }

            let expectedParentID = oldNode.parentID.flatMap { matches[$0] }
            let parentChanged: Bool
            if oldNode.parentID == nil {
                parentChanged = newNode.parentID != nil
            } else if let expectedParentID {
                parentChanged = expectedParentID != newNode.parentID
            } else {
                // 旧父节点已被删除：节点被挪到了别处
                parentChanged = true
            }
            if parentChanged {
                let oldParentName = oldNode.parentID.flatMap { baseline.nodes[$0] }.map { displayName(pathClassName(of: $0)) } ?? "—"
                let newParentName = newNode.parentID.flatMap { current.nodes[$0] }.map { displayName(pathClassName(of: $0)) } ?? "—"
                entries.append(
                    makeEntry(
                        category: .reparented,
                        baselineID: baselineID,
                        currentID: currentID,
                        node: newNode,
                        detail: "\(oldParentName) → \(newParentName)"
                    )
                )
            }

            let delta = ViewScopeRect(
                x: newNode.frame.x - oldNode.frame.x,
                y: newNode.frame.y - oldNode.frame.y,
                width: newNode.frame.width - oldNode.frame.width,
                height: newNode.frame.height - oldNode.frame.height
            )
            if abs(delta.x) > frameTolerance || abs(delta.y) > frameTolerance ||
                abs(delta.width) > frameTolerance || abs(delta.height) > frameTolerance {
                entries.append(
                    CaptureDiffEntry(
                        id: "frame|\(baselineID)|\(currentID)",
                        category: .frameChanged,
                        currentNodeID: currentID,
                        baselineNodeID: baselineID,
                        className: pathClassName(of: newNode),
                        title: newNode.title,
                        address: newNode.address,
                        detail: frameDeltaDescription(delta),
                        frameDelta: delta
                    )
                )
            }

            var visibilityChanges: [String] = []
            if oldNode.isHidden != newNode.isHidden {
                visibilityChanges.append("hidden \(oldNode.isHidden ? "YES" : "NO") → \(newNode.isHidden ? "YES" : "NO")")
            }
            if abs(oldNode.alphaValue - newNode.alphaValue) > alphaTolerance {
                visibilityChanges.append(
                    "alpha \(WorkspaceModificationValueFormatter.compactNumber(oldNode.alphaValue)) → \(WorkspaceModificationValueFormatter.compactNumber(newNode.alphaValue))"
                )
            }
            if visibilityChanges.isEmpty == false {
                entries.append(
                    makeEntry(
                        category: .visibilityChanged,
                        baselineID: baselineID,
                        currentID: currentID,
                        node: newNode,
                        detail: visibilityChanges.joined(separator: ", ")
                    )
                )
            }
        }

        // 新增：当前抓取中未被匹配的节点
        for currentID in orderedNodeIDs(in: current) where matchedCurrentIDs.contains(currentID) == false {
            guard let node = current.nodes[currentID] else {
                continue
            }
            let parentName = node.parentID.flatMap { current.nodes[$0] }.map { displayName(pathClassName(of: $0)) } ?? "—"
            entries.append(
                CaptureDiffEntry(
                    id: "added|\(currentID)",
                    category: .added,
                    currentNodeID: currentID,
                    baselineNodeID: nil,
                    className: pathClassName(of: node),
                    title: node.title,
                    address: node.address,
                    detail: parentName,
                    frameDelta: nil
                )
            )
        }

        // 删除：基线中未被匹配的节点
        for baselineID in orderedNodeIDs(in: baseline) where matches[baselineID] == nil {
            guard let node = baseline.nodes[baselineID] else {
                continue
            }
            let parentName = node.parentID.flatMap { baseline.nodes[$0] }.map { displayName(pathClassName(of: $0)) } ?? "—"
            entries.append(
                CaptureDiffEntry(
                    id: "removed|\(baselineID)",
                    category: .removed,
                    currentNodeID: nil,
                    baselineNodeID: baselineID,
                    className: pathClassName(of: node),
                    title: node.title,
                    address: node.address,
                    detail: parentName,
                    frameDelta: nil
                )
            )
        }

        return CaptureDiffResult(entries: entries)
    }

    // MARK: - 私有实现

    private static func makeEntry(
        category: CaptureDiffEntry.Category,
        baselineID: String,
        currentID: String,
        node: ViewScopeHierarchyNode,
        detail: String
    ) -> CaptureDiffEntry {
        CaptureDiffEntry(
            id: "\(category.rawValue)|\(baselineID)|\(currentID)",
            category: category,
            currentNodeID: currentID,
            baselineNodeID: baselineID,
            className: pathClassName(of: node),
            title: node.title,
            address: node.address,
            detail: detail,
            frameDelta: nil
        )
    }

    private static func addressKey(for node: ViewScopeHierarchyNode) -> String? {
        guard let address = node.address?.lowercased(), address.isEmpty == false else {
            return nil
        }
        // 地址本身已唯一标识对象；不拼接节点类型，避免同一对象在 view/layer 两种节点类型间切换时匹配失败
        return address
    }

    private static func displayName(_ className: String) -> String {
        ViewScopeClassNameFormatter.displayName(for: className)
    }

    private static func frameDeltaDescription(_ delta: ViewScopeRect) -> String {
        var parts: [String] = []
        let pairs: [(String, Double)] = [("x", delta.x), ("y", delta.y), ("w", delta.width), ("h", delta.height)]
        for (label, value) in pairs where abs(value) > frameTolerance {
            let sign = value > 0 ? "+" : ""
            parts.append("\(label) \(sign)\(WorkspaceModificationValueFormatter.compactNumber(value))")
        }
        return parts.joined(separator: ", ")
    }

    /// 深度优先的稳定节点顺序，保证差异列表按层级排列。
    static func orderedNodeIDs(in capture: ViewScopeCapturePayload) -> [String] {
        var result: [String] = []
        var visited = Set<String>()
        var stack = Array(capture.rootNodeIDs.reversed())
        while let nodeID = stack.popLast() {
            guard visited.insert(nodeID).inserted, let node = capture.nodes[nodeID] else {
                continue
            }
            result.append(nodeID)
            for childID in node.childIDs.reversed() {
                stack.append(childID)
            }
        }
        // 不在树上的游离节点追加到末尾
        for nodeID in capture.nodes.keys.sorted() where visited.contains(nodeID) == false {
            result.append(nodeID)
        }
        return result
    }

    /// 路径中使用的类名：带宿主视图的 layer 节点用视图类名，
    /// 这样视图在 `.view` 与 `.layer` 节点之间切换时路径保持一致。
    private static func pathClassName(of node: ViewScopeHierarchyNode) -> String {
        node.hostViewClassName ?? node.className
    }

    /// 每个节点的“类名 + 层级路径”，例如 `NSWindow[0]/NSView[0]/NSButton[1]`，
    /// 其中下标是同一父节点下同类兄弟的序号。
    static func structuralPaths(in capture: ViewScopeCapturePayload) -> [String: String] {
        var paths: [String: String] = [:]
        var rootCounters: [String: Int] = [:]
        var stack: [(nodeID: String, path: String)] = []
        for rootID in capture.rootNodeIDs {
            guard let node = capture.nodes[rootID] else {
                continue
            }
            let className = pathClassName(of: node)
            let index = rootCounters[className, default: 0]
            rootCounters[className] = index + 1
            stack.append((rootID, "\(className)[\(index)]"))
        }
        while let entry = stack.popLast() {
            let nodeID = entry.nodeID
            let path = entry.path
            guard paths[nodeID] == nil, let node = capture.nodes[nodeID] else {
                continue
            }
            paths[nodeID] = path
            var counters: [String: Int] = [:]
            for childID in node.childIDs {
                guard let child = capture.nodes[childID] else {
                    continue
                }
                let className = pathClassName(of: child)
                let index = counters[className, default: 0]
                counters[className] = index + 1
                stack.append((childID, "\(path)/\(className)[\(index)]"))
            }
        }
        return paths
    }
}
