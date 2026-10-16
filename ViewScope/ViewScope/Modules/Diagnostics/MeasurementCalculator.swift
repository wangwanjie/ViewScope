import CoreGraphics
import Foundation

/// 两个节点间距标注的纯计算（与界面无关，可单测）。
///
/// 输入两个统一画布坐标系（左上角原点，单位 pt）下的矩形：
/// - 包含：给出内矩形到外矩形四条边的距离；
/// - 相离：给出水平间隙与垂直间隙；
/// - 相交：给出对应边之间的偏移。
struct MeasurementCalculator {
    enum Relationship: Equatable {
        /// 目标在参照矩形内部。
        case targetInsideAnchor
        /// 参照矩形在目标内部。
        case anchorInsideTarget
        case disjoint
        case overlapping
        case identical
    }

    enum Axis: Equatable {
        case horizontal
        case vertical
    }

    /// 一条标注线：起止点（画布坐标）、长度与显示文本。
    struct Line: Equatable {
        let axis: Axis
        let start: CGPoint
        let end: CGPoint
        /// 长度（pt），始终为非负。
        let value: CGFloat
        let label: String
    }

    struct Result: Equatable {
        let relationship: Relationship
        let lines: [Line]
    }

    /// 宿主屏幕缩放比例，用于在非整数 pt 时附带像素值。
    var scale: CGFloat = 2
    /// 小于该值的距离不显示标注。
    var minimumVisibleDistance: CGFloat = 0.01

    func measure(anchor: CGRect, target: CGRect) -> Result {
        let anchor = anchor.standardized
        let target = target.standardized
        if approximatelyEqual(anchor, target) {
            return Result(relationship: .identical, lines: [])
        }
        if contains(anchor, target) {
            return Result(relationship: .targetInsideAnchor, lines: innerDistances(outer: anchor, inner: target))
        }
        if contains(target, anchor) {
            return Result(relationship: .anchorInsideTarget, lines: innerDistances(outer: target, inner: anchor))
        }
        if anchor.intersects(target) {
            return Result(relationship: .overlapping, lines: edgeOffsets(anchor: anchor, target: target))
        }
        return Result(relationship: .disjoint, lines: gaps(anchor: anchor, target: target))
    }

    /// 标注文本：整数 pt 只显示 pt；非整数 pt 额外附带按宿主缩放换算的像素值。
    func label(for value: CGFloat) -> String {
        let points = Self.format(value)
        if abs(value - value.rounded()) < 0.005 {
            return "\(points) pt"
        }
        return "\(points) pt · \(Self.format(value * scale)) px"
    }

    // MARK: - 包含：四条内边距

    private func innerDistances(outer: CGRect, inner: CGRect) -> [Line] {
        var lines: [Line] = []
        // 水平方向标注画在内矩形的垂直中线上，垂直方向标注画在水平中线上。
        let midY = inner.midY
        let midX = inner.midX
        appendLine(&lines, axis: .horizontal, from: CGPoint(x: outer.minX, y: midY), to: CGPoint(x: inner.minX, y: midY))
        appendLine(&lines, axis: .horizontal, from: CGPoint(x: inner.maxX, y: midY), to: CGPoint(x: outer.maxX, y: midY))
        appendLine(&lines, axis: .vertical, from: CGPoint(x: midX, y: outer.minY), to: CGPoint(x: midX, y: inner.minY))
        appendLine(&lines, axis: .vertical, from: CGPoint(x: midX, y: inner.maxY), to: CGPoint(x: midX, y: outer.maxY))
        return lines
    }

    // MARK: - 相离：水平 / 垂直间隙

    private func gaps(anchor: CGRect, target: CGRect) -> [Line] {
        var lines: [Line] = []

        // 水平间隙：两矩形在 x 方向不重叠时存在。标注线放在两者 y 方向重叠区间的中点；
        // 没有重叠时放在参照矩形的中线上。
        if target.minX >= anchor.maxX || anchor.minX >= target.maxX {
            let y = overlapMidpoint(anchor.minY, anchor.maxY, target.minY, target.maxY) ?? anchor.midY
            if target.minX >= anchor.maxX {
                appendLine(&lines, axis: .horizontal, from: CGPoint(x: anchor.maxX, y: y), to: CGPoint(x: target.minX, y: y))
            } else {
                appendLine(&lines, axis: .horizontal, from: CGPoint(x: target.maxX, y: y), to: CGPoint(x: anchor.minX, y: y))
            }
        }

        if target.minY >= anchor.maxY || anchor.minY >= target.maxY {
            let x = overlapMidpoint(anchor.minX, anchor.maxX, target.minX, target.maxX) ?? anchor.midX
            if target.minY >= anchor.maxY {
                appendLine(&lines, axis: .vertical, from: CGPoint(x: x, y: anchor.maxY), to: CGPoint(x: x, y: target.minY))
            } else {
                appendLine(&lines, axis: .vertical, from: CGPoint(x: x, y: target.maxY), to: CGPoint(x: x, y: anchor.minY))
            }
        }
        return lines
    }

    // MARK: - 相交：对应边偏移

    private func edgeOffsets(anchor: CGRect, target: CGRect) -> [Line] {
        var lines: [Line] = []
        let intersection = anchor.intersection(target)
        let midY = intersection.midY
        let midX = intersection.midX
        appendLine(&lines, axis: .horizontal, from: CGPoint(x: min(anchor.minX, target.minX), y: midY), to: CGPoint(x: max(anchor.minX, target.minX), y: midY))
        appendLine(&lines, axis: .horizontal, from: CGPoint(x: min(anchor.maxX, target.maxX), y: midY), to: CGPoint(x: max(anchor.maxX, target.maxX), y: midY))
        appendLine(&lines, axis: .vertical, from: CGPoint(x: midX, y: min(anchor.minY, target.minY)), to: CGPoint(x: midX, y: max(anchor.minY, target.minY)))
        appendLine(&lines, axis: .vertical, from: CGPoint(x: midX, y: min(anchor.maxY, target.maxY)), to: CGPoint(x: midX, y: max(anchor.maxY, target.maxY)))
        return lines
    }

    // MARK: - 工具

    private func appendLine(_ lines: inout [Line], axis: Axis, from start: CGPoint, to end: CGPoint) {
        let value = axis == .horizontal ? abs(end.x - start.x) : abs(end.y - start.y)
        guard value >= minimumVisibleDistance else {
            return
        }
        lines.append(Line(axis: axis, start: start, end: end, value: value, label: label(for: value)))
    }

    private func overlapMidpoint(_ minA: CGFloat, _ maxA: CGFloat, _ minB: CGFloat, _ maxB: CGFloat) -> CGFloat? {
        let lower = max(minA, minB)
        let upper = min(maxA, maxB)
        guard upper >= lower else {
            return nil
        }
        return (lower + upper) / 2
    }

    private func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        let tolerance: CGFloat = 0.001
        return inner.minX >= outer.minX - tolerance &&
            inner.minY >= outer.minY - tolerance &&
            inner.maxX <= outer.maxX + tolerance &&
            inner.maxY <= outer.maxY + tolerance
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.001 &&
            abs(lhs.minY - rhs.minY) < 0.001 &&
            abs(lhs.width - rhs.width) < 0.001 &&
            abs(lhs.height - rhs.height) < 0.001
    }

    /// 最多保留两位小数并去掉末尾的 0。
    static func format(_ value: CGFloat) -> String {
        LayoutDiagnosticsAnalyzer.formatNumber(value)
    }
}
