import CoreGraphics
import XCTest

@testable import ImageCake

/// 身体细纹（颈纹 / 妊娠纹）的断言。
///
/// 这一项复用 `RegionEnhance.thinDarkLinePass`（法令纹那一条已经跑绿的数学），
/// 所以断言的重点不在"填得对不对"（那条由法令纹的既有断言守着），而在
/// **新接的三段**：涂抹选区 → 掩码 → 渲染链消费 → 缺件点名 → 预设与同步。
final class BodyLineTests: XCTestCase {
    private func greyField(_ size: PixelSize, _ v: Double) -> [Float] {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            pixels[i * 4] = Float(v); pixels[i * 4 + 1] = Float(v)
            pixels[i * 4 + 2] = Float(v); pixels[i * 4 + 3] = 1
        }
        return pixels
    }

    private func image(_ size: PixelSize, _ pixels: [Float]) -> DisplayImage {
        DisplayImage(size: size, pixels: pixels)
    }

    private func luma(_ pixels: [Float], _ index: Int) -> Double {
        let o = index * 4
        return Double(ColorMath.luma(pixels[o], pixels[o + 1], pixels[o + 2]))
    }

    /// 中灰底（0.60）上画：一条 2px 宽的暗线、一块 20px 宽的暗斑、一条 2px 宽的亮线。
    ///
    /// 涂行时必须钉在画布内：上一版这里直接拿 10..80 写，结果在 40×40 的夹具上
    /// **数组越界写**，CI 报的是 `Fatal error: Index out of range` 而不是断言失败。
    /// 测试自己也会把宿主跑崩，这一类错不会给你可读的失败信息。
    private func fixture(_ size: PixelSize) -> [Float] {
        var pixels = greyField(size, 0.60)
        func paintRow(_ y: Int, _ from: Int, _ to: Int, _ v: Double) {
            guard y >= 0, y < size.height else { return }
            for x in max(0, from) ..< min(to, size.width) {
                let o = (y * size.width + x) * 4
                pixels[o] = Float(v); pixels[o + 1] = Float(v); pixels[o + 2] = Float(v)
            }
        }
        let lineY = min(20, size.height - 12)
        paintRow(lineY, 10, 80, 0.30)                       // 细暗线
        paintRow(lineY + 1, 10, 80, 0.30)
        let blobFrom = lineY + 8, blobTo = min(blobFrom + 20, size.height - 6)
        if blobTo > blobFrom {
            for y in blobFrom ..< blobTo { paintRow(y, 10, 40, 0.30) }   // 宽暗斑（低频阴影）
        }
        paintRow(size.height - 4, 10, 80, 0.90)              // 细亮线
        return pixels
    }

    /// 上面那张图的行布局（同一套夹具给两个尺寸的图用）。
    private func layout(_ size: PixelSize) -> (line: Int, blobCentre: Int, bright: Int) {
        let lineY = min(20, size.height - 12)
        let blobFrom = lineY + 8
        return (lineY, blobFrom + 10 < min(blobFrom + 20, size.height - 6) ? blobFrom + 10 : blobFrom,
                size.height - 4)
    }

    // MARK: - 算子性质（方向与频宽）

    func testThinDarkLineFillsThinLineAndLeavesWideShadowAlone() {
        let size = PixelSize(width: 100, height: 100)
        let before = fixture(size)
        var after = before
        let weight = [Float](repeating: 1, count: size.pixelCount)
        RegionEnhance.thinDarkLinePass(&after, size: size, weight: weight, amount: 1.0)
    
        let place = layout(size)
        let thin = place.line * size.width + 45
        XCTAssertGreaterThan(luma(after, thin), luma(before, thin),
                             "2px 宽的暗线要被填起来，不然这个功能没有意义")
    
        // 宽暗斑的中心：邻域本身就是暗的低频，不许被当成"纹"抹平。
        let blob = place.blobCentre * size.width + 25
        XCTAssertEqual(luma(after, blob), luma(before, blob), accuracy: 1e-6,
                       "低频阴影不得被动：抹了就把人抹平到扁")
    
        // 亮线一律不动（只填暗线，不压亮线）。
        let bright = place.bright * size.width + 45
        XCTAssertEqual(luma(after, bright), luma(before, bright), accuracy: 1e-6, "亮线不是纹")
    }

    func testThinDarkLineIsBitExactOutsideWeight() {
        let size = PixelSize(width: 100, height: 100)
        let before = fixture(size)
        var after = before
        // 只有左半边有权重：右半边那一行的暗线也必须原样留着。
        var weight = [Float](repeating: 0, count: size.pixelCount)
        for y in 0 ..< size.height {
            for x in 0 ..< (size.width / 2) { weight[y * size.width + x] = 1 }
        }
        RegionEnhance.thinDarkLinePass(&after, size: size, weight: weight, amount: 1.0)
        let leftLine = 20 * size.width + 20, rightLine = 20 * size.width + 70
        XCTAssertGreaterThan(luma(after, leftLine), luma(before, leftLine), "选区内要填")
        XCTAssertEqual(after[20 * size.width * 4 + 70 * 4], before[20 * size.width * 4 + 70 * 4],
                       "选区外不得改一个比特")
        XCTAssertEqual(luma(after, rightLine), luma(before, rightLine), accuracy: 1e-9)
    }

    // MARK: - 引擎闸门与选区

    func testLineEngineNeutralGate() {
        let size = PixelSize(width: 40, height: 40)
        let base = image(size, fixture(size))
        let weight = [Float](repeating: 1, count: size.pixelCount)
        XCTAssertEqual(LineEngine.apply(base, weights: weight, lines: BodyLineParameters()).pixels,
                       base.pixels, "力度 0 必须逐比特原图")

        var lines = BodyLineParameters()
        lines.deLine = 80
        XCTAssertFalse(lines.isNeutral)
        XCTAssertTrue(EditParameters().bodyLine.isNeutral, "出厂必须是中性")
        XCTAssertNotEqual(LineEngine.apply(base, weights: weight, lines: lines).pixels, base.pixels,
                          "闸门开了算子就得真跑")
    }

    func testBrushStateLineMaskIsNilUntilPainted() {
        let size = PixelSize(width: 32, height: 32)
        var brush = BrushState()
        XCTAssertNil(brush.lineMask(for: size), "没涂就是 nil，而不是全零掩码")
        XCTAssertTrue(brush.isEmpty)
        brush.lines = [BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.1, hardness: 0.5)]
        XCTAssertNotNil(brush.lineMask(for: size))
        XCTAssertFalse(brush.isEmpty, "细纹区要进 isEmpty，否则'没有笔迹'的快速路径会漏掉它")
    }

    func testDocumentConsumesLineMaskOnAPictureThatActuallyHasALine() {
        let size = PixelSize(width: 32, height: 32)
        // 这份文档夹具本来是纯皮肤色，所以上一版"涂了渲染必须变"的期待错了：
        // 图上没有细线时算子按设计什么也不动，那正是它该 behave 的样子。
        // 这里把线性图换成"背底 + 两行暗线"，才拿得到真正的消费证据。
        var linear = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let dark = y == 19 || y == 20
                let v: Float = dark ? 0.02 : 0.35
                let o = (y * size.width + x) * 4
                linear[o] = v; linear[o + 1] = v; linear[o + 2] = v; linear[o + 3] = 1
            }
        }
        var document = PipelineWiringDocument.make(size: size) { params in
            params.bodyLine.deLine = 100
        }
        document.linear = LinearImage(size: size, pixels: linear)
        XCTAssertTrue(document.pipelineWarnings.contains { $0.contains("[no_line_region]") },
                      "开了但没涂选区要点名，实际：\(document.pipelineWarnings)")
        let before = document.render().pixels

        // 涂在暗线所在的那一行上（半径 0.25 的圆盘盖住 x 8..24）。
        document.brush.lines = [BrushStroke(points: [CGPoint(x: 0.5, y: 0.61)],
                                            radius: 0.25, hardness: 0.5)]
        XCTAssertFalse(document.pipelineWarnings.contains { $0.contains("[no_line_region]") },
                       "涂上了就不该再报，实际：\(document.pipelineWarnings)")
        let after = document.render().pixels
        let onLine = 19 * size.width + 16
        XCTAssertGreaterThan(Double(ColorMath.luma(after[onLine * 4], after[onLine * 4 + 1], after[onLine * 4 + 2])),
                             Double(ColorMath.luma(before[onLine * 4], before[onLine * 4 + 1], before[onLine * 4 + 2])),
                             "涂在细线上时渲染链必须真的把它填起来")
        // 没涂到的那一行（图顶）逐比特不变：选区真的在限定作用范围。
        let outside = 2 * size.width + 16
        XCTAssertEqual(after[outside * 4], before[outside * 4], accuracy: 1e-6,
                       "选区外的行不得被动")
    }

    // MARK: - 预设契约与同步

    func testBodyLinePresetRoundTripAndOldFileDefaultsOff() throws {
        XCTAssertTrue(EditParameters.knownKeys.contains("body_line"),
                      "CodingKeys 加了就要同步 knownKeys，否则报告把自家键当陌生键")
        let legacy = try JSONDecoder().decode(EditParameters.self,
                                              from: #"{"exposure":0.5}"#.data(using: .utf8)!)
        XCTAssertEqual(legacy.bodyLine.deLine, 0, accuracy: 1e-9, "旧预设没有这一组，落出厂（关）")
        XCTAssertTrue(legacy.bodyLine.isNeutral)
        XCTAssertFalse(legacy.isNeutral, "上面那份 JSON 带了曝光 +0.5，整组当然不中性；"
                       + "只看 bodyLine 自已在旧文件里是否为关才是本条要钉的")

        var params = EditParameters()
        params.bodyLine.deLine = 62
        XCTAssertFalse(params.isNeutral, "开了细纹就不能再算整组中性")
        let data = try JSONEncoder().encode(params)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("body_line") && text.contains("de_line"),
                      "键名必须 snake_case 且嵌套要写出去：\(text.prefix(240))")
        XCTAssertEqual(try JSONDecoder().decode(EditParameters.self, from: data).bodyLine,
                       params.bodyLine, "往返要等值")

        // 坏值收敛而不是崩：夹到 0…100。
        let wild = try JSONDecoder().decode(EditParameters.self,
                                            from: #"{"body_line":{"de_line":900}}"#.data(using: .utf8)!)
        XCTAssertEqual(wild.bodyLine.deLine, 100, accuracy: 1e-9, "越界要夹住，不能喂给算子")
    }

    func testParamSyncShapeCarriesStrengthButNotTheStroke() {
        var source = EditParameters()
        source.bodyLine.deLine = 70
        source.garment.deWrinkle = 55
        let merged = ParamSync.merge(source: source, into: EditParameters(), groups: [.shape])
        XCTAssertEqual(merged.bodyLine.deLine, 70, accuracy: 1e-9,
                       "细纹力度跟美型同组：全批按同一个深浅填细线")
        XCTAssertEqual(merged.garment.deWrinkle, 55, accuracy: 1e-9)
        let toneOnly = ParamSync.merge(source: source, into: EditParameters(), groups: [.tone])
        XCTAssertEqual(toneOnly.bodyLine.deLine, 0, accuracy: 1e-9, "只勾调色不该把身体项带过去")

        // 涂在哪一块**同步不了**：笔迹在 BrushState 里，不在 EditParameters 里。
        // 这是类型决定的（merge 的入参与返回都没有 BrushState），所以不需要断言：
        // 想搬也搬不走。面板上"清除细纹区"只能逐张做，就是同一个原因。
    }
}
