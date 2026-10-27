import Foundation

// 调色链。顺序是产品语义，不是实现细节，写在这里一次，别处不许重排：
//
//   线性域：曝光 → 色温/色调
//   转显示域
//   显示域：对比 → 四条曲线（RGB 复合在前、单通道在后）→ 三区色轮
//           → 八分区 HSL + 色相旋转 + 饱和度
//
// 为什么色轮在 HSL 之前：色轮按亮度分区推整片颜色（阴影像左、高光偏右），
// HSL 只动"落在某个色相附近"的像素。反过来会让 HSL 之后又整片染色，
// 用户会觉得"我调的那块颜色被拉走了"。
//
// 性能闸门：每一项在中性时整段跳过（isNeutral 那组谓词）。这不是优化癖好：
// 12MP 图上一次 HSV 往返是秒级的，滑杆拖动会因此变成幻灯片。

enum ToneEngine {
    static func render(_ source: LinearImage, params: EditParameters) -> DisplayImage {
        let size = source.size
        guard size.pixelCount > 0 else { return DisplayImage(size: size, pixels: []) }

        let p = params
        let count = size.pixelCount

        // —— 线性域预计算 ——
        let exposureGain = Float(pow(2.0, p.exposure))
        let temp = p.temperatureGain
        let tint = p.tintGain
        let gainR = Float(temp.r * tint.rb) * exposureGain
        let gainB = Float(temp.b * tint.rb) * exposureGain
        let gainG = Float(tint.g) * exposureGain
        let linearActive = !p.isLinearNeutral

        // —— 显示域预计算 ——
        let contrastGain = Float(pow(2.0, p.contrast / 100))
        let contrastActive = p.contrast != 0

        let curveLUTs: [[Float]]? = p.curves.allSatisfy(\.isIdentity) ? nil : p.curves.map { CurveMath.lut($0) }

        let wheelActive = !p.isWheelsNeutral
        let wheelShadows = wheelOffset(hue: p.wshHue, sat: p.wshSat, lum: p.wshLum)
        let wheelMids = wheelOffset(hue: p.wmtHue, sat: p.wmtSat, lum: p.wmtLum)
        let wheelHighlights = wheelOffset(hue: p.whlHue, sat: p.whlSat, lum: p.whlLum)

        let hslActive = !p.isHSLNeutral
        let hueShift = Float(p.hue)
        let saturationFactor = Float(1 + p.saturation / 100)
        let hsvActive = hslActive || hueShift != 0 || p.saturation != 0
        let hslHue = p.hslHue.map { Float($0) }
        let hslSat = p.hslSat.map { Float($0) }
        let hslLum = p.hslLum.map { Float($0) }
        let bandCenters = ColorMath.bandCenters

        let src = source.pixels
        let dst = UnsafeMutablePointer<Float>.allocate(capacity: count * 4)
        dst.initialize(repeating: 0, count: count * 4)
        defer { dst.deallocate() }

        let bands = min(max(1, ProcessInfo.processInfo.activeProcessorCount), 16)

        src.withUnsafeBufferPointer { srcPtr in
            let base = srcPtr.baseAddress!
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let start = count * band / bands
                let end = count * (band + 1) / bands
                var i = start
                while i < end {
                    let o = i * 4
                    var r = base[o]
                    var g = base[o + 1]
                    var b = base[o + 2]

                    if linearActive {
                        r *= gainR
                        g *= gainG
                        b *= gainB
                    }

                    // 线性 → 显示（裁剪在线性域做：超过 1 的部分保留为白）
                    r = ColorMath.encode(r)
                    g = ColorMath.encode(g)
                    b = ColorMath.encode(b)

                    if contrastActive {
                        r = (r - 0.5) * contrastGain + 0.5
                        g = (g - 0.5) * contrastGain + 0.5
                        b = (b - 0.5) * contrastGain + 0.5
                    }

                    if let luts = curveLUTs {
                        var rr = CurveMath.sample(luts[0], r)
                        var gg = CurveMath.sample(luts[0], g)
                        var bb = CurveMath.sample(luts[0], b)
                        rr = CurveMath.sample(luts[1], rr)
                        gg = CurveMath.sample(luts[2], gg)
                        bb = CurveMath.sample(luts[3], bb)
                        r = rr; g = gg; b = bb
                    }

                    if wheelActive {
                        let y = ColorMath.luma(r, g, b)
                        let w = ColorMath.zoneWeights(luma: y)
                        r += wheelShadows.r * w.shadows + wheelMids.r * w.mids + wheelHighlights.r * w.highlights
                        g += wheelShadows.g * w.shadows + wheelMids.g * w.mids + wheelHighlights.g * w.highlights
                        b += wheelShadows.b * w.shadows + wheelMids.b * w.mids + wheelHighlights.b * w.highlights
                    }

                    if hsvActive {
                        let hsv = ColorMath.rgbToHSV(clamp01(r), clamp01(g), clamp01(b))
                        var hue = hsv.h + hueShift
                        var sat = hsv.s * saturationFactor
                        var value = hsv.v

                        if hslActive {
                            var sumW: Float = 0
                            var hueAdj: Float = 0
                            var satAdj: Float = 0
                            var lumAdj: Float = 0
                            // 色相带权重：环距 45° 内线性衰减，一条带最多影响 ±45°，
                            // 相邻带中心距 30/60/60…，重叠区按权重和归一（不会叠加成 2 倍）。
                            for band in 0 ..< bandCenters.count {
                                let distance = abs(ColorMath.hueDistance(hsv.h, bandCenters[band]))
                                guard distance < 45 else { continue }
                                let weight = 1 - distance / 45
                                sumW += weight
                                hueAdj += hslHue[band] * weight
                                satAdj += hslSat[band] * weight
                                lumAdj += hslLum[band] * weight
                            }
                            if sumW > 1e-5 {
                                hue += hueAdj / sumW
                                sat *= 1 + (satAdj / sumW) / 100
                                value *= 1 + (lumAdj / sumW) / 200
                            }
                        }

                        let rgb = ColorMath.hsvToRGB(hue, clamp01(sat), clamp01(value))
                        r = rgb.r; g = rgb.g; b = rgb.b
                    }

                    dst[o] = clamp01(r)
                    dst[o + 1] = clamp01(g)
                    dst[o + 2] = clamp01(b)
                    dst[o + 3] = base[o + 3]
                    i += 1
                }
            }
        }

        let pixels = Array(UnsafeBufferPointer(start: dst, count: count * 4))
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 色轮偏移：sat 决定染色力度，lum 决定该区的明暗。两者都在显示域，
    /// 且色轮注入先减掉自身亮度，所以"只推色不推亮"是默认行为。
    private static func wheelOffset(hue: Double, sat: Double, lum: Double) -> (r: Float, g: Float, b: Float) {
        let tint = ColorMath.wheelTint(hueDegrees: hue)
        let strength = Float(sat / 100) * 0.35
        let lift = Float(lum / 100) * 0.25
        return (tint.r * strength + lift, tint.g * strength + lift, tint.b * strength + lift)
    }

    @inline(__always)
    private static func clamp01(_ v: Float) -> Float {
        Swift.min(Swift.max(v, 0), 1)
    }
}
