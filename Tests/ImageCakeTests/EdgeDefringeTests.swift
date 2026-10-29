import XCTest
@testable import ImageCake

/// 边缘去色溢出。
///
/// 这组断言守的是「用实心邻居的颜色替换边缘色」这个语义：
/// 绿边必须被去掉、实心像素必须一点都不动、找不到实心邻居时必须保守。
/// 半径与强度系数是主观参数，改它是调品味，不该让断言红。
final class EdgeDefringeTests: XCTestCase {
    /// 中心 3×3 实心红、外圈半透明绿——「绿幕换底后边缘发绿」的最小复现。
    private func fringeFixture() -> (DisplayImage, MaskBuffer) {
        makeImage(width: 5, height: 5,
                  solid: { x, y in (1 ... 3).contains(x) && (1 ... 3).contains(y) })
    }

    private func makeImage(width: Int, height: Int,
                           solid: @escaping (Int, Int) -> Bool) -> (DisplayImage, MaskBuffer) {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let isSolid = solid(x, y)
                pixels[index] = isSolid ? 1 : 0     // 实心：红
                pixels[index + 1] = isSolid ? 0 : 1 // 边缘：绿（脏色）
                pixels[index + 2] = 0
                // alpha 通道留给 DisplayImage 自己，掩码单独一份
                bytes[y * width + x] = isSolid ? 255 : 128
            }
        }
        let image = DisplayImage(size: PixelSize(width: width, height: height), pixels: pixels)
        let mask = MaskBuffer(size: PixelSize(width: width, height: height), data: Data(bytes))
        return (image, mask)
    }

    /// 角上的边缘像素半径内只有实心红邻居，满强度下应该完全变成红。
    func testFringeIsReplacedBySolidColour() {
        let (image, mask) = fringeFixture()
        let out = EdgeDefringe.apply(image, alpha: mask, strength: 100)
        XCTAssertEqual(out.pixels[0], 1, accuracy: 0.01, "红通道没被实心红填满")
        XCTAssertEqual(out.pixels[1], 0, accuracy: 0.01, "绿边没被去掉")
        XCTAssertEqual(out.pixels[2], 0, accuracy: 0.01)
    }

    /// 实心像素不属于「边缘」，必须一点不动——否则整张主体会被轻微染色。
    func testSolidPixelsAreUntouched() {
        let (image, mask) = fringeFixture()
        let out = EdgeDefringe.apply(image, alpha: mask, strength: 100)
        let center = (2 * 5 + 2) * 4
        XCTAssertEqual(out.pixels[center], image.pixels[center], accuracy: 1e-6)
        XCTAssertEqual(out.pixels[center + 1], image.pixels[center + 1], accuracy: 1e-6)
    }

    /// 强度按比例混合：50 时应当是红绿各半。
    func testStrengthBlendsProportionally() {
        let (image, mask) = fringeFixture()
        let out = EdgeDefringe.apply(image, alpha: mask, strength: 50)
        XCTAssertEqual(out.pixels[0], 0.5, accuracy: 0.01)
        XCTAssertEqual(out.pixels[1], 0.5, accuracy: 0.01)
    }

    /// 强度 0 必须是恒等（直接返回原图，不做一次拷贝）。
    func testZeroStrengthIsIdentity() {
        let (image, mask) = fringeFixture()
        XCTAssertEqual(EdgeDefringe.apply(image, alpha: mask, strength: 0).pixels, image.pixels)
    }

    /// 找不到实心邻居（整张都是半透明）时保留原样：
    /// 猜一个颜色比留一点脏边更糟。
    func testWithoutSolidNeighbourKeepsOriginal() {
        var pixels = [Float](repeating: 1, count: 5 * 5 * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 0
            pixels[index + 1] = 1
            pixels[index + 2] = 0
        }
        let image = DisplayImage(size: PixelSize(width: 5, height: 5), pixels: pixels)
        let mask = MaskBuffer(size: PixelSize(width: 5, height: 5),
                              data: Data([UInt8](repeating: 128, count: 25)))
        let out = EdgeDefringe.apply(image, alpha: mask, strength: 100)
        for index in stride(from: 0, to: out.pixels.count, by: 4) {
            XCTAssertEqual(out.pixels[index], 0, accuracy: 1e-6, "没有实心邻居时不该动颜色")
            XCTAssertEqual(out.pixels[index + 1], 1, accuracy: 1e-6, "没有实心邻居时不该动颜色")
        }
    }

    /// 只改颜色，不碰 DisplayImage 的 alpha 通道。
    func testDisplayAlphaIsUntouched() {
        let (image, mask) = fringeFixture()
        let out = EdgeDefringe.apply(image, alpha: mask, strength: 100)
        for index in stride(from: 3, to: out.pixels.count, by: 4) {
            XCTAssertEqual(out.pixels[index], image.pixels[index], accuracy: 1e-6)
        }
    }
}
