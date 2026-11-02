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
/// 覆盖范围 = 当前真正接了 `PixelParallel` 的内核：降噪与锐化（`SpatialFilters`）、
/// `ab82107` 分带的六个逐像素热段（衣物祛褶 / 上粉 / 区域与细线 / 头发 / 手 /
/// 皮肤掩码），以及 `BeautyEngine` 的三个 pass（第二次接上）。
///
/// 为什么"加一个分带就得同时加一个 case"是硬规矩：生产代码分了带而对照被删掉,
/// 就会出现本仓刚发生过的那种假话 —— 文件头声称已覆盖，实际那几个内核没人验。
/// 第一次撤 `BeautyEngine` 的理由是"整机中位分辨不出"，而当时那把尺子本身比收益
/// 更抖（跨跑 21%），所以换成 min-of-7 之后重做一次再判。
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

    // MARK: - 六个逐像素热段（`ab82107` 分带的部分）

    /// 肤色夹具（与 `busyImage` 的区分很重要：`SkinMask.build`、`HandMask.build` 要的是
    /// **命中肤椭圆**的像素，而 busyImage 因为 b > g 根本不算肤 —— 拿它去测掩码类
    /// 入口只会得到空掩码。发区则相反，要的是非肤，所以那边用 busyImage。
    private func skinFixture() -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        var state = UInt64(0xDEAD_BEEF_0BAD_F00D)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let o = (y * size.width + x) * 4
                let patch: Float = ((x / 11) + (y / 9)) % 3 == 0 ? 0.10 : 0
                pixels[o] = Swift.min(Swift.max(0.74 - patch + Float((state >> 41) % 60) / 1000, 0), 1)
                pixels[o + 1] = Swift.min(Swift.max(0.55 - patch * 0.8 + Float((state >> 31) % 50) / 1000, 0), 1)
                pixels[o + 2] = Swift.min(Swift.max(0.45 - patch * 0.6 + Float((state >> 21) % 40) / 1000, 0), 1)
                pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 带硬边的亮细节与细暗线：`tameFlyaways` 只看"比邻域低频亮出 0.05 以上"的像素，
    /// 而 `shapeShine` 只看 luma > 0.45 且高于局部均值那一段 —— 平（或单块）图会让
    /// 它们按设计什么都不做，拿那种夹具断言"必须变"是自相矛盾的期待。
    private func frizzFixture() -> [Float] {
        var pixels = skinFixture().pixels
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                if x == size.width * 2 / 3, y % 9 == 0 {
                    pixels[o] = 0.95; pixels[o + 1] = 0.94; pixels[o + 2] = 0.92
                }
                if x == size.width / 3, y % 13 == 0 {
                    pixels[o] *= 0.55; pixels[o + 1] *= 0.55; pixels[o + 2] *= 0.55
                }
            }
        }
        return pixels
    }

    private func fullWeights(_ fill: Float = 1) -> [Float] {
        [Float](repeating: fill, count: size.pixelCount)
    }

    /// 掩码类入口的对照：除了串并相等，还要求掩码真的命中（否则两边都是空掩码）。
    private func assertMaskSameBothWays(_ label: String, _ run: () -> [Float]) {
        PixelParallel.forcedBands = nil
        let parallel = run()
        PixelParallel.forcedBands = 1
        let serial = run()
        PixelParallel.forcedBands = nil
        XCTAssertEqual(serial.count, parallel.count, "\(label): 串行与并行的长度不同")
        XCTAssertGreaterThan(parallel.filter { $0 > 0 }.count, 0,
                             "\(label): 掩码全空 —— 这条比较是在自我安慰（夹具不对）")
        var bad: [Int] = []
        for i in 0 ..< parallel.count where serial[i] != parallel[i] {
            if bad.count < 5 { bad.append(i) }
        }
        XCTAssertTrue(bad.isEmpty, "\(label): \(bad.count)+ 个权重串并不一致，前几个下标 \(bad)")
    }

    /// 磨皮/祛瑕疵/匀肤色三个 pass（`BeautyEngine.apply` 的全部逐像素环）。
    func testBeautyEnginePassesMatchSerial() {
        let image = skinFixture()
        let layers = SkinMask.build(image, personMask: MaskBuffer.filled(size, value: 255),
                                    faceBoxes: [CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)])
        // 夹具自检：掩码必须真的命中，否则两边都是"没皮肤可磨"，比的是空操作。
        XCTAssertGreaterThan(SkinMask.weights(layers.face, size: size).filter { $0 > 0 }.count, 0,
                             "夹具没让脸部皮肤掩码命中")
        XCTAssertGreaterThan(SkinMask.weights(layers.body, size: size).filter { $0 > 0 }.count, 0,
                             "夹具没让身体皮肤掩码命中")
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

    func testGarmentDeWrinkleMatchesSerial() {
        let input = skinFixture().pixels
        let weight = fullWeights()
        assertSameBothWays("garment.deWrinkle", input: input) {
            var pixels = input
            GarmentEngine.deWrinkle(&pixels, size: size, weights: weight, amount: 0.8)
            return pixels
        }
    }

    func testThinDarkLineMatchesSerial() {
        // 这一环同时被祛法令纹与身体细纹（颈纹/妊娠纹）走，一处不一致两处都错。
        let input = skinFixture().pixels
        let weight = fullWeights()
        assertSameBothWays("thinDarkLinePass", input: input) {
            var pixels = input
            RegionEnhance.thinDarkLinePass(&pixels, size: size, weight: weight, amount: 0.75)
            return pixels
        }
    }

    func testRegionModifyAndMakeupMatchSerial() {
        let input = skinFixture().pixels
        let weight = fullWeights()
        // `edit` 在多个带上被并发调用，所以这同时是一条竞态检查：它必须是纯函数。
        assertSameBothWays("region.modify", input: input) {
            var pixels = input
            RegionEnhance.modify(&pixels, size: size, weight: weight, amount: 0.6) { l, a, b in
                (l + 0.30 * (1 - l), a * 1.45 + 0.05, b * 1.2)
            }
            return pixels
        }
        assertSameBothWays("makeup.layDown", input: input) {
            var pixels = input
            MakeupEngine.layDown(&pixels, size: size, weight: weight, hex: 0xAA3344,
                                 opacity: 0.55, lumaKeep: 0.35)
            return pixels
        }
    }

    func testHairPassesMatchSerial() {
        let input = skinFixture().pixels
        let weight = fullWeights()
        assertSameBothWays("hair.dampFrizz", input: input) {
            var pixels = input
            HairEngine.dampFrizz(&pixels, size: size, weights: weight, amount: 0.7)
            return pixels
        }
        assertSameBothWays("hair.shapeShine", input: input) {
            var pixels = input
            HairEngine.shapeShine(&pixels, size: size, weights: weight, amount: 0.6)
            return pixels
        }
        assertSameBothWays("hair.saturate", input: input) {
            var pixels = input
            HairEngine.saturate(&pixels, size: size, weights: weight, amount: 0.6)
            return pixels
        }
        assertSameBothWays("hair.recolor", input: input) {
            var pixels = input
            HairEngine.recolor(&pixels, size: size, weights: weight, amount: 0.6, hex: 0x884422)
            return pixels
        }
        // 祛碎发只看掩码的**边界环带**（三角窗在 w=1 处正好归 0），所以它的权重
        // 必须是 0.5：给 1 会让环带算成 0，两边都短路。
        let frizz = frizzFixture()
        assertSameBothWays("hair.tameFlyaways", input: frizz) {
            var pixels = frizz
            HairEngine.tameFlyaways(&pixels, size: size, weights: fullWeights(0.5), amount: 0.9)
            return pixels
        }
        // 发区要的是**非肤色**像素，所以用 busyImage（上面写过：肤色夹具进不了发区）。
        let box = CGRect(x: 0.2, y: 0, width: 0.6, height: 0.75)
        let busy = busyImage()
        assertMaskSameBothWays("HairMask.build") {
            HairMask.build(busy, faceBounds: box)
        }
    }

    func testHandEngineAndMasksMatchSerial() {
        let input = skinFixture().pixels
        let weight = fullWeights()
        var hands = HandParameters()
        hands.evenTone = 55
        hands.redness = 40
        assertSameBothWays("hand.evenToneAndRedness", input: input) {
            var pixels = input
            HandEngine.evenToneAndRedness(&pixels, size: size, weights: weight, hands: hands)
            return pixels
        }
        // 凸包夹具：一个方形环（HandMask 内部会先取凸包再与肤色椭圆相与）。
        var hull: [CGPoint] = []
        for x in stride(from: 0.30, through: 0.46, by: 0.04) { hull.append(CGPoint(x: x, y: 0.42)) }
        for y in stride(from: 0.42, through: 0.62, by: 0.04) { hull.append(CGPoint(x: 0.46, y: y)) }
        for x in stride(from: 0.46, through: 0.30, by: -0.04) { hull.append(CGPoint(x: x, y: 0.62)) }
        for y in stride(from: 0.62, through: 0.42, by: -0.04) { hull.append(CGPoint(x: 0.30, y: y)) }
        assertMaskSameBothWays("HandMask.build") {
            HandMask.build(size: size, hulls: [hull], pixels: input)
        }
        let person = MaskBuffer.filled(size, value: 255)
        let boxes = [CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)]
        let image = skinFixture()
        assertMaskSameBothWays("SkinMask.face") {
            SkinMask.weights(SkinMask.build(image, personMask: person, faceBoxes: boxes).face, size: size)
        }
        assertMaskSameBothWays("SkinMask.body") {
            SkinMask.weights(SkinMask.build(image, personMask: person, faceBoxes: boxes).body, size: size)
        }
    }

    func testForEachPixelCoversEveryIndexExactlyOnce() {
        // 分带唯一可能改变结果的地方就是"某个像素被算两次或漏算"。这条不跑算子，
        // 直接把覆盖性拉出来测，并同时命中并行与小图两条分支。
        for count in [1, 63, 4095, 4096, 12_707, 250_000] {
            var perBand = [[Int]](repeating: [], count: 16)
            let lock = NSLock()
            PixelParallel.forEach(count) { start, end in
                var local: [Int] = []
                local.reserveCapacity(end - start)
                for i in start ..< end { local.append(i) }
                lock.lock()
                perBand[start % 16] += local
                lock.unlock()
            }
            var visited = [Int](repeating: 0, count: count)
            for index in perBand.flatMap({ $0 }) { visited[index] += 1 }
            XCTAssertEqual(visited, [Int](repeating: 1, count: count),
                           "forEach 在 count=\(count) 上没有恰好覆盖一次")
        }
        for height in [1, 63, 64, 97, 512] {
            var perBand = [[Int]](repeating: [], count: 16)
            let lock = NSLock()
            PixelParallel.forEachRow(height) { start, end in
                var local: [Int] = []
                for y in start ..< end { local.append(y) }
                lock.lock()
                perBand[start % 16] += local
                lock.unlock()
            }
            var visited = [Int](repeating: 0, count: height)
            for index in perBand.flatMap({ $0 }) { visited[index] += 1 }
            XCTAssertEqual(visited, [Int](repeating: 1, count: height),
                           "forEachRow 在 height=\(height) 上没有恰好覆盖一次")
        }
    }

    func testForEachPixelIgnoresShortBuffers() {
        // 缓冲比 count*4 短时必须整段跳过，而不是越界写：症状是随机崩溃而不是错值。
        var tooShort = [Float](repeating: 0.5, count: 8)
        PixelParallel.forEachPixel(&tooShort, 4096) { buf, i in buf[i] = 0 }
        XCTAssertEqual(tooShort, [Float](repeating: 0.5, count: 8))
    }

    /// 并行化不许把"权重为 0 的像素一个比特都不动"这条承诺弄丢：它在串行下是显然的
    /// （那个环直接 continue），分带后仍然是 —— 因为带与带之间不共享写入位置。
    func testZeroWeightRegionStaysBitIdentical() {
        let input = skinFixture().pixels
        var weight = [Float](repeating: 0, count: size.pixelCount)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width / 2 { weight[y * size.width + x] = 1 }
        }
        let untouched: (String, [Float]) -> Void = { label, got in
            // 这个闭包被当成显式函数类型的变量使用， Swift 要求写 self.size（否则报
            // "reference to property in closure requires explicit use of self"）。
            for y in 0 ..< self.size.height {
                for x in (self.size.width / 2 + 1) ..< self.size.width {
                    let o = (y * self.size.width + x) * 4
                    for c in 0 ..< 4 {
                        XCTAssertEqual(got[o + c], input[o + c],
                                       "\(label): 权重为 0 的像素被改了（第 \(c) 通道）")
                    }
                }
            }
        }
        var garment = input
        GarmentEngine.deWrinkle(&garment, size: size, weights: weight, amount: 1)
        untouched("garment", garment)

        var line = input
        RegionEnhance.thinDarkLinePass(&line, size: size, weight: weight, amount: 1)
        untouched("thinDarkLine", line)

        var hair = input
        HairEngine.dampFrizz(&hair, size: size, weights: weight, amount: 1)
        untouched("dampFrizz", hair)

        var make = input
        MakeupEngine.layDown(&make, size: size, weight: weight, hex: 0xAA3344, opacity: 1, lumaKeep: 1)
        untouched("layDown", make)

        var hands = HandParameters()
        hands.evenTone = 100
        hands.redness = 100
        var hand = input
        HandEngine.evenToneAndRedness(&hand, size: size, weights: weight, hands: hands)
        untouched("handEvenTone", hand)
    }
}
