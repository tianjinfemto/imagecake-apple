import CoreGraphics
import XCTest

@testable import ImageCake

/// 渲染阶段计时器与它接进管线后的两条承诺：
///   1. **不许改变任何像素** —— 插桩只是加了一层闭包包装，若返回值被搬运过
///      或阶段被跳过判断写错，第 5 条断言会立刻红；
///   2. **没跑的阶段不出现在列表里** —— 这是"改一个滑杆只重算受影响阶段"
///      第一次变成可断言的事实（以前这句话只写在注释里）。
final class RenderPerfTests: XCTestCase {
    private var size: PixelSize { PixelSize(width: 24, height: 24) }

    private func doc(_ tune: (inout EditParameters) -> Void = { _ in }) -> ImageDocument {
        PipelineWiringDocument.make(size: size, tune)
    }

    // MARK: - 记录器本身

    func testDisabledCollectorIsPassThroughAndRecordsNothing() {
        let perf = RenderPerf.disabled
        let value = perf.stage("tone") { 40 + 2 }
        XCTAssertEqual(value, 42, "关闭时也必须原样返回 body 的结果")
        XCTAssertTrue(perf.samples.isEmpty)
        XCTAssertEqual(perf.stageTotalMS, 0, accuracy: 1e-12)
        XCTAssertTrue(perf.summary().contains("[perf_off]"))
    }

    func testEnabledRecordsNamesInExecutionOrder() {
        let perf = RenderPerf()
        _ = perf.stage("alpha") { 1 }
        Thread.sleep(forTimeInterval: 0.01)
        _ = perf.stage("beta") { 2 }
        XCTAssertEqual(perf.names, ["alpha", "beta"], "顺序必须就是执行顺序（渲染链的顺序是有承诺的）")
        XCTAssertTrue(perf.didRun("beta"))
        XCTAssertFalse(perf.didRun("gamma"))
        XCTAssertEqual(perf.stageCount, 2)
        XCTAssertGreaterThan(perf.milliseconds(for: "beta") ?? 0, 0, "睡了 10ms 的那段必须量到")
        XCTAssertNil(perf.milliseconds(for: "gamma"))
    }

    func testUnknownNameAndDuplicateSums() {
        let perf = RenderPerf()
        _ = perf.stage("tone") { 1 }
        _ = perf.stage("tone") { 2 }
        // 重名时不能只取第一条（那是静默丢数据），也不能猜“瞬时就是 0”
        // —— 两次取时钟本身就是几十纳秒，只会四舍五入到 0.000 多毫秒。
        XCTAssertEqual(perf.stageCount, 2)
        XCTAssertGreaterThanOrEqual(perf.milliseconds(for: "tone") ?? -1, 0)
        XCTAssertNil(perf.milliseconds(for: "nope"))
    }

    func testSlowestOrderingAndBounds() {
        let perf = RenderPerf(enabled: false)
        // 直接验排序逻辑：用手工样本做不到（samples 是 private(set)），
        // 所以这里靠"跑三段不同长度"来构造，不猜具体毫秒值。
        _ = perf.stage("x") { 1 }
        XCTAssertTrue(perf.slowest(3).isEmpty, "关闭时不该有任何样本可排")

        let live = RenderPerf()
        _ = live.stage("tiny") { 1 }
        _ = live.stage("slept", { Thread.sleep(forTimeInterval: 0.02) })
        let top = live.slowest(1)
        XCTAssertEqual(top.map(\.name), ["slept"], "最慢的那个必须排第一")
        XCTAssertTrue(live.slowest(0).isEmpty, "n=0 要给空而不是崩")
        XCTAssertTrue(live.slowest(-5).isEmpty, "负数同样给空")
        XCTAssertEqual(live.slowest(99).count, 2, "超过样本数时给全部")
    }

    func testSummaryCarriesTotalAndStageCount() {
        let perf = RenderPerf()
        _ = perf.stage("tone") { 1 }
        _ = perf.stage("region") { 2 }
        let text = perf.summary()
        XCTAssertTrue(text.contains("渲染"), text)
        XCTAssertTrue(text.contains("2 段"), text)
        XCTAssertTrue(text.contains("最慢"), text)
    }

    func testStageAsyncRecordsToo() async {
        let perf = RenderPerf()
        let value = await perf.stageAsync("faceRestore") {
            try? await Task.sleep(nanoseconds: 5_000_000)
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(perf.names, ["faceRestore"], "导出里最贵的阶段是 async 的，不能没有计时")
    }

    // MARK: - 接进渲染链

    func testInstrumentationDoesNotChangeAPixel() {
        let document = doc { params in
            params.beauty.skinSmooth = 60
            params.beauty.lipColor = 50
            params.contrast = 20
            params.lens.vignette = 30
        }
        var withPerf = document
        withPerf.faceGeometries = [FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())].compactMap { $0 }
        let perf = RenderPerf()
        let timed = withPerf.render(perf: perf)
        let plain = withPerf.render()
        XCTAssertEqual(timed.pixels, plain.pixels, "插桩不许改变输出：它只能加一层闭包")
        XCTAssertFalse(perf.samples.isEmpty, "开了就得记到东西，否则上面那条相等也没意义")
    }

    func testSkippedStagesAreAbsentForNeutralDocument() {
        let perf = RenderPerf()
        _ = doc().render(perf: perf)
        let names = Set(perf.names)
        // 恒等路径上也必然出现的两段（几何与逐像素调色）：它们不是被闸门跳过的。
        XCTAssertTrue(names.contains("geometry"), "\(perf.names)")
        XCTAssertTrue(names.contains("tone"), "\(perf.names)")
        // 被中性闸门挡住的阶段**根本不该出现**，而不是"出现但 0 毫秒"。
        for skipped in ["skinMask", "skin", "region", "makeup", "shape", "filter",
                        "sky", "relight", "overlay", "garment", "bodyLine", "colorMatch"] {
            XCTAssertFalse(names.contains(skipped), "中性文档不该跑 \(skipped)，跑没跑要看列表：\(perf.names)")
        }
    }

    func testSwitchedOnStagesDoAppear() {
        guard let geometry = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints()) else {
            XCTFail("合成脸派生不出几何"); return
        }
        let style = FilterEngine.styles.first?.id ?? ""
        var document = doc { params in
            params.beauty.skinSmooth = 50
            params.beauty.lipColor = 40
            params.beauty.slimFace = 30
            params.makeup.styleID = MakeupEngine.looks.first?.id ?? ""
            params.filter.style = style
            params.filter.strength = 60
            params.lens.vignette = 20
            params.light.intensity = 30
            params.colorMatch.enabled = true
            params.colorMatch.strength = 50
            params.sky.enabled = true
            params.sky.strength = 40
            params.garment.deWrinkle = 50
            params.bodyLine.deLine = 50
            // background 阶段的闸门是 bgEnabled（还要有 personMask，下面给了）：
            // 不打开却断言它跑了，就是拿一个本不该成立的期待碰运气。
            params.bgEnabled = true
        }
        document.faceGeometries = [geometry]
        document.personMask = MaskBuffer.filled(size, value: 255)
        document.skyMask = MaskBuffer.filled(size, value: 255)
        document.colorReference = TestImage.solid(width: 12, height: 12, r: 0.4, g: 0.5, b: 0.6)
        document.brush.garments = [BrushStroke(points: [CGPoint(x: 0.5, y: 0.7)], radius: 0.2, hardness: 0.5)]
        document.brush.lines = [BrushStroke(points: [CGPoint(x: 0.5, y: 0.75)], radius: 0.2, hardness: 0.5)]

        let perf = RenderPerf()
        _ = document.render(perf: perf)
        let names = Set(perf.names)
        for ran in ["skinMask", "skin", "region", "makeup", "shape", "filter",
                    "sky", "relight", "overlay", "colorMatch", "garment", "bodyLine", "background"] {
            XCTAssertTrue(names.contains(ran), "开了却没跑到 \(ran)：\(perf.names)")
        }
        // 顺序承诺：几何必须在最前，输出层（打光→暗角颗粒）必须在最后。
        XCTAssertEqual(perf.names.first, "geometry")
        XCTAssertEqual(perf.names.suffix(2).map(\.self), ["relight", "overlay"],
                       "打光必须在暗角之前、且两者都是输出层末段：\(perf.names)")
    }

    func testStageNamesAreUniqueAndStageTimeSumsToTotal() {
        let perf = RenderPerf()
        var document = doc { params in
            params.beauty.skinSmooth = 40
            params.contrast = 10
        }
        document.personMask = MaskBuffer.filled(size, value: 255)
        _ = document.render(perf: perf)
        XCTAssertEqual(Set(perf.names).count, perf.names.count,
                       "重名会让 milliseconds(for:) 变成含糊的求和：\(perf.names)")
        let sum = perf.names.reduce(0.0) { $0 + (perf.milliseconds(for: $1) ?? 0) }
        XCTAssertEqual(sum, perf.stageTotalMS, accuracy: 1e-9)
        XCTAssertGreaterThan(perf.stageTotalMS, 0, "总时长为 0 说明根本没在计时（可能优化后忘了开）")
        XCTAssertTrue(perf.summary().contains(RenderPerf.buildConfig),
                      "耗时行必须自带构建配置：不然 Debug 的数会被当成 shipped 性能读：\(perf.summary())")
    }

    func testExportReportCarriesPerfLine() async {
        let store = ModelStore(manifest: .emptyForTests)
        let outcome = await ExportPipeline.render(doc(), store: store,
                                                  ort: ORTEngine.shared, fullResolution: false)
        let line = outcome.notes.first { $0.hasPrefix("[perf]") }
        XCTAssertNotNil(line, "导出报告必须带耗时行，否则'导出慢'只能凭感觉说：\(outcome.notes)")
        XCTAssertTrue(line!.contains("渲染"), line!)
    }
}
