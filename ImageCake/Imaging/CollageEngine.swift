import CoreGraphics
import Foundation

// 拼图排版：把多张图按模板排到一张画布上。
//
// 模板是确定性的几何布局（不是 AI）：网格/瀑布/拼贴/相框。
// 每个槽位指定位置与尺寸（归一化），图按 contain/cover 适配。
//
// v1 提供 4 种模板：1×2、2×1、2×2、1×3。

struct CollageTemplate: Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var columns: Int
    var rows: Int
    /// 每个槽位的归一化矩形（0...1），按行优先序。
    var slots: [CGRect]
    /// 槽间距（归一化）。
    var gap: Double = 0.01
    /// 背景色。
    var background: RGBA8 = RGBA8(r: 255, g: 255, b: 255)
}

enum CollageEngine {
    static let templates: [CollageTemplate] = [
        CollageTemplate(name: "1×2 横排", columns: 2, rows: 1,
                        slots: [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                                CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]),
        CollageTemplate(name: "2×1 竖排", columns: 1, rows: 2,
                        slots: [CGRect(x: 0, y: 0, width: 1, height: 0.5),
                                CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]),
        CollageTemplate(name: "2×2 网格", columns: 2, rows: 2,
                        slots: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                                CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                                CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]),
        CollageTemplate(name: "1×3 横排", columns: 3, rows: 1,
                        slots: [CGRect(x: 0, y: 0, width: 1.0/3, height: 1),
                                CGRect(x: 1.0/3, y: 0, width: 1.0/3, height: 1),
                                CGRect(x: 2.0/3, y: 0, width: 1.0/3, height: 1)])
    ]

    /// 把多张图按模板排到一张画布上。
    /// canvasSize 是输出画布尺寸；images 数量必须 >= slots 数量。
    static func compose(images: [RGBA8Buffer], template: CollageTemplate,
                        canvasSize: PixelSize) -> RGBA8Buffer? {
        guard images.count >= template.slots.count else { return nil }
        var canvas = [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height * 4)
        for i in 0..<canvasSize.height {
            for j in 0..<canvasSize.width {
                let idx = (i * canvasSize.width + j) * 4
                canvas[idx] = template.background.r
                canvas[idx + 1] = template.background.g
                canvas[idx + 2] = template.background.b
                canvas[idx + 3] = 255
            }
        }
        for (slot, image) in zip(template.slots, images) {
            let rect = PixelRect.fromNormalized(slot, in: canvasSize)
            let resized = image.resized(to: rect.size)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let cx = rect.x + x
                    let cy = rect.y + y
                    guard cx >= 0, cx < canvasSize.width, cy >= 0, cy < canvasSize.height else { continue }
                    let srcIdx = (y * rect.width + x) * 4
                    let dstIdx = (cy * canvasSize.width + cx) * 4
                    canvas[dstIdx] = resized.data[srcIdx]
                    canvas[dstIdx + 1] = resized.data[srcIdx + 1]
                    canvas[dstIdx + 2] = resized.data[srcIdx + 2]
                    canvas[dstIdx + 3] = resized.data[srcIdx + 3]
                }
            }
        }
        return RGBA8Buffer(size: canvasSize, data: Data(canvas))
    }
}