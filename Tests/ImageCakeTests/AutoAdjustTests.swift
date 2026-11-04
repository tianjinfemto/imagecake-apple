import CoreGraphics
import XCTest

@testable import ImageCake

/// 自动增强（曝光 + 白平衡）与逐脸自动力度的断言。
///
/// 白平衡那条是**闭式解**（推导写在 `AutoAdjust` 里），所以断言写成性质而不是抄数：
/// "把建议的色温/色调代回自家增益模型后，参考区的 a、b 都要更靠近 0"。抄数字的断言
/// 只会把实现钉死在我某一次的算错上；而性质断了就是解错了。
///
/// 曝光那条也一样：`exposureGain = 2^EV` 与"中位数对 18% 灰"都是本仓自己的定义，
/// 所以断言的是"提到不越界为止"和"夹在参数域内"，不是某个 EV 值。
///
/// 注意近无彩带的存在意义：能被当成白参照的像素通道极差 ≤ 0.06，所以强偏色的画面
/// 本来就不该被自动白平衡硬判 —— 那类必须走 `[auto:wb_noref]`（宁可不动）。
final class AutoAdjustTests: XCTestCase {
    /// 整幅同一 RGB 的线性图（`hits` 会等于样本数，统计量最干净）。
    private func flat(_ rgb: (Double, Double, Double),
                      size: PixelSize = PixelSize(width: 64, height: 48)) -> LinearImage {
        let count = size.pixelCount
        var pixels = [Float](repeating: 0, count: count * 4)
        for i in 0 ..< count {
            pixels[i * 4] = Float(rgb.0)
            pixels[i * 4 + 1] = Float(rgb.1)
            pixels[i * 4 + 2] = Float(rgb.2)
            pixels[i * 4 + 3] = 1
        }
        return LinearImage(size: size, pixels: pixels)
    }

    /// 按比例拼两色（用于造"大部分暗 + 少量亮"的高光上限夹具）。
    private func twoTone(dark: (Double, Double, Double), bright: (Double, Double, Double),
                         brightEvery: Int) -> LinearImage {
        let size = PixelSize(width: 64, height: 48)
        let count = size.pixelCount
        var pixels = [Float](repeating: 0, count: count * 4)
        for i in 0 ..< count {
            let c = (i % brightEvery == 0) ? bright : dark
            pixels[i * 4] = Float(c.0)
            pixels[i * 4 + 1] = Float(c.1)
            pixels[i * 4 + 2] = Float(c.2)
            pixels[i * 4 + 3] = 1
        }
        return LinearImage(size: size, pixels: pixels)
    }

    /// 参考区在给定色温/色调增益下的 a、b 均值（用的就是被测对象那套增益定义）。
    private func opponentMeans(_ linear: LinearImage, temperature: Double, tint: Double) -> (a: Double, b: Double) {
        var p = EditParameters()
        p.temperature = temperature
        p.tint = tint
        let temp = p.temperatureGain
        let tone = p.tintGain
        var sumA = 0.0, sumB = 0.0, hits = 0
        let stride = AutoAdjust.sampleStride(for: linear.size.pixelCount)
        var i = 0
        while i < linear.size.pixelCount {
            let o = i * 4
            let r = Double(linear.pixels[o]) * temp.r * tone.rb
            let g = Double(linear.pixels[o + 1]) * tone.g
            let b = Double(linear.pixels[o + 2]) * temp.b * tone.rb
            // 选参考区用**原始**像素（与 AutoAdjust 同一口径）：换了增益再判，“哪些
            // 像素算白参照”会跟着结果变，那就不是在检验解而是自我实现。
            let srcR = Double(linear.pixels[o])
            let srcG = Double(linear.pixels[o + 1])
            let srcB = Double(linear.pixels[o + 2])
            let srcSpan = max(srcR, max(srcG, srcB)) - min(srcR, min(srcG, srcB))
            let srcLuma = 0.2126 * srcR + 0.7152 * srcG + 0.0722 * srcB
            if srcSpan <= AutoAdjust.neutralBand, srcLuma >= AutoAdjust.minReferenceLuma {
                sumA += r - g
                sumB += b - (r + g) / 2
                hits += 1
            }
            i += stride
        }
        guard hits > 0 else { return (0, 0) }
        return (sumA / Double(hits), sumB / Double(hits))
    }

    private func proposal(_ linear: LinearImage) -> AutoAdjust.Proposal {
        guard let p = AutoAdjust.proposal(linear: linear) else {
            XCTFail("夹具应当能出建议；出不来就是抽样/守卫写错了")
            return AutoAdjust.Proposal(exposure: 0, temperature: 0, tint: 0, notes: [])
        }
        return p
    }

    // MARK: - 白平衡

    /// 轻微暖偏（近无彩带内的偏色）必须被解到中性。
    func testWarmNearNeutralCastIsNeutralised() {
        let warm = flat((0.52, 0.49, 0.46))          // 蓝少红多 = 偏暖
        let p = proposal(warm)
        XCTAssertTrue(p.notes.filter { $0.contains("wb_noref") || $0.contains("wb_clamped") }.isEmpty,
                      "这个夹具该能解、且不该被夹：\(p.notes)")
        XCTAssertLessThan(p.temperature, 0, "偏暖要往冷方向补，实得 \(p.temperature)")

        let before = opponentMeans(warm, temperature: 0, tint: 0)
        let after = opponentMeans(warm, temperature: p.temperature, tint: p.tint)
        XCTAssertLessThan(abs(after.a), abs(before.a), "a 轴必须更靠近 0：\(before.a) → \(after.a)")
        XCTAssertLessThan(abs(after.b), abs(before.b), "b 轴必须更靠近 0：\(before.b) → \(after.b)")
        XCTAssertLessThan(abs(after.a), 0.005, "闭式解应当把 a 压到近 0，实得 \(after.a)")
        XCTAssertLessThan(abs(after.b), 0.005, "闭式解应当把 b 压到近 0，实得 \(after.b)")
    }

    /// 冷偏要给出反号的色温 —— 符号错了整条链就反了，而且肉眼只会觉得"更偏了"。
    func testCoolCastGoesTheOtherWay() {
        let cool = flat((0.46, 0.49, 0.52))
        let p = proposal(cool)
        XCTAssertGreaterThan(p.temperature, 0, "偏冷要往暖方向补，实得 \(p.temperature)")
    }

    /// 超出参数域时必须夹住并且**说出来**：不说的症状是"自动了但还偏色"。
    func testStrongCastIsClampedAndSaysSo() {
        let extreme = flat((0.02, 0.05, 0.08))       // 极端的蓝绿偏
        let p = proposal(extreme)
        XCTAssertEqual(p.temperature, AutoAdjust.shiftRange.upperBound, accuracy: 1e-9,
                       "需要的色温远超 +100，必须夹在参数域上界")
        XCTAssertTrue(p.notes.contains { $0.contains("[auto:wb_clamped]") },
                      "夹过必须写进 note：\(p.notes)")
    }

    /// 强偏色的画面**不该**被硬判白平衡：近无彩带就是它的护栏。
    func testSaturatedSceneSkipsWhiteBalance() {
        let saturated = flat((0.50, 0.20, 0.10))     // 极差 0.40，远超 neutralBand
        let p = proposal(saturated)
        XCTAssertEqual(p.temperature, 0, "没有白参照就不该动色温")
        XCTAssertEqual(p.tint, 0)
        XCTAssertTrue(p.notes.contains { $0.contains("[auto:wb_noref]") }, p.notes.description)
    }

    // MARK: - 曝光

    func testNeutralMidGrayIsLeftAlone() {
        let p = proposal(flat((0.18, 0.18, 0.18)))
        XCTAssertTrue(p.isNoOp, "18% 灰的中性图不该被推任何滑杆：\(p)")
        XCTAssertTrue(p.notes.contains { $0.contains("[auto:near_mid]") }, p.notes.description)
    }

    func testDeepShadowIsLiftedButClampedToParameterRange() {
        let p = proposal(flat((0.03, 0.03, 0.03)))
        XCTAssertGreaterThan(p.exposure, 0, "暗帧要提亮")
        XCTAssertEqual(p.exposure, AutoAdjust.evRange.upperBound, accuracy: 1e-9,
                       "需要的 EV 超出参数域，必须夹住")
        XCTAssertTrue(p.notes.contains { $0.contains("[auto:ev_clamped]") }, p.notes.description)
    }

    /// 提亮不许把 99 分位推过 1：高光死了比欠曝难救。
    func testLiftIsCappedBeforeHighlightsClip() {
        let darkWithLights = twoTone(dark: (0.02, 0.02, 0.02), bright: (0.6, 0.6, 0.6),
                                     brightEvery: 10)
        let p = proposal(darkWithLights)
        let expected = log2(1.0 / 0.6)               // 镜像同式：cap = log2(1/p99)
        XCTAssertGreaterThan(p.exposure, 0, "整体偏暗仍要提，只是提得少")
        XCTAssertLessThan(p.exposure, 1.0, "不能按原始需求（≈3.2 EV）提，那会炸高光")
        XCTAssertEqual(p.exposure, expected, accuracy: 0.05,
                       "应当正好停在「提到不越界」那一档")
        XCTAssertTrue(p.notes.contains { $0.contains("[auto:hl_cap]") }, p.notes.description)
    }

    func testAllBlackFrameDoesNotLift() {
        let p = proposal(flat((0, 0, 0)))
        XCTAssertEqual(p.exposure, 0, "全黑帧量不到中间调，不许凭空提亮")
        XCTAssertTrue(p.notes.contains { $0.contains("[auto:no_midtone]") }, p.notes.description)
    }

    // MARK: - 口径与幂等

    /// 抽样步长必须与 `ColorTransfer` 同一个函数：两处统计各走一套，
    /// "同一张图给同一个建议"迟早会破。
    func testSamplingUsesTheSharedStride() {
        for count in [400, 50_000, 40_000_000] {
            XCTAssertEqual(AutoAdjust.sampleStride(for: count), ColorTransfer.sampleStride(for: count),
                           "样本数 \(count) 处的步长不一致")
        }
    }

    func testProposalIsDeterministic() {
        let warm = flat((0.52, 0.49, 0.46))
        let first = proposal(warm)
        for _ in 0 ..< 3 {
            XCTAssertEqual(proposal(warm), first, "同一张图两次建议不一致（连按会跳）")
        }
    }

    // MARK: - 逐脸自动力度（政策，不是实测）

    func testFaceScalePolicyIsAnchoredMonotoneAndClamped() {
        XCTAssertEqual(AutoAdjust.faceScale(AutoAdjust.faceAreaReference), 100, accuracy: 1e-9,
                       "参考占比那一张必须正好等于跟随全局")
        XCTAssertEqual(AutoAdjust.faceScale(0.01), 50, accuracy: 1e-9, "1/4 面积 → sqrt 后一半力度，落在下限")
        XCTAssertEqual(AutoAdjust.faceScale(0.16), 150, accuracy: 1e-9, "4 倍面积本来要 200%，必须夹在上限")
        XCTAssertEqual(AutoAdjust.faceScale(0), 100, accuracy: 1e-9, "量不到脸框就当跟随全局，不惩罚")
        var previous = 0.0
        var i = 1
        while i <= 40 {
            let value = AutoAdjust.faceScale(Double(i) / 400.0)
            XCTAssertGreaterThanOrEqual(value, previous, "力度必须随面积单调不减")
            previous = value
            i += 1
        }
    }

    /// 政策常量一旦被改，文档里那句"4% 占比 = 100%"就假了 —— 所以钉在这里。
    func testFaceScalePolicyConstantsAreTheDocumentedOnes() {
        XCTAssertEqual(AutoAdjust.faceAreaReference, 0.04, accuracy: 1e-12)
        XCTAssertEqual(AutoAdjust.faceScaleRange.lowerBound, 50, accuracy: 1e-12)
        XCTAssertEqual(AutoAdjust.faceScaleRange.upperBound, 150, accuracy: 1e-12)
    }
}
