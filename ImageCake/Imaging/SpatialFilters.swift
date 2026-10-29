import Foundation

// 空间滤波：降噪与锐化。
//
// 为什么不做进 ToneEngine：那个循环是**逐像素**的（按像素数分块并行），
// 而这两个算子要读邻域。硬塞进去只有两条路——放弃并行，或者把循环改成
// 滑窗；后者会让「调色只管自己的像素」这条边界消失，以后再加通道相关算子
// 时容易互相污染。
//
// 为什么在显示域（sRGB 码）而不是线性域：
// · 显示域值域均匀，双边滤波的值域带宽（σ_r）好定，一份参数在亮部暗部都好用；
// · 与锐化的单位一致，两个滑杆的量级可以直接比较；
// · 代价是对比/曲线放大的噪声要到这一步才回收，但换来的是不需要给线性域
//   单独调一套 σ——真机上更难解释"为什么同样 30 的降噪，暗部没效果"。
//
// 顺序：先降噪再锐化。反过来等于先把噪声锐化一遍。

enum SpatialFilters {
    // MARK: - 降噪

    /// 双边滤波。保边平滑：值域差大的邻居几乎不参与平均，所以边缘不会被磨平。
    ///
    /// 复杂度是 O(r²)/像素，r = 2（5×5）。4MP 预览约 0.3–0.8 秒，
    /// 32MP 导出约 3–8 秒——导出本来就是分钟级，可以接受；
    /// 预览拖滑杆变卡是已知代价，靠 EditorModel 的渲染节流兜。
    ///
    /// 值域核用 257 项 LUT 查表而不是直接调 exp：内层循环里每次 exp 都会
    /// 把耗时翻几倍，而相邻像素的 RGB 距离平方落进同一格完全看不出来。
    static func denoise(_ image: DisplayImage, strength: Double) -> DisplayImage {
        let amount = Float(min(max(strength, 0), 100) / 100)
        guard amount > 0, image.size.pixelCount > 0 else { return image }

        let width = image.size.width
        let height = image.size.height
        let radius = 2
        let span = radius * 2 + 1

        // 值域带宽：0.25 时约 64 级显示码内的差异仍算「同一块颜色」。
        let sigmaRange = amount * 0.25
        let sigmaRange2 = 2 * sigmaRange * sigmaRange
        // RGB 距离平方最大是 3（1²+1²+1²）。
        let rangeLUT: [Float] = (0 ... 256).map { step in
            let distance2 = Float(step) / 256 * 3
            return expf(-distance2 / sigmaRange2)
        }

        let sigmaSpace = Float(radius) * 0.6
        let sigmaSpace2 = 2 * sigmaSpace * sigmaSpace
        var spatialWeights = [Float](repeating: 0, count: span * span)
        for dy in -radius ... radius {
            for dx in -radius ... radius {
                let distance2 = Float(dx * dx + dy * dy)
                spatialWeights[(dy + radius) * span + (dx + radius)] = expf(-distance2 / sigmaSpace2)
            }
        }

        let source = image.pixels
        var output = source

        source.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                for y in 0 ..< height {
                    for x in 0 ..< width {
                        let center = (y * width + x) * 4
                        let cr = src[center]
                        let cg = src[center + 1]
                        let cb = src[center + 2]

                        var sumR: Float = 0
                        var sumG: Float = 0
                        var sumB: Float = 0
                        var sumWeight: Float = 0

                        for dy in -radius ... radius {
                            let yy = min(max(y + dy, 0), height - 1)
                            for dx in -radius ... radius {
                                let xx = min(max(x + dx, 0), width - 1)
                                let neighbor = (yy * width + xx) * 4
                                let dr = src[neighbor] - cr
                                let dg = src[neighbor + 1] - cg
                                let db = src[neighbor + 2] - cb
                                let distance2 = dr * dr + dg * dg + db * db
                                let bucket = Int(min(distance2 / 3, 1) * 256)
                                let weight = spatialWeights[(dy + radius) * span + (dx + radius)]
                                    * rangeLUT[bucket]
                                sumR += src[neighbor] * weight
                                sumG += src[neighbor + 1] * weight
                                sumB += src[neighbor + 2] * weight
                                sumWeight += weight
                            }
                        }

                        if sumWeight > 1e-6 {
                            dst[center] = sumR / sumWeight
                            dst[center + 1] = sumG / sumWeight
                            dst[center + 2] = sumB / sumWeight
                        }
                        // alpha 原样保留：降噪是颜色的事，不碰透明度。
                    }
                }
            }
        }

        return DisplayImage(size: image.size, pixels: output)
    }

    // MARK: - 锐化

    /// Unsharp mask：原图 + amount × (原图 - 模糊图)。
    ///
    /// 高斯核用可分离的 [1 2 1]/4，两次 1D 卷积就是 3×3 高斯——比二维核
    /// 少一半乘法，边缘处理也只需要写一次。
    static func sharpen(_ image: DisplayImage, strength: Double) -> DisplayImage {
        let amount = Float(min(max(strength, 0), 100) / 100) * 1.5
        guard amount > 0, image.size.pixelCount > 0 else { return image }

        let blurred = gaussianBlur(image)
        var output = image.pixels
        for index in stride(from: 0, to: output.count, by: 4) {
            for channel in 0 ..< 3 {
                let base = output[index + channel]
                let difference = base - blurred[index + channel]
                output[index + channel] = min(max(base + amount * difference, 0), 1)
            }
        }
        return DisplayImage(size: image.size, pixels: output)
    }

    private static func gaussianBlur(_ image: DisplayImage) -> [Float] {
        let width = image.size.width
        let height = image.size.height
        let source = image.pixels
        var horizontal = source
        var output = source
        let kernel: [Float] = [0.25, 0.5, 0.25]

        // 水平
        for y in 0 ..< height {
            for x in 0 ..< width {
                for channel in 0 ..< 3 {
                    var value: Float = 0
                    for offset in -1 ... 1 {
                        let xx = min(max(x + offset, 0), width - 1)
                        value += source[(y * width + xx) * 4 + channel] * kernel[offset + 1]
                    }
                    horizontal[(y * width + x) * 4 + channel] = value
                }
            }
        }
        // 垂直
        for y in 0 ..< height {
            for x in 0 ..< width {
                for channel in 0 ..< 3 {
                    var value: Float = 0
                    for offset in -1 ... 1 {
                        let yy = min(max(y + offset, 0), height - 1)
                        value += horizontal[(yy * width + x) * 4 + channel] * kernel[offset + 1]
                    }
                    output[(y * width + x) * 4 + channel] = value
                }
            }
        }
        return output
    }
}
