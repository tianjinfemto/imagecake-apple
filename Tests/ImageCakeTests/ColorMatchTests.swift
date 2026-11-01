import CoreGraphics
import XCTest

@testable import ImageCake

/// 追色（样片对齐）的断言。
///
/// 这批全部是**关系型/恒等型**断言，不抄我自己推导的像素数值：
/// "追完之后离参考更近了"、"强度 0 逐比特不动"、"平坦通道的增益锁在 1"、
/// "保护皮肤只减色度位移不减亮度位移"。这些命题即使统计量算错也仍然成立地
/// 指向同一处实现，而抄数字的断言只会把实现钉死在某个错误上。
///
/// 数值口径来自 Python 镜像（同一组常量与同一套对立色往返）跑出的实测：
/// 暖客片(0.62,0.46,0.36)+抖动 → 冷样片(0.44,0.52,0.58)：A 轴均值距离
/// 0.2396 → 0，B 轴 0.2798 → 0，强度 0/30/100 的平均位移 0 / 0.138 / 0.459。

final class ColorMatchTests: XCTestCase {
    private func flat(_ size: PixelSize, _ r: Double, _ g: Double, _ b: Double) -> DisplayImage {
        TestImage.solid(width: size.width, height: size.height, r: r, g: g, b: b)
    }

    /// 两色棋盘。用它而不是渐变：标准差可控且逐比特可复现。
    private func checker(_ size: PixelSize, _ a: (Double, Double, Double),
                         _ b: (Double, Double, Double)) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let c = ((x + y) % 2 == 0) ? a : b
                let o = (y * size.width + x) * 4
                pixels[o] = Float(c.0); pixels[o + 1] = Float(c.1)
                pixels[o + 2] = Float(c.2); pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    private func luma(_ image: DisplayImage, _ index: Int) -> Double {
        let o = index * 4
        return Double(ColorMath.luma(image.pixels[o], image.pixels[o + 1], image.pixels[o + 2]))
    }

    private func move(_ a: DisplayImage, _ b: DisplayImage, _ index: Int) -> Double {
        var total = 0.0
        for c in 0 ..< 3 {
            total += abs(Double(a.pixels[index * 4 + c]) - Double(b.pixels[index * 4 + c]))
        }
        return total
    }

    private var warm: (Double, Double, Double) { (0.62, 0.46, 0.36) }
    private var warmAlt: (Double, Double, Double) { (0.68, 0.52, 0.42) }
    private var cool: (Double, Double, Double) { (0.44, 0.52, 0.58) }
    private var coolAlt: (Double, Double, Double) { (0.38, 0.46, 0.54) }

    // MARK: - 1. 统计量本身

    func testSampleStrideCapsSampleCount() {
        XCTAssertEqual(ColorTransfer.sampleStride(for: 1_000), 1)
        XCTAssertEqual(ColorTransfer.sampleStride(for: ColorTransfer.maxSamples), 1)
        XCTAssertEqual(ColorTransfer.sampleStride(for: ColorTransfer.maxSamples * 2), 2)
        // 上取整：样本数不能超过上限，否则"小图与全图口径不同"这条就白写了。
        let stride = ColorTransfer.sampleStride(for: ColorTransfer.maxSamples + 1)
        XCTAssertGreaterThanOrEqual(stride, 2)
        // 步长不是 Range 的成员；`Swift.stride` 返的是 Sequence而不是 Collection，
        // 也没有 .count。直接算项数：向上取整的总数 / 步长。
        let total = ColorTransfer.maxSamples + 1
        let taken = (total + stride - 1) / stride
        XCTAssertLessThanOrEqual(taken, ColorTransfer.maxSamples)
    }

    func testStatsOfSolidImageAreExact() {
        let size = PixelSize(width: 12, height: 9)
        let stats = ColorTransfer.stats(flat(size, 0.5, 0.5, 0.5))
        XCTAssertNotNil(stats)
        // 三轴权重和为 1，所以纯灰的 L 就是 0.5、两个色度轴正好 0。
        XCTAssertEqual(stats?.lMean ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(stats?.aMean ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats?.bMean ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats?.lStd ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats?.samples ?? 0, size.pixelCount, "小图不该抽样")
    }

    func testStatsIgnoreAlphaAndSurviveColourSwap() {
        let size = PixelSize(width: 8, height: 8)
        let a = ColorTransfer.stats(checker(size, warm, warmAlt))
        let b = ColorTransfer.stats(checker(size, warmAlt, warm))
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        // 棋盘的两色对调不改变均值，但必须不是同一张图。
        XCTAssertEqual(a?.lMean ?? -1, b?.lMean ?? -2, accuracy: 1e-6, "对调颜色不该改均值")
        XCTAssertGreaterThan(a?.lStd ?? 0, 0, "两色图必须有反差")

        // 透明度不参与统计：追色是色彩操作，_alpha_ 为 0 的像素不该把均值拉偏。
        var faded = checker(size, warm, warmAlt)
        for i in 0 ..< size.pixelCount { faded.pixels[i * 4 + 3] = 0 }
        let statsFaded = ColorTransfer.stats(faded)
        XCTAssertEqual(statsFaded?.lMean ?? -1, a?.lMean ?? -2, accuracy: 1e-9, "统计量必须只看 RGB")
        XCTAssertEqual(statsFaded?.aMean ?? -1, a?.aMean ?? -2, accuracy: 1e-9)
    }

    // MARK: - 2. 恒等与强度闸门

    func testPlanIsIdentityWhenReferenceIsTheImage() {
        let size = PixelSize(width: 20, height: 20)
        let image = checker(size, warm, warmAlt)
        let stats = ColorTransfer.stats(image)
        XCTAssertNotNil(stats)
        let maps = ColorTransfer.plan(current: stats!, reference: stats!)
        XCTAssertTrue(maps.l.isIdentity && maps.a.isIdentity && maps.b.isIdentity,
                      "同一张图当参考时三轴都必须是恒等")
        var match = ColorMatchParameters()
        match.enabled = true
        let out = ColorTransfer.apply(image, reference: image, match: match)
        XCTAssertEqual(out.pixels, image.pixels, "恒等必须逐比特，不能只是近似原图")
    }

    func testZeroStrengthIsBitExactOriginal() {
        let size = PixelSize(width: 20, height: 20)
        let image = checker(size, warm, warmAlt)
        let reference = checker(size, cool, coolAlt)
        var match = ColorMatchParameters()
        match.enabled = true
        match.strength = 0
        let out = ColorTransfer.apply(image, reference: reference, match: match)
        XCTAssertEqual(out.pixels, image.pixels, "强度 0 必须一个比特都不动")
        XCTAssertTrue(match.isNeutral, "强度 0 算中性，渲染链整段跳过")
    }

    func testDisabledIsBitExactEvenAtFullStrength() {
        let size = PixelSize(width: 20, height: 20)
        let image = checker(size, warm, warmAlt)
        let reference = checker(size, cool, coolAlt)
        var match = ColorMatchParameters()
        match.enabled = false
        match.strength = 100
        XCTAssertEqual(ColorTransfer.apply(image, reference: reference, match: match).pixels,
                       image.pixels, "开关关了就不该拿强度当理由动图")
    }

    func testStrengthMonotonic() {
        let size = PixelSize(width: 24, height: 24)
        let image = checker(size, warm, warmAlt)
        let reference = checker(size, cool, coolAlt)
        var match = ColorMatchParameters()
        match.enabled = true; match.protectSkin = false
        var moved: [Double] = []
        for strength in [0.0, 30.0, 100.0] {
            match.strength = strength
            let out = ColorTransfer.apply(image, reference: reference, match: match)
            moved.append((0 ..< size.pixelCount).reduce(0) { $0 + move(image, out, $1) } / Double(size.pixelCount))
        }
        XCTAssertEqual(moved[0], 0, accuracy: 1e-9)
        XCTAssertLessThan(moved[0], moved[1], "强度 30 必须比 0 动得多")
        XCTAssertLessThan(moved[1], moved[2], "强度 100 必须比 30 动得多")
    }

    // MARK: - 3. 追到了没有

    func testAllThreeAxesGetCloserToReference() {
        let size = PixelSize(width: 24, height: 24)
        let image = checker(size, warm, warmAlt)
        let reference = checker(size, cool, coolAlt)
        var match = ColorMatchParameters()
        match.enabled = true; match.protectSkin = false; match.strength = 100
        let out = ColorTransfer.apply(image, reference: reference, match: match)
        guard let before = ColorTransfer.stats(image),
              let after = ColorTransfer.stats(out),
              let ref = ColorTransfer.stats(reference) else {
            XCTFail("统计量算不出来"); return
        }
        XCTAssertLessThan(abs(after.lMean - ref.lMean), abs(before.lMean - ref.lMean), "亮度均值要更接近样片")
        XCTAssertLessThan(abs(after.aMean - ref.aMean), abs(before.aMean - ref.aMean), "红绿轴要更接近样片")
        XCTAssertLessThan(abs(after.bMean - ref.bMean), abs(before.bMean - ref.bMean), "蓝黄轴要更接近样片")
        // 镜像实测：这类两色图追完之后三轴均值几乎完全落在参考上（差 < 1e-3）。
        XCTAssertEqual(after.aMean, ref.aMean, accuracy: 2e-3, "色度轴应基本对齐到参考均值")
        XCTAssertEqual(after.bMean, ref.bMean, accuracy: 2e-3)
    }

    func testMatchLumaOffKeepsPerPixelLuma() {
        let size = PixelSize(width: 24, height: 24)
        let image = checker(size, warm, warmAlt)
        let reference = checker(size, cool, coolAlt)
        var match = ColorMatchParameters()
        match.enabled = true; match.protectSkin = false; match.matchLuma = false
        let out = ColorTransfer.apply(image, reference: reference, match: match)
        var biggest = 0.0
        var change = 0.0
        for i in 0 ..< size.pixelCount {
            biggest = Swift.max(biggest, abs(luma(image, i) - luma(out, i)))
            change += move(image, out, i)
        }
        XCTAssertEqual(biggest, 0, accuracy: 1e-5, "关掉亮度轴后每个像素的亮度都不许动")
        XCTAssertGreaterThan(change, 1e-3, "但色度必须真的追了，否则这条断言是空的")
    }

    // MARK: - 4. 防炸三条

    func testFlatChannelGainLockedToOne() {
        // 纯色本图（std = 0）配一张有反差的样片：反差没法"放大"，只能锁 1。
        let maps = ColorTransfer.plan(current: ColorStats(lMean: 0.5, lStd: 0, aMean: 0, aStd: 0,
                                                          bMean: 0, bStd: 0, samples: 100),
                                      reference: ColorStats(lMean: 0.55, lStd: 0.2, aMean: 0.1, aStd: 0.2,
                                                            bMean: -0.1, bStd: 0.2, samples: 100))
        XCTAssertEqual(maps.l.gain, 1.0, accuracy: 1e-12)
        XCTAssertEqual(maps.a.gain, 1.0, accuracy: 1e-12)
        XCTAssertEqual(maps.b.gain, 1.0, accuracy: 1e-12)

        // 而且整段输出必须仍然是平的：症状"纯色墙炸成斑块"就是这么抓的。
        let size = PixelSize(width: 16, height: 16)
        var match = ColorMatchParameters()
        match.enabled = true; match.protectSkin = false
        let out = ColorTransfer.apply(flat(size, 0.5, 0.5, 0.5),
                                      reference: checker(size, cool, coolAlt), match: match)
        // 纯色追完必须还是纯色：症状“纯色墙被追成一堆斑块”就是这么抓的。
        let first = (Double(out.pixels[0]), Double(out.pixels[1]), Double(out.pixels[2]))
        for i in 0 ..< size.pixelCount {
            XCTAssertEqual(Double(out.pixels[i * 4]), first.0, accuracy: 1e-6, "纯色追完还是纯色")
            XCTAssertEqual(Double(out.pixels[i * 4 + 1]), first.1, accuracy: 1e-6)
            XCTAssertEqual(Double(out.pixels[i * 4 + 2]), first.2, accuracy: 1e-6)
        }
        // 而且均值真的动了（不然上面三条在“整段没跑”时也会绿）。
        let moved = abs(first.0 - 0.5) + abs(first.1 - 0.5) + abs(first.2 - 0.5)
        XCTAssertGreaterThan(moved, 0.01, "只追均值也必须看得出往样片靠了")
    }

    func testGainClampsAtBothEnds() {
        // 夹范围的下沿：参考几乎没反差、本图反差很大 → 不许把反差抽到负方向。
        XCTAssertEqual(ColorTransfer.gain(reference: 0.001, current: 0.2),
                       ColorTransfer.gainRange.lowerBound, accuracy: 1e-12)
        // 上沿：参考反差极大、本图刚好过 std 下限 → 夹住。
        XCTAssertEqual(ColorTransfer.gain(reference: 0.9, current: ColorTransfer.stdFloor),
                       ColorTransfer.gainRange.upperBound, accuracy: 1e-12)
        // std 下限以下一律锁 1，跟比值多大无关。
        XCTAssertEqual(ColorTransfer.gain(reference: 0.9, current: ColorTransfer.stdFloor * 0.99), 1.0,
                       accuracy: 1e-12)
    }

    func testReportNamesClippedAxes() {
        let current = ColorStats(lMean: 0.5, lStd: 0.02, aMean: 0.1, aStd: 0.02,
                                 bMean: -0.1, bStd: 0.02, samples: 100)
        let reference = ColorStats(lMean: 0.52, lStd: 0.03, aMean: -0.05, aStd: 0.5,
                                   bMean: 0.12, bStd: 0.5, samples: 100)
        var match = ColorMatchParameters()
        match.enabled = true
        match.strength = 80
        let text = ColorTransfer.report(current: current, reference: reference, match: match)
        XCTAssertTrue(text.contains("追色"), text)
        XCTAssertTrue(text.contains("强度 80%"), "报告里要看得出当前强度：\(text)")
        XCTAssertTrue(text.contains("已夹顶"),
                      "增益撞到上限必须点名，不然用户只看到追不到：\(text)")
        XCTAssertTrue(text.contains("A/B轴"), "要说具体是哪两轴被夹：\(text)")

        // 两轴接近时不该报夹顶（假报警比不报更坑）。
        let calm = ColorTransfer.report(current: current, reference: ColorStats(
            lMean: 0.51, lStd: 0.021, aMean: 0.09, aStd: 0.021, bMean: -0.09, bStd: 0.021, samples: 100
        ), match: match)
        XCTAssertFalse(calm.contains("已夹顶"), "\(calm)")
    }

    func testOutputStaysInRangeWithExtremeReference() {
        let size = PixelSize(width: 16, height: 16)
        let image = checker(size, (0.5, 0.5, 0.5), (0.52, 0.5, 0.48))   // 反差极小 → 增益锁 1
        let reference = checker(size, (0.05, 0.9, 0.05), (0.9, 0.1, 0.9)) // 极端反差与色度
        var match = ColorMatchParameters()
        match.enabled = true; match.protectSkin = false; match.strength = 100
        let out = ColorTransfer.apply(image, reference: reference, match: match)
        XCTAssertTrue(out.pixels.allSatisfy { (0...1).contains(Double($0)) }, "夹到合法区间，不靠后续编码器兜底")
    }

    // MARK: - 5. 皮肤保护

    func testSkinProtectionDampensOnlySkinChroma() {
        let size = PixelSize(width: 16, height: 16)
        let skin = (0.70, 0.55, 0.45)
        let sky = (0.30, 0.45, 0.60)
        XCTAssertTrue(SkinMask.isSkin(r: skin.0, g: skin.1, b: skin.2), "夹具得先是皮肤")
        XCTAssertFalse(SkinMask.isSkin(r: sky.0, g: sky.1, b: sky.2), "夹具里的蓝不能算皮肤")
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            let c = i % 2 == 0 ? skin : sky
            pixels[i * 4] = Float(c.0); pixels[i * 4 + 1] = Float(c.1)
            pixels[i * 4 + 2] = Float(c.2); pixels[i * 4 + 3] = 1
        }
        let image = DisplayImage(size: size, pixels: pixels)
        let reference = checker(size, cool, coolAlt)
        var match = ColorMatchParameters()
        match.enabled = true; match.strength = 100
        match.protectSkin = false
        let open = ColorTransfer.apply(image, reference: reference, match: match)
        match.protectSkin = true
        let guarded = ColorTransfer.apply(image, reference: reference, match: match)

        let skinIndex = 0, skyIndex = 1
        XCTAssertLessThan(move(image, guarded, skinIndex), move(image, open, skinIndex),
                          "皮肤像素在保护下位移更小")
        XCTAssertEqual(move(image, guarded, skyIndex), move(image, open, skyIndex), accuracy: 1e-9,
                       "非皮肤像素不受保护影响")
        XCTAssertEqual(luma(guarded, skinIndex), luma(open, skinIndex), accuracy: 1e-6,
                       "保护只减色度位移：两个口径的亮度位移必须相同")
        XCTAssertNotEqual(luma(guarded, skinIndex), luma(guarded, skyIndex),
                          "皮肤与蓝块的亮度位移本来就该不同，否则上面那条是空的")
    }

    // MARK: - 6. 确定性

    func testApplyIsDeterministic() {
        let size = PixelSize(width: 32, height: 32)
        let image = checker(size, warm, warmAlt)
        let reference = checker(size, cool, coolAlt)
        var match = ColorMatchParameters()
        match.enabled = true
        let first = ColorTransfer.apply(image, reference: reference, match: match)
        let second = ColorTransfer.apply(image, reference: reference, match: match)
        XCTAssertEqual(first.pixels, second.pixels, "同输入必须同输出（预览与导出共用这条承诺）")
    }

    // MARK: - 7. 接线：渲染链 / 缺件点名 / 导出搬运

    func testRenderChainConsumesReferenceAndNamesMissingOne() {
        let size = PixelSize(width: 16, height: 16)
        var document = PipelineWiringDocument.make(size: size) { params in
            params.colorMatch.enabled = true
            params.colorMatch.sourceName = "sample.jpg"
        }
        XCTAssertTrue(document.pipelineWarnings.contains { $0.contains("[no_colorref:sample.jpg]") },
                      "启用了但字节不在，要报名字而不是沉默，实际：\(document.pipelineWarnings)")
        let baseline = PipelineWiringDocument.make(size: size)
        XCTAssertEqual(document.render().pixels, baseline.render().pixels, "缺参考图时整段必须不跑")

        document.colorReference = checker(PixelSize(width: 24, height: 24), cool, coolAlt)
        XCTAssertFalse(document.pipelineWarnings.contains { $0.contains("colorref") },
                       "资产到位后警告要消失，实际：\(document.pipelineWarnings)")
        XCTAssertNotEqual(document.render().pixels, baseline.render().pixels,
                          "资产到位后渲染链必须真的消费它")
    }

    func testExportCarriesReferenceSoPreviewAndFileAgree() async {
        let size = PixelSize(width: 16, height: 16)
        var document = PipelineWiringDocument.make(size: size) { params in
            params.colorMatch.enabled = true
            params.colorMatch.sourceName = "sample.jpg"
            params.colorMatch.protectSkin = false
        }
        document.colorReference = checker(PixelSize(width: 24, height: 24), cool, coolAlt)
        let store = ModelStore(manifest: .emptyForTests)
        let outcome = await ExportPipeline.render(document, store: store,
                                                  ort: ORTEngine.shared, fullResolution: false)
        XCTAssertFalse(outcome.notes.contains { $0.contains("colorref") },
                       "资产在位时导出报告不该点名，实际：\(outcome.notes)")

        let baseline = PipelineWiringDocument.make(size: size)
        let plain = await ExportPipeline.render(baseline, store: store,
                                               ort: ORTEngine.shared, fullResolution: false)
        XCTAssertNotEqual(outcome.display.pixels, plain.display.pixels,
                          "导出件必须也追了色，否则预览是一个颜色、文件是另一个颜色")
    }

    // MARK: - 8. 预设契约与同步分组

    func testPresetRoundTripOldPresetDefaultsOff() throws {
        let decoded = try JSONDecoder().decode(EditParameters.self,
                                               from: #"{"exposure":0.5}"#.data(using: .utf8)!)
        XCTAssertTrue(decoded.colorMatch.isNeutral, "旧预设里没有追色，必须落出厂（关）")
        XCTAssertFalse(decoded.colorMatch.enabled)
        XCTAssertEqual(decoded.colorMatch.strength, 100, accuracy: 1e-9, "强度出厂是满档，不是 0")
        XCTAssertTrue(decoded.colorMatch.protectSkin, "皮肤保护默认开：默认场景是人像批量")
        XCTAssertTrue(decoded.colorMatch.matchLuma)
        XCTAssertTrue(EditParameters.knownKeys.contains("color_match"),
                      "CodingKeys 改了 knownKeys 必须一起改，否则报告会把自家键当陌生键")

        var params = EditParameters()
        params.colorMatch.enabled = true
        params.colorMatch.sourceName = "dusk-sample"
        params.colorMatch.strength = 42
        params.colorMatch.matchLuma = false
        params.colorMatch.protectSkin = false
        let data = try JSONEncoder().encode(params)
        let back = try JSONDecoder().decode(EditParameters.self, from: data)
        XCTAssertEqual(back.colorMatch, params.colorMatch, "追色六个字段都要走得完往返")
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("color_match"))
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("protect_skin"),
                      "嵌套键也必须是 snake_case，与 imagecake 同一口径")
    }

    func testParamSyncStyleGroupCarriesColorMatchAndItsAsset() {
        var source = EditParameters()
        source.colorMatch.enabled = true
        source.colorMatch.sourceName = "dusk-sample"
        source.colorMatch.strength = 70
        source.filter.style = "teal-orange"
        source.requires = ["lut:kodak", "colorref:dusk-sample", "sky:some-sky"]
        let target = EditParameters()

        let styled = ParamSync.merge(source: source, into: target, groups: [.style])
        XCTAssertTrue(styled.colorMatch.enabled, "追色必须跟 .style 组同步：一张样片对整批客片")
        XCTAssertEqual(styled.colorMatch.strength, 70, accuracy: 1e-9)
        XCTAssertTrue(styled.requires.contains("colorref:dusk-sample"), "参考图的依赖登记要跟着走")
        XCTAssertTrue(styled.requires.contains("lut:kodak"))
        XCTAssertFalse(styled.requires.contains("sky:some-sky"), "天不跟着风格跑，区域是逐张算的")

        let toneOnly = ParamSync.merge(source: source, into: target, groups: [.tone])
        XCTAssertFalse(toneOnly.colorMatch.enabled, "只勾调色不该把追色带过去")
    }

    func testNeutralGateOnEditParametersAccountsForColorMatch() {
        var params = EditParameters()
        XCTAssertTrue(params.isNeutral)
        params.colorMatch.enabled = true
        XCTAssertFalse(params.isNeutral, "启用追色后不能再算整组中性，否则快路径会把效果跳掉")
        params.colorMatch.strength = 0
        XCTAssertTrue(params.isNeutral, "强度 0 又回到中性")
    }
}
