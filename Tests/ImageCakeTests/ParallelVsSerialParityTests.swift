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
    override func tearDown() {
        PixelParallel.forcedBands = nil
        super.tearDown()
    }

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

    // MARK: - 剩下的逐像素热段（本轮改成分带的六个引擎）

    private func fullWeights() -> [Float] {
        [Float](repeating: 1, count: size.pixelCount)
    }

    /// 掩码类入口（返回权重图而不是改像素）用的对照：除了串行/并行相等，
    /// 还要掩码真的命中 —— 否则两边都是空掩码，比的还是"什么都没做"。
    private func assertMaskSameBothWays(_ label: String, _ run: () -> [Float]) {
        PixelParallel.forcedBands = nil
        let parallel = run()
        PixelParallel.forcedBands = 1
        let serial = run()
        PixelParallel.forcedBands = nil
        XCTAssertEqual(serial.count, parallel.count, "\(label): 串行与并行的长度不同")
        let hits = parallel.filter { $0 > 0 }.count
        XCTAssertGreaterThan(hits, 0, "\(label): 掩码全空，这条比较是在自我安慰")
        var bad: [Int] = []
        for i in 0 ..< parallel.count where serial[i] != parallel[i] {
            if bad.count < 5 { bad.append(i) }
        }
        XCTAssertTrue(bad.isEmpty, "\(label): \(bad.count)+ 个权重并行与串行不一致，前几个下标 \(bad)")
    }

    func testGarmentDeWrinkleMatchesSerial() {
        let input = skinImage().pixels
        let weight = fullWeights()
        assertSameBothWays("garment.deWrinkle", input: input) {
            var pixels = input
            GarmentEngine.deWrinkle(&pixels, size: size, weights: weight, amount: 0.8)
            return pixels
        }
    }

    func testThinDarkLineMatchesSerial() {
        // 祛法令纹与颈纹/妊娠纹共用这一环，所以它一处不一致两处都错。
        let input = skinImage().pixels
        let weight = fullWeights()
        assertSameBothWays("thinDarkLinePass", input: input) {
            var pixels = input
            RegionEnhance.thinDarkLinePass(&pixels, size: size, weight: weight, amount: 0.75)
            return pixels
        }
    }

    func testRegionModifyMatchesSerial() {
        let input = skinImage().pixels
        let weight = fullWeights()
        // `edit` 在多个带上被并发调用，所以这也是一条竞态检查：它必须是纯函数。
        assertSameBothWays("region.modify", input: input) {
            var pixels = input
            RegionEnhance.modify(&pixels, size: size, weight: weight, amount: 0.6) { l, a, b in
                (l + 0.30 * (1 - l), a * 1.45 + 0.05, b * 1.2)
            }
            return pixels
        }
    }

    /// 带硬边与细结构的变体：既有一块比邻域亮很多的细线（祛碎发要的东西），
    /// 也有暗痘与暗纹（磨皮/瑕疵/细线的门限才能被触发）。
    private func textureImage() -> DisplayImage {
        var pixels = skinImage().pixels
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                if x == size.width * 2 / 3, y % 9 == 0 {         // 亮于邻域的碎发丝
                    pixels[o] = 0.95; pixels[o + 1] = 0.94; pixels[o + 2] = 0.92
                }
                if x == size.width / 3, y % 13 == 0 {            // 细暗线
                    pixels[o] *= 0.55; pixels[o + 1] *= 0.55; pixels[o + 2] *= 0.55
                }
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 祛碎发只看掩码的**边界环带**（三角窗在 w=1 处正好归 0），所以它的
    /// 夹具权重必须是 0.5 —— 全 1 会把环带算成 0，两边都短路。
    private func bandWeights() -> [Float] {
        [Float](repeating: 0.5, count: size.pixelCount)
    }

    func testHairPassesMatchSerial() {
        let input = skinImage().pixels
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
        let frizz = textureImage().pixels
        let ring = bandWeights()
        assertSameBothWays("hair.tameFlyaways", input: frizz) {
            var pixels = frizz
            HairEngine.tameFlyaways(&pixels, size: size, weights: ring, amount: 0.9)
            return pixels
        }
        // 发区需要**非肤色**的像素，而 skinImage 整张都是肤色（那正是它的职责），
        // 所以单独造一个头部夹具：顶几行是暗发（亮度 0.12 不进肤色椭圆）。
        var hairPixels = skinImage().pixels
        for y in 0 ..< 14 {
            for x in size.width / 4 ..< size.width * 3 / 4 {
                let o = (y * size.width + x) * 4
                hairPixels[o] = 0.12; hairPixels[o + 1] = 0.11; hairPixels[o + 2] = 0.10
            }
        }
        let hairImage = DisplayImage(size: size, pixels: hairPixels)
        let box = CGRect(x: 0.2, y: 0, width: 0.6, height: 0.75)
        assertMaskSameBothWays("HairMask.build") {
            HairMask.build(hairImage, faceBounds: box)
        }
    }

    func testHandEngineMatchesSerial() {
        let input = skinImage().pixels
        let weight = fullWeights()
        var hands = HandParameters()
        hands.evenTone = 55
        hands.redness = 40
        assertSameBothWays("hand.evenToneAndRedness", input: input) {
            var pixels = input
            HandEngine.evenToneAndRedness(&pixels, size: size, weights: weight, hands: hands)
            return pixels
        }
        // 凸包用两个矩形当夹具：HandMask.build 内部会先走凸包再与色域相与。
        let left = stride(from: 0.30, through: 0.46, by: 0.04).map { CGPoint(x: $0, y: 0.42) }
            + stride(from: 0.42, through: 0.62, by: 0.04).map { CGPoint(x: 0.46, y: $0) }
            + stride(from: 0.46, through: 0.30, by: -0.04).map { CGPoint(x: $0, y: 0.62) }
            + stride(from: 0.62, through: 0.42, by: -0.04).map { CGPoint(x: 0.30, y: $0) }
        assertMaskSameBothWays("HandMask.build") {
            HandMask.build(size: size, hulls: [left], pixels: input)
        }
    }

    func testMakeupLayDownMatchesSerial() {
        let input = skinImage().pixels
        let weight = fullWeights()
        assertSameBothWays("makeup.layDown", input: input) {
            var pixels = input
            MakeupEngine.layDown(&pixels, size: size, weight: weight, hex: 0xAA3344,
                                 opacity: 0.55, lumaKeep: 0.35)
            return pixels
        }
    }

    func testSkinMaskBuildMatchesSerial() {
        let image = skinImage()
        let person = MaskBuffer.filled(size, value: 255)
        let boxes = [CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)]
        assertMaskSameBothWays("SkinMask.all") {
            SkinMask.weights(SkinMask.build(image, personMask: person, faceBoxes: boxes).all, size: size)
        }
        assertMaskSameBothWays("SkinMask.face") {
            SkinMask.weights(SkinMask.build(image, personMask: person, faceBoxes: boxes).face, size: size)
        }
        assertMaskSameBothWays("SkinMask.body") {
            SkinMask.weights(SkinMask.build(image, personMask: person, faceBoxes: boxes).body, size: size)
        }
    }

    // MARK: - 分带本身的两条性质

    func testForEachPixelCoversEveryIndexExactlyOnce() {
        // 分带唯一可能改变结果的地方就是"某个像素被算两次或漏算"。这里不跑算子，
        // 直接把覆盖性拉出来测，并同时命中并行与小图两条分支。
        for count in [1, 63, 4095, 4096, 12_707, 250_000] {
            var visited = [Int](repeating: 0, count: count)
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
            for index in perBand.flatMap({ $0 }) { visited[index] += 1 }
            XCTAssertEqual(visited, [Int](repeating: 1, count: count), "forEach 在 count=\(count) 上没有恰好覆盖一次")
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
            XCTAssertEqual(visited, [Int](repeating: 1, count: height), "forEachRow 在 height=\(height) 上没有恰好覆盖一次")
        }
    }

    func testForEachPixelIgnoresShortBuffers() {
        // 缓冲比 count*4 短时必须整段跳过，而不是越界写：症状是随机崩溃而不是错值。
        var tooShort = [Float](repeating: 0.5, count: 8)
        PixelParallel.forEachPixel(&tooShort, 4096) { buf, i in buf[i] = 0 }
        XCTAssertEqual(tooShort, [Float](repeating: 0.5, count: 8))
    }

    /// 并行化不许把"权重为 0 的像素一个比特都不动"这条承诺弄丢。
    /// 它在串行下是显然的（那个环直接 continue），分带后仍然是——因为带与带
    /// 之间不共享任何写入位置。这条防的是"把权重判据改成了先写后回滚"那种写法。
    func testZeroWeightRegionStaysBitIdentical() {
        let input = skinImage().pixels
        var weight = [Float](repeating: 0, count: size.pixelCount)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width / 2 { weight[y * size.width + x] = 1 }
        }
        let untouched: (String, [Float]) -> Void = { label, got in
            for y in 0 ..< size.height {
                for x in (size.width / 2 + 1) ..< size.width {
                    let o = (y * size.width + x) * 4
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

        var shine = input
        HairEngine.shapeShine(&shine, size: size, weights: weight, amount: 1)
        untouched("shapeShine", shine)

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
