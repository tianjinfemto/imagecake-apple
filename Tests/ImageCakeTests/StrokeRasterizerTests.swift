import CoreGraphics
import XCTest
@testable import ImageCake

/// 笔迹栅格化。
///
/// 液化/图章/保护笔刷都建立在「一条笔迹 → 一张掩码」上。这层错了，
/// 上面几个工具的表现会是「笔刷拖不匀」「边缘毛毛的」，而在真机上
/// 很难判断是栅格化的问题还是渲染的问题。所以先把约定钉死。
final class StrokeRasterizerTests: XCTestCase {
    private let size = PixelSize(width: 64, height: 64)

    private func bytes(_ mask: MaskBuffer) -> [UInt8] {
        [UInt8](mask.data)
    }

    private func value(_ mask: MaskBuffer, x: Int, y: Int) -> UInt8 {
        bytes(mask)[y * size.width + x]
    }

    /// 单点、硬边：圆心满覆盖，远处为 0。
    func testSingleHardStampCoversItsRadius() {
        let stroke = BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.1, hardness: 1)
        let mask = StrokeRasterizer.mask(strokes: [stroke], size: size)

        XCTAssertEqual(value(mask, x: 32, y: 32), 255, "圆心应为满覆盖")
        XCTAssertEqual(value(mask, x: 0, y: 0), 0, "远处应为 0")
    }

    /// 两点之间的线段必须连通——插值步长如果大于直径就会出现断续的圆点。
    func testSegmentIsContinuous() {
        let stroke = BrushStroke(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)],
                                 radius: 0.05, hardness: 1)
        let mask = StrokeRasterizer.mask(strokes: [stroke], size: size)
        let row = bytes(mask)
        for x in 13 ... 51 {
            XCTAssertEqual(row[32 * size.width + x], 255, "x=\(x) 处断了")
        }
    }

    /// 软边应当有中间值；同一位置硬边直接是 255。
    func testSoftnessProducesGradient() {
        let size = self.size
        let soft = StrokeRasterizer.mask(
            strokes: [BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.1, hardness: 0.2)],
            size: size)
        let hard = StrokeRasterizer.mask(
            strokes: [BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.1, hardness: 1)],
            size: size)

        // 距圆心约 3.5px（半径 6.4）：软边落在过渡带里，硬边仍是满覆盖。
        let softEdge = value(soft, x: 35, y: 32)
        XCTAssertGreaterThan(softEdge, 40, "软边过渡带太窄，看不出软")
        XCTAssertLessThan(softEdge, 240, "软边过渡带太硬，等于没有")
        XCTAssertEqual(value(hard, x: 35, y: 32), 255)
    }

    /// 半径是归一化的（相对长边），所以半径翻倍时覆盖面积约变成 4 倍。
    /// 用 6.4px / 12.8px 两档：再小的话离散化误差会淹没面积比较。
    func testRadiusScalesAreaQuadratically() {
        func covered(radius: Double) -> Int {
            let mask = StrokeRasterizer.mask(
                strokes: [BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)],
                                      radius: radius, hardness: 1)],
                size: size)
            return bytes(mask).filter { $0 > 127 }.count
        }
        let small = covered(radius: 0.1)
        let large = covered(radius: 0.2)
        XCTAssertGreaterThan(small, 0)
        XCTAssertEqual(Double(large) / Double(small), 4, accuracy: 0.6,
                       "半径翻倍但面积没变成 4 倍，说明半径不是按长边归一化的")
    }

    /// 同一笔涂两次不该叠加成「两倍覆盖」：重复笔迹会让掩码提前饱和。
    func testOverlappingStrokesTakeMaxNotSum() {
        let stroke = BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.1, hardness: 0.5)
        let once = StrokeRasterizer.mask(strokes: [stroke], size: size)
        let twice = StrokeRasterizer.mask(strokes: [stroke, stroke], size: size)
        XCTAssertEqual(bytes(once), bytes(twice))
    }

    func testEmptyStrokesProduceEmptyMask() {
        let mask = StrokeRasterizer.mask(strokes: [], size: size)
        XCTAssertEqual(mask.data.count, size.pixelCount)
        XCTAssertTrue(bytes(mask).allSatisfy { $0 == 0 })
    }

    /// 笔迹拖出画布只应被裁掉，不能越界写内存。
    func testStrokesOutsideCanvasAreClipped() {
        let stroke = BrushStroke(points: [CGPoint(x: -0.5, y: -0.5), CGPoint(x: 1.5, y: 1.5)],
                                 radius: 0.2, hardness: 1)
        let mask = StrokeRasterizer.mask(strokes: [stroke], size: size)
        XCTAssertEqual(mask.data.count, size.pixelCount)
        // 对角线穿过画布中心，中心必然被覆盖。
        XCTAssertEqual(value(mask, x: 32, y: 32), 255)
    }

    /// 半径小到不足一个像素时直接跳过，而不是留下一个半透明点。
    func testTinyRadiusIsSkipped() {
        let stroke = BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.001, hardness: 1)
        let mask = StrokeRasterizer.mask(strokes: [stroke], size: PixelSize(width: 8, height: 8))
        XCTAssertTrue(bytes(mask).allSatisfy { $0 == 0 })
    }
}
