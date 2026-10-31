import CoreGraphics
import Foundation

// 本地调节：在选区内只改调色参数，选区外不动。
//
// 选区有三种形状（`LocalMask`）：画笔笔迹、径向渐变、线性渐变。
// 像素蛋糕把"径向/线性/画笔蒙版"当作专业修图的基本盘，而本仓之前只有
// 笔迹那一种——径向与线性不是"另一种笔刷"，它们的权重是**连续渐变**而不是
// "盖到哪算哪"，所以栅格化单独一条路径，不塞进 StrokeRasterizer。
//
// 渲染时把全图调色结果与选区调色结果按掩码混合。与全局调色的区别：
// 全局调色是全图一个参数集；本地调节是若干个 (选区, 参数集) 对。
// 实现上不是两次全图调色——而是在 ToneEngine 之外按掩码混合。

/// 本地调节的选区。坐标归一化（0…1，y 向下），与笔迹同口径，
/// 所以预览档与全分辨率导出之间不需要换算。
enum LocalMask: Equatable, Sendable {
    /// 画笔笔迹（复用 StrokeRasterizer）。
    case stroke(BrushStroke)
    /// 径向：中心在 `center`，半径 `radius`（相对长边），中心满、边缘 0。
    case radial(center: CGPoint, radius: Double)
    /// 线性：沿 from → to 方向的一条形带，`width` 是半宽（相对长边）。
    /// 坡道从 from 处 0 到 to 处 1（所以"往哪推"就是"往哪边亮"）。
    case linear(from: CGPoint, to: CGPoint, width: Double)

    static func rasterize(_ mask: LocalMask, size: PixelSize) -> MaskBuffer {
        switch mask {
        case .stroke(let stroke):
            return StrokeRasterizer.mask(strokes: [stroke], size: size)
        case .radial(let center, let radius):
            let px = CGPoint(x: center.x * CGFloat(size.width), y: center.y * CGFloat(size.height))
            // x/y 分开给半径，作用域在屏幕上才是圆的。
            let r = radius * Double(size.longEdge)
            let ratio = Double(size.height) > 0 ? Double(size.width) / Double(size.height) : 1
            return RegionRaster.disk(center: px, radiusX: r, radiusY: r * ratio, size: size)
        case .linear(let from, let to, let width):
            return linearMask(from: from, to: to, width: width, size: size)
        }
    }

    private static func linearMask(from: CGPoint, to: CGPoint, width: Double, size: PixelSize) -> MaskBuffer {
        guard size.pixelCount > 0 else { return MaskBuffer.filled(size, value: 0) }
        let w = Double(size.width), h = Double(size.height)
        let ax = Double(from.x) * w, ay = Double(from.y) * h
        let bx = Double(to.x) * w, by = Double(to.y) * h
        let vx = bx - ax, vy = by - ay
        let length2 = vx * vx + vy * vy
        guard length2 > 1e-9 else { return MaskBuffer.filled(size, value: 0) }
        let halfWidth = Swift.max(1, width * Double(size.longEdge))
        var bytes = [UInt8](repeating: 0, count: size.pixelCount)
        for y in 0 ..< size.height {
            let row = y * size.width
            let py = Double(y) + 0.5 - ay
            for x in 0 ..< size.width {
                let px = Double(x) + 0.5 - ax
                // t = 沿方向的投影（归一化到 from→to，0 = from 处，1 = to 处），
                // n = 到轴线的垂距。两个权重相乘就是条形的渐变。
                let t = (px * vx + py * vy) / length2
                let n = abs(px * vy - py * vx) / length2.squareRoot()
                let across = Swift.min(1, Swift.max(0, 1 - n / halfWidth))
                let along = Swift.min(1, Swift.max(0, t))
                let value = across * along
                if value > 0 { bytes[row + x] = UInt8((value * 255).rounded()) }
            }
        }
        return MaskBuffer(size: size, data: Data(bytes))
    }
}

struct LocalAdjustment: Equatable, Sendable {
    /// 选区。画笔/径向/线性三选一。
    var mask: LocalMask
    /// 这个选区内用的调色参数（只取曝光/对比/饱和等标量，色轮/HSL 不做本地）。
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var sharpness: Double = 0
    /// 羽化半径（归一化），让选区边缘不硬。径向/线性本来就是渐变，
    /// 这一项主要给笔迹选区用。
    var feather: Double = 0.02
    var enabled: Bool = true
}

extension LocalAdjustment {
    /// 笔迹选区的便捷入口（与旧写法一致：`mask` 直接给一条 BrushStroke）。
    init(mask: BrushStroke, exposure: Double = 0, contrast: Double = 0, saturation: Double = 0,
         temperature: Double = 0, tint: Double = 0, sharpness: Double = 0, feather: Double = 0.02) {
        self.init(mask: LocalMask.stroke(mask), exposure: exposure, contrast: contrast,
                  saturation: saturation, temperature: temperature, tint: tint,
                  sharpness: sharpness, feather: feather)
    }
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
            let mask = LocalMask.rasterize(adj.mask, size: image.size)
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
        let c = 4
        var result = base.pixels
        let overlayFloats = overlay.pixels
        mask.data.withUnsafeBytes { maskPtr in
            let maskBytes = maskPtr.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) {
                let m = Double(maskBytes[i]) / 255
                for ch in 0..<c {
                    result[i * c + ch] = Float(Double(result[i * c + ch]) * (1 - m) + Double(overlayFloats[i * c + ch]) * m)
                }
            }
        }
        return DisplayImage(size: PixelSize(width: w, height: h), pixels: result)
    }
}