import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 背景污点检出的内核测试。重点是**反误检**那几条：修错位置的代价（把人身上的一块
/// 抹掉）远大于留一个背景灰点，所以"平坦、非肤色、不在脸框里"三道门都要有断言钉着。
final class SpotRepairTests: XCTestCase {
    private let size = PixelSize(width: 80, height: 60)

    private func canvas(_ value: Float = 0.62) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            pixels[o] = value; pixels[o + 1] = value; pixels[o + 2] = value; pixels[o + 3] = 1
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 在 (x, y) 画一个暗点（默认 3×3，模拟传感器灰点）。
    private func spot(_ image: DisplayImage, x: Int, y: Int, span: Int = 1,
                      value: Float = 0.22) -> DisplayImage {
        var pixels = image.pixels
        for dy in (-span)...span {
            for dx in (-span)...span {
                let px = x + dx, py = y + dy
                guard px >= 0, py >= 0, px < size.width, py < size.height else { continue }
                let o = (py * size.width + px) * 4
                pixels[o] = value; pixels[o + 1] = value; pixels[o + 2] = value
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 肤色块（YCbCr/HSV 双门会认它），用来验证肤色门。
    private func skinBlock(_ image: DisplayImage, x0: Int, y0: Int, x1: Int, y1: Int) -> DisplayImage {
        var pixels = image.pixels
        for y in y0 ... y1 {
            for x in x0 ... x1 {
                let o = (y * size.width + x) * 4
                pixels[o] = 0.52; pixels[o + 1] = 0.36; pixels[o + 2] = 0.28
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    private func noisyTexture() -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                let v: Float = (x / 2 + y / 2) % 2 == 0 ? 0.80 : 0.30
                pixels[o] = v; pixels[o + 1] = v; pixels[o + 2] = v; pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    func testSingleFlatBackgroundSpotIsFound() {
        let (found, tokens) = SpotRepair.detect(spot(canvas(), x: 40, y: 30))
        XCTAssertEqual(found.count, 1, "应只检出一个：\(found)")
        XCTAssertTrue(tokens.contains("[spot-repair:1]"), "令牌要报数量：\(tokens)")
        XCTAssertEqual(found[0].at.x, CGFloat(40) / CGFloat(size.width), accuracy: 0.03)
        XCTAssertEqual(found[0].at.y, CGFloat(30) / CGFloat(size.height), accuracy: 0.05)
        XCTAssertGreaterThan(found[0].radius, 0)
        XCTAssertGreaterThan(found[0].source.y, found[0].at.y, "取样点要落在别处，不能原地自取")
    }

    func testCleanFlatBackgroundFindsNothing() {
        // 没有这一格，"检出 0 个"和"检出不工作"就分不开。
        let (found, tokens) = SpotRepair.detect(canvas())
        XCTAssertTrue(found.isEmpty, "平坦干净的背景不该有检出：\(found)")
        XCTAssertTrue(tokens.contains("[spot-repair:none]"), "空结果要点名：\(tokens)")
    }

    func testTextureIsNotMistakenForASpot() {
        // 明暗相间的细纹理每一点都"偏离局部均值"，只有平坦度门能挡住它们。
        let (found, _) = SpotRepair.detect(noisyTexture())
        XCTAssertTrue(found.isEmpty, "起伏大的画面被当成一排污点，这是最坏的一类误检")
    }

    func testSkinPixelsAreExcluded() {
        // 暗肤色块在灰背景上就是"一大片暗点"，肤色门必须把它整块排除。
        let withSkin = skinBlock(canvas(), x0: 20, y0: 20, x1: 44, y1: 40)
        let (found, _) = SpotRepair.detect(withSkin)
        XCTAssertTrue(found.isEmpty, "人身上的颜色被当成了背景污点：\(found)")
    }

    func testFaceBoxExcludesItsInterior() {
        let image = spot(canvas(), x: 40, y: 30)
        let inside = SpotRepair.detect(image, faceBounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.25))
        XCTAssertTrue(inside.found.isEmpty,
                      "污点落在脸框里（比如鼻尖上的灰点）也不能自动提意修：\(inside.found)")
        let away = SpotRepair.detect(image, faceBounds: CGRect(x: 0.02, y: 0.02, width: 0.1, height: 0.1))
        XCTAssertEqual(away.found.count, 1, "脸框挪开后就该正常检出：\(away.found)")
        XCTAssertTrue(away.tokens.contains("[no_face_box]") == false,
                      "给了脸框就不该再报缺关键点：\(away.tokens)")
        XCTAssertTrue(SpotRepair.detect(image).tokens.contains("[no_face_box]"),
                      "没关键点时必须点名，因为只靠肤色判据兜不住")
    }

    func testOneBlobYieldsOneStrokeAndIsDeterministic() {
        // 一个大灰斑会被逐像素命中好几次；重叠抑制必须把它并成一笔，
        // 否则接受一次提意 = 在原地糊两三遍。
        let big = spot(canvas(), x: 30, y: 30, span: 3)
        let first = SpotRepair.detect(big)
        XCTAssertLessThanOrEqual(first.found.count, 2, "同一块污点被切成了多笔：\(first.found)")
        let again = SpotRepair.detect(big)
        XCTAssertEqual(first.found, again.found, "同一输入两次结果不同，检出器不能用于提意")
    }

    func testCapIsNamedNotSilent() {
        var image = canvas()
        for y in stride(from: 6, to: size.height - 6, by: 6) {
            for x in stride(from: 6, to: size.width - 6, by: 6) {
                image = spot(image, x: x, y: y)
            }
        }
        let (found, tokens) = SpotRepair.detect(image)
        XCTAssertLessThanOrEqual(found.count, SpotRepair.maxFindings, "超出上限必须夹住")
        XCTAssertTrue(tokens.contains("[spot-repair:capped]"),
                      "被截断必须说出来，否则用户以为背景干净：\(tokens)")
    }

    func testDegenerateInputIsNamed() {
        let tiny = SpotRepair.detect(DisplayImage(size: PixelSize(width: 4, height: 4),
                                                  pixels: [Float](repeating: 0.5, count: 4 * 4 * 4)))
        XCTAssertTrue(tiny.tokens.contains("[too_small]"), "太小要点名而不是给一个空结果：\(tiny.tokens)")
    }
}
