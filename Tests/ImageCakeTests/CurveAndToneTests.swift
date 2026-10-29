import XCTest
@testable import ImageCake

final class CurveAndToneTests: XCTestCase {
    func testIdentityCurveIsIdentity() {
        let lut = CurveMath.lut(.identity, size: 257)
        for i in 0 ..< 257 {
            XCTAssertEqual(lut[i], Float(i) / 256, accuracy: 1e-4)
        }
    }

    func testMonotoneCurveNeverOvershoots() {
        // 中间调拉成 S 形：单调插值不允许出现"回勾"。
        let channel = CurveChannel(x: [0, 0.25, 0.5, 0.75, 1], y: [0, 0.12, 0.5, 0.9, 1])
        let lut = CurveMath.lut(channel, size: 512)
        for i in 1 ..< lut.count {
            XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1] - 1e-5, "第 \(i) 项比前一项小")
        }
        XCTAssertEqual(lut.first ?? -1, 0, accuracy: 1e-5)
        XCTAssertEqual(lut.last ?? -1, 1, accuracy: 1e-5)
    }

    func testInvalidCurveFallsBackToIdentity() {
        let broken = CurveChannel(x: [0, 0.8, 0.2, 1], y: [0, 0.5, 0.5, 1]) // x 非递增
        XCTAssertFalse(broken.isValid)
        let lut = CurveMath.lut(broken, size: 64)
        for i in 0 ..< 64 {
            XCTAssertEqual(lut[i], Float(i) / 63, accuracy: 1e-5)
        }
    }

    func testNeutralToneIsDisplayEncodingOnly() {
        let linear = LinearImage(size: PixelSize(width: 2, height: 2),
                                 pixels: Array(repeating: [Float(0.18), 0.18, 0.18, 1], count: 4).flatMap { $0 })
        let out = ToneEngine.render(linear, params: EditParameters())
        let expected = ColorMath.encode(0.18)
        for i in 0 ..< 4 {
            XCTAssertEqual(out.pixels[i * 4], expected, accuracy: 1e-5)
            XCTAssertEqual(out.pixels[i * 4 + 1], expected, accuracy: 1e-5)
            XCTAssertEqual(out.pixels[i * 4 + 2], expected, accuracy: 1e-5)
        }
    }

    func testExposureOneStopDoublesLinear() {
        let linear = LinearImage(size: PixelSize(width: 1, height: 1), pixels: [0.1, 0.1, 0.1, 1])
        var params = EditParameters()
        params.exposure = 1
        let out = ToneEngine.render(linear, params: params)
        XCTAssertEqual(out.pixels[0], ColorMath.encode(0.2), accuracy: 1e-5)
    }

    func testHueShiftMovesChannelDominance() {
        // 纯红（显示域 1,0,0）旋转 120° 后应接近纯绿。
        let linear = LinearImage(size: PixelSize(width: 1, height: 1),
                                 pixels: [1, 0, 0, 1])
        var params = EditParameters()
        params.hue = 120
        let out = ToneEngine.render(linear, params: params)
        XCTAssertGreaterThan(out.pixels[1], 0.9, "绿色通道没有抬起来")
        XCTAssertLessThan(out.pixels[0], 0.1, "红色通道没有落下去")
    }

    // MARK: - 三区色轮与八分区 HSL
    //
    // 这两项的算子一直在 ToneEngine 里跑，但面板入口以前不存在，
    // 也就从没有断言盖到它们。入口补上之后，先把算子行为钉住：
    // 以后改色轮权重或色相带中心时，这里会先红。

    /// 青带（180°）与左右邻居（绿 120°、蓝 240°）都相距 60°，是 45° 窗口内
    /// 唯一生效的带——sumW = 1，所以拉满就是真的完全去饱和。
    func testHSLSaturationOnIsolatedBandDesaturatesFully() {
        let cyan = LinearImage(size: PixelSize(width: 1, height: 1), pixels: [0, 1, 1, 1])

        var params = EditParameters()
        params.hslSat[4] = -100            // 青带，下标 4
        let out = ToneEngine.render(cyan, params: params)
        XCTAssertEqual(out.pixels[0], out.pixels[1], accuracy: 1e-4, "去饱和后三通道应相等")
        XCTAssertEqual(out.pixels[1], out.pixels[2], accuracy: 1e-4, "去饱和后三通道应相等")
        XCTAssertGreaterThan(out.pixels[0], 0.9, "青的 V = 1，去饱和后应该是白而不是灰")
    }

    /// 红带（0°）**不独占**：品红带（320°）环距只有 40°，橙带（30°）30°，
    /// 两者都在 45° 窗口内分摊权重（sumW ≈ 1.444）。所以单拉红带只能
    /// 去掉约 69% 的饱和度——这条钉的是「环上渐变过渡」这个设计，不是噪声。
    func testHSLBandWeightsBlendAcrossNeighbours() {
        let red = LinearImage(size: PixelSize(width: 1, height: 1), pixels: [1, 0, 0, 1])

        var params = EditParameters()
        params.hslSat[0] = -100            // 只拉红带
        let partial = ToneEngine.render(red, params: params)
        XCTAssertGreaterThan(partial.pixels[1], 0.5, "红带去饱和应抬高绿/蓝")
        XCTAssertGreaterThan(partial.pixels[0], partial.pixels[1], "红仍是主导通道")
        XCTAssertLessThan(partial.pixels[1], 0.99, "相邻带分摊了权重，不该是完全去饱和")

        params.hslSat[1] = -100            // 再把橙带拉满
        params.hslSat[7] = -100            // 以及品红带——三个带都拉满才是全去色
        let full = ToneEngine.render(red, params: params)
        XCTAssertEqual(full.pixels[0], full.pixels[1], accuracy: 1e-4, "窗口内所有带拉满后应完全去色")
        XCTAssertEqual(full.pixels[1], full.pixels[2], accuracy: 1e-4, "窗口内所有带拉满后应完全去色")
    }

    /// 远离 45° 窗口的带完全不参与：蓝带（240°）距青（180°）60°。
    func testHSLFarBandLeavesColourUntouched() {
        let cyan = LinearImage(size: PixelSize(width: 1, height: 1), pixels: [0, 1, 1, 1])

        var params = EditParameters()
        params.hslSat[5] = -100            // 蓝带，距青 60°，在窗口外
        let out = ToneEngine.render(cyan, params: params)
        XCTAssertLessThan(out.pixels[0], 0.02, "青的红通道应保持 0")
        XCTAssertEqual(out.pixels[1], 1, accuracy: 1e-4, "绿通道不该被蓝带动")
        XCTAssertEqual(out.pixels[2], 1, accuracy: 1e-4, "蓝通道不该被蓝带动")
    }

    /// 阴影区权重 = clamp(1 - 2L)：暗部（编码后 L≈0.24）拿到 ≈0.51，
    /// 亮部（L≈0.91）拿到 0——所以只推阴影时亮部必须一点不动。
    func testWheelOnlyPushesItsOwnLumaZone() {
        let dark = LinearImage(size: PixelSize(width: 1, height: 1), pixels: [0.05, 0.05, 0.05, 1])
        let bright = LinearImage(size: PixelSize(width: 1, height: 1), pixels: [0.8, 0.8, 0.8, 1])

        var shadows = EditParameters()
        shadows.wshHue = 0                  // 推红
        shadows.wshSat = 100

        let darkBase = ToneEngine.render(dark, params: EditParameters())
        let darkLit = ToneEngine.render(dark, params: shadows)
        XCTAssertGreaterThan(darkLit.pixels[0], darkBase.pixels[0] + 0.05, "暗部红通道没有被抬高")

        let brightBase = ToneEngine.render(bright, params: EditParameters())
        let brightLit = ToneEngine.render(bright, params: shadows)
        for channel in 0 ..< 3 {
            XCTAssertEqual(brightLit.pixels[channel], brightBase.pixels[channel], accuracy: 1e-5,
                           "亮度已进高光区，阴影色轮不该碰它")
        }
    }

    /// 色轮「亮度」只推该区的明暗，不依赖色相（hue 留着也不该染上去）。
    func testWheelLumLiftsWithoutTinting() {
        let mid = LinearImage(size: PixelSize(width: 1, height: 1), pixels: [0.3, 0.3, 0.3, 1])
        var params = EditParameters()
        params.wmtLum = 100
        let out = ToneEngine.render(mid, params: params)
        XCTAssertEqual(out.pixels[0], out.pixels[1], accuracy: 1e-5, "只推亮度不该产生色偏")
        XCTAssertEqual(out.pixels[1], out.pixels[2], accuracy: 1e-5, "只推亮度不该产生色偏")
        let base = ToneEngine.render(mid, params: EditParameters())
        XCTAssertGreaterThan(out.pixels[0], base.pixels[0], "亮度应被抬高")
    }

    /// 面板可以直接写数组下标，所以「长度恒为 8」是 UI 的安全边界。
    func testHSLArraysStayEightLongAfterClamp() {
        var params = EditParameters()
        params.hslHue = [999]
        params.hslSat = Array(repeating: 999, count: 3)
        params.clamp()

        XCTAssertEqual(params.hslHue.count, 8)
        XCTAssertEqual(params.hslSat.count, 8)
        XCTAssertEqual(params.hslLum.count, 8)
        XCTAssertEqual(params.hslHue[0], 30, accuracy: 1e-6, "色相偏移应被夹到 ±30°")
        XCTAssertEqual(params.hslSat[0], 100, accuracy: 1e-6)
        XCTAssertTrue(params.hslHue.dropFirst().allSatisfy { $0 == 0 }, "短数组应补 0")
    }

    // MARK: - 补光 / 高光柔化

    private func grey(_ linear: Float) -> LinearImage {
        LinearImage(size: PixelSize(width: 1, height: 1), pixels: [linear, linear, linear, 1])
    }

    /// 补光只抬暗部。亮部落在 shadows 权重 = 0 的区域（编码后 L≈0.91），
    /// 必须一点不动——否则“补光”就变成了全局提亮。
    func testFillLightLiftsShadowsOnly() {
        var params = EditParameters()
        params.fillLight = 100

        let darkBase = ToneEngine.render(grey(0.05), params: EditParameters()).pixels[0]
        let darkLit = ToneEngine.render(grey(0.05), params: params).pixels[0]
        XCTAssertGreaterThan(darkLit, darkBase + 0.1, "暗部没有被抬起来")

        let brightBase = ToneEngine.render(grey(0.8), params: EditParameters()).pixels[0]
        let brightLit = ToneEngine.render(grey(0.8), params: params).pixels[0]
        XCTAssertEqual(brightLit, brightBase, accuracy: 1e-5, "亮部不该被补光抬高")
    }

    /// 高光柔化只压高光。暗部的 highlights 权重为 0，同样必须不动。
    func testHighlightSoftenPressesHighlightsOnly() {
        var params = EditParameters()
        params.highlightSoften = 100

        let brightBase = ToneEngine.render(grey(0.8), params: EditParameters()).pixels[0]
        let brightPressed = ToneEngine.render(grey(0.8), params: params).pixels[0]
        XCTAssertLessThan(brightPressed, brightBase - 0.1, "高光没有被压下来")

        let darkBase = ToneEngine.render(grey(0.05), params: EditParameters()).pixels[0]
        let darkPressed = ToneEngine.render(grey(0.05), params: params).pixels[0]
        XCTAssertEqual(darkPressed, darkBase, accuracy: 1e-5, "暗部不该被高光柔化影响")
    }

    /// 两项都只动亮度：灰色进必须灰色出，不能顺手染一个色。
    func testToneRecoverKeepsNeutralGrey() {
        var params = EditParameters()
        params.fillLight = 60
        params.highlightSoften = 60
        let out = ToneEngine.render(grey(0.2), params: params)
        XCTAssertEqual(out.pixels[0], out.pixels[1], accuracy: 1e-6)
        XCTAssertEqual(out.pixels[1], out.pixels[2], accuracy: 1e-6)
    }

    /// 满强度也不该把值顶出 0...1：溢出在编码时会被截断成色块。
    func testToneRecoverStaysInRange() {
        var params = EditParameters()
        params.fillLight = 100
        params.highlightSoften = 100
        for step in 0 ... 20 {
            let value = Float(step) / 20
            let out = ToneEngine.render(grey(value), params: params)
            XCTAssertGreaterThanOrEqual(out.pixels[0], 0, "输入 \(value) 时越界")
            XCTAssertLessThanOrEqual(out.pixels[0], 1, "输入 \(value) 时越界")
        }
    }

    func testToneRecoverParametersClamp() {
        var params = EditParameters()
        params.fillLight = 500
        params.highlightSoften = -30
        params.clamp()
        XCTAssertEqual(params.fillLight, 100)
        XCTAssertEqual(params.highlightSoften, 0)
    }
}
