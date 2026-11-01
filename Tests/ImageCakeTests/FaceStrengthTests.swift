import CoreGraphics
import XCTest

@testable import ImageCake

/// 逐脸力度（合影）的断言。
///
/// 中心那条关系是：**把第 N 张脸的力度设成 0，等价于这一场里根本没有第 N 张脸**。
/// 它比"某格像素变了多少"强得多——不依赖我对权重栅格/位移场的任何手算，
/// 而且如果哪天有人写成短路累加（本项目为此栽过一次）或忘了传 factor，这条立刻红。
final class FaceStrengthTests: XCTestCase {
    private var size: PixelSize { PixelSize(width: 120, height: 120) }

    private func face(offset: CGFloat) -> FaceGeometry? {
        let points = BeautyEngineTests.syntheticFacePoints().map {
            CGPoint(x: $0.x + offset, y: $0.y)
        }
        return FaceGeometry.from(points: points)
    }

    /// 棋盘：位移场一改就能看出来（纯色图上线性插值的结果仍是纯色，测不出东西）。
    private func checker(_ cell: Int) -> DisplayImage {
        let s = size
        var pixels = [Float](repeating: 0, count: s.pixelCount * 4)
        for y in 0 ..< s.height {
            for x in 0 ..< s.width {
                let v = ((x / cell) + (y / cell)) % 2 == 0 ? 0.32 : 0.68
                let o = (y * s.width + x) * 4
                pixels[o] = Float(v); pixels[o + 1] = Float(v)
                pixels[o + 2] = Float(v); pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: s, pixels: pixels)
    }

    private func beautyWithFaceEffects() -> BeautyParameters {
        var beauty = BeautyParameters()
        beauty.slimFace = 60
        beauty.enlargeEyes = 50
        beauty.lipColor = 70
        beauty.eyeBright = 60
        return beauty
    }

    // MARK: - 参数本身

    func testFactorFollowsGlobalOutsideItsOwnRange() {
        var strengths = FaceStrengthParameters()
        XCTAssertEqual(strengths.factor(for: 0), 1, accuracy: 1e-12, "空数组 = 全部跟随全局")
        XCTAssertTrue(strengths.isNeutral)

        strengths.setFactor(40, for: 2)
        XCTAssertEqual(strengths.scales, [100, 100, 40], "补平而不是存稀疏结构")
        XCTAssertEqual(strengths.factor(for: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(strengths.factor(for: 2), 0.4, accuracy: 1e-12)
        XCTAssertEqual(strengths.factor(for: 3), 1, accuracy: 1e-12,
                       "脸数多于数组时多出来的脸跟随全局，而不是当 0 处理")
        XCTAssertFalse(strengths.isNeutral)

        strengths.setFactor(5_000, for: 5)
        XCTAssertEqual(strengths.factor(for: 5), 2.0, accuracy: 1e-12, "上限 200%：再高就变形到不像同一个人")
        strengths.setFactor(-30, for: 6)
        XCTAssertEqual(strengths.factor(for: 6), 0, accuracy: 1e-12, "负值夹到 0（不动），不许变成反向推")
    }

    func testScaledOnlyTouchesTheLandmarkGroups() {
        let base = beautyWithFaceEffects()
        let zero = base.scaled(by: 0)
        XCTAssertEqual(zero.slimFace, 0, accuracy: 1e-12)
        XCTAssertEqual(zero.enlargeEyes, 0, accuracy: 1e-12)
        XCTAssertEqual(zero.lipColor, 0, accuracy: 1e-12)
        XCTAssertEqual(zero.eyeBright, 0, accuracy: 1e-12)
        // 皮肤与身形不属于任何一张脸，所以逐脸缩放绝不能碰它们。
        var withSkinAndBody = base
        withSkinAndBody.skinSmooth = 55
        withSkinAndBody.whitening = 40
        withSkinAndBody.heighten = 30
        let scaled = withSkinAndBody.scaled(by: 0)
        XCTAssertEqual(scaled.skinSmooth, 55, accuracy: 1e-12, "皮肤组不参与逐脸缩放")
        XCTAssertEqual(scaled.whitening, 40, accuracy: 1e-12)
        XCTAssertEqual(scaled.heighten, 30, accuracy: 1e-12, "身形组不属于任何一张脸")
        // 有符号项按同一比例缩，保留方向。
        var shaped = BeautyParameters()
        shaped.chinAdjust = -40
        XCTAssertEqual(shaped.scaled(by: 0.5).chinAdjust, -20, accuracy: 1e-12)
        // k = 1 直接返回自身，不做浮点往返。
        XCTAssertEqual(base.scaled(by: 1), base)
    }

    // MARK: - 引擎真的按脸取力度

    func testZeroForSecondFaceEqualsSingleFaceForWarp() {
        guard let a = face(offset: -0.2), let b = face(offset: 0.2) else {
            XCTFail("合成脸派生不出几何"); return
        }
        let beauty = beautyWithFaceEffects()
        let image = checker(8)

        var only = FaceStrengthParameters()
        only.setFactor(0, for: 1)                       // 第二张 = 不动
        let singleFaceField = ShapeWarp.apply(image, faces: [a], body: nil, beauty: beauty)
        let muted = ShapeWarp.apply(image, faces: [a, b], body: nil, beauty: beauty, faceStrength: only)
        XCTAssertEqual(muted.pixels, singleFaceField.pixels,
                       "把第二张脸设成 0 必须逐比特等于只有第一张脸")

        let both = ShapeWarp.apply(image, faces: [a, b], body: nil, beauty: beauty)
        XCTAssertNotEqual(both.pixels, singleFaceField.pixels,
                          "默认（跟随全局）时第二张脸必须真的起作用，否则上面那条是空的")
    }

    func testZeroForFirstFaceEqualsSingleFaceForRegions() {
        guard let a = face(offset: -0.2), let b = face(offset: 0.2) else {
            XCTFail("合成脸派生不出几何"); return
        }
        let beauty = beautyWithFaceEffects()
        let image = checker(8)

        var muteFirst = FaceStrengthParameters()
        muteFirst.scales = [0, 100]
        let onlySecond = RegionEnhance.apply(image, geometries: [b], beauty: beauty)
        let muted = RegionEnhance.apply(image, geometries: [a, b], beauty: beauty, faceStrength: muteFirst)
        XCTAssertEqual(muted.pixels, onlySecond.pixels,
                       "第一张设成 0 时，区域美化必须逐比特等于只有第二张脸")

        let both = RegionEnhance.apply(image, geometries: [a, b], beauty: beauty)
        XCTAssertNotEqual(both.pixels, onlySecond.pixels, "默认时第一张脸要真参与")
    }

    func testStrengthScalesMonotonicallyAgainstTheOriginal() {
        guard let a = face(offset: 0) else { XCTFail(); return }
        // 基础力度故意给得很小：位移场有 `clampMagnitude` 封顶，拿满幅度再去跑 200%
        // 会两边都撞到同一上限，那时"更大"本就该不成立，断言也就测不到力度缩放了。
        var beauty = BeautyParameters()
        beauty.slimFace = 18
        beauty.enlargeEyes = 12
        let image = checker(8)
        var half = FaceStrengthParameters(); half.scales = [50]
        var double = FaceStrengthParameters(); double.scales = [200]
        let full = ShapeWarp.apply(image, faces: [a], body: nil, beauty: beauty)
        let weak = ShapeWarp.apply(image, faces: [a], body: nil, beauty: beauty, faceStrength: half)
        let strong = ShapeWarp.apply(image, faces: [a], body: nil, beauty: beauty, faceStrength: double)

        // 参照物必须是**未变形的原图**：上一版拿 `changed(base)` 当基准，而 base 就是
        // 它自己，永远是 0，所以"50% 要比它小"必假。
        func moved(_ out: DisplayImage) -> Int {
            out.pixels.indices.filter { abs(Double(out.pixels[$0]) - Double(image.pixels[$0])) > 1e-4 }.count
        }
        XCTAssertGreaterThan(moved(full), 0, "夹具得先真能产位移，否则下面两条是空的")
        XCTAssertLessThan(moved(weak), moved(full), "50% 要比跟随全局改得更少")
        XCTAssertGreaterThan(moved(strong), moved(full), "200% 要比跟随全局改得更多")
    }

    // MARK: - 文档、预设与同步

    func testDocumentReachesTheEnginesWithFaceStrength() {
        guard let a = face(offset: -0.2), let b = face(offset: 0.2) else { XCTFail(); return }
        var document = PipelineWiringDocument.make(size: size) { params in
            params.beauty.slimFace = 70
            params.beauty.lipColor = 80
            params.faceStrength.scales = [100, 0]
        }
        document.faceGeometries = [a, b]
        let mutedSecond = document.render().pixels

        document.params.faceStrength.scales = [100, 100]
        let bothActive = document.render().pixels
        XCTAssertNotEqual(bothActive, mutedSecond,
                          "改的只是 faceStrength，渲染必须跟着变——否则参数存下了但没人消费")

        document.params.faceStrength.scales = []
        XCTAssertEqual(document.render().pixels, bothActive,
                       "空数组 = 全部跟随全局 = 出厂行为，必须逐比特一致")
    }

    func testFaceStrengthSurvivesPresetRoundTripAndOldFiles() throws {
        XCTAssertTrue(EditParameters.knownKeys.contains("face_strength"),
                      "CodingKeys 与 knownKeys 必须一起改")
        let legacy = try JSONDecoder().decode(EditParameters.self,
                                              from: #"{"exposure":0.5}"#.data(using: .utf8)!)
        XCTAssertTrue(legacy.faceStrength.scales.isEmpty, "旧预设没有这一组 = 全部跟随全局")
        XCTAssertTrue(legacy.faceStrength.isNeutral)

        var params = EditParameters()
        params.faceStrength.scales = [100, 30, 180]
        let data = try JSONEncoder().encode(params)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("face_strength") && text.contains("scales"),
                      String(text.prefix(240)))
        XCTAssertEqual(try JSONDecoder().decode(EditParameters.self, from: data).faceStrength,
                       params.faceStrength)

        // 坏值收敛而不是崩：超上限夹住、超长截断。
        let wild = try JSONDecoder().decode(EditParameters.self,
                                            from: #"{"face_strength":{"scales":[-50,900,100]}}"#.data(using: .utf8)!)
        XCTAssertEqual(wild.faceStrength.scales, [0, 200, 100], "越界逐项夹回合法区间")
        // 超长数组要被截住：预设不该变成无上限的容器。
        let many = (0 ..< 200).map { String(Double($0 % 101)) }.joined(separator: ",")
        let floodedJSON = "{\"face_strength\":{\"scales\":[\(many)]}}"
        let flooded = try JSONDecoder().decode(EditParameters.self, from: Data(floodedJSON.utf8))
        XCTAssertLessThanOrEqual(flooded.faceStrength.scales.count, 64, "预设里不能塞进无长度的数组")

        // 它是修正量：只有它开着、别的人脸项全关时，整组仍算中性（不该白跑一整条渲染）。
        var onlyStrength = EditParameters()
        onlyStrength.faceStrength.scales = [40]
        XCTAssertTrue(onlyStrength.isNeutral, "没有别的脸项开着时它不产生效果，也不算不中性")
    }

    func testParamSyncShapeCarriesFaceStrength() {
        var source = EditParameters()
        source.beauty.slimFace = 50
        source.faceStrength.scales = [100, 20]
        let shape = ParamSync.merge(source: source, into: EditParameters(), groups: [.shape])
        XCTAssertEqual(shape.faceStrength.scales, [100, 20], "同批合影逐脸设定要能抄过去")
        let tone = ParamSync.merge(source: source, into: EditParameters(), groups: [.tone])
        XCTAssertTrue(tone.faceStrength.scales.isEmpty, "只勾调色不该把人像项带过去")
    }
}
