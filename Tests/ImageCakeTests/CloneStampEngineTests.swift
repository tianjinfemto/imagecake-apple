import CoreGraphics
import XCTest
@testable import ImageCake

/// 仿制图章。
///
/// 这组断言盯的是三件容易错的事：取样位置对不对（锚点偏移的符号）、
/// 掩码外是否真的一个字节都没动、以及源会不会被自己上一笔污染。
final class CloneStampEngineTests: XCTestCase {
    private let size = PixelSize(width: 16, height: 16)

    /// 左半黑、右半白：取样对不对，看目标位置有没有变白。
    private func halfSplit() -> DisplayImage {
        var pixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let index = (y * size.width + x) * 4
                let value: Float = x >= 8 ? 1 : 0
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

    private func stamp(source: CGPoint = CGPoint(x: 0.75, y: 0.5),
                       points: [CGPoint] = [CGPoint(x: 0.25, y: 0.5)],
                       radius: Double = 0.2,
                       strength: Double = 1,
                       hardness: Double = 1) -> CloneStamp {
        CloneStamp(source: source, points: points, radius: radius,
                   strength: strength, hardness: hardness)
    }

    /// 从右半取样、画到左半：目标位置应当变白。
    /// 这条同时钉住了锚点偏移的符号——反了就会取到左边自己的黑色。
    func testCopiesFromSourceAnchor() {
        let image = halfSplit()
        let out = CloneStampEngine.apply(image, stamps: [stamp()])
        XCTAssertGreaterThan(red(out, x: 4, y: 8), 0.9, "取样内容没被搬过来")
    }

    /// 掩码外必须逐像素不动——图章最容易出的问题是「顺手糊了一圈」。
    func testPixelsOutsideMaskAreUntouched() {
        let image = halfSplit()
        let out = CloneStampEngine.apply(image, stamps: [stamp()])
        XCTAssertEqual(red(out, x: 0, y: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(red(out, x: 0, y: 8), 0, accuracy: 1e-6, "距笔迹中心 4px，半径只有 3.2px")
        XCTAssertEqual(red(out, x: 15, y: 15), 1, accuracy: 1e-6)
    }

    /// 强度 0.5 应当得到源与目标的中间值，而不是全量覆盖。
    func testPartialStrengthBlends() {
        let image = halfSplit()
        let out = CloneStampEngine.apply(image, stamps: [stamp(strength: 0.5)])
        XCTAssertEqual(red(out, x: 4, y: 8), 0.5, accuracy: 0.05)
    }

    func testZeroStrengthIsIdentity() {
        let image = halfSplit()
        XCTAssertEqual(CloneStampEngine.apply(image, stamps: [stamp(strength: 0)]).pixels, image.pixels)
    }

    func testEmptyStampsAreIdentity() {
        let image = halfSplit()
        XCTAssertEqual(CloneStampEngine.apply(image, stamps: []).pixels, image.pixels)
    }

    /// 源取自输入而不是上一笔的输出：同一处涂两次的结果必须与涂一次相同。
    /// 否则来回涂会把已经涂过的内容当成源，图章「自己吃自己」。
    func testSourceIsNotPollutedByPreviousStamp() {
        let image = halfSplit()
        let once = CloneStampEngine.apply(image, stamps: [stamp()])
        let twice = CloneStampEngine.apply(image, stamps: [stamp(), stamp()])
        XCTAssertEqual(once.pixels, twice.pixels)
    }

    /// 取样点跟着笔迹走：横拖一条线，整条都该被填上源颜色。
    func testSamplingFollowsTheStroke() {
        let image = halfSplit()
        let dragging = stamp(points: [CGPoint(x: 0.125, y: 0.5), CGPoint(x: 0.375, y: 0.5)],
                             radius: 0.1)
        let out = CloneStampEngine.apply(image, stamps: [dragging])
        for x in 3 ... 5 {
            XCTAssertGreaterThan(red(out, x: x, y: 8), 0.9, "x=\(x) 处没被填上")
        }
    }

    /// 保护笔刷：掩码 255 的区域必须一个字节都不动。
    func testFullProtectionBlocksTheStamp() {
        let image = halfSplit()
        let protected = MaskBuffer.filled(size, value: 255)
        let out = CloneStampEngine.apply(image, stamps: [stamp()], protection: protected)
        XCTAssertEqual(out.pixels, image.pixels)
    }

    /// 掩码全 0 应当等价于没传保护——否则「用了保护笔刷但没涂」也会失效。
    func testZeroProtectionBehavesLikeNone() {
        let image = halfSplit()
        let unprotected = MaskBuffer.filled(size, value: 0)
        let withZero = CloneStampEngine.apply(image, stamps: [stamp()], protection: unprotected)
        let without = CloneStampEngine.apply(image, stamps: [stamp()])
        XCTAssertEqual(withZero.pixels, without.pixels)
    }
}
