import CoreGraphics
import Foundation

// 色轮控件的坐标数学。
//
// 为什么从 ColorWheelControl 里抽出来：这一段是最容易错、又最没法靠肉眼发现
// 的那类逻辑——屏幕 y 轴朝下（正角度落在下半圈）、盘面用 0...360 而模型用
// -180...180、死区里该不该动色相。抽成纯函数就能在 CI 里钉住（真机上看不出
// 一个方向反了的色轮），View 只负责画和转发手势。

/// 一次拖动的结果。
struct WheelAdjustment: Equatable {
    /// 色相。死区内为 nil——表示「保持原色相，只把力度归零」，
    /// 而不是把方向也重置成红色。
    var hue: Double?

    /// 力度，0...100。0 = 不染色。
    var saturation: Double
}

enum WheelGeometry {
    /// 圆心附近这个比例内视为「不推」。手抖残留一个 sat=1 会让整张图带一个
    /// 几乎看不见的染色，用户无从判断自己到底动没动过。
    static let deadZoneRatio: Double = 0.04

    /// 屏幕坐标 → 模型参数。
    ///
    /// 约定：圆心 = 不推，外圈 = 满力度；0° 在 3 点方向，顺时针增加
    /// （右 红 → 下 黄绿 → 左 青 → 上 紫）。这与 Canvas 画色相环的
    /// addArc 方向一致，所以手柄所指的颜色就是实际会得到的方向。
    ///
    /// 返回的 hue 落在 -180...180，与 `EditParameters` 的取值区间一致。
    static func adjust(at point: CGPoint,
                       center: CGPoint,
                       radius: CGFloat) -> WheelAdjustment {
        guard radius > 0 else { return WheelAdjustment(hue: nil, saturation: 0) }

        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let ratio = (dx * dx + dy * dy).squareRoot() / Double(radius)

        if ratio < deadZoneRatio {
            return WheelAdjustment(hue: nil, saturation: 0)
        }

        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        if degrees > 180 { degrees -= 360 }
        return WheelAdjustment(hue: degrees, saturation: min(ratio, 1) * 100)
    }

    /// 模型参数 → 屏幕坐标。`adjust(at:)` 的反函数。
    /// hue 为 nil 时按 0° 处理（此时 saturation 通常也是 0，方向无意义）。
    static func location(hue: Double?,
                         saturation: Double,
                         center: CGPoint,
                         radius: CGFloat) -> CGPoint {
        let raw = hue ?? 0
        let degrees = raw < 0 ? raw + 360 : raw
        let radians = degrees * .pi / 180
        let distance = Double(radius) * min(max(saturation / 100, 0), 1)
        return CGPoint(x: center.x + CGFloat(cos(radians) * distance),
                       y: center.y + CGFloat(sin(radians) * distance))
    }
}
