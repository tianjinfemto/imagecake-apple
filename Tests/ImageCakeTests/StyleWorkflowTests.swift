import CoreGraphics
import XCTest

@testable import ImageCake

/// 滤镜/镜头/证件照/参数同步/局部蒙版的离线断言。
///
/// 这一批的共性：全部是**确定性算术**（查表、径向映射、mm→像素、字段搬运），
/// 没有一项需要权重。断言钉的是"约定"——.cube 的枚举顺序、1D 表的逐通道语义、
/// 锚线以上不动、同步组只搬自己那一组——这些约定一旦漂移，成品上表现为
/// "红蓝串色""排版少一张""把液化也抄过去了"，都比报错更难查。
final class StyleWorkflowTests: XCTestCase {
    // MARK: - .cube 解析与采样

    private let cube2 = """
    # 测试表
    TITLE "tiny"
    LUT_3D_SIZE 2
    0 0 0
    0.5 0 0
    0 0.5 0
    0.5 0.5 0
    0 0 0.5
    0.5 0 0.5
    0 0.5 0.5
    1 1 1
    """

    func testCubeParsingFollowsRedFastestOrder() throws {
        let lut = try LUTParser.parse(cube2)
        XCTAssertEqual(lut.size, 2)
        XCTAssertTrue(lut.isValid)
        // 红最快、绿次之、蓝最慢：第二行是 (r=1,g=0,b=0)。
        let red = lut.sample(r: 1, g: 0, b: 0)
        XCTAssertEqual(red.r, 0.5, accuracy: 1e-6)
        XCTAssertEqual(red.g, 0, accuracy: 1e-6)
        XCTAssertEqual(red.b, 0, accuracy: 1e-6)
        let blue = lut.sample(r: 0, g: 0, b: 1)
        XCTAssertEqual(blue.b, 0.5, accuracy: 1e-6)
        XCTAssertEqual(blue.r, 0, accuracy: 1e-6)
        let white = lut.sample(r: 1, g: 1, b: 1)
        XCTAssertEqual(white.r, 1, accuracy: 1e-6)
    }

    func testCubeTrilinearMidpoint() throws {
        let lut = try LUTParser.parse(cube2)
        let mid = lut.sample(r: 0.5, g: 0, b: 0)
        XCTAssertEqual(mid.r, 0.25, accuracy: 1e-6, "节点之间线性内插")
        XCTAssertEqual(mid.g, 0, accuracy: 1e-6)
    }

    func testIdentityLUTIsTransparent() throws {
        // size 2 的恒等表就是八个角点自己。三线性插值对恒等表必须还原输入。
        let data: [Float] = [0, 0, 0,  1, 0, 0,  0, 1, 0,  1, 1, 0,
                             0, 0, 1,  1, 0, 1,  0, 1, 1,  1, 1, 1]
        let lut = CubeLUT(size: 2, data: data, is1D: false)
        let out = lut.sample(r: 0.4, g: 0.6, b: 0.2)
        XCTAssertEqual(out.r, 0.4, accuracy: 1e-6)
        XCTAssertEqual(out.g, 0.6, accuracy: 1e-6)
        XCTAssertEqual(out.b, 0.2, accuracy: 1e-6)
    }

    func testOneDimensionalLUTIsPerChannel() throws {
        let text = """
        LUT_1D_SIZE 2
        0 0 0
        0.5 0.5 0.5
        """
        let lut = try LUTParser.parse(text)
        XCTAssertTrue(lut.is1D)
        let out = lut.sample(r: 1, g: 0.5, b: 0)
        XCTAssertEqual(out.r, 0.5, accuracy: 1e-6)
        XCTAssertEqual(out.g, 0.25, accuracy: 1e-6)
        XCTAssertEqual(out.b, 0, accuracy: 1e-6)
    }

    func testCubeParsingRejectsBrokenTables() {
        XCTAssertThrowsError(try LUTParser.parse("0 0 0\n1 1 1"))
        XCTAssertThrowsError(try LUTParser.parse("LUT_3D_SIZE 2\n0 0 0\n1 1 1"))
        XCTAssertThrowsError(try LUTParser.parse("LUT_3D_SIZE 2\n0 0 0\n1 1 zzz"))
        XCTAssertThrowsError(try LUTParser.parse("DOMAIN_MIN 0.1 0.1 0.1\nLUT_3D_SIZE 2\n" +
                                                 String(repeating: "0 0 0\n", count: 8)))
    }

    func testSerializeRoundTrip() throws {
        let lut = try LUTParser.parse(cube2)
        let text = LUTParser.serialize(lut)
        let back = try LUTParser.parse(text)
        XCTAssertEqual(back.size, lut.size)
        XCTAssertEqual(back.data, lut.data)
    }

    // MARK: - 内置风格

    func testBuiltInStylesAreDeterministicAndBounded() {
        XCTAssertGreaterThanOrEqual(FilterEngine.styles.count, 8)
        for style in FilterEngine.styles {
            let first = FilterEngine.lut(for: style)
            let second = FilterEngine.lut(for: style)
            XCTAssertEqual(first.data, second.data, "同一 id 每次得到同一张表")
            XCTAssertTrue(first.data.allSatisfy { (0 ... 1).contains(Double($0)) }, "\(style.id) 有越界值")
        }
    }

    func testMonoStyleCollapsesChannels() {
        guard let mono = FilterEngine.style(id: "mono") else { return XCTFail("缺 mono 风格") }
        let lut = FilterEngine.lut(for: mono)
        let out = lut.sample(r: 0.8, g: 0.3, b: 0.2)
        XCTAssertEqual(out.r, out.g, accuracy: 1e-6)
        XCTAssertEqual(out.g, out.b, accuracy: 1e-6)
    }

    func testFilmStyleLiftsBlacksOnAllChannels() {
        guard let film = FilterEngine.style(id: "film") else { return XCTFail("缺 film 风格") }
        let lut = FilterEngine.lut(for: film)
        let black = lut.sample(r: 0, g: 0, b: 0)
        XCTAssertGreaterThan(black.r, 0.01, "抬黑必须三个通道同时成立，否则黑场偏色")
        XCTAssertGreaterThan(black.g, 0.01)
        XCTAssertGreaterThan(black.b, 0.01)
    }

    func testTealOrangePushesShadowsAndHighlightsOpposite() {
        guard let style = FilterEngine.style(id: "teal-orange") else { return XCTFail("缺青橙风格") }
        let lut = FilterEngine.lut(for: style)
        let shadow = lut.sample(r: 0.1, g: 0.1, b: 0.1)
        XCTAssertGreaterThan(shadow.b, shadow.r, "阴影偏青：蓝要压过红")
        let highlight = lut.sample(r: 0.95, g: 0.95, b: 0.95)
        XCTAssertGreaterThan(highlight.r, highlight.b, "高光偏暖：红要压过蓝")
    }

    func testFilterApplyZeroStrengthIsBitExact() throws {
        let image = TestImage.gradient(width: 8, height: 8)
        let lut = try LUTParser.parse(cube2)
        let result = FilterEngine.apply(image, lut: lut, strength: 0)
        XCTAssertEqual(result.pixels, image.pixels)
    }

    func testFilterResolveNamesUnknownStyleInsteadOfGuessing() {
        XCTAssertNotNil(FilterEngine.resolve(name: "mono"))
        XCTAssertNil(FilterEngine.resolve(name: "no-such-style"),
                     "找不到表要返回 nil，让调用侧点名 [no_lut:名字]")
        XCTAssertNil(FilterEngine.resolve(name: ""))
    }

    // MARK: - 镜头

    func testRadialMapsAreWellBehaved() {
        XCTAssertEqual(LensEngine.radiusMap(0, k: 0.3), 0, "中心不动是这条算子的定义之一")
        XCTAssertEqual(LensEngine.radiusMap(1, k: 0.3), 1.3, accuracy: 1e-12)
        let samples = stride(from: 0.0, through: 1.0, by: 0.05).map { LensEngine.radiusMap($0, k: 0.3) }
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0.0 <= $0.1 }, "径向映射必须单调")

        let center = LensEngine.caScale(0, amount: 0.2)
        XCTAssertEqual(center.red, 1, accuracy: 1e-12)
        XCTAssertEqual(center.blue, 1, accuracy: 1e-12)
        let edge = LensEngine.caScale(1, amount: 0.2)
        XCTAssertEqual(edge.red + edge.green + edge.blue, 3, accuracy: 1e-12, "等量反向：不改变整体缩放")
    }

    func testVignetteWeightBounds() {
        XCTAssertEqual(LensEngine.vignetteWeight(rho: 0, strength: 1, falloff: 2), 1, accuracy: 1e-12)
        XCTAssertEqual(LensEngine.vignetteWeight(rho: 1, strength: 1, falloff: 1), 0, accuracy: 1e-12)
        XCTAssertEqual(LensEngine.vignetteWeight(rho: 1, strength: 0, falloff: 2), 1, accuracy: 1e-12)
        let ramp = stride(from: 0.0, through: 1.0, by: 0.1).map { LensEngine.vignetteWeight(rho: $0, strength: 0.5, falloff: 2) }
        XCTAssertTrue(zip(ramp, ramp.dropFirst()).allSatisfy { $0.0 >= $0.1 }, "暗角必须从中心向外单调变暗")
    }

    func testGrainIsDeterministic() {
        XCTAssertEqual(LensEngine.hashNoise(x: 123, y: 456), LensEngine.hashNoise(x: 123, y: 456))
        XCTAssertNotEqual(LensEngine.hashNoise(x: 123, y: 456), LensEngine.hashNoise(x: 124, y: 456))
        let values = (0 ..< 200).map { LensEngine.hashNoise(x: $0, y: $0 * 7 + 3) }
        XCTAssertTrue(values.allSatisfy { abs($0) <= 1 })
        XCTAssertGreaterThan(Set(values.map { $0 > 0 }).count, 1, "噪声必须真的有正有负")
    }

    func testLensGeometryOnSolidImageIsTransparent() {
        let solid = TestImage.solid(width: 24, height: 16, r: 0.6, g: 0.5, b: 0.4)
        var lens = LensParameters()
        lens.distortion = 60
        lens.chromaticAberration = 40
        let result = LensEngine.applyGeometry(solid, lens: lens)
        XCTAssertEqual(result.pixels, solid.pixels, "纯色图上重新采样还是同一个颜色")

        var neutral = LensParameters()
        neutral.distortion = 0
        XCTAssertEqual(LensEngine.applyGeometry(solid, lens: neutral).pixels, solid.pixels)
    }

    func testVignetteDarkensCornersMoreThanCenter() {
        let image = TestImage.solid(width: 41, height: 41, r: 0.8, g: 0.8, b: 0.8)
        var lens = LensParameters()
        lens.vignette = 100
        let result = LensEngine.applyOverlay(image, lens: lens)
        let center = result.pixels[(20 * 41 + 20) * 4]
        let corner = result.pixels[(0 * 41 + 0) * 4]
        XCTAssertEqual(center, 0.8, accuracy: 1e-4, "中心不受暗角影响")
        XCTAssertLessThan(corner, center, "角落必须更暗")
    }

    func testGrainOverlayIsRepeatable() {
        let image = TestImage.solid(width: 32, height: 32, r: 0.5, g: 0.5, b: 0.5)
        var lens = LensParameters()
        lens.grain = 80
        let first = LensEngine.applyOverlay(image, lens: lens)
        let second = LensEngine.applyOverlay(image, lens: lens)
        XCTAssertEqual(first.pixels, second.pixels, "同参数两次结果逐比特一致（导出可比对）")
        XCTAssertNotEqual(first.pixels, image.pixels)
    }

    // MARK: - 证件照

    func testMillimetreToPixelConversion() {
        XCTAssertEqual(IDPhoto.pixels(mm: 25), 295)
        XCTAssertEqual(IDPhoto.pixels(mm: 35), 413)
        let one = IDPhoto.spec(id: "one")
        XCTAssertNotNil(one)
        XCTAssertEqual(one?.pixelSize.width, 295)
        XCTAssertEqual(one?.pixelSize.height, 413)
        if let one { XCTAssertEqual(one.aspect, 25.0 / 35.0, accuracy: 1e-9) }
    }

    func testSuggestedCropKeepsAspectAndHeadRatio() {
        let canvas = PixelSize(width: 1200, height: 1600)
        guard let spec = IDPhoto.spec(id: "one") else { return XCTFail("缺一寸规格") }
        let head = PixelRect(x: 500, y: 200, width: 200, height: 300)
        let rect = IDPhoto.suggestedCrop(canvas: canvas, spec: spec, headBox: head)
        XCTAssertEqual(rect.width / rect.height, Double(spec.aspect), accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 1)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxY, 1)
        let frameHeightPixels = rect.height * CGFloat(canvas.height)
        XCTAssertEqual(head.height / Double(frameHeightPixels), spec.headRatio, accuracy: 0.02)
        // 头顶留白约 8%：框顶要在头顶之上一点。
        XCTAssertLessThan(rect.minY * CGFloat(canvas.height), CGFloat(head.y))
    }

    func testSuggestedCropWithoutHeadBoxCentersByAspect() {
        let canvas = PixelSize(width: 1000, height: 1000)
        guard let spec = IDPhoto.spec(id: "visa-us") else { return XCTFail("缺美签规格") }
        let rect = IDPhoto.suggestedCrop(canvas: canvas, spec: spec, headBox: nil)
        XCTAssertEqual(rect.width / rect.height, spec.aspect, accuracy: 0.01)
        XCTAssertEqual(rect.midX, 0.5, accuracy: 1e-6, "没有头部信息就只能居中，而且要居中得对称")
        XCTAssertEqual(rect.midY, 0.5, accuracy: 1e-6)
    }

    func testSheetSlotsFitAndDoNotOverlap() {
        guard let spec = IDPhoto.spec(id: "one"), let paper = IDPhoto.paper(id: "6inch") else {
            return XCTFail("缺规格")
        }
        let sheet = IDPhoto.sheet(spec: spec, paper: paper)
        XCTAssertGreaterThan(sheet.count, 0)
        XCTAssertEqual(sheet.canvas, paper.pixelSize)
        for slot in sheet.slots {
            XCTAssertEqual(slot.size, spec.pixelSize, "每个槽位都是冲印尺寸")
            XCTAssertTrue(slot.maxX <= sheet.canvas.width && slot.maxY <= sheet.canvas.height,
                          "槽位越界会把照片切到画布外")
        }
        for (i, a) in sheet.slots.enumerated() {
            for b in sheet.slots.dropFirst(i + 1) {
                XCTAssertTrue(a.intersected(with: b).isEmpty, "槽位重叠会把两张脸叠在一起")
            }
        }
    }

    func testLayoutPlacesPhotoInEverySlot() {
        guard let spec = IDPhoto.spec(id: "one"), let paper = IDPhoto.paper(id: "5inch") else {
            return XCTFail("缺规格")
        }
        let sheet = IDPhoto.sheet(spec: spec, paper: paper)
        XCTAssertGreaterThan(sheet.count, 0, "5 寸相纸必须能排下一寸")
        guard let slot = sheet.slots.first else { return XCTFail("没有槽位") }
        let photo = TestImage.solidRGBA8(width: spec.pixelSize.width, height: spec.pixelSize.height,
                                          r: 200, g: 30, b: 30)
        let result = IDPhoto.layout(photo, sheet: sheet)
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.size, sheet.canvas)
        let centerY = slot.y + slot.height / 2
        let centerX = slot.x + slot.width / 2
        let inside = centerY * sheet.canvas.width + centerX
        XCTAssertEqual(result.data[inside * 4], 200, "槽位中心是照片")
        XCTAssertEqual(result.data[0], 255, "页边距是白底")
    }

    func testLayoutGivesNilWhenPaperTooSmall() {
        let spec = IDPhotoSpec(id: "big", title: "巨大", widthMM: 200, heightMM: 300, headRatio: 0.6, background: nil)
        let paper = PaperSpec(id: "tiny", title: "邮票", widthMM: 30, heightMM: 40)
        let sheet = IDPhoto.sheet(spec: spec, paper: paper)
        XCTAssertEqual(sheet.count, 0)
        XCTAssertNil(IDPhoto.layout(TestImage.solidRGBA8(width: 10, height: 10, r: 1, g: 1, b: 1), sheet: sheet))
    }

    // MARK: - 参数同步

    func testSyncCopiesOnlySelectedGroups() {
        var source = EditParameters()
        source.exposure = 1.5
        source.beauty.skinSmooth = 20
        source.beauty.slimFace = 30
        source.filter.style = "film"
        source.lens.grain = 40
        source.faceRestore = 60
        source.requires = ["lut:film", "sky:sunset"]

        var target = EditParameters()
        target.beauty.skinSmooth = 70
        target.exposure = -0.5

        let toneOnly = ParamSync.merge(source: source, into: target, groups: [.tone])
        XCTAssertEqual(toneOnly.exposure, 1.5, accuracy: 1e-9)
        XCTAssertEqual(toneOnly.beauty.skinSmooth, 70, "只勾调色时美肤力度必须保持原值")
        XCTAssertEqual(toneOnly.filter.style, "")
        XCTAssertEqual(toneOnly.faceRestore, 0, "交付端没勾就不该抄过去")

        let skinOnly = ParamSync.merge(source: source, into: target, groups: [.skin])
        XCTAssertEqual(skinOnly.beauty.skinSmooth, 20, accuracy: 1e-9)
        XCTAssertEqual(skinOnly.beauty.slimFace, 0, accuracy: 1e-9, "美肤 ≠ 美型，两组分家")
        XCTAssertEqual(skinOnly.exposure, -0.5, accuracy: 1e-9)

        let style = ParamSync.merge(source: source, into: target, groups: [.style])
        XCTAssertEqual(style.filter.style, "film")
        XCTAssertEqual(style.lens.grain, 40, accuracy: 1e-9)
        XCTAssertEqual(style.requires, ["lut:film"], "依赖只登记滤镜表，别的资产类型不跟着搬")

        let recommended = ParamSync.merge(source: source, into: target, groups: .default)
        XCTAssertEqual(recommended.faceRestore, 0, "默认不同步交付端（逐张耗时项要用户自己开）")
        XCTAssertNotEqual(recommended.exposure, -0.5)
    }

    func testBatchConfigAppliesGroupsToFreshDocuments() {
        var params = EditParameters()
        params.exposure = 0.7
        params.beauty.whitening = 50
        let config = BatchConfig(params: params, format: .png8,
                                 outputDirectory: URL(fileURLWithPath: "/tmp"), groups: [.tone])
        XCTAssertEqual(config.effectiveParams.exposure, 0.7, accuracy: 1e-9)
        XCTAssertEqual(config.effectiveParams.beauty.whitening, 0, accuracy: 1e-9)
        let all = BatchConfig(params: params, format: .png8,
                              outputDirectory: URL(fileURLWithPath: "/tmp"), groups: nil)
        XCTAssertEqual(all.effectiveParams.beauty.whitening, 50, accuracy: 1e-9, "nil = 全同步")
    }

    // MARK: - 局部蒙版三形状

    func testRadialMaskIsRoundAndBounded() {
        let size = PixelSize(width: 41, height: 41)
        let mask = LocalMask.rasterize(.radial(center: CGPoint(x: 0.5, y: 0.5), radius: 0.25), size: size)
        XCTAssertEqual(Int(mask.data[20 * 41 + 20]), 255, "中心满")
        XCTAssertEqual(Int(mask.data[20 * 41 + 40]), 0, "边缘外为 0")
        // smoothstep 落边让"有效面积"比硬圆盘小，这里只钉住量级：
        // 真正的精度要求在 RegionRaster 自己的单调断言里。
        XCTAssertGreaterThan(mask.coveredCount, 150)
    }

    func testLinearMaskRampsAlongItsAxis() {
        let size = PixelSize(width: 100, height: 100)
        let mask = LocalMask.rasterize(.linear(from: CGPoint(x: 0.2, y: 0.5),
                                               to: CGPoint(x: 0.8, y: 0.5), width: 0.2), size: size)
        let warm = Int(mask.data[50 * 100 + 75])
        let cold = Int(mask.data[50 * 100 + 25])
        XCTAssertGreaterThan(warm, cold, "坡道从 from 处 0 涨到 to 处 1")
        XCTAssertEqual(Int(mask.data[90 * 100 + 50]), 0, "条带半宽之外必须为 0")
    }

    func testStrokeLocalAdjustmentStillCompilesWithLegacyInit() {
        let stroke = BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.1)
        let adjustment = LocalAdjustment(mask: stroke)
        XCTAssertTrue(adjustment.isNeutral)
        if case .stroke(let fromStroke) = adjustment.mask {
            XCTAssertEqual(fromStroke.points.count, 1)
        } else {
            XCTFail("便捷 init 应该把 BrushStroke 包成 .stroke")
        }
    }

    // MARK: - 预设契约（新增三组键）

    func testPresetRoundTripCarriesBeautyFilterLens() throws {
        var params = EditParameters()
        params.beauty.skinSmooth = 40
        params.beauty.smoothMode = 1
        params.beauty.slimFace = -20
        params.filter.style = "teal-orange"
        params.filter.strength = 65
        params.lens.vignette = 30
        params.lens.vignetteFalloff = 2.5
        params.presetVersion = 12

        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["beauty"])
        XCTAssertNotNil(json?["filter"])
        XCTAssertNotNil(json?["lens"])
        XCTAssertEqual(json?["preset_version"] as? Int, 12)

        let back = try JSONDecoder().decode(EditParameters.self, from: data)
        XCTAssertEqual(back, params, "三组嵌套键必须完整往返")
        XCTAssertFalse(back.isNeutral)
    }

    func testNewKeysAreDeclaredKnown() {
        for key in ["beauty", "filter", "lens"] {
            XCTAssertTrue(EditParameters.knownKeys.contains(key), "\(key) 没进已知键集合，会被自家报告当成未知键")
        }
    }

    func testMissingGroupsFallBackToFactoryDefaults() throws {
        // 旧版（或 imagecake）的预设没有这三组：读进来必须是"全关"，
        // 而不是让 clamp() 之外的随机值溜进来。
        let json = #"{"exposure": 0.5, "preset_version": 37}"#
        let params = try JSONDecoder().decode(EditParameters.self, from: Data(json.utf8))
        XCTAssertTrue(params.beauty.isNeutral)
        XCTAssertTrue(params.filter.isNeutral)
        XCTAssertTrue(params.lens.isNeutral)
        XCTAssertEqual(params.exposure, 0.5, accuracy: 1e-9)
    }

    func testClampConvergesOutOfRangeValues() throws {
        let json = """
        {"beauty": {"skin_smooth": 900, "smooth_mode": 7, "slim_face": -900},
         "lens": {"vignette": 500, "vignette_falloff": 99},
         "filter": {"strength": -30}}
        """
        let params = try JSONDecoder().decode(EditParameters.self, from: Data(json.utf8))
        XCTAssertEqual(params.beauty.skinSmooth, 100, accuracy: 1e-9)
        XCTAssertEqual(params.beauty.smoothMode, 0, "模式只认 0/1，其余落出厂")
        XCTAssertEqual(params.beauty.slimFace, -100, accuracy: 1e-9)
        XCTAssertEqual(params.lens.vignette, 100, accuracy: 1e-9)
        XCTAssertEqual(params.lens.vignetteFalloff, 10, accuracy: 1e-9)
        XCTAssertEqual(params.filter.strength, 0, accuracy: 1e-9)
    }
}
