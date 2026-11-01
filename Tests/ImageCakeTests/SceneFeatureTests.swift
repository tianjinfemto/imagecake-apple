import CoreGraphics
import XCTest

@testable import ImageCake

/// 造型与场景六个功能的断言：妆容模板、头发、手部、衣物祛褶、换天空、
/// 虚拟打光，外加多帧堆栈与联机拍摄的决策层。
///
/// 写法规矩沿用仓里那条：**能断确定性性质的写死，需要数值的地方先向被测
/// 函数要落点（argmax）再下笔**。上一轮被"手算 smoothstep 的字节值"坑过一次
/// （旋转椭圆的对称格其实是 (18,18)/(21,21) 而不是 (18,18)/(22,22)），所以
/// 这一批尽量用"这一处比那一处大"、"区外逐比特不变"、"与只给一张时不同"
/// 这类能真正抓住接线错误的关系，而不是抄数字。

final class SceneFeatureTests: XCTestCase {
    private var skin: (r: Double, g: Double, b: Double) { (0.70, 0.55, 0.45) }

    private func solid(_ size: PixelSize, _ r: Double, _ g: Double, _ b: Double) -> DisplayImage {
        TestImage.solid(width: size.width, height: size.height, r: r, g: g, b: b)
    }

    private func argmax(_ weights: [Float]) -> Int {
        var best = 0
        for (index, value) in weights.enumerated() where value > weights[best] { best = index }
        return best
    }

    private func shifted(dx: CGFloat) -> [CGPoint] {
        /// 合成一张"够用"的 478 点脸，并补上眉毛两点序列（BeautyEngineTests 那份
        /// 没有眉毛，因为当时没有功能消费它）。眉毛放在眼睛上方 0.05。
        var points = BeautyEngineTests.syntheticFacePoints().map {
            CGPoint(x: $0.x + dx, y: $0.y)
        }
        if dx == 0 {
            for index in FaceGeometry.Index.rightBrow { points[index] = CGPoint(x: 0.36, y: 0.36) }
            points[104] = CGPoint(x: 0.35, y: 0.372); points[100] = CGPoint(x: 0.40, y: 0.352)
            points[97] = CGPoint(x: 0.45, y: 0.368)
            for index in FaceGeometry.Index.leftBrow { points[index] = CGPoint(x: 0.64, y: 0.36) }
            points[300] = CGPoint(x: 0.65, y: 0.372); points[296] = CGPoint(x: 0.60, y: 0.352)
            points[336] = CGPoint(x: 0.55, y: 0.368)
        }
        return points
    }

    // MARK: - 1. 妆容模板

    func testMakeupNeutralAndUnknownLookAreBitExact() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: shifted(dx: 0))!
        let base = solid(size, skin.r, skin.g, skin.b)
        var off = MakeupParameters()
        off.styleID = "red-lip"; off.strength = 0
        XCTAssertEqual(MakeupEngine.apply(base, geometries: [geometry], makeup: off).pixels, base.pixels,
                       "浓淡 0 必须整段恒等，而不是跑一遍近似")
        var unknown = MakeupParameters()
        unknown.styleID = "no-such-look"
        XCTAssertEqual(MakeupEngine.apply(base, geometries: [geometry], makeup: unknown).pixels, base.pixels,
                       "模板查不到就当没有这一步（调用侧点名 [no_makeup:名字]）")
        var emptyFaces = MakeupParameters()
        emptyFaces.styleID = "nude"; emptyFaces.strength = 100
        XCTAssertEqual(MakeupEngine.apply(base, geometries: [], makeup: emptyFaces).pixels, base.pixels,
                       "没关键点不跑")
    }

    func testMakeupLaysLipAndBrowOnlyInsideTheirRegions() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: shifted(dx: 0))!
        let lips = RegionEnhance.lipWeights(geometry, size: size)
        let brow = MakeupEngine.browWeights(geometry, size: size)
        let lipPeak = argmax(lips), browPeak = argmax(brow)
        XCTAssertGreaterThan(lips[lipPeak], 0.4, "唇环必须有实权重")
        XCTAssertGreaterThan(brow[browPeak], 0.4, "眉带必须有实权重")
        // 眉带必须落在眼睛上方（主峰 y 小于虹膜 y）。这条抓的是"眉毛索引错了"。
        // 主峰行必须在虹膜上方。`argmax` 给的是**扁平下标**，除一次 width 得到的是
        // 像素行（不是 0…1 的占比）；写成 Int / Int 还会被截断。
        // 两边统一用像素行比较，比镜像算出的眉带主峰在 row 36、虹膜在 row 43。
        let irisY = Double(geometry.irisCenters[0].y) * Double(size.height)
        let browRow = Double(browPeak) / Double(size.width)
        XCTAssertLessThan(browRow, irisY - 2.0,
                          "眉带跑到眼睛下方 = 眉毛索引表错了")

        let base = solid(size, skin.r, skin.g, skin.b)
        var makeup = MakeupParameters()
        makeup.styleID = "brow-only"; makeup.strength = 100
        let result = MakeupEngine.apply(base, geometries: [geometry], makeup: makeup)
        XCTAssertNotEqual(result.pixels[browPeak * 4], base.pixels[browPeak * 4], "眉带处要上粉")
        XCTAssertEqual(result.pixels[(2 * 100 + 2) * 4], base.pixels[(2 * 100 + 2) * 4], "远离五官的角落逐比特不动")
    }

    func testMakeupKeepsLumaStructureWhileShiftingChroma() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: shifted(dx: 0))!
        let lips = RegionEnhance.lipWeights(geometry, size: size)
        let peak = argmax(lips)

        // 唇区里铺一条亮暗相间的竖纹（模拟唇纹）：上粉后**亮度差必须留下大部分**。
        var pixels = solid(size, skin.r, skin.g, skin.b).pixels
        for x in (peak % size.width - 5) ... (peak % size.width + 5) {
            let bright = x % 2 == 0
            for y in (peak / size.width - 2) ... (peak / size.width + 2) {
                let o = (y * size.width + x) * 4
                pixels[o] = Float(bright ? 0.82 : 0.62)
                pixels[o + 1] = Float(bright ? 0.66 : 0.46)
                pixels[o + 2] = Float(bright ? 0.56 : 0.36)
            }
        }
        let input = DisplayImage(size: size, pixels: pixels)
        var makeup = MakeupParameters()
        makeup.styleID = "red-lip"; makeup.strength = 100
        let out = MakeupEngine.apply(input, geometries: [geometry], makeup: makeup)
        let row = peak / size.width
        let a = (row * size.width + (peak % size.width - 5)) * 4
        let b = (row * size.width + (peak % size.width - 4)) * 4
        let beforeLuma = abs(input.pixels[a] - input.pixels[b])
        let afterLuma = abs(out.pixels[a] - out.pixels[b])
        XCTAssertGreaterThan(afterLuma, beforeLuma * 0.5, "唇纹不能被妆盖平（lumaKeep 失效）")
        XCTAssertLessThan(afterLuma, beforeLuma + 1e-6, "妆不会反过来加对比")
    }

    func testMakeupAppliedToEveryFace() {
        let size = PixelSize(width: 100, height: 100)
        let left = FaceGeometry.from(points: shifted(dx: 0))!
        let right = FaceGeometry.from(points: shifted(dx: 0.25))!
        let base = solid(size, skin.r, skin.g, skin.b)
        var makeup = MakeupParameters()
        makeup.styleID = "red-lip"; makeup.strength = 100
        let one = MakeupEngine.apply(base, geometries: [left], makeup: makeup)
        let both = MakeupEngine.apply(base, geometries: [left, right], makeup: makeup)
        XCTAssertNotEqual(one.pixels, both.pixels, "两张脸必须比一张脸多做事情")
        let secondLip = RegionEnhance.lipWeights(right, size: size)
        let peak = argmax(secondLip)
        XCTAssertGreaterThan(secondLip[peak], 0.4)
        XCTAssertNotEqual(both.pixels[peak * 4], one.pixels[peak * 4], "第二张脸的唇也要上妆")
    }

    // MARK: - 2. 头发

    func testHairMaskNeedsFaceBoundsAndSkipsSkinAndLowerBlue() {
        let size = PixelSize(width: 60, height: 100)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            pixels[o] = Float(skin.r); pixels[o + 1] = Float(skin.g)
            pixels[o + 2] = Float(skin.b); pixels[o + 3] = 1
        }
        func paint(_ yRange: Range<Int>, _ xRange: Range<Int>, _ rgb: (Double, Double, Double)) {
            for y in yRange {
                for x in xRange {
                    let o = (y * size.width + x) * 4
                    pixels[o] = Float(rgb.0); pixels[o + 1] = Float(rgb.1); pixels[o + 2] = Float(rgb.2)
                }
            }
        }
        // 头顶那一排涂成深灰（非皮肤、亮度高）；画面下方涂一块蓝（也不属皮肤，
        // 但它在头部框外）。只有前者该算头发。
        paint(0 ..< 12, 0 ..< 60, (0.62, 0.64, 0.68))
        paint(88 ..< 100, 0 ..< 60, (0.20, 0.40, 0.85))
        let image = DisplayImage(size: size, pixels: pixels)
        let faceBounds = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.5)
        let weights = HairMask.build(image, faceBounds: faceBounds)
        XCTAssertGreaterThan(weights[3 * size.width + 30], 0.5, "头顶的深灰要算头发")
        XCTAssertEqual(weights[93 * size.width + 30], 0, "头部框外的蓝不会被当成头发")
        XCTAssertEqual(weights[50 * size.width + 30], 0, "皮肤色域内永远不是头发")
        XCTAssertTrue(HairMask.build(image, faceBounds: .zero).allSatisfy { $0 == 0 },
                      "没有脸框就不能谎称知道头发在哪")
    }

    func testHairFrizzDampsSmallJitterButKeepsStrands() {
        let size = PixelSize(width: 64, height: 64)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        var state = UInt64(7)
        for i in 0 ..< size.pixelCount {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let jitter = (Double(state >> 33) / Double(1 << 31) - 0.5) * 0.014   // 毛躁
            let strand: Double = (i % size.width) % 9 == 0 ? 0.11 : 0            // 真发丝
            let o = i * 4
            pixels[o] = Float(0.30 + jitter + strand)
            pixels[o + 1] = Float(0.26 + jitter + strand)
            pixels[o + 2] = Float(0.24 + jitter + strand)
            pixels[o + 3] = 1
        }
        let input = DisplayImage(size: size, pixels: pixels)
        let weights = [Float](repeating: 1, count: size.pixelCount)
        var hair = HairParameters()
        hair.smooth = 100
        let out = HairEngine.apply(input, weights: weights, hair: hair)

        func adjacentJitter(_ buffer: [Float]) -> Double {
            // 相邻且都不在发丝列上的像素差 = 毛躁量。
            var sum = 0.0, n = 0
            for y in 8 ..< 56 {
                for x in 8 ..< 55 {
                    let a = (y * size.width + x) * 4, b = (y * size.width + x + 1) * 4
                    if (x % 9 == 0) || (x + 1) % 9 == 0 { continue }
                    sum += abs(Double(buffer[a] - buffer[b])); n += 1
                }
            }
            return n > 0 ? sum / Double(n) : 0
        }
        func strandDepth(_ buffer: [Float]) -> Double {
            let base = 0.30
            var sum = 0.0, n = 0
            for y in 8 ..< 56 {
                for x in 8 ..< 56 where x % 9 == 0 {
                    sum += Double(buffer[(y * size.width + x) * 4]) - base
                    n += 1
                }
            }
            return n > 0 ? sum / Double(n) : 0
        }
        let jitterBefore = adjacentJitter(input.pixels), jitterAfter = adjacentJitter(out.pixels)
        // 实测（镜像脚本）：力度拉满时拖动噪声降到 0.70 倍，而真发丝深度保持 1.00 倍。
        // 阈值留到 0.85 / 0.9：方向对了就不因后续微调而假红。
        XCTAssertLessThan(jitterAfter, jitterBefore * 0.85, "毛躁没被压下去 = 阈值/半径不对")
        XCTAssertGreaterThan(strandDepth(out.pixels), strandDepth(input.pixels) * 0.9,
                             "真发丝被一起抹平了 —— 那就成塑料头发了")
    }

    func testHairShineOnlyTouchesHighlightsAndOutsideIsBitExact() {
        let size = PixelSize(width: 40, height: 40)
        let dark = solid(size, 0.25, 0.22, 0.20)
        var hair = HairParameters()
        hair.shine = -100
        // 暗区：压亮丝不该动它（只处理高光侧）
        let kept = HairEngine.apply(dark, weights: [Float](repeating: 1, count: size.pixelCount), hair: hair)
        XCTAssertEqual(kept.pixels, dark.pixels, "低于 0.45 的像素不参与光泽")
        // 权认为 0 时连亮区也不动
        let bright = solid(size, 0.98, 0.97, 0.96)
        let untouched = HairEngine.apply(bright, weights: [Float](repeating: 0, count: size.pixelCount), hair: hair)
        XCTAssertEqual(untouched.pixels, bright.pixels, "发区外逐比特不变")
        let pressed = HairEngine.apply(bright, weights: [Float](repeating: 1, count: size.pixelCount), hair: hair)
        XCTAssertLessThan(pressed.pixels[0], bright.pixels[0], "过曝的亮丝要被压回去")
    }

    // MARK: - 3. 手部

    func testConvexHullIsDeterministicAndCoversItsPoints() {
        let scattered: [CGPoint] = [
            CGPoint(x: 0.30, y: 0.60), CGPoint(x: 0.34, y: 0.40), CGPoint(x: 0.40, y: 0.30),
            CGPoint(x: 0.48, y: 0.34), CGPoint(x: 0.52, y: 0.55), CGPoint(x: 0.44, y: 0.62),
            CGPoint(x: 0.38, y: 0.50),
        ]
        let hull = HandHull.polygon(scattered)
        XCTAssertGreaterThanOrEqual(hull.count, 3)
        XCTAssertGreaterThan(HandHull.area(hull), 0.01)
        XCTAssertEqual(HandHull.area(hull), HandHull.area(HandHull.polygon(scattered.reversed())),
                       accuracy: 1e-12, "输入顺序不能改变凸包（否则同图两次导出会不一样）")
        for point in scattered {
            // `CGRect.contains` 对 max 边是开区间：x == bounds.maxX 的关节点（本例的
            // (0.52, 0.55)）会被判"在外面"。外接框本来就是闭区间语义，外放一个
            // 极小 epsilon 再判，否则这条断言抓的是 CGRect 而不是凸包。
            XCTAssertTrue(HandHull.bounds(scattered)!.insetBy(dx: -1e-9, dy: -1e-9).contains(point),
                          "外接框必须包住每个关节点")
        }
        XCTAssertEqual(HandHull.polygon([CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2)]).count, 0,
                       "两个点围不出凸包")
        XCTAssertEqual(HandHull.area(HandHull.polygon(Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 9))),
                       0, accuracy: 1e-12, "全重合的退化姿态面积为 0，调用侧据此丢弃")
    }

    func testHandEngineOnlyTouchesSkinColouredHullPixels() {
        let size = PixelSize(width: 60, height: 60)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            pixels[o] = Float(skin.r); pixels[o + 1] = Float(skin.g)
            pixels[o + 2] = Float(skin.b); pixels[o + 3] = 1
        }
        // 凸包中央画一块"指甲"（高亮、偏冷，不属皮肤色域）：它不该被磨。
        for y in 26 ..< 34 {
            for x in 26 ..< 34 {
                let o = (y * size.width + x) * 4
                pixels[o] = 0.95; pixels[o + 1] = 0.96; pixels[o + 2] = 0.97
            }
        }
        // 加一点抖动，才有可被磨掉的"毛躁"。
        var state = UInt64(11)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                if pixels[o] > 0.9 { continue }
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let jitter = (Double(state >> 40) / Double(1 << 24) - 0.5) * 0.05
                pixels[o] = Float(Swift.min(1, Swift.max(0, Double(pixels[o]) + jitter)))
            }
        }
        let image = DisplayImage(size: size, pixels: pixels)
        let hull = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.9, y: 0.9),
                    CGPoint(x: 0.1, y: 0.9)]
        let weights = HandMask.build(size: size, hulls: [hull], pixels: image.pixels)
        XCTAssertGreaterThan(weights[10 * size.width + 10], 0.5, "手背（皮肤色域内）参与")
        XCTAssertEqual(weights[30 * size.width + 30], 0, "指甲不参与：颜色不属皮肤色域")
        // 羽化是**三次** box blur（MaskOps.feathered），实际扩散半径≈ 3×radius，
        // 而凸包右缘到画面角只有 6 px，所以这里不是 0 而是余下的一丝。
        // 断言语义不变：区域外不得参与——但不能拿"逐比特 0"去要求羽化边缘。
        XCTAssertLessThan(weights[59 * size.width + 59], 0.02, "凸包外只剩羽化余量，不构成参与")

        var hands = HandParameters()
        hands.smooth = 100
        let out = HandEngine.apply(image, weights: weights, hands: hands)
        let nail = (30 * size.width + 30) * 4
        let back = (10 * size.width + 10) * 4
        XCTAssertEqual(out.pixels[nail], image.pixels[nail], "指甲被改 = 色域闸门没生效")
        XCTAssertNotEqual(out.pixels[back], image.pixels[back], "手背的抖动要被磨掉")
    }

    // MARK: - 4. 衣物祛褶

    func testGarmentWithoutStrokesIsNamedAndSkipped() {
        let size = PixelSize(width: 16, height: 16)
        var document = PipelineWiringDocument.make(size: size)
        document.params.garment.deWrinkle = 80
        XCTAssertTrue(document.pipelineWarnings.contains { $0.contains("[no_garment_region]") },
                      "没涂衣物区必须说出来，实际：\(document.pipelineWarnings)")
        let strokes = BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.1)
        document.brush.garments = [strokes]
        XCTAssertFalse(document.pipelineWarnings.contains { $0.contains("[no_garment_region]") },
                       "涂过了就不该再点名")
    }

    func testGarmentFlattensCreaseButKeepsWeave() {
        let size = PixelSize(width: 200, height: 200)
        // 布纹 = 2px 周期的小幅抖动；褶 = 4px 宽的一条暗带。两者幅度接近，
        // 只有频段不同 —— 这正是"直接糊"与"频分"能分开的唯一场合。
        func makeImage() -> DisplayImage {
            var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
            for y in 0 ..< size.height {
                for x in 0 ..< size.width {
                    let o = (y * size.width + x) * 4
                    let weave: Double = x % 2 == 0 ? 0.02 : -0.02
                    let crease: Double = (x >= 98 && x <= 101) ? -0.10 : 0
                    let v = 0.50 + weave + crease
                    pixels[o] = Float(v); pixels[o + 1] = Float(v * 0.95); pixels[o + 2] = Float(v * 0.9)
                    pixels[o + 3] = 1
                }
            }
            return DisplayImage(size: size, pixels: pixels)
        }
        let input = makeImage()
        let weights = [Float](repeating: 1, count: size.pixelCount)

        var garment = GarmentParameters()
        garment.deWrinkle = 100
        let out = GarmentEngine.apply(input, weights: weights, garment: garment)

        func luma(_ buffer: [Float], _ x: Int, _ y: Int) -> Double {
            let o = (y * size.width + x) * 4
            return Double(ColorMath.luma(buffer[o], buffer[o + 1], buffer[o + 2]))
        }
        let creaseBefore = luma(input.pixels, 100, 100), creaseAfter = luma(out.pixels, 100, 100)
        let flatLevel = luma(input.pixels, 60, 100)
        XCTAssertGreaterThan(creaseAfter, creaseBefore + 0.03, "褶子的暗带没被抬起来")

        // 布纹：相邻列之差。频分的关键就是它必须几乎不动。
        func weaveAmplitude(_ buffer: [Float]) -> Double {
            var sum = 0.0, n = 0
            for y in 20 ..< 180 {
                for x in stride(from: 20, to: 178, by: 3) {
                    if x >= 96 && x <= 104 { continue }        // 避开褶子那一小段
                    sum += abs(Double(buffer[(y * size.width + x) * 4] - buffer[(y * size.width + x + 1) * 4]))
                    n += 1
                }
            }
            return sum / Double(n)
        }
        let weaveBefore = weaveAmplitude(input.pixels), weaveAfter = weaveAmplitude(out.pixels)
        XCTAssertGreaterThan(weaveAfter, weaveBefore * 0.7, "布纹被一起抹平了 = 频段选错")
        XCTAssertLessThan(creaseAfter, flatLevel, "也不能把褶子抬到比周围还亮")
    }

    // MARK: - 5. 换天空

    private func skyImage(_ size: PixelSize) -> DisplayImage {
        // 上 30% 蓝（连到顶边）、中间一条深灰带、下面再来一块同样的蓝（不连顶边）、
        // 以及一条绿色带（颜色就不该算天）。
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        func row(_ y: Int, _ rgb: (Double, Double, Double)) {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                pixels[o] = Float(rgb.0); pixels[o + 1] = Float(rgb.1); pixels[o + 2] = Float(rgb.2)
                pixels[o + 3] = 1
            }
        }
        let sky: (Double, Double, Double) = (0.24, 0.47, 0.80)
        let wall: (Double, Double, Double) = (0.15, 0.16, 0.18)
        let grass: (Double, Double, Double) = (0.20, 0.55, 0.20)
        // 分段边界用显式 Double 换算：`Int * Double` 在这里推不出混型乘法，
        // 而 switch 里的部分区间写法又把同一个表达式报成 unary operator 错。
        let skyEnd = Int(Double(size.height) * 0.30)
        let wallEnd = Int(Double(size.height) * 0.55)
        let grassEnd = Int(Double(size.height) * 0.62)
        for y in 0 ..< size.height {
            if y < skyEnd { row(y, sky) }
            else if y < wallEnd { row(y, wall) }
            else if y < grassEnd { row(y, grass) }
            else { row(y, sky) }        // 与顶边不相连的同色蓝
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    func testSkyMaskGrowsFromTopEdgeOnly() {
        let size = PixelSize(width: 40, height: 60)
        let weights = SkyMask.build(skyImage(size))
        XCTAssertGreaterThan(weights[5 * size.width + 20], 0.9, "连到顶边的蓝算天空")
        XCTAssertLessThan(weights[45 * size.width + 20], 0.02, "被隔开的那块同色蓝不算天空")
        XCTAssertLessThan(weights[34 * size.width + 20], 0.5, "绿色带不是天，连通到这里就该断")
        XCTAssertEqual(weights.count, size.pixelCount)
    }

    func testSkyMaskRejectsCanvasThatIsAllSky() {
        let size = PixelSize(width: 20, height: 20)
        // 整幅都是蓝：这不是"天"，是一面墙/一张蓝布 —— 换掉会毁掉整张图。
        let weights = SkyMask.build(solid(size, 0.24, 0.47, 0.80))
        XCTAssertTrue(weights.allSatisfy { $0 == 0 }, "占比过高时宁可不做也不换整张图")
    }

    func testSkyGradientCompositeRespectsStrengthAndMask() {
        let size = PixelSize(width: 40, height: 60)
        let image = skyImage(size)
        let weights = SkyMask.build(image)
        var sky = SkyParameters()
        sky.enabled = true; sky.mode = .gradient; sky.lightMatch = 0
        // 天顶给纯蓝、地平线给纯红：两个方向都能单独看出来
        sky.topHex = 0x00_00FF; sky.horizonHex = 0xFF_00_00
        sky.strength = 0
        XCTAssertEqual(SkyEngine.apply(image, weights: weights, sky: sky, photo: nil).pixels, image.pixels,
                       "强度 0 必须恒等")
        sky.strength = 100
        let out = SkyEngine.apply(image, weights: weights, sky: sky, photo: nil)
        let top = 0
        XCTAssertLessThan(out.pixels[top * 4], image.pixels[top * 4], "顶行往天顶色靠：红被拉向 0")
        XCTAssertGreaterThan(out.pixels[top * 4 + 2], image.pixels[top * 4 + 2], "顶行蓝要上升")
        // 中间那条绿带不属于天 → 逐比特不动
        let grass = (34 * size.width + 20) * 4
        XCTAssertEqual(out.pixels[grass], image.pixels[grass], "天空区域外不得改一个比特")
    }

    func testSkyLightMatchKeepsLumaAndOnlyMovesSubjectChroma() {
        let size = PixelSize(width: 40, height: 60)
        let image = skyImage(size)
        let weights = SkyMask.build(image)
        var sky = SkyParameters()
        sky.enabled = true; sky.strength = 0; sky.lightMatch = 100
        sky.horizonHex = 0xFF_80_00
        let out = SkyEngine.apply(image, weights: weights, sky: sky, photo: nil)
        let subject = (34 * size.width + 20) * 4        // 绿带：不在天空区域里
        XCTAssertNotEqual(out.pixels[subject + 1], image.pixels[subject + 1], "主体色度要往新天光靠")
        let lumaBefore = Double(ColorMath.luma(image.pixels[subject], image.pixels[subject + 1], image.pixels[subject + 2]))
        let lumaAfter = Double(ColorMath.luma(out.pixels[subject], out.pixels[subject + 1], out.pixels[subject + 2]))
        XCTAssertEqual(lumaBefore, lumaAfter, accuracy: 2e-3, "光照匹配只改色度：亮度动就等于动了曝光")
        let skyIndex = (2 * size.width + 20) * 4        // 天空区不参与
        XCTAssertEqual(out.pixels[skyIndex], image.pixels[skyIndex], "天空自己不需要被匹配")
    }

    func testSkyAssetGatesReachTheDocumentAndExportCarriesThem() {
        let size = PixelSize(width: 16, height: 16)
        var document = PipelineWiringDocument.make(size: size) { params in
            params.sky.enabled = true
            params.sky.mode = .photo
            params.sky.sourceName = "dusk-ridge"
        }
        XCTAssertTrue(document.pipelineWarnings.contains { $0.contains("[no_sky_mask]") },
                      "没检测天空就要点名，实际：\(document.pipelineWarnings)")
        document.skyMask = MaskBuffer.filled(size, value: 255)
        XCTAssertTrue(document.pipelineWarnings.contains { $0.contains("[no_sky:dusk-ridge]") },
                      "导入的那张天读不出来时，要报 [no_sky:名字] 而不是悄悄用渐变，实际：\(document.pipelineWarnings)")
        let baseline = PipelineWiringDocument.make(size: size)
        XCTAssertEqual(document.render().pixels, baseline.render().pixels, "缺资产时整段必须不跑")
    }

    // MARK: - 6. 虚拟打光

    /// 中性灰的亮斑（右上）+ 大片平坦背景：亮度等于通道值，方便直接比。
    private func blobImage(_ size: PixelSize) -> DisplayImage {
        let sigma = 900.0 * (Double(size.longEdge) / 64.0) * (Double(size.longEdge) / 64.0)
        let cx = 0.72 * Double(size.width), cy = 0.22 * Double(size.height)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let v = 0.30 + 0.35 * exp(-(dx * dx + dy * dy) / sigma)
                let o = (y * size.width + x) * 4
                pixels[o] = Float(v); pixels[o + 1] = Float(v); pixels[o + 2] = Float(v)
                pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    func testRelightNeutralAndFlatAreBitExact() {
        let size = PixelSize(width: 64, height: 64)
        let image = blobImage(size)
        var light = LightParameters()
        light.intensity = 0
        XCTAssertEqual(RelightEngine.apply(image, light: light).pixels, image.pixels,
                       "光强 0 必须恒等（预览拖滑杆不能白跑一遍）")
        // 纯色画面没有任何朝光面：整段不动
        let flat = solid(size, 0.5, 0.5, 0.5)
        light.intensity = 100
        XCTAssertEqual(RelightEngine.apply(flat, light: light).pixels, flat.pixels,
                       "无结构可打时逐比特不动")
    }

    func testRelightOnlyAddsAndLeavesFlatGroundAlone() {
        let size = PixelSize(width: 64, height: 64)
        let image = blobImage(size)
        var light = LightParameters()
        light.intensity = 100; light.direction = 0; light.softness = 60
        light.spread = 0; light.warmth = 0
        let out = RelightEngine.apply(image, light: light)
        // 只加不减：加一盏灯不会让其它地方变暗（早期版本减均值就是这个错）。
        var darkest = 0.0
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            let delta = Double(out.pixels[o] - image.pixels[o])
            XCTAssertGreaterThanOrEqual(delta, -1e-6, "打光把像素压暗了")
            XCTAssertLessThanOrEqual(out.pixels[o], 1)
            darkest = Swift.min(darkest, delta)
        }
        XCTAssertEqual(darkest, 0, accuracy: 1e-6, "存在被压暗的像素 = 不再是在打光")
        let raised = (0 ..< size.pixelCount).filter {
            Double(out.pixels[$0 * 4] - image.pixels[$0 * 4]) > 0.01
        }
        XCTAssertGreaterThan(raised.count, 300, "没有一个区域被提亮 = 方向/半径不对")
        // 右下角的平坦背景不参与（镜像实测：逐比特不变）
        let corner = (58 * size.width + 58) * 4
        XCTAssertEqual(out.pixels[corner], image.pixels[corner], accuracy: 1e-6,
                       "局部平坦区不该被顺手压暗或提亮")
    }

    func testRelightDirectionChangesWhichSideFacesTheLight() {
        let size = PixelSize(width: 64, height: 64)
        let image = blobImage(size)
        var light = LightParameters()
        light.intensity = 100; light.softness = 60; light.spread = 0; light.warmth = 0
        func litCount(direction: Double) -> Int {
            light.direction = direction
            let buffer = RelightEngine.apply(image, light: light).pixels
            return (0 ..< size.pixelCount).filter { Double(buffer[$0 * 4] - image.pixels[$0 * 4]) > 0.01 }.count
        }
        let fromRight = litCount(direction: 0)
        let fromLeft = litCount(direction: 180)
        XCTAssertNotEqual(fromRight, fromLeft, "光方向反了结果却一样 = 方向没接进去")
        XCTAssertGreaterThan(fromRight, fromLeft, "亮斑在右上：从右边打光应当照到更多朝光面")
    }

    func testRelightStrengthIsResolutionIndependent() {
        // 同一张图在两个分辨率上采样：斜率与画幅成反比，乘回画幅后
        // "满力度最多加 0.25 亮度"必须在两个档上成立（否则预览与导出会不一样）。
        func peakRise(_ edge: Int) -> Double {
            let size = PixelSize(width: edge, height: edge)
            let image = blobImage(size)
            var light = LightParameters()
            light.intensity = 100; light.direction = 0; light.softness = 60
            light.spread = 0; light.warmth = 0
            let out = RelightEngine.apply(image, light: light)
            var peak = 0.0
            for i in 0 ..< size.pixelCount {
                peak = Swift.max(peak, Double(out.pixels[i * 4] - image.pixels[i * 4]))
            }
            return peak
        }
        let small = peakRise(64), large = peakRise(256)
        XCTAssertGreaterThan(small, 0.05, "没提亮任何东西")
        XCTAssertEqual(small, large, accuracy: 0.03,
                       "同一条滑杆在两个分辨率上力度不同：预览与导出会不一回事（\(small) vs \(large)）")
        XCTAssertLessThanOrEqual(small, 0.26, "上限没生效：会把脸打爆")
    }

    // MARK: - 7. 多帧堆栈

    func testStackOfIdenticalFramesIsBitExact() {
        let size = PixelSize(width: 48, height: 48)
        let frame = blobImage(size)
        let result = LongExposureEngine.stack([frame, frame, frame], mode: .average)
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.image.pixels, frame.pixels, "同样的图堆一起不该引入任何损耗")
        XCTAssertEqual(result.shifts.count, 3)
        XCTAssertEqual(result.shifts[1].width, 0, accuracy: 1e-9)
        XCTAssertTrue(LongExposureEngine.report(result).hasPrefix("[stack] 3 帧"))
        XCTAssertNil(LongExposureEngine.stack([frame], mode: .average), "少于 2 帧不做")
        XCTAssertNil(LongExposureEngine.stack([frame, blobImage(PixelSize(width: 30, height: 30))],
                                              mode: .average),
                     "尺寸不一致不静默重采样")
    }

    func testStackAlignsShiftedFramesByIntegerSearch() {
        let size = PixelSize(width: 64, height: 64)
        let base = blobImage(size)
        // 第二帧 = 内容整体右移 3px（回绕），所以对齐应当报 dx = −3。
        var shiftedPixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let source = (y * size.width + ((x - 3 + size.width) % size.width)) * 4
                let o = (y * size.width + x) * 4
                for c in 0 ..< 4 { shiftedPixels[o + c] = base.pixels[source + c] }
            }
        }
        let second = DisplayImage(size: size, pixels: shiftedPixels)
        let result = LongExposureEngine.stack([base, second], mode: .average)
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.shifts[1].width, -3, accuracy: 1e-9, "平移量必须被找回来（符号也要对）")
        // 对齐后堆出来的图应当接近底图；不对齐时（人为给一个错位移）差得多。
        func meanDifference(_ buffer: [Float]) -> Double {
            var sum = 0.0
            for y in 10 ..< 54 {
                for x in 10 ..< 54 {
                    let o = (y * size.width + x) * 4
                    sum += abs(Double(buffer[o] - base.pixels[o]))
                }
            }
            return sum / (44 * 44)
        }
        let aligned = meanDifference(result.image.pixels)
        XCTAssertLessThan(aligned, meanDifference(second.pixels) * 0.5,
                          "对齐没起作用：堆完仍然重影")
    }

    func testStackBrightestAndDarkestModesPickExtremes() {
        let size = PixelSize(width: 16, height: 16)
        let dim = solid(size, 0.2, 0.2, 0.2)
        let bright = solid(size, 0.8, 0.8, 0.8)
        let light = LongExposureEngine.stack([dim, bright], mode: .brightest)
        let dark = LongExposureEngine.stack([dim, bright], mode: .darkest)
        XCTAssertNotNil(light)
        XCTAssertNotNil(dark)
        XCTAssertEqual(light?.image.pixels[0] ?? 0, 0.8, accuracy: 1e-4, "取亮 = 保亮点（光轨/星轨）")
        XCTAssertEqual(dark?.image.pixels[0] ?? 0, 0.2, accuracy: 1e-4, "取暗 = 去路人（背景是暗的那一侧）")
        let mean = LongExposureEngine.stack([dim, bright], mode: .average)
        XCTAssertEqual(mean?.image.pixels[0] ?? 0, 0.5, accuracy: 1e-3, "平均在不动的地方就是均值")
    }

    // MARK: - 8. 联机拍摄的决策层

    /// 设备工厂。第二个形参不设标签，调用处写 `device("a", "external")`。
    private func device(_ id: String, _ kind: String, usable: Bool = true) -> TetheredDevice {
        TetheredDevice(id: id, name: "Cam-\(id)", kind: kind, isUsable: usable)
    }

    func testTetherDeviceRankingIsExternalFirstAndStable() {
        let devices = [device("b", "builtIn"), device("a", "external"),
                       device("c", "continuity"), device("d", "external", usable: false)]
        XCTAssertEqual(TetherPlan.ranked(devices).map(\.id), ["a", "c", "b", "d"])
        let picked = TetherPlan.pickDevice(from: devices, preferred: nil)
        XCTAssertEqual(picked?.0.id, "a", "默认拿外接那台")
        XCTAssertFalse(picked!.1, "没有指定就不算回落")
        let preferred = TetherPlan.pickDevice(from: devices, preferred: "b")
        XCTAssertEqual(preferred?.0.id, "b")
        XCTAssertFalse(preferred!.1)
        // 指定了但不可用 → 回落到首选，并且要标记"这是回落"
        let fallback = TetherPlan.pickDevice(from: devices, preferred: "d")
        XCTAssertEqual(fallback?.0.id, "a")
        XCTAssertTrue(fallback!.1, "回落必须被标出来，面板要说为什么换了一台")
        XCTAssertNil(TetherPlan.pickDevice(from: [device("x", "builtIn", usable: false)], preferred: nil))
    }

    func testTetherQueueCapsBurstAndNamesIt() {
        var settings = TetherSettings()
        settings.burstCount = 3
        settings.intervalSeconds = 0.5
        let queue = TetherPlan.queue(settings: settings)
        XCTAssertEqual(queue.shots.count, 3)
        XCTAssertEqual(queue.shots.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(queue.shots[0].waitSeconds, 0, "第一张不等")
        XCTAssertEqual(queue.shots[2].waitSeconds, 0.5, accuracy: 1e-9)
        XCTAssertTrue(queue.notes.isEmpty)

        settings.burstCount = 999
        let capped = TetherPlan.queue(settings: settings)
        XCTAssertEqual(capped.shots.count, TetherPlan.queueLimit)
        XCTAssertTrue(capped.notes.first?.contains("[burst_capped]") == true,
                      "截断必须点名，不能悄悄少拍：\(capped.notes)")

        settings.burstCount = -5
        XCTAssertEqual(TetherPlan.queue(settings: settings).shots.count, 1, "非法值夹回单拍")
    }

    func testTetherFileNamesAreOrderedAndCollisionFree() {
        XCTAssertEqual(TetherPlan.fileName(sequence: 1, stamp: "20261031-093000", ext: "jpg"),
                       "tether-20261031-093000-001.jpg")
        XCTAssertEqual(TetherPlan.fileName(sequence: 42, stamp: "20261031-093000", ext: "jpg"),
                       "tether-20261031-093000-042.jpg")
        let padded = (1 ... 30).map { TetherPlan.fileName(sequence: $0, stamp: "s", ext: "jpg") }
        XCTAssertEqual(Set(padded).count, 30, "同一秒内的连拍也不能撞名")
        XCTAssertEqual(padded.sorted(), padded, "序号补零后按字典序排就是拍摄顺序")
    }

    func testTetherMissingDevicesAreNamedPerCase() {
        XCTAssertTrue(TetherPlan.missingNote(devices: []).contains("[no_camera]"))
        let unusable = TetherPlan.missingNote(devices: [device("a", "external", usable: false)])
        XCTAssertTrue(unusable.contains("[no_camera_unusable]"))
        XCTAssertTrue(unusable.contains("entitlement"), "iPad 侧的原因要直接写在点名里：\(unusable)")
    }

    // MARK: - 9. 预设契约（新参数组）

    func testSceneParameterGroupsDefaultToOffAndSurviveRoundTrip() throws {
        let decoded = try JSONDecoder().decode(EditParameters.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(decoded.isSceneNeutral, "旧预设载入不能突然开始化妆/换天")
        XCTAssertEqual(decoded.light.spread, 50, "spread 的出厂值不是 0（它是中间档）")
        XCTAssertTrue(decoded.light.isNeutral, "但光强为 0 时整组仍算关")

        var params = EditParameters()
        params.makeup.styleID = "smokey"
        params.hair.shine = -40
        params.hand.redness = 25
        params.garment.deWrinkle = 60
        params.sky.enabled = true
        params.sky.topHex = 0x1234AB
        params.light.direction = 90
        params.light.intensity = 35
        let data = try JSONEncoder().encode(params)
        let back = try JSONDecoder().decode(EditParameters.self, from: data)
        XCTAssertEqual(back, params, "六组都要能原样回来")
        for key in ["makeup", "hair", "hand", "garment", "sky", "light"] {
            XCTAssertTrue(EditParameters.knownKeys.contains(key), "已知键集合漏了 \(key)")
        }

        // 越界值一律被夹住，不静默通过
        var wild = EditParameters()
        wild.light.intensity = 9_000
        wild.hair.shine = -400
        wild.sky.topHex = 0x1FF_0000
        wild.clamp()
        XCTAssertEqual(wild.light.intensity, 100)
        XCTAssertEqual(wild.hair.shine, -100)
        XCTAssertEqual(wild.sky.topHex, 0xFF_0000, "hex 只保留 24bit")
    }

    func testHexColorRoundTripIsExactForEveryChannelValue() {
        for channel in [0, 1, 128, 255] {
            let hex = UInt32(channel << 16 | channel << 8 | channel)
            let (r, g, b) = HexColor.rgb(hex)
            XCTAssertEqual(r, Double(channel) / 255, accuracy: 1e-12)
            let rgba = HexColor.toRGBA8(hex)
            XCTAssertEqual(rgba.r, UInt8(channel))
            XCTAssertEqual(rgba.g, UInt8(channel))
            XCTAssertEqual(rgba.b, UInt8(channel))
        }
    }

    // MARK: - 10. 参数同步（造型/场景归组）

    func testParamSyncRoutesMakeupHairHandGarmentAndLight() {
        var source = EditParameters()
        source.makeup.styleID = "korean"
        source.hair.tint = 30
        source.hand.smooth = 20
        source.garment.deWrinkle = 45
        source.light.intensity = 55
        source.sky.enabled = true
        source.sky.sourceName = "dusk"
        source.requires = ["lut: kodak", "sky:dusk"]

        let portrait = ParamSync.merge(source: source, into: EditParameters(), groups: [.skin, .shape])
        XCTAssertEqual(portrait.makeup.styleID, "korean")
        XCTAssertEqual(portrait.hair.tint, 30)
        XCTAssertEqual(portrait.hand.smooth, 20)
        XCTAssertEqual(portrait.garment.deWrinkle, 45, "祛褶力度跟美型同组")

        let style = ParamSync.merge(source: source, into: EditParameters(), groups: [.style])
        XCTAssertEqual(style.light.intensity, 55, "打光是画面观感，跟滤镜同组")
        XCTAssertFalse(style.sky.enabled, "换天空不参与同步：天空区域是逐张算的资产")
        XCTAssertEqual(style.requires, ["lut: kodak"], "天的依赖不跟着风格跑")
    }
}
