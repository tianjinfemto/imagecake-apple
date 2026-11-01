import CoreGraphics
import XCTest

@testable import ImageCake

/// P0-b 的断言：眼镜祛反光、换发色、祛碎发。
///
/// 三条铁律贯穿本文件：
///   · **先向被测函数要落点再下笔**——镜片区的眩光位置由 `lensWeights` 的
///     argmax 决定，不硬写坐标（上一轮硬写像素坐标错过两次）；
///   · **方向性断言**（只降不升 / 只动色度不动亮度）比数值断言更值钱，
///     因为它们正好是这三个算子的失败模式；
///   · **区域外逐比特不变**，且每条"不变"都配一条"区域内确实变了"，
///     免得整段没跑也绿。

final class RetouchExtrasTests: XCTestCase {
    private var face: FaceGeometry? {
        FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())
    }

    private func solid(_ size: PixelSize, _ r: Double, _ g: Double, _ b: Double) -> DisplayImage {
        TestImage.solid(width: size.width, height: size.height, r: r, g: g, b: b)
    }

    private func lumaOf(_ pixels: [Float], _ index: Int) -> Double {
        let o = index * 4
        return Double(ColorMath.luma(pixels[o], pixels[o + 1], pixels[o + 2]))
    }

    private func chromaOf(_ pixels: [Float], _ index: Int) -> (Double, Double) {
        let o = index * 4
        let axis = BeautyEngine.opponent(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
        return (axis.a, axis.b)
    }

    private func argmax(_ values: [Float]) -> Int {
        var best = 0
        for (i, v) in values.enumerated() where v > values[best] { best = i }
        return best
    }

    // MARK: - 1. 镜片区域

    func testLensWeightsCentreOnTheEyesAndLeaveChinEmpty() {
        let size = PixelSize(width: 100, height: 100)
        guard let geometry = face else { XCTFail("合成脸派生不出几何"); return }
        let weights = RegionEnhance.lensWeights(geometry, size: size)
        XCTAssertEqual(weights.count, size.pixelCount)
        let peak = argmax(weights)
        XCTAssertGreaterThan(weights[peak], 0.5, "镜片区必须有实权重（拿不到就是眼圈环或放大比例错了）")
        let peakRow = Double(peak / size.width), peakCol = Double(peak % size.width)
        let iris = geometry.irisCenters.first!
        // 镜片区包住虹膜：峰值落在同一片镜圈内，而不是一路滑到额头或下巴。
        XCTAssertEqual(peakCol / Double(size.width), Double(iris.x), accuracy: 0.12,
                       "镜片区横向应以眼睛为中心")
        XCTAssertLessThan(peakRow / Double(size.height), Double(iris.y) + 0.05,
                          "镜片区应主要压在眼睛上方，不是压到脸颊")
        // 下巴那个位置（0.72 高）不许被算进镜片
        let chin = Int(0.72 * Double(size.height)) * size.width + Int(0.5 * Double(size.width))
        XCTAssertEqual(weights[chin], 0, "下巴被圈进镜片区 = 外接框放大过头")
    }

    // MARK: - 2. 眼镜祛反光

    /// 在镜片区核心涂一块低饱和亮班当眩光，跑算子。
    private func glareFixture(_ size: PixelSize, geometry: FaceGeometry)
        -> (image: DisplayImage, weights: [Float], glare: [Int], red: Int, dark: Int) {
        let weights = RegionEnhance.lensWeights(geometry, size: size)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            pixels[i * 4] = 0.70; pixels[i * 4 + 1] = 0.55; pixels[i * 4 + 2] = 0.45; pixels[i * 4 + 3] = 1
        }
        func paint(_ centre: Int, _ r: Double, _ g: Double, _ b: Double, half: Int) {
            let cx = centre % size.width, cy = centre / size.width
            for dy in -half ... half {
                for dx in -half ... half {
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < size.width, y >= 0, y < size.height else { continue }
                    let o = (y * size.width + x) * 4
                    pixels[o] = Float(r); pixels[o + 1] = Float(g); pixels[o + 2] = Float(b)
                }
            }
        }
        let core = argmax(weights)
        // 眩光：亮 + 低饱和（镜像确认这类像素会触发）。
        paint(core, 0.88, 0.90, 0.92, half: 3)
        var glare: [Int] = []
        for i in 0 ..< size.pixelCount where weights[i] > 0.7 {
            let l = Double(ColorMath.luma(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]))
            if l > 0.8 { glare.append(i) }
        }
        // 同一片镜圈里放一块高饱和红（假想彩色镜片/唇），以及一块暗像素。
        let redCandidate = core &+ (size.width * 2)
        paint(redCandidate, 0.75, 0.10, 0.12, half: 1)
        let darkCandidate = core &- (size.width * 2)
        paint(darkCandidate, 0.16, 0.12, 0.10, half: 1)
        return (DisplayImage(size: size, pixels: pixels), weights, glare, redCandidate, darkCandidate)
    }

    func testAntiGlareReducesOnlyTheBrightLowSaturationPatch() {
        let size = PixelSize(width: 100, height: 100)
        guard let geometry = face else { XCTFail("合成脸派生不出几何"); return }
        let fixture = glareFixture(size, geometry: geometry)
        XCTAssertFalse(fixture.glare.isEmpty, "夹具里镜片区必须真有眩光像素，否则下面的断言是空的")

        var beauty = BeautyParameters()
        beauty.antiGlare = 100
        var pixels = fixture.image.pixels
        RegionEnhance.antiGlarePass(&pixels, size: size, geometries: [geometry],
                                   amount: BeautyParameters.unit(beauty.antiGlare))

        var reduced = 0
        for i in fixture.glare where lumaOf(pixels, i) < lumaOf(fixture.image.pixels, i) - 0.02 {
            reduced += 1
        }
        XCTAssertGreaterThan(reduced, max(1, fixture.glare.count / 3),
                             "眩光至少要被压掉三分之一，实际压了 \(reduced)/\(fixture.glare.count)")

        // 高饱和那块（彩色镜片/唇）不许被当成反光压掉。
        XCTAssertEqual(lumaOf(pixels, fixture.red), lumaOf(fixture.image.pixels, fixture.red), accuracy: 1e-6,
                       "饱和色不是反光")
        // 暗部也不是反光：没有亮度门就会把暗噪点当眩光。
        XCTAssertEqual(lumaOf(pixels, fixture.dark), lumaOf(fixture.image.pixels, fixture.dark), accuracy: 1e-6,
                       "暗像素不该被动")

        // 区域外逐比特不变。
        var outsideUntouched = true
        for i in 0 ..< size.pixelCount where weightsZero(fixture.weights[i]) {
            for c in 0 ..< 3 where pixels[i * 4 + c] != fixture.image.pixels[i * 4 + c] { outsideUntouched = false }
        }
        XCTAssertTrue(outsideUntouched, "镜片区外不得改一个比特")
    }

    private func weightsZero(_ v: Float) -> Bool { v == 0 }

    func testAntiGlareNeverBrightensAndKeepsAFloor() {
        let size = PixelSize(width: 100, height: 100)
        guard let geometry = face else { XCTFail(); return }
        let fixture = glareFixture(size, geometry: geometry)
        var pixels = fixture.image.pixels
        RegionEnhance.antiGlarePass(&pixels, size: size, geometries: [geometry], amount: 1.0)

        // 只降不升：任何像素的亮度都不许高于原图。
        var brightened = 0
        for i in 0 ..< size.pixelCount where lumaOf(pixels, i) > lumaOf(fixture.image.pixels, i) + 1e-6 {
            brightened += 1
        }
        XCTAssertEqual(brightened, 0, "祛反光把像素变亮了就是在加光不是在减眩光")

        // 而且不能压成洞：反光的下限是"不低于邻域低频"（fire 过的像素 L' ≥ base+0.06，
        // 没 fire 的逐比特不动）。拿 min(L, base) 当全局下限，两条都能包到。
        let base = BeautyEngine.blurredChannel(RegionEnhance.lumaChannel(fixture.image.pixels, size: size),
                                               size: size, radius: 8)
        var belowFloor = 0
        for i in 0 ..< size.pixelCount {
            let floor = Swift.min(lumaOf(fixture.image.pixels, i), Double(base[i]))
            if lumaOf(pixels, i) < floor - 1e-6 { belowFloor += 1 }
        }
        XCTAssertEqual(belowFloor, 0, "眩光被压穿就成了比周围还暗的洞")
    }

    func testAntiGlareIsNeutralWhenZero() {
        let size = PixelSize(width: 40, height: 40)
        let image = solid(size, 0.70, 0.55, 0.45)
        XCTAssertTrue(BeautyParameters().isRegionNeutral, "出厂值必须算中性，否则渲染链白跑")
        var beauty = BeautyParameters()
        beauty.antiGlare = 0
        XCTAssertEqual(RegionEnhance.apply(image, geometries: [], beauty: beauty).pixels, image.pixels)
    }

    // MARK: - 3. 换发色

    private func hairWeights(_ size: PixelSize, interior: Int, band: Int) -> [Float] {
        var weights = [Float](repeating: 0, count: size.pixelCount)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                // 左半当发团内部，中间一条当环带，右半当区外。
                if x < interior { weights[y * size.width + x] = 1 }
                else if x < band { weights[y * size.width + x] = 0.5 }
            }
        }
        return weights
    }

    func testHairRecolorKeepsLumaAndOnlyTouchesHairArea() {
        let size = PixelSize(width: 60, height: 20)
        let image = solid(size, 0.25, 0.15, 0.10)          // 深棕发
        var weights = [Float](repeating: 0, count: size.pixelCount)
        for i in 0 ..< size.pixelCount { weights[i] = (i % size.width) < 30 ? 1 : 0 }
        var pixels = image.pixels
        HairEngine.recolor(&pixels, size: size, weights: weights, amount: 1.0, hex: 0x63_1F_30) // 酒红

        let inside = 5, outside = 45
        XCTAssertNotEqual(chromaOf(pixels, inside).0, chromaOf(image.pixels, inside).0,
                          "发区内色度必须往目标色靠")
        XCTAssertEqual(lumaOf(pixels, inside), lumaOf(image.pixels, inside), accuracy: 2e-3,
                       "换发色不动亮度：动了就没体积了")
        for c in 0 ..< 4 {
            XCTAssertEqual(pixels[outside * 4 + c], image.pixels[outside * 4 + c],
                           "发区外不得改一个比特")
        }
    }

    func testHairRecolorCapsTheChromaShift() {
        let size = PixelSize(width: 8, height: 8)
        let image = solid(size, 0.72, 0.62, 0.48)          // 浅亚麻
        var pixels = image.pixels
        let weights = [Float](repeating: 1, count: size.pixelCount)
        // 蓝黑目标与浅亚麻的 B 轴差得比 maxShift 还远，正好用来钉上限。
        HairEngine.recolor(&pixels, size: size, weights: weights, amount: 1.0, hex: 0x2C_33_42)
        let before = chromaOf(image.pixels, 0), after = chromaOf(pixels, 0)
        XCTAssertLessThanOrEqual(abs(after.1 - before.1), 0.22 + 1e-9,
                                 "B 轴位移被 maxShift 锁住：目标色再进也不许推到不属于头发的颜色")
        XCTAssertGreaterThan(abs(after.1 - before.1), 0.15,
                             "但这条上限必须真的撞到，否则上面那条是空的")
    }

    func testHairExtrasAreWiredIntoTheGate() {
        let size = PixelSize(width: 32, height: 32)
        let image = solid(size, 0.30, 0.22, 0.18)
        let weights = [Float](repeating: 1, count: size.pixelCount)

        XCTAssertTrue(HairParameters().isNeutral, "出厂（含新三项）必须是中性")
        var colourOnly = HairParameters()
        colourOnly.colorStrength = 60
        colourOnly.colorHex = 0x9E_4B_2A
        XCTAssertFalse(colourOnly.isNeutral, "只开换发色也要算生效，否则渲染链整段跳过")
        let out = HairEngine.apply(image, weights: weights, hair: colourOnly)
        XCTAssertNotEqual(out.pixels, image.pixels, "闸门开了算子就必须真的跑")

        var tameOnly = HairParameters()
        tameOnly.tame = 100
        XCTAssertFalse(tameOnly.isNeutral, "只开祛碎发也要算生效")

        var zero = HairParameters()
        zero.colorStrength = 0
        zero.tame = 0
        XCTAssertEqual(HairEngine.apply(image, weights: weights, hair: zero).pixels, image.pixels,
                       "新两项为 0 时逐比特原图")
    }

    // MARK: - 4. 祛碎发

    func testTameFlyawaysOnlyTouchesTheBandAndOnlyDarkens() {
        let size = PixelSize(width: 60, height: 20)
        // 背景中灰，一条"碎发"横贯三处：内部、环带、区外。
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                pixels[o] = 0.30; pixels[o + 1] = 0.31; pixels[o + 2] = 0.32; pixels[o + 3] = 1
            }
        }
        for x in 0 ..< size.width {
            let o = (10 * size.width + x) * 4        // 亮丝行
            pixels[o] = 0.86; pixels[o + 1] = 0.88; pixels[o + 2] = 0.90
        }
        let weights = hairWeights(size, interior: 20, band: 40)
        var out = pixels
        HairEngine.tameFlyaways(&out, size: size, weights: weights, amount: 1.0)

        let inInterior = 10 * size.width + 5      // 权重 1 → 三角窗为 0
        let inBand = 10 * size.width + 25         // 权重 0.5 → 三角窗为 1
        let outside = 10 * size.width + 50        // 权重 0 → 三角窗为 0
        XCTAssertLessThan(lumaOf(out, inBand), lumaOf(pixels, inBand), "环带上的亮碎丝要被压下去")
        XCTAssertEqual(lumaOf(out, inInterior), lumaOf(pixels, inInterior), accuracy: 1e-6,
                       "发团内部不许动：动了就是把头发啃薄一圈")
        for c in 0 ..< 4 {
            XCTAssertEqual(out[outside * 4 + c], pixels[outside * 4 + c],
                           "区外（背景）不许动")
            XCTAssertEqual(out[inInterior * 4 + c], pixels[inInterior * 4 + c],
                           "发团内部逐比特不变")
        }
        // 只降不升。
        var brightened = 0
        for i in 0 ..< size.pixelCount where lumaOf(out, i) > lumaOf(pixels, i) + 1e-6 { brightened += 1 }
        XCTAssertEqual(brightened, 0, "祛碎发把碎发顶亮就是反向失败")
    }

    func testTameIgnoresStrandsThatAreNotBrighterThanNeighbourhood() {
        let size = PixelSize(width: 20, height: 20)
        let image = solid(size, 0.50, 0.50, 0.50)          // 均匀灰，没有"亮于邻域"的丝
        let weights = [Float](repeating: 0.5, count: size.pixelCount)
        var out = image.pixels
        HairEngine.tameFlyaways(&out, size: size, weights: weights, amount: 1.0)
        XCTAssertEqual(out, image.pixels, "不比邻域亮的像素不该被动（否则整片边缘被糊掉）")
    }

    // MARK: - 5. 预设与同步契约

    func testNewFieldsSurvivePresetRoundTripAndOldFilesDefaultOff() throws {
        let legacy = try JSONDecoder().decode(EditParameters.self,
                                              from: #"{"exposure":0.5,"beauty":{"lip_color":30}}"#.data(using: .utf8)!)
        XCTAssertEqual(legacy.beauty.antiGlare, 0, accuracy: 1e-9, "旧预设没有祛反光，必须落关")
        XCTAssertEqual(legacy.hair.colorStrength, 0, accuracy: 1e-9, "旧预设没有换发色，必须落关")
        XCTAssertEqual(legacy.hair.tame, 0, accuracy: 1e-9)
        XCTAssertEqual(legacy.hair.colorHex, 0x6B_4A_34, "目标色落出厂默认而不是 0（0 是纯黑）")

        var params = EditParameters()
        params.beauty.antiGlare = 55
        params.hair.colorStrength = 40
        params.hair.colorHex = 0x2C_33_42
        params.hair.tame = 70
        let json = try JSONEncoder().encode(params)
        let back = try JSONDecoder().decode(EditParameters.self, from: json)
        XCTAssertEqual(back.beauty, params.beauty, "祛反光一个字段走得完往返")
        XCTAssertEqual(back.hair, params.hair, "头发新增三项都要走得完往返")
        let text = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("anti_glare") && text.contains("color_strength") && text.contains("tame"),
                      "键名必须是 snake_case 且新键都要写出去：\(text.prefix(200))")
    }

    func testParamSyncSkinGroupCarriesTheNewRetouchItems() {
        var source = EditParameters()
        source.beauty.antiGlare = 60
        source.hair.colorStrength = 35
        source.hair.tame = 80
        let merged = ParamSync.merge(source: source, into: EditParameters(), groups: [.skin])
        XCTAssertEqual(merged.beauty.antiGlare, 60, accuracy: 1e-9, "祛反光要跟着美肤同步")
        XCTAssertEqual(merged.hair.colorStrength, 35, accuracy: 1e-9, "换发色要跟着美肤同步")
        XCTAssertEqual(merged.hair.tame, 80, accuracy: 1e-9)
        let none = ParamSync.merge(source: source, into: EditParameters(), groups: [.tone])
        XCTAssertEqual(none.beauty.antiGlare, 0, accuracy: 1e-9, "只勾调色不该把人像项带过去")
    }
}
