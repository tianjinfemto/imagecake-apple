import CoreGraphics
import Foundation

// 本地调节：在选区内只改调色参数，选区外不动。
//
// 选区复用笔迹底座（BrushState 的 protection 笔迹），语义是"这个区域内
// 用这组参数"。渲染时把全图调色结果与选区调色结果按掩码混合。
//
// 与全局调色的区别：全局调色是全图一个参数集；本地调节是若干个
// (选区, 参数集) 对，按选区掩码叠加。实现上不是两次全图调色——
// 而是在 ToneEngine 里按掩码混合调色结果。

struct LocalAdjustment: Equatable, Sendable {
    /// 选区笔迹（归一化坐标），与 BrushStroke 同构。
    var mask: BrushStroke
    /// 这个选区内用的调色参数（只取曝光/对比/饱和等标量，色轮/HSL 不做本地）。
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var sharpness: Double = 0
    /// 羽化半径（归一化），让选区边缘不硬。
    var feather: Double = 0.02
    var enabled: Bool = true
}

extension LocalAdjustment {
    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && saturation == 0
            && temperature == 0 && tint == 0 && sharpness == 0
    }
}

enum LocalAdjustmentEngine {
    /// 把本地调节应用到已调色的画面上。
    /// 全局调色已在 render() 里做完了，这里只做"选区内再调一层"。
    static func apply(_ image: DisplayImage, adjustments: [LocalAdjustment], linear: LinearImage) -> DisplayImage {
        guard adjustments.contains(where: { $0.enabled && !$0.isNeutral }) else { return image }
        var result = image
        for adj in adjustments where adj.enabled && !adj.isNeutral {
            let mask = StrokeRasterizer.rasterize(adj.mask, in: image.size)
            let feathered = MaskOps.feathered(mask, radius: max(1, Int(adj.feather * Double(max(image.size.width, image.size.height)))))
            let localParams = localParams(from: adj)
            let locallyToned = ToneEngine.render(linear, params: localParams)
            result = blend(base: result, overlay: locallyToned, mask: feathered)
        }
        return result
    }

    private static func localParams(from adj: LocalAdjustment) -> EditParameters {
        var p = EditParameters()
        p.exposure = adj.exposure
        p.contrast = adj.contrast
        p.saturation = adj.saturation
        p.temperature = adj.temperature
        p.tint = adj.tint
        p.sharpen = adj.sharpness
        return p
    }

    private static func blend(base: DisplayImage, overlay: DisplayImage, mask: MaskBuffer) -> DisplayImage {
        let w = base.size.width
        let h = base.size.height
        let c = base.channels
        var result = base.floats
        let overlayFloats = overlay.floats
        mask.data.withUnsafeBytes { maskPtr in
            let maskBytes = maskPtr.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) {
                let m = Double(maskBytes[i]) / 255
                for ch in 0..<c {
                    result[i * c + ch] = Float(Double(result[i * c + ch]) * (1 - m) + Double(overlayFloats[i * c + ch]) * m)
                }
            }
        }
        return DisplayImage(width: w, height: h, channels: c, floats: result)
    }
}