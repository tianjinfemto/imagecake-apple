import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 背景污点检出。两条硬性纪律来自上一轮的失败：
/// ① 判据必须**同时覆盖 3×3 / 5×5 / 7×7 三种尺寸** —— 上次只测一种，CI 上另一格
///    才暴露出环统计被高斯近似污染；
/// ② 反误检（纹理、人身上的颜色、脸框内）比检得多更值钱，每种都单独钉。
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

    private func blob(_ image: DisplayImage, x: Int, y: Int, span: Int,
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

    /// 三种尺寸各检出且只检出 1 个 —— 这正是上一轮崩掉的地方。
    func testThreeBlobSizesEachYieldExactlyOneFinding() {
        for span in [1, 2, 3] {
            let side = 2 * span + 1
            let (found, tokens) = SpotRepair.detect(blob(canvas(size), x: 40, y: 30, span: span))
            XCTAssertEqual(found.count, 1, "\(side)×\(side) 灰斑应检出 1 个，实际 \(found.count)：\(tokens)")
            XCTAssertEqual(tokens.first, "[spot-repair:1]", "令牌要报数量：\(tokens)")
            XCTAssertEqual(found[0].at.x, CGFloat(40) / CGFloat(size.width), accuracy: 0.05,
                           "\(side)×\(side) 的位置偏了：\(found)")
            XCTAssertGreaterThan(found[0].source.y, found[0].at.y, "取样点必须落在别处")
        }
    }

    func testCleanFlatBackgroundFindsNothing() {
        let (found, tokens) = SpotRepair.detect(canvas(size))
        XCTAssertTrue(found.isEmpty, "干净平坦背景不该有检出：\(found)")
        XCTAssertTrue(tokens.contains("[spot-repair:none]"), "空结果要点名：\(tokens)")
    }

    func testFineTextureIsNotMistakenForDust() {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                let v: Float = (x / 2 + y / 2) % 2 == 0 ? 0.80 : 0.30
                pixels[o] = v; pixels[o + 1] = v; pixels[o + 2] = v; pixels[o + 3] = 1
            }
        }
        let (found, _) = SpotRepair.detect(DisplayImage(size: size, pixels: pixels))
        XCTAssertTrue(found.isEmpty, "细纹理被当成一排污点是最坏的一类误检：\(found)")
    }

    func testSkinColoursAreExcluded() {
        let w = size.width
        var pixels = canvas(size).pixels
        for y in 20 ... 40 {
            for x in 20 ... 44 {
                let o = (y * w + x) * 4
                pixels[o] = 0.52; pixels[o + 1] = 0.36; pixels[o + 2] = 0.28
            }
        }
        let (found, _) = SpotRepair.detect(DisplayImage(size: size, pixels: pixels))
        XCTAssertTrue(found.isEmpty, "人身上的颜色不能当背景污点：\(found)")
    }

    func testFaceBoxExcludesItsInterior() {
        let image = blob(canvas(size), x: 40, y: 30, span: 1)
        let inside = SpotRepair.detect(image, faceBounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.25))
        XCTAssertTrue(inside.found.isEmpty, "脸框内的点不自动提意修：\(inside.found)")
        let away = SpotRepair.detect(image, faceBounds: CGRect(x: 0.02, y: 0.02, width: 0.1, height: 0.1))
        XCTAssertEqual(away.found.count, 1, "脸框挪开后应正常检出：\(away.found)")
        XCTAssertFalse(away.tokens.contains("[no_face_box]"), "给了脸框就不该报缺关键点：\(away.tokens)")
        XCTAssertTrue(SpotRepair.detect(image).tokens.contains("[no_face_box]"),
                      "没有关键点时必须点名——只靠肤色判据兜不住人")
    }

    func testRepeatedRunsAgreeOnTiedDepths() {
        // 一个斑里多个像素深度完全相同，而 Swift 的排序不保证稳定；并列时必须按
        // 下标定序，否则同一输入两次会挑中不同的那个点。
        let image = blob(canvas(size), x: 40, y: 30, span: 3)
        let first = SpotRepair.detect(image)
        for _ in 0 ..< 5 {
            XCTAssertEqual(SpotRepair.detect(image).found, first.found,
                           "并列深度的取舍不稳定")
        }
    }

    func testCapIsNamedNotSilent() {
        // 间距必须大于外窗半径两倍，否则邻点互相污染环域，一格都检不出而断言会假绿。
        let grid = PixelSize(width: 320, height: 240)
        var image = canvas(grid)
        for y in stride(from: 40, to: 220, by: 40) {
            for x in stride(from: 40, to: 300, by: 40) {
                image = blob(image, x: x, y: y, span: 1)
            }
        }
        let (found, tokens) = SpotRepair.detect(image)
        XCTAssertEqual(found.count, SpotRepair.maxFindings, "应被截在上限：\(found.count)")
        XCTAssertTrue(tokens.contains("[spot-repair:capped]"),
                      "截断必须说出来，否则用户以为背景干净：\(tokens)")
    }

    func testCanvasTooSmallForTheRingIsNamed() {
        // 10×10 → r1=3、r2=7，内外窗共需要 15 像素宽，装不下：必须点名，
        // 而不是给一个看起来正常的空结果。
        let tiny = SpotRepair.detect(canvas(PixelSize(width: 10, height: 10)))
        XCTAssertTrue(tiny.tokens.contains("[too_small]"), "小画布要点名：\(tiny.tokens)")
    }
}
