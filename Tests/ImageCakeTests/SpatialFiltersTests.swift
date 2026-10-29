import XCTest
@testable import ImageCake

/// 空间滤波：降噪与锐化。
///
/// 这组断言守的是"效果的方向"而不是具体数值：降噪必须真的降方差、但
/// 硬边缘不能被磨平；锐化必须产生 overshoot、又不能把值域顶出 0...1。
/// 具体强度系数是主观参数，改它是调品味，不该让断言红；但方向反了
/// （比如降噪把边缘糊了、锐化把图压平了）必须红。
final class SpatialFiltersTests: XCTestCase {
    private func makeImage(width: Int, height: Int, value: (Int, Int) -> Float) -> DisplayImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let v = value(x, y)
                pixels[index] = v
                pixels[index + 1] = v
                pixels[index + 2] = v
            }
        }
        return DisplayImage(size: PixelSize(width: width, height: height), pixels: pixels)
    }

    private func reds(_ image: DisplayImage) -> [Float] {
        stride(from: 0, to: image.pixels.count, by: 4).map { image.pixels[$0] }
    }

    private func variance(_ image: DisplayImage) -> Float {
        let values = reds(image)
        let mean = values.reduce(0, +) / Float(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
    }

    /// 强度为 0 时必须是恒等（直接返回原值，连一次拷贝都不做）。
    func testZeroStrengthIsIdentity() {
        let image = makeImage(width: 8, height: 8) { x, y in Float(x + y) / 20 }
        XCTAssertEqual(SpatialFilters.denoise(image, strength: 0).pixels, image.pixels)
        XCTAssertEqual(SpatialFilters.sharpen(image, strength: 0).pixels, image.pixels)
    }

    /// 降噪的核心目的：把小幅抖动平均掉。用确定性伪随机（不用 Random），
    /// 保证跑一万次结果一致，红就是真红。
    func testDenoiseReducesVariance() {
        let noisy = makeImage(width: 16, height: 16) { x, y in
            let seed = (x * 7 + y * 13) % 11
            return 0.5 + Float(seed - 5) / 50      // 0.5 ± 0.1
        }
        let before = variance(noisy)
        let after = variance(SpatialFilters.denoise(noisy, strength: 100))
        XCTAssertLessThan(after, before * 0.5, "降噪后方差应显著下降")
    }

    /// 保边的意义：0.2 与 0.8 的硬边不该被降噪抹匀。
    /// 取边外两像素处——那里 5×5 窗口完全落在同一侧。
    func testDenoiseKeepsHardEdges() {
        let edge = makeImage(width: 8, height: 8) { x, _ in x < 4 ? 0.2 : 0.8 }
        let out = SpatialFilters.denoise(edge, strength: 100)
        XCTAssertEqual(out.pixels[(2 * 8 + 1) * 4], 0.2, accuracy: 0.01, "边缘左侧被拉走了")
        XCTAssertEqual(out.pixels[(2 * 8 + 6) * 4], 0.8, accuracy: 0.01, "边缘右侧被拉走了")
    }

    /// 锐化的可见证据就是 overshoot：亮侧更亮、暗侧更暗。
    func testSharpenPushesEdgeOutward() {
        let edge = makeImage(width: 8, height: 8) { x, _ in x < 4 ? 0.2 : 0.8 }
        let out = SpatialFilters.sharpen(edge, strength: 100)
        XCTAssertLessThan(out.pixels[(4 * 8 + 3) * 4], 0.2, "暗侧没有下沉")
        XCTAssertGreaterThan(out.pixels[(4 * 8 + 4) * 4], 0.8, "亮侧没有上冲")
    }

    /// 黑白相间的极端图 + 满强度锐化，值域也不能溢出（溢出会在编码时被截断成色块）。
    func testOutputStaysInUnitRange() {
        let stripes = makeImage(width: 8, height: 8) { x, _ in x % 2 == 0 ? 0 : 1 }
        for strength in [25.0, 50.0, 100.0] {
            let out = SpatialFilters.sharpen(stripes, strength: strength)
            for value in reds(out) {
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    /// alpha 不参与滤波：降噪只处理颜色，透明度原样带过。
    func testAlphaIsUntouched() {
        var pixels = [Float](repeating: 0.5, count: 4 * 4 * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) { pixels[index + 3] = 0.3 }
        let image = DisplayImage(size: PixelSize(width: 4, height: 4), pixels: pixels)
        let out = SpatialFilters.denoise(image, strength: 100)
        for index in stride(from: 0, to: out.pixels.count, by: 4) {
            XCTAssertEqual(out.pixels[index + 3], 0.3, accuracy: 1e-6)
        }
    }

    /// 面板给的是 0...100，坏值一律夹住而不是让算子吃负数。
    func testSpatialParametersClampToRange() {
        var params = EditParameters()
        params.denoise = 500
        params.sharpen = -20
        params.clamp()
        XCTAssertEqual(params.denoise, 100)
        XCTAssertEqual(params.sharpen, 0)
        XCTAssertFalse(params.isSpatialNeutral)
    }
}
