import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// `SpatialFilters` 的降噪与锐化改成按行/按像素分带并行，主张是**逐比特不变**。
/// 这里放一份改动前的串行实现当参照物（原样照抄，只去掉分带），逐元素要求完全相等。
///
/// 尺寸必须**足够大**才能命中并行分支（`PixelParallel` 在小图上直接单线程走完，
/// 那是有意的：开线程的开销盖掉收益，而结果不受影响）。所以这里既测大图也测小图，
/// 保证两条分支都对。
final class SpatialParallelParityTests: XCTestCase {
    // MARK: 参照实现（改动前的串行版本，逐行照抄）

    private func referenceDenoise(_ image: DisplayImage, strength: Double) -> DisplayImage {
        let amount = Float(min(max(strength, 0), 100) / 100)
        guard amount > 0, image.size.pixelCount > 0 else { return image }
        let width = image.size.width
        let height = image.size.height
        let radius = 2
        let span = radius * 2 + 1
        let sigmaRange = amount * 0.25
        let sigmaRange2 = 2 * sigmaRange * sigmaRange
        let rangeLUT: [Float] = (0 ... 256).map { step in
            let distance2 = Float(step) / 256 * 3
            return expf(-distance2 / sigmaRange2)
        }
        let sigmaSpace = Float(radius) * 0.6
        let sigmaSpace2 = 2 * sigmaSpace * sigmaSpace
        var spatialWeights = [Float](repeating: 0, count: span * span)
        for dy in -radius ... radius {
            for dx in -radius ... radius {
                let distance2 = Float(dx * dx + dy * dy)
                spatialWeights[(dy + radius) * span + (dx + radius)] = expf(-distance2 / sigmaSpace2)
            }
        }
        let source = image.pixels
        var output = source
        for y in 0 ..< height {
            for x in 0 ..< width {
                let center = (y * width + x) * 4
                let cr = source[center]
                let cg = source[center + 1]
                let cb = source[center + 2]
                var sumR: Float = 0
                var sumG: Float = 0
                var sumB: Float = 0
                var sumWeight: Float = 0
                for dy in -radius ... radius {
                    let yy = min(max(y + dy, 0), height - 1)
                    for dx in -radius ... radius {
                        let xx = min(max(x + dx, 0), width - 1)
                        let neighbor = (yy * width + xx) * 4
                        let dr = source[neighbor] - cr
                        let dg = source[neighbor + 1] - cg
                        let db = source[neighbor + 2] - cb
                        let distance2 = dr * dr + dg * dg + db * db
                        let bucket = Int(min(distance2 / 3, 1) * 256)
                        let weight = spatialWeights[(dy + radius) * span + (dx + radius)] * rangeLUT[bucket]
                        sumR += source[neighbor] * weight
                        sumG += source[neighbor + 1] * weight
                        sumB += source[neighbor + 2] * weight
                        sumWeight += weight
                    }
                }
                if sumWeight > 1e-6 {
                    output[center] = sumR / sumWeight
                    output[center + 1] = sumG / sumWeight
                    output[center + 2] = sumB / sumWeight
                }
            }
        }
        return DisplayImage(size: image.size, pixels: output)
    }

    private func referenceSharpen(_ image: DisplayImage, strength: Double) -> DisplayImage {
        let amount = Float(min(max(strength, 0), 100) / 100) * 1.5
        guard amount > 0, image.size.pixelCount > 0 else { return image }
        let width = image.size.width
        let height = image.size.height
        let source = image.pixels
        var horizontal = source
        var blurred = source
        let kernel: [Float] = [0.25, 0.5, 0.25]
        for y in 0 ..< height {
            for x in 0 ..< width {
                for channel in 0 ..< 3 {
                    var value: Float = 0
                    for offset in -1 ... 1 {
                        let xx = min(max(x + offset, 0), width - 1)
                        value += source[(y * width + xx) * 4 + channel] * kernel[offset + 1]
                    }
                    horizontal[(y * width + x) * 4 + channel] = value
                }
            }
        }
        for y in 0 ..< height {
            for x in 0 ..< width {
                for channel in 0 ..< 3 {
                    var value: Float = 0
                    for offset in -1 ... 1 {
                        let yy = min(max(y + offset, 0), height - 1)
                        value += horizontal[(yy * width + x) * 4 + channel] * kernel[offset + 1]
                    }
                    blurred[(y * width + x) * 4 + channel] = value
                }
            }
        }
        var output = source
        for index in stride(from: 0, to: output.count, by: 4) {
            for channel in 0 ..< 3 {
                let base = output[index + channel]
                let difference = base - blurred[index + channel]
                output[index + channel] = min(max(base + amount * difference, 0), 1)
            }
        }
        return DisplayImage(size: image.size, pixels: output)
    }

    // MARK: 输入

    /// 带硬边缘 + 细密噪声的图：双边核与高斯核都会被真正触发（纯色会被短路掉）。
    private func image(_ size: PixelSize) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        var state = UInt64(0xDEADBEEFCAFEBABE)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let o = (y * size.width + x) * 4
                let edge = ((x / 9) + (y / 7)) % 2 == 0 ? 0.15 : 0.85
                let jitter = Float((state >> 35) % 100) / 1000
                pixels[o] = edge + jitter
                pixels[o + 1] = edge * 0.7 + jitter
                pixels[o + 2] = 1 - edge * 0.5 + jitter
                pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 第一、二个尺寸必须同时满足 `pixelCount >= 4096` 与 `height >= 64`，
    /// 否则并行分支根本没被跑到，这张测试就只是自我安慰。
    private let big = [PixelSize(width: 131, height: 97),
                       PixelSize(width: 200, height: 120),
                       PixelSize(width: 317, height: 64)]
    private let small = PixelSize(width: 32, height: 32)

    private func assertParallel(_ label: String, _ got: [Float], _ want: [Float]) {
        XCTAssertEqual(got.count, want.count, "\(label): 长度都变了")
        var bad: [Int] = []
        for i in 0 ..< want.count where got[i] != want[i] {
            if bad.count < 5 { bad.append(i) }
        }
        XCTAssertTrue(bad.isEmpty,
                      "\(label): \(bad.count)+ 个通道与串行参照不等，前几个下标 \(bad)")
    }

    func testDenoiseMatchesSerialReference() {
        for size in big {
            let input = image(size)
            for strength in [12.0, 40.0, 100.0] {
                assertParallel("denoise \(size.width)x\(size.height) s=\(strength)",
                               SpatialFilters.denoise(input, strength: strength).pixels,
                               referenceDenoise(input, strength: strength).pixels)
            }
        }
        let tiny = image(small)
        assertParallel("denoise small", SpatialFilters.denoise(tiny, strength: 40).pixels,
                       referenceDenoise(tiny, strength: 40).pixels)
    }

    func testSharpenMatchesSerialReference() {
        for size in big {
            let input = image(size)
            for strength in [20.0, 35.0, 90.0] {
                assertParallel("sharpen \(size.width)x\(size.height) s=\(strength)",
                               SpatialFilters.sharpen(input, strength: strength).pixels,
                               referenceSharpen(input, strength: strength).pixels)
            }
        }
        let tiny = image(small)
        assertParallel("sharpen small", SpatialFilters.sharpen(tiny, strength: 35).pixels,
                       referenceSharpen(tiny, strength: 35).pixels)
    }

    func testRepeatedRunsAreDeterministic() {
        let input = image(PixelSize(width: 257, height: 191))
        let denoised = SpatialFilters.denoise(input, strength: 45).pixels
        let sharpened = SpatialFilters.sharpen(input, strength: 60).pixels
        for _ in 0 ..< 4 {
            XCTAssertEqual(SpatialFilters.denoise(input, strength: 45).pixels, denoised,
                           "同一输入四次降噪结果不同：分带并行有竞态")
            XCTAssertEqual(SpatialFilters.sharpen(input, strength: 60).pixels, sharpened,
                           "同一输入四次锐化结果不同：分带并行有竞态")
        }
    }

    func testNeutralStrengthsReturnInputUnchanged() {
        // 并行化不能把"力度 0 就原样返回"这条短路弄丢（它同时是导出与预览的口径）。
        let input = image(PixelSize(width: 131, height: 97))
        XCTAssertEqual(SpatialFilters.denoise(input, strength: 0).pixels, input.pixels)
        XCTAssertEqual(SpatialFilters.sharpen(input, strength: 0).pixels, input.pixels)
    }
}
