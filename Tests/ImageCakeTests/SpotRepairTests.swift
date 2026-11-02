import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 背景污点检出的内核测试。重点是**反误检**那几条：修错位置的代价（把人身上的一块
/// 抹掉）远大于留一个背景灰点，所以"环域平坦、非肤色、不在脸框里"三道门都要有断言钉着。
///
/// 夹具尺寸不是随手挑的：80×60 对应 r1=2 / r2=6（镜像脚本用来分离"灰点"与"纹理"的
/// 就是这组半径），换尺寸等于换判据。
final class SpotRepairTests: XCTestCase {
    private let size = PixelSize(width: 80, height: 60)

    private func canvas(_ size: PixelSize, _ value: Float = 0.62) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            pixels[o] = value; pixels[o + 1] = value; pixels[o + 2] = value; pixels[o + 3] = 1
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 在 (x, y) 画一个 (2·span+1)² 的暗块，模拟传感器灰点。
    private func spot(_ image: DisplayImage, x: Int, y: Int, span: Int = 1,
                      value: Float = 0.22) -> DisplayImage {
        let w = image.size.width
        let h = image.size.height
        var pixels = image.pixels
        for dy in (-span)...span {
            for dx in (-span)...span {
                let px = x + dx, py = y + dy
                guard px >= 0, py >= 0, px < w, py < h else { continue }
                let o = (py * w + px) * 4
                pixels[o] = value; pixels[o + 1] = value; pixels[o + 2] = value
            }
        }
        return DisplayImage(size: image.size, pixels: pixels)
    }

    func testSingleFlatBackgroundSpotIsFound() {
        let (found, tokens) = SpotRepair.detect(spot(canvas(size), x: 40, y: 30))
        XCTAssertEqual(found.count, 1, "应只检出一个：\(found)")
        XCTAssertTrue(tokens.contains("[spot-repair:1]"), "令牌要报数量：\(tokens)")
        XCTAssertEqual(found[0].at.x, CGFloat(40) / CGFloat(size.width), accuracy: 0.03)
        XCTAssertEqual(found[0].at.y, CGFloat(30) / CGFloat(size.height), accuracy: 0.05)
        XCTAssertGreaterThan(found[0].radius, 0)
        XCTAssertGreaterThan(found[0].source.y, found[0].at.y, "取样点要落在别处，不能原地自取")
    }

    func testCleanFlatBackgroundFindsNothing() {
        // 没有这一格，"检出 0 个"和"检出器不工作"就分不开。
        let (found, tokens) = SpotRepair.detect(canvas(size))
        XCTAssertTrue(found.isEmpty, "平坦干净的背景不该有检出：\(found)")
        XCTAssertTrue(tokens.contains("[spot-repair:none]"), "空结果要点名：\(tokens)")
    }

    func testTextureIsNotMistakenForASpot() {
        // 明暗相间的细纹理每一点都"偏离局部均值"，只有环域平坦度门能挡住它们。
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                let v: Float = (x / 2 + y / 2) % 2 == 0 ? 0.80 : 0.30
                pixels[o] = v; pixels[o + 1] = v; pixels[o + 2] = v; pixels[o + 3] = 1
            }
        }
        let (found, _) = SpotRepair.detect(DisplayImage(size: size, pixels: pixels))
        XCTAssertTrue(found.isEmpty, "起伏大的画面被当成一排污点，这是最坏的一类误检：\(found)")
    }

    func testSkinPixelsAreExcluded() {
        // 暗肤色块在灰背景上就是"一大片暗点"，肤色门必须把它整块排除。
        let w = size.width
        var image = canvas(size)
        var pixels = image.pixels
        for y in 20 ... 40 {
            for x in 20 ... 44 {
                let o = (y * w + x) * 4
                pixels[o] = 0.52; pixels[o + 1] = 0.36; pixels[o + 2] = 0.28
            }
        }
        image = DisplayImage(size: size, pixels: pixels)
        let (found, _) = SpotRepair.detect(image)
        XCTAssertTrue(found.isEmpty, "人身上的颜色被当成了背景污点：\(found)")
    }

    func testFaceBoxExcludesItsInterior() {
        let image = spot(canvas(size), x: 40, y: 30)
        let inside = SpotRepair.detect(image, faceBounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.25))
        XCTAssertTrue(inside.found.isEmpty,
                      "污点落在脸框里（鼻尖上的灰点）也不能自动提意修：\(inside.found)")
        let away = SpotRepair.detect(image, faceBounds: CGRect(x: 0.02, y: 0.02, width: 0.1, height: 0.1))
        XCTAssertEqual(away.found.count, 1, "脸框挪开后就该正常检出：\(away.found)")
        XCTAssertFalse(away.tokens.contains("[no_face_box]"),
                       "给了脸框就不该再报缺关键点：\(away.tokens)")
        XCTAssertTrue(SpotRepair.detect(image).tokens.contains("[no_face_box]"),
                      "没关键点时必须点名，只靠肤色判据兜不住")
    }

    func testOneBlobYieldsOneStrokeAndIsDeterministic() {
        // 5×5 的斑会被好几个像素同时命中；重叠抑制必须并成一两笔，否则接受一次
        // 提意 = 在原地糊两三遍。
        let big = spot(canvas(size), x: 40, y: 30, span: 2)
        let first = SpotRepair.detect(big)
        XCTAssertFalse(first.found.isEmpty, "5×5 的灰斑一个都检不出，说明抑制过头了")
        XCTAssertLessThanOrEqual(first.found.count, 2, "同一块污点被切成了多笔：\(first.found)")
        XCTAssertEqual(first.found, SpotRepair.detect(big).found,
                       "同一输入两次结果不同，检出器不能用于提意")
    }

    func testCapIsNamedNotSilent() {
        // 间距必须大于外窗半径的两倍，否则邻点会落进彼此的环域、把平坦度撑爆，
        // 检出一个都测不到 —— 那样这条断言就只是在看空气。
        let big = PixelSize(width: 320, height: 240)
        var image = canvas(big)
        for y in stride(from: 40, to: 220, by: 40) {
            for x in stride(from: 40, to: 300, by: 40) {
                image = spot(image, x: x, y: y)
            }
        }
        let (found, tokens) = SpotRepair.detect(image)
        XCTAssertGreaterThan(found.count, 0, "35 个分开摆的灰点一个都没检出：\(tokens)")
        XCTAssertLessThanOrEqual(found.count, SpotRepair.maxFindings, "超出上限必须夹住")
        XCTAssertTrue(tokens.contains("[spot-repair:capped]"),
                      "被截断必须说出来，否则用户以为背景干净：\(tokens)")
    }

    func testDegenerateInputIsNamed() {
        // 10×10 时 longEdge=10 → r1=2、r2=5，而环域要 11 像素宽——装不下，
        // 必须报 [too_small]。（换成 20×20 就装得下了，那条断言会变成假绿。）
        let tiny = SpotRepair.detect(canvas(PixelSize(width: 10, height: 10)))
        XCTAssertTrue(tiny.tokens.contains("[too_small]"),
                      "画布装不下内外窗时必须点名，而不是给一个看起来正常的空结果：\(tiny.tokens)")
    }
}
