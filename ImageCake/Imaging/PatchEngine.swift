import CoreGraphics
import Foundation

// 修补工具 / 祛路人：同图取样修复。
//
// 与 LaMa 的区别：LaMa 是 AI 语义修复（造内容），修补工具是同图取样
// （从同一张图的别处搬纹理过来）。用户指定一个源点 + 一个目标区域，
// 算子按偏移量把源区域的内容搬到目标区域，用羽化掩码混合。
//
// 用途：祛路人（把路人区域用旁边的背景填掉）、去瑕疵（用附近干净皮肤
// 填掉痘痘/划痕）。比 LaMa 快得多（零推理），但只适合"附近有可搬的
// 内容"的场景。

struct PatchStroke: Equatable, Sendable {
    /// 源点（归一化），取样锚点。
    var source: CGPoint
    /// 目标笔迹点（归一化），与 CloneStamp 同构。
    var points: [CGPoint]
    /// 笔刷半径（归一化）。
    var radius: Double
    /// 羽化硬度 0...1。
    var hardness: Double
}

enum PatchEngine {
    /// 把修补笔迹应用到画面上。与 CloneStampEngine.apply 同构，
    /// 但源点是固定的偏移量而不是动态取样。
    static func apply(_ image: DisplayImage, strokes: [PatchStroke]) -> DisplayImage {
        guard !strokes.isEmpty else { return image }
        let w = image.size.width
        let h = image.size.height
        let c = 4
        var result = image.pixels
        let src = image.pixels

        for stroke in strokes {
            let pixelRadius = max(1, Int(stroke.radius * Double(max(w, h))))
            let offsetX = Int((stroke.source.x - (stroke.points.first?.x ?? stroke.source.x)) * Double(w))
            let offsetY = Int((stroke.source.y - (stroke.points.first?.y ?? stroke.source.y)) * Double(h))

            for point in stroke.points {
                let cx = Int(point.x * Double(w))
                let cy = Int(point.y * Double(h))
                for y in (cy - pixelRadius)...(cy + pixelRadius) {
                    guard y >= 0, y < h else { continue }
                    for x in (cx - pixelRadius)...(cx + pixelRadius) {
                        guard x >= 0, x < w else { continue }
                        let dx = x - cx
                        let dy = y - cy
                        let dist = sqrt(Double(dx * dx + dy * dy))
                        if dist > Double(pixelRadius) { continue }
                        let weight = weightAt(dist, radius: Double(pixelRadius), hardness: stroke.hardness)
                        let sx = x + offsetX
                        let sy = y + offsetY
                        guard sx >= 0, sx < w, sy >= 0, sy < h else { continue }
                        for ch in 0..<c {
                            let srcIdx = (sy * w + sx) * c + ch
                            let dstIdx = (y * w + x) * c + ch
                            result[dstIdx] = Float(Double(result[dstIdx]) * (1 - weight) + Double(src[srcIdx]) * weight)
                        }
                    }
                }
            }
        }
        return DisplayImage(size: PixelSize(width: w, height: h), pixels: result)
    }

    private static func weightAt(_ dist: Double, radius: Double, hardness: Double) -> Double {
        if dist >= radius { return 0 }
        let t = dist / radius
        return 1 - pow(t, 1.0 / max(0.01, 1 - hardness))
    }
}