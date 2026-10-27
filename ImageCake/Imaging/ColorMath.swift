import Foundation

// 色彩数学的公共底座。
//
// 为什么 sRGB 传递函数要自己写而不是交给 Core Image：预览、导出、AI 预处理
// 三条路都要做"线性 ↔ 显示码"的换算，而 Core Image 的自动色彩管理会在
// 不同平台上给出不同的隐藏路径（CIContext 的 working color space 默认随
// 系统设置变）。同一套参数在导出件上换一个像素，用户是看得出来的。
//
// 数值口径与 imagecake 一致：sRGB 分段函数（0.04045 / 12.92 / 2.4），
// 亮度权重 Rec.709（0.2126/0.7152/0.0722）。

enum ColorMath {
    static let lumaR: Float = 0.2126
    static let lumaG: Float = 0.7152
    static let lumaB: Float = 0.0722

    /// 8bit 显示码 → 线性。256 项精确表（没有插值误差）。
    static let decodeU8: [Float] = (0 ... 255).map { i in
        let c = Double(i) / 255.0
        return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
    }

    /// 线性 → 显示码 [0,1]。4096 项 + 线性插值（量化误差 < 1/4096）。
    static let encodeLUT: [Float] = {
        let n = 4096
        return (0 ..< n).map { i -> Float in
            let c = Double(i) / Double(n - 1)
            return Float(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
        }
    }()

    @inline(__always)
    static func encode(_ linear: Float) -> Float {
        if linear <= 0 { return 0 }
        if linear >= 1 { return 1 }
        let pos = linear * Float(encodeLUT.count - 1)
        let i = Int(pos)
        let f = pos - Float(i)
        if i >= encodeLUT.count - 1 { return encodeLUT[encodeLUT.count - 1] }
        return encodeLUT[i] + (encodeLUT[i + 1] - encodeLUT[i]) * f
    }

    @inline(__always)
    static func decode(_ display: Float) -> Float {
        if display <= 0 { return 0 }
        if display >= 1 { return 1 }
        let c = Double(display)
        return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
    }

    @inline(__always)
    static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        lumaR * r + lumaG * g + lumaB * b
    }

    // MARK: - HSV

    /// RGB（显示域 0..1）→ HSV。h 单位度、[0,360)。s/v ∈ [0,1]。
    @inline(__always)
    static func rgbToHSV(_ r: Float, _ g: Float, _ b: Float) -> (h: Float, s: Float, v: Float) {
        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let delta = maxV - minV
        var h: Float = 0
        if delta > 1e-7 {
            if maxV == r {
                h = 60 * ((g - b) / delta)
            } else if maxV == g {
                h = 60 * (2 + (b - r) / delta)
            } else {
                h = 60 * (4 + (r - g) / delta)
            }
            if h < 0 { h += 360 }
        }
        let s: Float = maxV <= 1e-7 ? 0 : delta / maxV
        return (h, s, maxV)
    }

    @inline(__always)
    static func hsvToRGB(_ h: Float, _ s: Float, _ v: Float) -> (r: Float, g: Float, b: Float) {
        if s <= 1e-7 { return (v, v, v) }
        var hh = h.truncatingRemainder(dividingBy: 360)
        if hh < 0 { hh += 360 }
        let sector = hh / 60
        let i = Int(sector)
        let f = sector - Float(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    // MARK: - 色轮

    /// 八分区中心色相（度）：红/橙/黄/绿/青/蓝/紫/品红。
    /// 与 imagecake 的"参数序"对齐；它内部按 CbCr 角度重排，我们在显示域
    /// 用标准色相中心，序一致、数值不共享（预设数组仍可互换）。
    static let bandCenters: [Float] = [0, 30, 60, 120, 180, 240, 285, 320]

    /// 环距（度），归一到 (-180, 180]。
    @inline(__always)
    static func hueDistance(_ a: Float, _ b: Float) -> Float {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// 色轮手柄指向的"注入色"：某个色相在显示域推满后的偏移向量。
    /// 取 HSV(s=1,v=1) 再减掉自身亮度——盘面上手柄的方向就是实际会得到的
    /// 色偏方向，并且中性注入为 0（不会顺手把整张图提亮）。
    static func wheelTint(hueDegrees: Double) -> (r: Float, g: Float, b: Float) {
        let (r, g, b) = hsvToRGB(Float(hueDegrees), 1, 1)
        let y = luma(r, g, b)
        return (r - y, g - y, b - y)
    }

    /// 三区权重：和恒为 1（0.5 亮度处中间调为 1）。
    @inline(__always)
    static func zoneWeights(luma y: Float) -> (shadows: Float, mids: Float, highlights: Float) {
        let shadows = clamp(1 - 2 * y, 0, 1)
        let highlights = clamp(2 * y - 1, 0, 1)
        return (shadows, 1 - shadows - highlights, highlights)
    }

    @inline(__always)
    static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        Swift.min(Swift.max(v, lo), hi)
    }
}
