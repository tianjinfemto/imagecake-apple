import CoreGraphics
import XCTest
@testable import ImageCake

/// 文档级渲染管线。
///
/// 引擎单测证明的是「算子算得对」，这组证明的是另一件事：**笔刷确实被接进了
/// render()，而且接在正确的位置上**。接线错误（漏调、调了两次、把保护掩码传错）
/// 在引擎单测里全都看不出来，因为那些测试从不经过文档。
///
/// 最关键的一条是跨分辨率那条：预览是 2048 档、导出是全分辨率，笔刷存的是
/// 归一化坐标，只有同一条笔迹在两种画布上落在同一处相对位置，导出才不会
/// 「预览对、导出错」。这条在真机上极难验证——你得先导出一次才发现偏了。
final class DocumentRenderTests: XCTestCase {
    /// 水平渐变：R = G = B = x / (w-1)。方向可辨、且线性函数在双线性插值下
    /// 是精确的，跨分辨率比较才有意义。
    private func gradient(_ size: PixelSize) -> DisplayImage {
        var pixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let index = (y * size.width + x) * 4
                let value = Float(x) / Float(size.width - 1)
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    private func doc(_ size: PixelSize,
                     base: DisplayImage? = nil,
                     brush: BrushState = BrushState()) -> ImageDocument {
        let pixels = (base ?? gradient(size)).pixels
        return ImageDocument(linear: LinearImage(size: size, pixels: pixels),
                             originalSize: size,
                             params: EditParameters(),
                             sourceURL: nil,
                             isRAW: false,
                             loadNote: "",
                             personMask: nil,
                             maskReference: size,
                             patches: [],
                             brush: brush)
    }

    private func red(_ image: DisplayImage, size: PixelSize, x: Int, y: Int) -> Float {
        image.pixels[(y * size.width + x) * 4]
    }

    /// 左半红、右半蓝。图章取样/落点的颜色一眼可辨。
    private func halfSplit(_ size: PixelSize) -> DisplayImage {
        var pixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let index = (y * size.width + x) * 4
                let isLeft = x < size.width / 2
                pixels[index] = isLeft ? 1 : 0
                pixels[index + 1] = 0
                pixels[index + 2] = isLeft ? 0 : 1
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 没涂笔刷时**一个比特都不能变**。这条防的是"接了管线就无条件重采样一遍"——
    /// 症状是导出图整体糊一丝，而不是任何断言里的失败。
    func testEmptyBrushLeavesRenderBitIdentical() {
        let size = PixelSize(width: 8, height: 8)
        let plain = doc(size).render()
        let withEmpty = doc(size, brush: BrushState(liquify: [], stamps: [], protection: []))
        XCTAssertEqual(withEmpty.render().pixels, plain.pixels)
    }

    /// 一笔液化经过文档后必须真的生效，并且**半径外不动**——后者是接错
    /// 掩码尺寸时的典型症状（比如把保护掩码当成位移场传下去）。
    func testLiquifyStrokeAppliesThroughRender() {
        let size = PixelSize(width: 8, height: 8)
        var brush = BrushState()
        brush.liquify = [LiquifyStroke(from: CGPoint(x: 0.5, y: 0.5),
                                       to: CGPoint(x: 0.625, y: 0.5),
                                       radius: 0.3, strength: 1)]
        let out = doc(size, brush: brush).render()
        let plain = doc(size).render()

        // 往右推 → 中心改成左边那个像素的值（更小）。
        XCTAssertLessThan(red(out, size: size, x: 4, y: 4),
                          red(plain, size: size, x: 4, y: 4),
                          "中心没有沿拖动方向被推走")
        XCTAssertEqual(red(out, size: size, x: 0, y: 4),
                       red(plain, size: size, x: 0, y: 4),
                       "笔迹半径外被改动了")
    }

    /// 保护笔刷存的是笔迹，栅格化发生在渲染时。这条证明"存笔迹"这条路走得通：
    /// 同一条液化在涂了保护的位置被完全挡住。
    func testProtectionStrokeBlocksLiquifyThroughRender() {
        let size = PixelSize(width: 8, height: 8)
        var brush = BrushState()
        brush.liquify = [LiquifyStroke(from: CGPoint(x: 0.5, y: 0.5),
                                       to: CGPoint(x: 0.625, y: 0.5),
                                       radius: 0.3, strength: 1)]
        brush.protection = [BrushStroke(points: [CGPoint(x: 0.8, y: 0.5)],
                                        radius: 0.4, hardness: 1)]
        let out = doc(size, brush: brush).render()
        let plain = doc(size).render()
        XCTAssertEqual(red(out, size: size, x: 4, y: 4), red(plain, size: size, x: 4, y: 4),
                       "保护笔刷没挡住液化")
    }

    /// 一笔图章经过文档后必须把源处的颜色搬到落处，而笔迹外一个像素不该动。
    func testCloneStampAppliesThroughRender() {
        let size = PixelSize(width: 8, height: 8)
        var brush = BrushState()
        brush.stamps = [CloneStamp(source: CGPoint(x: 0.2, y: 0.5),
                                   points: [CGPoint(x: 0.8, y: 0.5)],
                                   radius: 0.15, strength: 1, hardness: 1)]
        let out = doc(size, base: halfSplit(size), brush: brush).render()
        XCTAssertGreaterThan(red(out, size: size, x: 6, y: 4), 0.9, "落点没有取到左侧的红")
        XCTAssertLessThan(red(out, size: size, x: 7, y: 4), 0.1, "笔迹外的蓝被改动了")
    }

    /// 渲染不得消耗笔迹（笔迹是历史，不是中间结果）。这条一旦挂了，
    /// 表现是"撤销后重渲染发现笔迹少了一笔"。
    func testRenderDoesNotConsumeBrush() {
        let size = PixelSize(width: 8, height: 8)
        var brush = BrushState()
        brush.liquify = [LiquifyStroke(from: CGPoint(x: 0.5, y: 0.5),
                                       to: CGPoint(x: 0.625, y: 0.5),
                                       radius: 0.3, strength: 1)]
        let document = doc(size, brush: brush)
        XCTAssertEqual(document.render().pixels, document.render().pixels)
        XCTAssertEqual(document.brush, brush)
    }

    /// 同一条笔迹在 32×32 与 128×128 上必须落在同一处相对位置。
    ///
    /// 这是"预览对、导出错"的唯一离线防线：真机上你要导出一次才看得出来偏了。
    /// 真实的预览/导出对是 2048 档与全分辨率，那上边误差只有 0.0008 量级；
    /// 这里用 32/128 是为了在单测里能算完，代价是容差必须按小画布的像素步长给：
    /// 0.05 ≈ 32 档上一个像素步长（1/31）。两侧都钉了方向与位移量，
    /// 所以"符号反了"与"半径错乘了分辨率"都跑不掉。
    func testBrushScalesToAnotherCanvasResolution() {
        let small = PixelSize(width: 32, height: 32)
        let large = PixelSize(width: 128, height: 128)
        let stroke = LiquifyStroke(from: CGPoint(x: 0.5, y: 0.5),
                                   to: CGPoint(x: 0.6, y: 0.5),
                                   radius: 0.25, strength: 1)

        var smallBrush = BrushState()
        smallBrush.liquify = [stroke]
        var largeBrush = BrushState()
        largeBrush.liquify = [stroke]

        let smallPlain = doc(small).render()
        let largePlain = doc(large).render()
        let smallOut = doc(small, brush: smallBrush).render()
        let largeOut = doc(large, brush: largeBrush).render()
        XCTAssertNotEqual(smallOut.pixels, smallPlain.pixels, "小图上液化没生效")
        XCTAssertNotEqual(largeOut.pixels, largePlain.pixels, "大图上液化没生效")

        // 两边的中点（大图 64,64 ↔ 小图 16,16）。
        let s = red(smallOut, size: small, x: 16, y: 16)
        let l = red(largeOut, size: large, x: 64, y: 64)
        let sPlain = red(smallPlain, size: small, x: 16, y: 16)
        let lPlain = red(largePlain, size: large, x: 64, y: 64)

        // 1. 方向一致：往右推 → 中点取到左边的值（更小）。
        XCTAssertLessThan(s, sPlain, "小图上方向不对")
        XCTAssertLessThan(l, lPlain, "大图上方向不对")

        // 2. 位移量与分辨率无关：拖幅是画布宽的 10%，所以中点下降量在两张图
        //    上都应该是 ~0.100。这条防的是"半径/位移被当成像素量用"——
        //    那个错的表现正是预览对、导出偏。
        XCTAssertEqual(sPlain - s, 0.1024, accuracy: 0.005, "小图上的位移量不对")
        XCTAssertEqual(lPlain - l, 0.1007, accuracy: 0.005, "大图上的位移量不对")

        // 3. 两张图在中点处取到的值本身也应当一致到小图一个像素以内。
        XCTAssertEqual(s, l, accuracy: 0.05, "同一条笔迹在两种分辨率上落在了不同处")
    }
}
