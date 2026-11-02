import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 好片初筛的三轴。阈值来自镜像脚本（硬边棋盘 5.70 / 糊 8 半径 0.19 / 平涂 0.0 /
/// 白场截幅占比 1.0），不是顺手写的数字。
final class FrameTriageTests: XCTestCase {
    private func checker(_ size: PixelSize) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                let v: Float = ((x / 4) + (y / 4)) % 2 == 0 ? 0.9 : 0.1
                pixels[o] = v; pixels[o + 1] = v * 0.95; pixels[o + 2] = v * 0.9; pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    private func solid(_ size: PixelSize, _ v: Float) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            pixels[o] = v; pixels[o + 1] = v; pixels[o + 2] = v; pixels[o + 3] = 1
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    private func gradient(_ size: PixelSize) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                let v = Float(x) / Float(max(size.width - 1, 1))
                pixels[o] = 0.2 + 0.6 * v; pixels[o + 1] = pixels[o]; pixels[o + 2] = pixels[o]
                pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    func testSharpCheckerIsKept() {
        let v = FrameTriage.review(checker(PixelSize(width: 64, height: 48)))
        XCTAssertGreaterThan(v.sharpness, 3.0, "硬边棋盘的归一化清晰度应当很高（镜像 5.70）：\(v)")
        XCTAssertFalse(v.tokens.contains("[blurry]"), "清晰图被判糊：\(v.tokens)")
        XCTAssertTrue(v.keep)
        XCTAssertEqual(v.exposure, 0.479, accuracy: 0.02, "镜像算出的均值")
    }

    func testBlurryFrameIsRejected() {
        let sharp = checker(PixelSize(width: 64, height: 48))
        let blurred = DisplayImage(size: sharp.size,
                                   pixels: ImageDocument.blurred(sharp.pixels, size: sharp.size, radius: 8))
        let s = FrameTriage.review(sharp)
        let b = FrameTriage.review(blurred)
        XCTAssertLessThan(b.sharpness, s.sharpness / 5,
                          "糊了 8 半径，归一化清晰度只要求「低一点」不够：\(s.sharpness) → \(b.sharpness)")
        XCTAssertTrue(b.tokens.contains("[blurry]"), "整帧糊掉必须点名：\(b.tokens)")
        XCTAssertFalse(b.keep, "被判定糊的帧不能 keep —— 这条就是当初「平涂豁免」会漏掉的情形")
    }

    func testFlatAndBlankFramesAreNamedNotSilentlyKept() {
        // 强糊图的亮度方差会掉到平涂线以下，所以 [flat-content] 与 [blurry] 必须
        // 各自独立成立（曾经写成 else if，于是糊帧会被"豁免"）。
        let g = FrameTriage.review(gradient(PixelSize(width: 64, height: 48)))
        XCTAssertTrue(g.tokens.contains("[blurry]") || g.tokens.contains("[flat-content]"),
                      "无边缘画面不能什么都不点名：\(g.tokens)")
        XCTAssertFalse(g.keep)

        let white = FrameTriage.review(solid(PixelSize(width: 64, height: 48), 1))
        XCTAssertEqual(white.clippedHighlights, 1.0, accuracy: 1e-9, "整幅死白占比应为 1")
        XCTAssertTrue(white.tokens.contains("[clipped-highlights]"))
        XCTAssertTrue(white.tokens.contains("[overexposed]"))

        let black = FrameTriage.review(solid(PixelSize(width: 64, height: 48), 0))
        XCTAssertTrue(black.tokens.contains("[clipped-shadows]"))
        XCTAssertTrue(black.tokens.contains("[underexposed]"))
    }

    func testExposureOnlyWarnsAndDoesNotReject() {
        // 欠曝/过曝是提示，不否决：夜景与高调片本来就该被留下，人比阈值可靠。
        let dark = FrameTriage.review(checker(PixelSize(width: 64, height: 48)))
        XCTAssertTrue(dark.tokens.allSatisfy { !$0.contains("exposed") }, "中亮棋盘不该报曝光：\(dark.tokens)")
        XCTAssertTrue(dark.keep)
    }

    func testDeterministicAndSummaryCarriesTokens() {
        let image = checker(PixelSize(width: 40, height: 30))
        let first = FrameTriage.review(image)
        XCTAssertEqual(FrameTriage.review(image), first)
        XCTAssertTrue(first.summary().contains("初筛"))
        XCTAssertTrue(first.summary().contains(first.tokens.first ?? "[clean]"))
    }

    func testDegenerateInputIsNamed() {
        let tiny = FrameTriage.review(solid(PixelSize(width: 2, height: 2), 0.5))
        XCTAssertTrue(tiny.tokens.contains("[too_small]") || tiny.tokens.contains("[no_image]"),
                      "太小/空画布必须点名，不能给一个看起来正常的判定：\(tiny.tokens)")
        XCTAssertFalse(tiny.keep)
    }
}
