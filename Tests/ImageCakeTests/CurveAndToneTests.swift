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
}
