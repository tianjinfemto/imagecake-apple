import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 初筛的几何两轴：闭眼与构图。都是**无量纲**比值，所以喂归一化点还是像素点结果一样
/// —— 这正是选这两个量的原因：`FaceGeometry` 的坐标空间跟着输入走，任何把半径和像素
/// 距离混在一起的判据都会从定义上错（镜片区已经栽过一次）。
final class FrameTriageGeometryTests: XCTestCase {
    /// 造一只眼：宽 0.1、高按张开度给。
    private func ring(openness: Double, center: CGPoint = CGPoint(x: 0.4, y: 0.45)) -> [CGPoint] {
        let halfW = 0.05
        let halfH = 0.05 * openness
        return (0 ..< 12).map { i in
            let t = Double(i) / 12 * 2 * Double.pi
            return CGPoint(x: center.x + CGFloat(cos(t) * halfW),
                           y: center.y + CGFloat(sin(t) * halfH))
        }
    }

    func testEyeOpennessIsTheRingAspectRatio() {
        let open = FrameTriage.eyeOpenness(ring: ring(openness: 0.36))
        let closed = FrameTriage.eyeOpenness(ring: ring(openness: 0.06))
        XCTAssertEqual(open ?? 0, 0.36, accuracy: 0.02, "圈高/圈宽本身就是定义，应当还原")
        XCTAssertEqual(closed ?? 0, 0.06, accuracy: 0.02)
        XCTAssertLessThan(closed ?? 1, FrameTriage.closedEyeLimit)
        XCTAssertGreaterThan(open ?? 0, FrameTriage.halfOpenLimit)
    }

    func testDimensionDoesNotChangeTheVerdict() {
        // 同一只眼，归一化坐标与"像素坐标"（乘 1000）必须给出同一个张开度。
        let small = ring(openness: 0.30)
        let scaled = small.map { CGPoint(x: $0.x * 1000, y: $0.y * 1000) }
        XCTAssertEqual(FrameTriage.eyeOpenness(ring: small) ?? 0,
                       FrameTriage.eyeOpenness(ring: scaled) ?? 0, accuracy: 1e-9,
                       "无量纲是这两轴的存在理由，一旦随尺度变就是错的")
    }

    func testWorseEyeWins() {
        // 一只眼睁、一只眼闭：取更闭的那只（挡住一只眼不该算通过）。
        let rings = [ring(openness: 0.40), ring(openness: 0.05, center: CGPoint(x: 0.6, y: 0.45))]
        XCTAssertEqual(FrameTriage.eyeOpenness(rings: rings) ?? 1, 0.05, accuracy: 0.02)
    }

    func testDegenerateRingsReturnNilNotZero() {
        XCTAssertNil(FrameTriage.eyeOpenness(ring: []), "空圈应当是「算不出」而不是「闭得完美」")
        XCTAssertNil(FrameTriage.eyeOpenness(ring: [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 2)]),
                     "两点圈宽度为 0，除法会炸")
        XCTAssertNil(FrameTriage.eyeOpenness(rings: []))
    }

    func testFramingMarginOnlyAnswersInNormalisedSpace() {
        let centred = [CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.7, y: 0.2),
                       CGPoint(x: 0.7, y: 0.9), CGPoint(x: 0.3, y: 0.9)]
        XCTAssertEqual(FrameTriage.framingMargin(points: centred) ?? 0, 0.1, accuracy: 1e-6)

        let cropped = [CGPoint(x: 0.0, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                       CGPoint(x: 0.9, y: 1.0), CGPoint(x: 0.0, y: 1.0)]
        XCTAssertEqual(FrameTriage.framingMargin(points: cropped) ?? 1, 0, accuracy: 1e-6,
                       "贴边必须量出 0，否则 [subject-at-edge] 永远不响")

        // 像素坐标下"到边距离"没有意义，必须给 nil 让调用侧点名，而不是报一个大数。
        let pixels = centred.map { CGPoint(x: $0.x * 1200, y: $0.y * 1600) }
        XCTAssertNil(FrameTriage.framingMargin(points: pixels),
                     "越界点被当成了正常构图余量，这正是假数的来源")
    }

    func testMissingLandmarksAreNamedNotSilent() {
        let v = FrameTriage.geometryReview(nil)
        XCTAssertTrue(v.tokens.contains("[no_landmarks]"),
                      "没有关键点必须点名；面板那行不能显示一个看起来正常的默认值")
        XCTAssertNil(v.eyeOpenness)
        XCTAssertTrue(v.keep, "缺件不该否决保留 —— 它只是「不知道」，不是「不好」")
        XCTAssertTrue(v.summary().contains("无关键点"))
    }
}
