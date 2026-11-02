import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 生产代码里的模糊改成了"缓冲复用 + 按行/按列并行"，主张是**逐比特不变**。
/// 主张不能靠自信：这里放一份改动前的串行实现（原样照抄，不"合理近似"），
/// 然后逐元素要求完全相等。
///
/// 这条断言的存在理由就是上一轮的教训：那次把模糊裁到选区矩形，看着也是"只跳过
/// 不改变算术"，实际滑窗累加器带着历史滑进选区，整片结果错 —— 由它自己的逐比特
/// 断言判红（见 docs/pixcake-parity.md §7）。所以这里守的是同一件事，只是这次
/// 分区方式确实不改变任何一条行/列内的递推。
final class BlurParityTests: XCTestCase {
    // MARK: 参照实现（改动前的串行版本）

    private func serialBoxBlur1(_ src: [Float], width w: Int, height h: Int, radius: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        let window = Float(radius * 2 + 1)
        for y in 0 ..< h {
            var sum: Float = 0
            for x in -radius ... radius {
                sum += src[y * w + min(max(x, 0), w - 1)]
            }
            for x in 0 ..< w {
                tmp[y * w + x] = sum / window
                sum -= src[y * w + min(max(x - radius, 0), w - 1)]
                sum += src[y * w + min(max(x + radius + 1, 0), w - 1)]
            }
        }
        for x in 0 ..< w {
            var sum: Float = 0
            for y in -radius ... radius {
                sum += tmp[min(max(y, 0), h - 1) * w + x]
            }
            for y in 0 ..< h {
                out[y * w + x] = sum / window
                sum -= tmp[min(max(y - radius, 0), h - 1) * w + x]
                sum += tmp[min(max(y + radius + 1, 0), h - 1) * w + x]
            }
        }
        return out
    }

    private func serialBoxBlurRGBA(_ src: [Float], width w: Int, height h: Int, radius: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        let window = Float(radius * 2 + 1)
        for y in 0 ..< h {
            for c in 0 ..< 4 {
                var sum: Float = 0
                for x in -radius ... radius {
                    sum += src[(y * w + min(max(x, 0), w - 1)) * 4 + c]
                }
                for x in 0 ..< w {
                    tmp[(y * w + x) * 4 + c] = sum / window
                    sum -= src[(y * w + min(max(x - radius, 0), w - 1)) * 4 + c]
                    sum += src[(y * w + min(max(x + radius + 1, 0), w - 1)) * 4 + c]
                }
            }
        }
        for x in 0 ..< w {
            for c in 0 ..< 4 {
                var sum: Float = 0
                for y in -radius ... radius {
                    sum += tmp[(min(max(y, 0), h - 1) * w + x) * 4 + c]
                }
                for y in 0 ..< h {
                    out[(y * w + x) * 4 + c] = sum / window
                    sum -= tmp[(min(max(y - radius, 0), h - 1) * w + x) * 4 + c]
                    sum += tmp[(min(max(y + radius + 1, 0), h - 1) * w + x) * 4 + c]
                }
            }
        }
        return out
    }

    /// 参照实现要走三遍链，与生产入口一样；只抄一遍是不够的。
    private func serialChannel3(_ v: [Float], _ s: PixelSize, _ r: Int) -> [Float] {
        var b = v
        for _ in 0 ..< 3 { b = serialBoxBlur1(b, width: s.width, height: s.height, radius: r) }
        return b
    }

    private func serialRGBA3(_ p: [Float], _ s: PixelSize, _ r: Int) -> [Float] {
        var b = p
        for _ in 0 ..< 3 { b = serialBoxBlurRGBA(b, width: s.width, height: s.height, radius: r) }
        return b
    }

    private func gradient(_ size: PixelSize) -> [Float] {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        var state = UInt64(0x9E3779B97F4A7C15)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let o = (y * size.width + x) * 4
                pixels[o] = Float((state >> 33) % 1000) / 1000
                pixels[o + 1] = Float(x) / Float(max(size.width - 1, 1))
                pixels[o + 2] = Float(y) / Float(max(size.height - 1, 1))
                pixels[o + 3] = 1
            }
        }
        return pixels
    }

    // 尺寸刻意取**非方形且互质**：分带边界与行/列数不整除时最容易出现漏写或重复写。
    private let sizes = [PixelSize(width: 41, height: 37),
                         PixelSize(width: 64, height: 33),
                         PixelSize(width: 33, height: 64),
                         PixelSize(width: 97, height: 71)]
    private let radii = [1, 2, 5, 11, 30]

    func testChannelBlurMatchesSerialReferenceBitForBit() {
        for size in sizes {
            let values = (0 ..< size.pixelCount).map { Float(($0 * 37) % 100) / 100 }
            for radius in radii where radius < max(size.width, size.height) * 2 {
                let got = BeautyEngine.blurredChannel(values, size: size, radius: radius)
                let want = serialChannel3(values, size, radius)
                XCTAssertEqual(got.count, want.count)
                var bad: [Int] = []
                for i in 0 ..< want.count where got[i] != want[i] {
                    if bad.count < 5 { bad.append(i) }
                }
                XCTAssertTrue(bad.isEmpty,
                              "blurredChannel \(size.width)x\(size.height) r=\(radius): "
                                  + "\(bad.count)+ 个通道与串行参照不等，前几个下标 \(bad)")
            }
        }
    }

    func testRGBABlurMatchesSerialReferenceBitForBit() {
        for size in sizes {
            let pixels = gradient(size)
            for radius in radii where radius < max(size.width, size.height) * 2 {
                let got = ImageDocument.blurred(pixels, size: size, radius: radius)
                let want = serialRGBA3(pixels, size, radius)
                XCTAssertEqual(got.count, want.count)
                var bad: [Int] = []
                for i in 0 ..< want.count where got[i] != want[i] {
                    if bad.count < 5 { bad.append(i) }
                }
                XCTAssertTrue(bad.isEmpty,
                              "blurred \(size.width)x\(size.height) r=\(radius): "
                                  + "\(bad.count)+ 个通道与串行参照不等，前几个下标 \(bad)")
            }
        }
    }

    func testRepeatedRunsAreDeterministic() {
        // 并行化最容易留下的不是错值，而是"每次略有不同"。这条把它钉住。
        let size = PixelSize(width: 129, height: 97)
        let pixels = gradient(size)
        let first = ImageDocument.blurred(pixels, size: size, radius: 7)
        for _ in 0 ..< 4 {
            XCTAssertEqual(ImageDocument.blurred(pixels, size: size, radius: 7), first,
                           "同一输入四次结果不同：并行分带有竞态")
        }
        let channel = (0 ..< size.pixelCount).map { Float(($0 * 7919) % 1000) / 1000 }
        let firstChannel = BeautyEngine.blurredChannel(channel, size: size, radius: 9)
        for _ in 0 ..< 4 {
            XCTAssertEqual(BeautyEngine.blurredChannel(channel, size: size, radius: 9), firstChannel)
        }
    }

    func testGuardPathsReturnInputUnchanged() {
        // 新加的像素数守卫不能把正常输入变成"原样返回"，也不能让边界输入走飞。
        let size = PixelSize(width: 8, height: 6)
        let pixels = gradient(size)
        XCTAssertEqual(ImageDocument.blurred(pixels, size: size, radius: 0), pixels,
                       "radius 0 应当原样返回（与改动前一致）")
        let short = Array(pixels.dropLast(4))
        XCTAssertEqual(ImageDocument.blurred(short, size: size, radius: 3), short,
                       "长度与画布不符时原样返回，不能越界读写")
        let values = (0 ..< size.pixelCount).map { Float($0 % 7) / 7 }
        XCTAssertEqual(BeautyEngine.blurredChannel(values, size: size, radius: 0), values)
        XCTAssertEqual(BeautyEngine.blurredChannel(Array(values.dropLast(2)), size: size, radius: 3),
                       Array(values.dropLast(2)))

        // 缓冲比画布大时也必须照常计算，并且**返回长度按画布**：按入参长度分配
        // 会把未初始化的尾部当成浮点返回，那是不只错一位的错。
        var padded = pixels
        padded.append(contentsOf: [Float](repeating: 0.5, count: 8))
        XCTAssertEqual(ImageDocument.blurred(padded, size: size, radius: 3),
                       ImageDocument.blurred(pixels, size: size, radius: 3),
                       "偏大缓冲得到了不同结果，或返回长度跟着入参走了")
    }
}
