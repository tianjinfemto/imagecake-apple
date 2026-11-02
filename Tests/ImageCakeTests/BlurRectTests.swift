import CoreGraphics
import XCTest

@testable import ImageCake

/// 模糊限定矩形（bbox 化）的正确性前提：**矩形内的值必须与全幅版本逐比特相同**。
///
/// 这条为什么是硬的而不是"差不多就行"：衣物祛褶、颈纹、头发、手部、区域美化
/// 全都把模糊结果当成"该区域的低频/局部均值"，一旦矩形边缘的值偏一点，
/// 症状就是选区边缘出现一圈看不见的处理差（缝），而那正是这批优化要消除的东西。
/// 实现上靠的是"跳过整行/整列，但行列内的递推仍从 0 起步"，
/// 因此算术序列不变；三遍链式则靠每遍多算一圈半径。
final class BlurRectTests: XCTestCase {
    private func noisy(_ size: PixelSize) -> [Float] {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        var state = UInt64(20261102)
        for i in 0 ..< size.pixelCount {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let v = Float((state >> 40) % 1000) / 1000
            // 让画面既有大块变化又有细碎抖动，两种模糊都能被触发。
            let block = Float((i / size.width) / 9 % 3) * 0.2
            let o = i * 4
            pixels[o] = v * 0.5 + block
            pixels[o + 1] = v * 0.6 + 0.2
            pixels[o + 2] = 1 - v * 0.4
            pixels[o + 3] = 1
        }
        return pixels
    }

    func testBoundingRectIsEmptyOnlyWhenWeightsAreEmpty() {
        let size = PixelSize(width: 20, height: 20)
        var weights = [Float](repeating: 0, count: size.pixelCount)
        XCTAssertNil(MaskOps.boundingRect(weights, size: size), "全零要返回 nil，而不是 .zero")
        weights[4 * size.width + 3] = 0.5
        weights[9 * size.width + 12] = 0.25
        let box = MaskOps.boundingRect(weights, size: size)
        XCTAssertEqual(box?.x, 3); XCTAssertEqual(box?.y, 4)
        XCTAssertEqual(box?.width, 10); XCTAssertEqual(box?.height, 6)
        let padded = MaskOps.boundingRect(weights, size: size, padding: 5)
        XCTAssertEqual(padded?.x, 0, "外扩要夹在画布内，不能出负坐标")
        XCTAssertEqual(padded?.y, 0)
        XCTAssertEqual(padded?.maxX, 18)
        XCTAssertEqual(padded?.maxY, size.height, "下边被画布夹住")
    }

    func testRectLimitedBlurIsBitIdenticalInsideRect() {
        let size = PixelSize(width: 48, height: 40)
        let pixels = noisy(size)
        for radius in [1, 3, 7] {
            let rect = PixelRect(x: 8, y: 6, width: 22, height: 18)
            let full = ImageDocument.blurred(pixels, size: size, radius: radius)
            let limited = ImageDocument.blurred(pixels, size: size, radius: radius, in: rect)
            var mismatched: [Int] = []
            for y in rect.y ..< rect.maxY {
                for x in rect.x ..< rect.maxX {
                    let o = (y * size.width + x) * 4
                    for c in 0 ..< 4 where full[o + c] != limited[o + c] {
                        mismatched.append(o + c)
                    }
                }
            }
            XCTAssertTrue(mismatched.isEmpty,
                          "半径 \(radius) 下矩形内出现 \(mismatched.count) 个不等的通道：矩形限定改变了结果")
            // 矩形外确实没算（留 0），这是"跳过整行整列"的证据；读它的代码必须在门外先过权重门。
            XCTAssertTrue(limited.indices.filter { $0 % 4 != 3 }.contains { limited[$0] == 0 },
                          "矩形外应当没写值")
        }
    }

    func testRectLimitedChannelBlurMatchesForEveryRadiusChain() {
        let size = PixelSize(width: 40, height: 40)
        let luma = (0 ..< size.pixelCount).map { Float(($0 * 37) % 100) / 100 }
        let rect = PixelRect(x: 12, y: 9, width: 15, height: 12)
        for radius in [2, 5, 11] {
            let full = BeautyEngine.blurredChannel(luma, size: size, radius: radius)
            let limited = BeautyEngine.blurredChannel(luma, size: size, radius: radius, in: rect)
            for i in 0 ..< size.pixelCount {
                let x = i % size.width, y = i / size.width
                guard x >= rect.x, x < rect.maxX, y >= rect.y, y < rect.maxY else { continue }
                XCTAssertEqual(limited[i], full[i], accuracy: 0,
                               "半径 \(radius) 三遍链的第 2、3 遍没多算一圈，矩形内值就会偏")
            }
        }
    }

    func testFullCoverageWeightsGiveSameResultAsNoRect() {
        // 选区铺满全图时，矩形路径必须与旧路径完全一致（这就是"不改变交付结果"的证据）。
        let size = PixelSize(width: 32, height: 32)
        let pixels = noisy(size)
        let weights = [Float](repeating: 1, count: size.pixelCount)
        let rect = MaskOps.boundingRect(weights, size: size, padding: 5)
        let plain = ImageDocument.blurred(pixels, size: size, radius: 4)
        let boxed = ImageDocument.blurred(pixels, size: size, radius: 4, in: rect)
        XCTAssertEqual(plain, boxed)
    }

    func testGarmentAndThinLineStillMatchTheirOwnSelectionGeometry() {
        let size = PixelSize(width: 40, height: 40)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                let v: Float = (3 ... 9).contains(y) && (5 ... 20).contains(x) ? 0.34 : 0.62
                pixels[o] = v; pixels[o + 1] = v; pixels[o + 2] = v; pixels[o + 3] = 1
            }
        }
        // 只在左半有一条暗带：选区在右半时，输出必须逐比特等于原图。
        var right = [Float](repeating: 0, count: size.pixelCount)
        for y in 0 ..< size.height {
            for x in 25 ..< size.width { right[y * size.width + x] = 1 }
        }
        var garment = GarmentParameters()
        garment.deWrinkle = 100
        let out = GarmentEngine.apply(DisplayImage(size: size, pixels: pixels),
                                      weights: right, garment: garment)
        XCTAssertEqual(out.pixels, pixels,
                       "选区里没有暗带结构时，限定矩形不该带来任何额外改动")

        var lines = BodyLineParameters()
        lines.deLine = 100
        let lineOut = LineEngine.apply(DisplayImage(size: size, pixels: pixels),
                                       weights: right, lines: lines)
        XCTAssertEqual(lineOut.pixels, pixels, "颈纹那一路同理")
    }
}
