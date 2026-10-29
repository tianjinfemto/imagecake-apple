import CoreGraphics
import XCTest
@testable import ImageCake

/// 液化。
///
/// 这组断言盯的是三件事：笔迹外必须**完全**不变（否则整张图被隐形重采样一遍）、
/// 中心必须沿拖动方向取到对侧的值（方向反了在真机上就是"越推越退"）、
/// 零位移必须恒等（否则滑一下没动也糊一层插值）。
final class LiquifyEngineTests: XCTestCase {
    private let size = PixelSize(width: 16, height: 16)

    /// 水平渐变：R = x / (w-1)。液化方向对不对，看中心取到的值变大还是变小。
    private func gradient() -> DisplayImage {
        var pixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let index = (y * size.width + x) * 4
                let value = Float(x) / Float(size.width - 1)
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    private func red(_ image: DisplayImage, x: Int, y: Int) -> Float {
        image.pixels[(y * size.width + x) * 4]
    }

    func testEmptyStrokesAreIdentity() {
        let image = gradient()
        XCTAssertEqual(LiquifyEngine.apply(image, strokes: []).pixels, image.pixels)
    }

    /// 笔迹半径之外的像素必须原样返回。这是「不隐形重采样整张图」的保证。
    func testPixelsOutsideRadiusAreUntouched() {
        let image = gradient()
        let stroke = LiquifyStroke(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.6, y: 0.5),
                                   radius: 0.2, strength: 1)
        let out = LiquifyEngine.apply(image, strokes: [stroke])
        XCTAssertEqual(red(out, x: 0, y: 0), red(image, x: 0, y: 0), accuracy: 1e-6)
        XCTAssertEqual(red(out, x: 15, y: 15), red(image, x: 15, y: 15), accuracy: 1e-6)
    }

    /// 向右推：中心像素从左边取色，渐变值应该变小。
    func testPushRightSamplesFromTheLeft() {
        let image = gradient()
        let stroke = LiquifyStroke(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.6, y: 0.5),
                                   radius: 0.3, strength: 1)
        let out = LiquifyEngine.apply(image, strokes: [stroke])
        XCTAssertLessThan(red(out, x: 8, y: 8), red(image, x: 8, y: 8),
                          "向右推却取到了右侧的值，方向反了")
    }

    /// 向左推则相反——两个方向都钉住，避免只测一边掩盖符号错误。
    func testPushLeftSamplesFromTheRight() {
        let image = gradient()
        let stroke = LiquifyStroke(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.4, y: 0.5),
                                   radius: 0.3, strength: 1)
        let out = LiquifyEngine.apply(image, strokes: [stroke])
        XCTAssertGreaterThan(red(out, x: 8, y: 8), red(image, x: 8, y: 8))
    }

    /// from == to 时没有位移，结果必须逐像素恒等——否则「按下去没拖」也会糊一层。
    func testZeroDisplacementIsIdentity() {
        let image = gradient()
        let stroke = LiquifyStroke(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.5, y: 0.5),
                                   radius: 0.3, strength: 1)
        XCTAssertEqual(LiquifyEngine.apply(image, strokes: [stroke]).pixels, image.pixels)
    }

    /// strength = 0 必须恒等：强度滑到底是「关」，不是「极小的推」。
    func testZeroStrengthIsIdentity() {
        let image = gradient()
        let stroke = LiquifyStroke(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.7, y: 0.5),
                                   radius: 0.3, strength: 0)
        XCTAssertEqual(LiquifyEngine.apply(image, strokes: [stroke]).pixels, image.pixels)
    }

    /// 垂直方向也别反：向下推，竖直渐变里的值应该变大。
    func testPushDownMovesVerticalGradient() {
        var pixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let index = (y * size.width + x) * 4
                let value = Float(y) / Float(size.height - 1)
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        let image = DisplayImage(size: size, pixels: pixels)
        let stroke = LiquifyStroke(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.5, y: 0.6),
                                   radius: 0.3, strength: 1)
        let out = LiquifyEngine.apply(image, strokes: [stroke])
        let center = (8 * size.width + 8) * 4
        XCTAssertLessThan(out.pixels[center], image.pixels[center],
                          "向下推却取到了下方的值，y 方向反了")
    }

    /// 多笔叠加不该崩，也不该把画布外的黑色拉进来（边界按 clamp）。
    func testMultipleStrokesStayInRange() {
        let image = gradient()
        let strokes = [
            LiquifyStroke(from: CGPoint(x: 0.3, y: 0.5), to: CGPoint(x: 0.5, y: 0.5), radius: 0.2, strength: 1),
            LiquifyStroke(from: CGPoint(x: 0.7, y: 0.5), to: CGPoint(x: 0.9, y: 0.5), radius: 0.2, strength: 1),
            LiquifyStroke(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: -0.2, y: -0.2), radius: 0.3, strength: 1)
        ]
        let out = LiquifyEngine.apply(image, strokes: strokes)
        XCTAssertEqual(out.pixels.count, image.pixels.count)
        for index in stride(from: 0, to: out.pixels.count, by: 4) {
            XCTAssertGreaterThanOrEqual(out.pixels[index], 0, "采到了画布外的值")
            XCTAssertLessThanOrEqual(out.pixels[index], 1, "采到了画布外的值")
        }
    }
}
