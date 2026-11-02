import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 用 `PixelParallel.forcedBands` 让**同一份实现**分别走串行与并行两条分带，要求输出
/// 逐比特相同。这比在测试里手抄一份引擎更可靠：抄本会和真实代码漂移，最后变成两个
/// 都不对的东西在互相证明。
///
/// 每条比较都先证明"算子真的动了"（输出必须不同于输入）。否则掩码或权重全为 0 时
/// 两边都短路、结果都是原图，比较就成了自我安慰 —— 这个坑本仓踩过（平坦夹具上的
/// 空断言）。尺寸也必须够大：小图走单线程分支，两边当然一样，但那没测到并行。
final class ParallelVsSerialParityTests: XCTestCase {
    /// 必须同时满足 `pixelCount >= 4096` 与 `height >= 64`，否则并行分支根本没被走到。
    private let size = PixelSize(width: 131, height: 97)

    /// 肤色基调 + 明暗不均 + 细碎噪声：让磨皮、祛瑕疵、匀肤色、祛红、祛油光、美白
    /// 都有活干（纯色或平坦图会被各自的阈值判据全部拒掉）。
    private func skinImage() -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        var state = UInt64(0x1234_ABCD_5678_9EF0)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let o = (y * size.width + x) * 4
                let patch: Float = ((x / 11) + (y / 9)) % 3 == 0 ? 0.10 : 0
                let jitterR = Float((state >> 41) % 60) / 1000
                let jitterG = Float((state >> 31) % 50) / 1000
                let jitterB = Float((state >> 21) % 40) / 1000
                pixels[o] = Swift.min(Swift.max(0.74 - patch + jitterR, 0), 1)
                pixels[o + 1] = Swift.min(Swift.max(0.55 - patch * 0.8 + jitterG, 0), 1)
                pixels[o + 2] = Swift.min(Swift.max(0.45 - patch * 0.6 + jitterB, 0), 1)
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
                              + "这条比较没有意义（夹具没有让权重成立）")
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

    func testBeautyEngineMatchesSerial() {
        let image = skinImage()
        let full = MaskBuffer.filled(size, value: 255)
        let layers = SkinMask.build(image, personMask: full,
                                    faceBoxes: [CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)])
        // 夹具自检：皮肤掩码必须真的命中，否则下面比的是两次"什么都没做"。
        let faceWeights = SkinMask.weights(layers.face, size: size)
        let bodyWeights = SkinMask.weights(layers.body, size: size)
        XCTAssertGreaterThan(faceWeights.filter { $0 > 0 }.count, 0, "夹具没能让脸部的皮肤掩码命中")
        XCTAssertGreaterThan(bodyWeights.filter { $0 > 0 }.count, 0, "夹具没能让身体的皮肤掩码命中")

        var beauty = BeautyParameters()
        beauty.skinSmooth = 60
        beauty.bodySmooth = 40
        beauty.blemish = 55
        beauty.toneUnify = 45
        beauty.redness = 35
        beauty.deShine = 30
        beauty.whitening = 40
        assertSameBothWays("BeautyEngine.apply", input: image.pixels) {
            BeautyEngine.apply(image, skin: layers, beauty: beauty).pixels
        }
    }

    func testSpatialFiltersMatchSerial() {
        let image = skinImage()
        assertSameBothWays("denoise", input: image.pixels) {
            SpatialFilters.denoise(image, strength: 45).pixels
        }
        assertSameBothWays("sharpen", input: image.pixels) {
            SpatialFilters.sharpen(image, strength: 60).pixels
        }
    }

    func testForcedBandsHookActuallyChangesThePartitioning() {
        // 钩子本身也要被证明是有效的：默认分带必须 > 1，否则上面两条断言是在
        // 拿"串行对串行"自证，看起来全绿却什么都没测。
        PixelParallel.forcedBands = 1
        XCTAssertEqual(PixelParallel.bands, 1, "forcedBands 没有生效")
        PixelParallel.forcedBands = nil
        XCTAssertGreaterThan(PixelParallel.bands, 1,
                             "这台机器只有 1 个可用核，并行分支无法被验证 —— 换 runner 再看这条")
    }
}
