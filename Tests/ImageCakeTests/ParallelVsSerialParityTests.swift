import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 用 `PixelParallel.forcedBands` 让**同一份实现**分别走串行与并行两条分带，要求输出
/// 逐比特相同。这比在测试里手抄一份引擎更可靠：抄本会和真实代码漂移，最后变成两个
/// 都不对的东西互相证明。
///
/// 每条比较都先证明"算子真的动了"（输出必须不同于输入）。否则权重全为 0 时两边都
/// 短路、结果都是原图，比较就成了自我安慰 —— 这个坑本仓踩过（平坦夹具上的空断言）。
/// 尺寸也必须够大：小图走单线程分支，两边当然一样，但那没测到并行。
///
/// 覆盖范围 = 当前真正接了 `PixelParallel` 的内核。`BeautyEngine` 的三个 pass 一度
/// 也接上并被这条对照验证过，但整机渲染量不出收益（2367.6ms → 2411.7ms，+1.9%，在
/// 噪声内），已按"量不出收益就回退"撤掉；把它们再放回来时应该同时补回对应的用例，
/// 而不是留一条"串行对串行"的空断言在这里冒充覆盖。
final class ParallelVsSerialParityTests: XCTestCase {
    /// 必须同时满足 `pixelCount >= 4096` 与 `height >= 64`，否则并行分支根本没被走到。
    private let size = PixelSize(width: 131, height: 97)

    /// 带硬边缘 + 明暗不均 + 细碎噪声的图：降噪与高斯都会被真正触发。
    private func busyImage() -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        var state = UInt64(0x1234_ABCD_5678_9EF0)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let o = (y * size.width + x) * 4
                let patch: Float = ((x / 11) + (y / 9)) % 3 == 0 ? 0.10 : 0
                let edge: Float = ((x / 7) + (y / 5)) % 2 == 0 ? 0.18 : 0.72
                pixels[o] = Swift.min(Swift.max(edge - patch + Float((state >> 41) % 60) / 1000, 0), 1)
                pixels[o + 1] = Swift.min(Swift.max(edge * 0.7 - patch + Float((state >> 31) % 50) / 1000, 0), 1)
                pixels[o + 2] = Swift.min(Swift.max(1 - edge * 0.5 - patch + Float((state >> 21) % 40) / 1000, 0), 1)
                pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 先证明动过了，再要求并行与串行完全相等。
    private func assertSameBothWays(_ label: String, input: [Float], _ run: () -> [Float]) {
        PixelParallel.forcedBands = nil
        let parallel = run()
        XCTAssertNotEqual(parallel, input,
                          "\(label): 并行结果与输入完全相同 —— 算子被短路了，"
                              + "这条比较没有意义（夹具没有触发它）")
        PixelParallel.forcedBands = 1
        let serial = run()
        PixelParallel.forcedBands = nil
        XCTAssertEqual(serial.count, parallel.count, "\(label): 串行与并行的长度不同")
        var bad: [Int] = []
        for i in 0 ..< parallel.count where serial[i] != parallel[i] {
            if bad.count < 5 { bad.append(i) }
        }
        XCTAssertTrue(bad.isEmpty,
                      "\(label): \(bad.count)+ 个通道并行与串行不一致，前几个下标 \(bad)")
    }

    func testSpatialFiltersMatchSerial() {
        let image = busyImage()
        assertSameBothWays("denoise", input: image.pixels) {
            SpatialFilters.denoise(image, strength: 45).pixels
        }
        assertSameBothWays("sharpen", input: image.pixels) {
            SpatialFilters.sharpen(image, strength: 60).pixels
        }
    }

    func testForcedBandsHookActuallyChangesThePartitioning() {
        // 钩子本身也要被证明有效：默认分带必须 > 1，否则上面那条是在拿
        // "串行对串行"自证，看起来全绿却什么都没测。
        PixelParallel.forcedBands = 1
        XCTAssertEqual(PixelParallel.bands, 1, "forcedBands 没有生效")
        PixelParallel.forcedBands = nil
        XCTAssertGreaterThan(PixelParallel.bands, 1,
                             "这台机器只有 1 个可用核，并行分支无法被验证 —— 换 runner 再看这条")
    }
}
