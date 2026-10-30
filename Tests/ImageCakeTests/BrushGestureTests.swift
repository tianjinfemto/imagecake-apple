import CoreGraphics
import XCTest
@testable import ImageCake

/// 笔刷手势的采样逻辑。
///
/// 动机：DragGesture 每帧回调几十个点，全塞进 BrushStroke 会让栅格化
/// 在重合点上反复画圆。采样错了在真机上只表现为「笔刷手感怪」，
/// 必须离线钉住。
final class BrushGestureTests: XCTestCase {
    func testEmptyReturnsEmpty() {
        XCTAssertEqual(StrokeSampler.resample([], minSpacing: 0.01), [])
    }

    func testSinglePointPreserved() {
        let p = CGPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(StrokeSampler.resample([p], minSpacing: 0.01), [p])
    }

    /// 间距足够大的点全部保留。
    func testWidelySpacedPointsAllKept() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.1, y: 0),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 1, y: 1)
        ]
        XCTAssertEqual(StrokeSampler.resample(points, minSpacing: 0.01), points)
    }

    /// 密集的点被过滤，但首尾保留。
    func testDensePointsAreFiltered() {
        let points = (0...100).map { i in
            CGPoint(x: Double(i) / 1000, y: 0)
        }
        let sampled = StrokeSampler.resample(points, minSpacing: 0.05)
        XCTAssertEqual(sampled.first, points.first, "首点必须保留")
        XCTAssertEqual(sampled.last, points.last, "尾点必须保留")
        XCTAssertLessThan(sampled.count, points.count, "密集点应被过滤")
        XCTAssertGreaterThan(sampled.count, 1, "不能过滤到只剩首尾之外什么都没有")
    }

    /// 相邻点间距恰好等于 minSpacing 时保留。
    func testPointsAtExactSpacingKept() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.05, y: 0),
            CGPoint(x: 0.1, y: 0)
        ]
        XCTAssertEqual(StrokeSampler.resample(points, minSpacing: 0.05), points)
    }

    /// minSpacing = 0 时全部保留（退化为不过滤）。
    func testZeroSpacingKeepsAll() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.001, y: 0),
            CGPoint(x: 0.002, y: 0)
        ]
        XCTAssertEqual(StrokeSampler.resample(points, minSpacing: 0), points)
    }

    /// 负间距当作 0 处理，不崩。
    func testNegativeSpacingTreatedAsZero() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.1, y: 0)]
        XCTAssertEqual(StrokeSampler.resample(points, minSpacing: -1), points)
    }

    /// 尾点即使离上一个保留点很近也必须保留——它是用户抬手的位置。
    func testTailAlwaysKeptEvenIfClose() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0),
            CGPoint(x: 0.501, y: 0)
        ]
        let sampled = StrokeSampler.resample(points, minSpacing: 0.05)
        XCTAssertEqual(sampled.first, points.first)
        XCTAssertEqual(sampled.last, points.last)
    }
}