import CoreGraphics

/// 画布矩形的均匀网格索引。
///
/// 用于把“找出与某个矩形相交的所有矩形”从 O(n) 线性扫描降到接近 O(k)：
/// - 每个矩形登记到它覆盖的网格单元；
/// - 覆盖单元过多的超大矩形（例如根视图）单独放进 `oversizedIDs`，每次查询都直接返回，避免一次插入展开成上千个单元。
struct CanvasSpatialIndex {
    private let cellSize: CGFloat
    private let maximumCellsPerRect = 256
    private var buckets: [Int64: [Int]] = [:]
    private var oversizedIDs: [Int] = []
    private(set) var rects: [CGRect] = []

    /// - Parameters:
    ///   - bounds: 预期的画布范围，用于推算单元尺寸。
    ///   - expectedCount: 预期矩形数量。
    init(bounds: CGRect, expectedCount: Int) {
        let extent = max(bounds.width, bounds.height, 1)
        let divisions = max(8, min(256, Int(Double(max(expectedCount, 1)).squareRoot().rounded(.up))))
        cellSize = max(extent / CGFloat(divisions), 8)
        rects.reserveCapacity(expectedCount)
    }

    /// 登记一个矩形，返回它的索引（按插入顺序递增）。
    @discardableResult
    mutating func insert(_ rect: CGRect) -> Int {
        let identifier = rects.count
        rects.append(rect)
        guard let range = cellRange(for: rect) else {
            return identifier
        }
        let cellCount = (range.maxX - range.minX + 1) * (range.maxY - range.minY + 1)
        if cellCount > maximumCellsPerRect {
            oversizedIDs.append(identifier)
            return identifier
        }
        for cellX in range.minX...range.maxX {
            for cellY in range.minY...range.maxY {
                buckets[key(cellX, cellY), default: []].append(identifier)
            }
        }
        return identifier
    }

    /// 返回可能与 `rect` 相交的矩形索引（已去重、升序，调用方需要再做精确判断）。
    func candidateIDs(intersecting rect: CGRect) -> [Int] {
        var result = oversizedIDs
        if let range = cellRange(for: rect) {
            for cellX in range.minX...range.maxX {
                for cellY in range.minY...range.maxY {
                    if let identifiers = buckets[key(cellX, cellY)] {
                        result.append(contentsOf: identifiers)
                    }
                }
            }
        }
        guard result.count > 1 else {
            return result
        }
        result.sort()
        var deduplicated: [Int] = []
        deduplicated.reserveCapacity(result.count)
        for identifier in result where deduplicated.last != identifier {
            deduplicated.append(identifier)
        }
        return deduplicated
    }

    private func cellRange(for rect: CGRect) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        guard rect.isNull == false,
              rect.minX.isFinite,
              rect.minY.isFinite,
              rect.maxX.isFinite,
              rect.maxY.isFinite else {
            return nil
        }
        // 把单元坐标限制在合理范围内，避免异常大的坐标导致整数溢出。
        let limit: CGFloat = 1_000_000
        let minX = Int((max(min(rect.minX, limit), -limit) / cellSize).rounded(.down))
        let minY = Int((max(min(rect.minY, limit), -limit) / cellSize).rounded(.down))
        let maxX = Int((max(min(rect.maxX, limit), -limit) / cellSize).rounded(.down))
        let maxY = Int((max(min(rect.maxY, limit), -limit) / cellSize).rounded(.down))
        return (minX, minY, max(minX, maxX), max(minY, maxY))
    }

    private func key(_ cellX: Int, _ cellY: Int) -> Int64 {
        (Int64(cellX) << 32) ^ Int64(UInt32(truncatingIfNeeded: cellY))
    }
}
