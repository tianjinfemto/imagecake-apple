import Foundation

// 镜头校正与画质层：畸变、色差、暗角、颗粒。
//
// 分成两个入口而不是一个，因为它们在管线里的**位置**不一样：
//   · `applyGeometry`（畸变 + 色差）改像素位置，必须在液化/图章/补丁之前跑——
//     笔刷坐标活在"用户看到的画面"上，画面被再次挪位之后笔迹就会漂；
//   · `applyOverlay`（暗角 + 颗粒）是输出层的风格，放在最后一道（导出端 AI
//     之前），这样超清/重绘不会把颗粒当细节放大成麻点。
//
// 三个决定都是纯函数（`radiusMap` / `caScale` / `vignetteWeight` / `hashNoise`），
// 可以脱离图像断言。颗粒用整数混合而不是系统随机数：同一坐标必须永远得到
// 同一个噪声值，否则"两次导出逐比特一致"这条承诺就没了，用户比对差异时会
// 以为是 bug。

enum LensEngine {
    // MARK: - 纯几何（可断言）

    /// 畸变的径向映射：输出半径 ρ（0 = 中心，1 = 角点）→ 采样半径。
    /// `k > 0` 从更外面取样（画面边缘向内收，等价于桶形校正的补集），
    /// `k < 0` 反之。ρ = 0 恒为 0，所以中心不动。
    static func radiusMap(_ rho: Double, k: Double) -> Double {
        rho * (1 + k * rho * rho)
    }

    /// 色差对各通道的**径向乘子**：红往外、蓝往里、绿不动。
    /// 三个乘子之和恒为 3（等量反向），所以黑白边缘只会出彩边、
    /// 不会整体被放大或缩小；三个乘子在 ρ=0 都是 1，中心不分离。
    static func caScale(_ rho: Double, amount: Double) -> (red: Double, green: Double, blue: Double) {
        let d = amount * rho * rho
        return (1 + d, 1, 1 - d)
    }

    /// 暗角权重：1 = 不动。ρ 归一到角点，所以圆角/非正方形画布不会突然变黑。
    static func vignetteWeight(rho: Double, strength: Double, falloff: Double) -> Double {
        let r = Swift.min(Swift.max(rho, 0), 1)
        return Swift.min(1, Swift.max(0, 1 - strength * pow(r, Swift.max(0.1, falloff))))
    }

    /// splitmix64 风格的整数混合 → [−1, 1]。同 (x, y, seed) 永远同值。
    static func hashNoise(x: Int, y: Int, seed: UInt64 = 0) -> Double {
        var value = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        value = value ^+ (UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F)
        value = value ^+ seed
        value = (value ^>> 30) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^>> 27) &* 0x94D0_49BB_1331_11EB
        value = value ^>> 31
        return Double(value) / Double(UInt64.max) * 2 - 1
    }

    // MARK: - 位置层

    static func applyGeometry(_ image: DisplayImage, lens: LensParameters) -> DisplayImage {
        guard !lens.isGeometryNeutral, image.size.pixelCount > 0 else { return image }
        let size = image.size
        let k = BeautyParameters.unit(lens.distortion) * 0.30      // 满力度 30% 径向偏移
        let ca = BeautyParameters.unit(lens.chromaticAberration) * 0.012
        let cx = Double(size.width - 1) / 2
        let cy = Double(size.height - 1) / 2
        // 归一化基准：中心到角点的距离。用它而不是宽/高，暗角与色差在
        // 竖图和横图上才是同一个力度。
        let corner = (cx * cx + cy * cy).squareRoot()
        guard corner > 0 else { return image }

        let source = image.pixels
        var output = source
        for y in 0 ..< size.height {
            let ny = (Double(y) - cy) / corner
            let row = y * size.width
            for x in 0 ..< size.width {
                let nx = (Double(x) - cx) / corner
                let rho = (nx * nx + ny * ny).squareRoot()
                // 畸变是所有通道共用的一层缩放，色差再在它上面逐通道偏移。
                // 缩放比直接由 radiusMap 除以 ρ 得来：径向映射只有**一处**定义，
                // 断言测的就是采样用的那一个式子。
                let geometric = rho > 1e-9 ? radiusMap(rho, k: k) / rho : 1
                let chroma = ca != 0 ? caScale(rho, amount: ca) : (red: 1.0, green: 1.0, blue: 1.0)
                let scales = [geometric * chroma.red, geometric * chroma.green, geometric * chroma.blue]
                let index = row + x
                let o = index * 4
                for channel in 0 ..< 3 {
                    let scale = scales[channel]
                    if scale == 1 { continue }          // 绿通道不动，直接留原值
                    let sx = Double(x) + (scale - 1) * (Double(x) - cx)
                    let sy = Double(y) + (scale - 1) * (Double(y) - cy)
                    output[o + channel] = sampleSingle(src: source, size: size, x: sx, y: sy, channel: channel)
                }
            }
        }
        return DisplayImage(size: size, pixels: output)
    }

    private static func sampleSingle(src: [Float], size: PixelSize, x: Double, y: Double, channel: Int) -> Float {
        let x0 = Int(x.rounded(.down))
        let y0 = Int(y.rounded(.down))
        let fx = Float(x - Double(x0))
        let fy = Float(y - Double(y0))
        func value(_ ix: Int, _ iy: Int) -> Float {
            let cx = Swift.min(Swift.max(ix, 0), size.width - 1)
            let cy = Swift.min(Swift.max(iy, 0), size.height - 1)
            return src[(cy * size.width + cx) * 4 + channel]
        }
        let top = value(x0, y0) + (value(x0 + 1, y0) - value(x0, y0)) * fx
        let bottom = value(x0, y0 + 1) + (value(x0 + 1, y0 + 1) - value(x0, y0 + 1)) * fx
        return top + (bottom - top) * fy
    }

    // MARK: - 输出层

    static func applyOverlay(_ image: DisplayImage, lens: LensParameters) -> DisplayImage {
        guard !lens.isOverlayNeutral, image.size.pixelCount > 0 else { return image }
        let size = image.size
        let strength = BeautyParameters.unit(lens.vignette)
        let grain = BeautyParameters.unit(lens.grain)
        let cx = Double(size.width - 1) / 2
        let cy = Double(size.height - 1) / 2
        let corner = (cx * cx + cy * cy).squareRoot()
        var pixels = image.pixels

        for y in 0 ..< size.height {
            let ny = Double(y) - cy
            let row = y * size.width
            for x in 0 ..< size.width {
                let index = row + x
                let o = index * 4
                var red = pixels[o], green = pixels[o + 1], blue = pixels[o + 2]
                if strength > 0 {
                    let nx = Double(x) - cx
                    let rho = (nx * nx + ny * ny).squareRoot() / Swift.max(corner, 1)
                    let weight = Float(LensEngine.vignetteWeight(rho: rho, strength: strength,
                                                                 falloff: lens.vignetteFalloff))
                    red *= weight; green *= weight; blue *= weight
                }
                if grain > 0 {
                    // 单色颗粒：三个通道加同一个噪声值。彩色颗粒在人像上
                    // 会被读成"脏"，而修图里的颗粒默认是银盐那种明暗颗粒。
                    let noise = Float(LensEngine.hashNoise(x: x, y: y) * grain * 0.10)
                    red = Swift.min(Swift.max(red + noise, 0), 1)
                    green = Swift.min(Swift.max(green + noise, 0), 1)
                    blue = Swift.min(Swift.max(blue + noise, 0), 1)
                }
                pixels[o] = red
                pixels[o + 1] = green
                pixels[o + 2] = blue
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }
}
