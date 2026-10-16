import CoreGraphics
import Testing
@testable import ViewScope

@Suite
@MainActor
struct MeasurementCalculatorTests {
    private let calculator = MeasurementCalculator(scale: 3)

    @Test func containmentReportsFourInnerDistances() {
        let result = calculator.measure(
            anchor: CGRect(x: 0, y: 0, width: 200, height: 100),
            target: CGRect(x: 20, y: 10, width: 100, height: 50)
        )
        #expect(result.relationship == .targetInsideAnchor)
        #expect(result.lines.map(\.value) == [20, 80, 10, 40])
        #expect(result.lines.filter { $0.axis == .horizontal }.count == 2)
        // 水平标注线画在内矩形的垂直中线上。
        #expect(result.lines.first?.start == CGPoint(x: 0, y: 35))
        #expect(result.lines.first?.end == CGPoint(x: 20, y: 35))
    }

    @Test func anchorInsideTargetIsAlsoContainment() {
        let result = calculator.measure(
            anchor: CGRect(x: 20, y: 10, width: 100, height: 50),
            target: CGRect(x: 0, y: 0, width: 200, height: 100)
        )
        #expect(result.relationship == .anchorInsideTarget)
        #expect(result.lines.count == 4)
    }

    @Test func flushEdgesAreSkipped() {
        let result = calculator.measure(
            anchor: CGRect(x: 0, y: 0, width: 200, height: 100),
            target: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(result.lines.map(\.value) == [100])
    }

    @Test func disjointHorizontalGapUsesVerticalOverlapMidpoint() {
        let result = calculator.measure(
            anchor: CGRect(x: 0, y: 0, width: 100, height: 100),
            target: CGRect(x: 130, y: 50, width: 50, height: 100)
        )
        #expect(result.relationship == .disjoint)
        #expect(result.lines.count == 1)
        let line = result.lines.first
        #expect(line?.axis == .horizontal)
        #expect(line?.value == 30)
        #expect(line?.start == CGPoint(x: 100, y: 75))
        #expect(line?.end == CGPoint(x: 130, y: 75))
    }

    @Test func diagonalDisjointRectsReportBothGaps() {
        let result = calculator.measure(
            anchor: CGRect(x: 100, y: 100, width: 50, height: 50),
            target: CGRect(x: 0, y: 0, width: 40, height: 60)
        )
        #expect(result.relationship == .disjoint)
        #expect(result.lines.map(\.axis) == [.horizontal, .vertical])
        #expect(result.lines.map(\.value) == [60, 40])
    }

    @Test func overlappingRectsReportEdgeOffsets() {
        let result = calculator.measure(
            anchor: CGRect(x: 0, y: 0, width: 100, height: 100),
            target: CGRect(x: 50, y: 20, width: 100, height: 100)
        )
        #expect(result.relationship == .overlapping)
        #expect(result.lines.map(\.value) == [50, 50, 20, 20])
    }

    @Test func identicalRectsHaveNoLines() {
        let rect = CGRect(x: 10, y: 10, width: 10, height: 10)
        let result = calculator.measure(anchor: rect, target: rect)
        #expect(result.relationship == .identical)
        #expect(result.lines.isEmpty)
    }

    @Test func labelsShowPixelsOnlyForFractionalPoints() {
        #expect(calculator.label(for: 12) == "12 pt")
        #expect(calculator.label(for: 12.5) == "12.5 pt · 37.5 px")
        #expect(MeasurementCalculator(scale: 2).label(for: 0.5) == "0.5 pt · 1 px")
        #expect(MeasurementCalculator.format(1.0 / 3.0) == "0.33")
    }
}
