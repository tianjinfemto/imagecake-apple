import CoreGraphics
import XCTest
@testable import ImageCake

/// 色轮的坐标数学。
///
/// 这一组断言存在的理由：色轮方向反了、死区算错了，在真机上看起来
/// 「就是不太好用」，没人能从截图上判断对错。抽成纯函数后，这些约定
/// 至少能被 CI 钉住。
final class WheelGeometryTests: XCTestCase {
    private let center = CGPoint(x: 100, y: 100)
    private let radius: CGFloat = 50

    /// 极坐标取样点。ratio 相对半径，degrees 用屏幕坐标（y 轴向下）。
    private func sample(ratio: Double, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let distance = ratio * Double(radius)
        return CGPoint(x: center.x + CGFloat(cos(radians) * distance),
                       y: center.y + CGFloat(sin(radians) * distance))
    }

    private func hue(_ adjustment: WheelAdjustment) -> Double {
        // nil（死区）用 nan 代替，这样断言会失败而不是静默通过。
        adjustment.hue ?? .nan
    }

    /// 约定：0° 在 3 点方向、顺时针增加；屏幕 y 轴向下，所以正角度落在下半圈。
    /// 这条如果反了，整个色轮的配色会镜像过来。
    func testCardinalDirectionsMapToExpectedHue() {
        let cases: [(name: String, degrees: Double, expected: Double)] = [
            ("右", 0, 0),
            ("下", 90, 90),
            ("左", 180, 180),
            ("上", -90, -90),
        ]
        for item in cases {
            let adjustment = WheelGeometry.adjust(at: sample(ratio: 1, degrees: item.degrees),
                                                 center: center, radius: radius)
            XCTAssertEqual(hue(adjustment), item.expected, accuracy: 0.01, "\(item.name)方向色相不对")
            XCTAssertEqual(adjustment.saturation, 100, accuracy: 0.01, "\(item.name)方向应满力度")
        }
    }

    /// 力度按到圆心的距离线性给。
    func testStrengthFollowsDistance() {
        for ratio in [0.1, 0.25, 0.5, 0.9] {
            let adjustment = WheelGeometry.adjust(at: sample(ratio: ratio, degrees: 0),
                                                 center: center, radius: radius)
            XCTAssertEqual(adjustment.saturation, ratio * 100, accuracy: 0.01,
                           "距离 \(ratio) 倍半径时力度应为 \(ratio * 100)")
        }
    }

    /// 拖到圈外不溢出：力度封顶，方向仍按指针角度算。
    func testOutsideRadiusClampsStrength() {
        let outside = CGPoint(x: center.x + radius * 4, y: center.y)
        let adjustment = WheelGeometry.adjust(at: outside, center: center, radius: radius)
        XCTAssertEqual(adjustment.saturation, 100, accuracy: 0.01)
        XCTAssertEqual(hue(adjustment), 0, accuracy: 0.01)
    }

    /// 死区内只把力度归零，**不动方向**——否则用户想撤销染色时，
    /// 原本选好的方向会被顺手重置成红色。
    func testDeadZoneClearsStrengthWithoutTouchingHue() {
        let inside = sample(ratio: WheelGeometry.deadZoneRatio * 0.5, degrees: 45)
        let adjustment = WheelGeometry.adjust(at: inside, center: center, radius: radius)
        XCTAssertNil(adjustment.hue, "死区内不该改方向")
        XCTAssertEqual(adjustment.saturation, 0)

        // 刚好压线外一点就该恢复工作。
        let justOutside = sample(ratio: WheelGeometry.deadZoneRatio * 1.2, degrees: 45)
        let resumed = WheelGeometry.adjust(at: justOutside, center: center, radius: radius)
        XCTAssertEqual(hue(resumed), 45, accuracy: 0.5)
    }

    /// location 是 adjust 的反函数：内部状态画成点、点再读回来，必须一致。
    func testLocationRoundTripsThroughAdjust() {
        for degrees in stride(from: -170.0, through: 170.0, by: 20) {
            let p = WheelGeometry.location(hue: degrees, saturation: 70, center: center, radius: radius)
            let adjustment = WheelGeometry.adjust(at: p, center: center, radius: radius)
            XCTAssertEqual(hue(adjustment), degrees, accuracy: 0.01, "色相 \(degrees) 往返不一致")
            XCTAssertEqual(adjustment.saturation, 70, accuracy: 0.01)
        }
    }

    /// 力度为 0 时手柄应落在圆心（而不是停在某个随机角度上）。
    func testZeroStrengthPutsHandleAtCenter() {
        let p = WheelGeometry.location(hue: 120, saturation: 0, center: center, radius: radius)
        XCTAssertEqual(p.x, center.x, accuracy: 0.01)
        XCTAssertEqual(p.y, center.y, accuracy: 0.01)
    }

    /// 半径为 0 时不能崩，也不该给一个方向。
    func testZeroRadiusIsSafe() {
        let adjustment = WheelGeometry.adjust(at: center, center: center, radius: 0)
        XCTAssertNil(adjustment.hue)
        XCTAssertEqual(adjustment.saturation, 0)
    }
}
