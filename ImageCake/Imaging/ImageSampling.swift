import Foundation

// 像素采样。
//
// 为什么单独抽出来：液化、仿制图章、以后的局部调节都要做「从连续坐标取
// RGBA」。这类函数一旦有两份，边界处理（clamp 还是回绕、+0.5 的像素中心
// 约定）迟早会漂移——而漂移的表现是"某个工具边缘发黑"，很难定位。
//
// 约定：整数坐标 = 像素中心（不是像素边缘）。所以 x = 3.0 取第 3 个像素的
// 全部，x = 3.5 在第 3、4 个像素中间。这与 LiquifyEngine 的位移场坐标系一致。
//
// 越界按 clamp 处理：液化/图章不该把画布外的黑色拖进来。

enum ImageSampling {
    /// 双线性采样 RGBA 四通道，写入 dst 的 [offset, offset+4)。
    ///
    /// 用 unsafe buffer 而不是返回元组：这两个调用方都在每像素循环里，
    /// 元组会多一次构造与拷贝，4MP 图上就是 400 万次。
    static func bilinear(src: UnsafeBufferPointer<Float>,
                         width: Int, height: Int,
                         x: Double, y: Double,
                         into dst: UnsafeMutableBufferPointer<Float>,
                         at offset: Int) {
        guard width > 0, height > 0 else { return }

        let x0 = Int(x.rounded(.down))
        let y0 = Int(y.rounded(.down))
        let fx = Float(x - Double(x0))
        let fy = Float(y - Double(y0))

        let left = min(max(x0, 0), width - 1)
        let right = min(max(x0 + 1, 0), width - 1)
        let top = min(max(y0, 0), height - 1)
        let bottom = min(max(y0 + 1, 0), height - 1)

        let topLeft = (top * width + left) * 4
        let topRight = (top * width + right) * 4
        let bottomLeft = (bottom * width + left) * 4
        let bottomRight = (bottom * width + right) * 4

        for channel in 0 ..< 4 {
            let a = src[topLeft + channel] + (src[topRight + channel] - src[topLeft + channel]) * fx
            let b = src[bottomLeft + channel] + (src[bottomRight + channel] - src[bottomLeft + channel]) * fx
            dst[offset + channel] = a + (b - a) * fy
        }
    }
}
