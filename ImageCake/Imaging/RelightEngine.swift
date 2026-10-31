import CoreGraphics
import Foundation

// 虚拟打光（像素蛋糕的"AI 打光/光影重塑"这一档）。
//
// 这里做的是**方向光的重塑**，不是三维重建：没有深度、没有法线的真实解，
// 用的是"画面亮度沿某个方向的抬升方向 ≈ 那一面朝光"这条近似。它能站得住的
// 理由是 Lambert 光照在图像上的表现就是这个：面朝光的区域，亮度沿那个方向上升。
// 所以
//   facing = clamp01(⟨d, ∇S⟩ × 画幅)   （S = 把细节抹掉之后的亮度场，只留大关系）
// 就是"这一面有多朝光"。
//
// 三条设计约束：
//   1. **只加不减**：加一盏灯不会让其它地方变暗。早期版本为了"均值守恒"减了
//      均值，症状是背光的平墙被跟着压暗 —— 那不再是在打光，而是在加对比。
//   2. **斜率乘画幅**：`∇S` 是每像素的亮度差，同一张图缩小一半它翻倍。乘回
//      长边之后 facing 与分辨率无关（同一条滑杆在预览档与全分辨率导出上同效果）。
//   3. **上限**：满力度最多加 0.25 亮度，不会把脸打爆。
//
// 已知边界（写清楚，别当成 AI）：
//   · 它是**梯度近似**：没有几何信息，转头的角度、耳朵这种自遮挡、头发投在
//      脸上的影子都重打不了——那需要深度/法线权重（本项目不做假实现）；
//   · 局部平坦的区域 facing = 0，因此**逐比特不动**；全图无结构时整段不跑。

enum RelightEngine {
    static func apply(_ image: DisplayImage, light: LightParameters) -> DisplayImage {
        let size = image.size
        guard size.pixelCount > 0, !light.isNeutral,
              image.pixels.count >= size.pixelCount * 4 else { return image }
        var pixels = image.pixels
        apply(&pixels, size: size, light: light)
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 就地打光。暴露给断言：不经过 DisplayImage 包装也能单独验"只加不减"。
    static func apply(_ pixels: inout [Float], size: PixelSize, light: LightParameters) {
        let count = size.pixelCount
        guard count > 0, !light.isNeutral, pixels.count >= count * 4 else { return }

        // 抹平半径：软光 = 大半径（只剩大关系），硬光 = 小半径（连中频一起用）。
        let radius = RelightEngine.shadeRadius(longEdge: size.longEdge, softness: light.softness)
        let luma = RegionEnhance.lumaChannel(pixels, size: size)
        guard !luma.isEmpty else { return }
        let smooth = BeautyEngine.blurredChannel(luma, size: size, radius: radius)

        // 梯度（像素度量：图不是正方形时，归一化空间里的"垂直"不是屏幕上的垂直）。
        let radians = light.direction * Double.pi / 180
        let dx = cos(radians), dy = sin(radians)
        let spread = BeautyParameters.unit(light.spread)
        let amount = BeautyParameters.unit(light.intensity)
        // 斜率×画幅：与分辨率无关（见顶部注释）。上限 0.25 亮度："最亮的一盖"。
        let gradientScale = Double(size.longEdge) * 2
        let (warmA, warmB) = warmthOffset(light.warmth)
        var touched = false
        for y in 0 ..< size.height {
            let row = y * size.width
            for x in 0 ..< size.width {
                let left = smooth[row + Swift.max(0, x - 1)]
                let right = smooth[row + Swift.min(size.width - 1, x + 1)]
                let up = smooth[Swift.max(0, y - 1) * size.width + x]
                let down = smooth[Swift.min(size.height - 1, y + 1) * size.width + x]
                let gx = Double(right - left) / 2
                let gy = Double(down - up) / 2
                let along = (gx * dx + gy * dy) * gradientScale
                guard along > 0.001 else { continue }        // 不朝光：逐比特不动
                let facing = Swift.min(1.0, along)
                let i = row + x
                let o = i * 4
                let l = Double(ColorMath.luma(pixels[o], pixels[o + 1], pixels[o + 2]))
                // spread = 1 时只抬暗部（补光），= 0 时均匀加（主光）。
                let bias = (1 - spread) + spread * 1.6 * Swift.min(1.0, Swift.max(0.0, 1 - l))
                let add = 0.25 * amount * facing * bias
                guard add > 1e-6 else { continue }
                touched = true
                let source = BeautyEngine.opponent(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
                let rgb = BeautyEngine.fromOpponent(l: Swift.min(1.0, source.l + add),
                                                    a: source.a + warmA * add,
                                                    b: source.b + warmB * add)
                pixels[o] = Float(Swift.min(Swift.max(rgb.r, 0), 1))
                pixels[o + 1] = Float(Swift.min(Swift.max(rgb.g, 0), 1))
                pixels[o + 2] = Float(Swift.min(Swift.max(rgb.b, 0), 1))
            }
        }
        _ = touched        // 没有任何面朝光的像素时，上面每条 continue 已经保住了原值
    }

    /// 光色的偏移：正 = 暖（A 轴正向、B 轴负向）。只给"加进去的那部分光"上色，
    /// 原图的色偏不动——否则打一盏暖光灯会顺手把整张图的白平衡改掉。
    static func warmthOffset(_ warmth: Double) -> (a: Double, b: Double) {
        let w = BeautyParameters.unit(warmth)
        return (0.6 * w, -0.45 * w)
    }

    /// 亮度场抹平后的梯度半径（像素）。单独一个入口而不埋在 apply 里：
    /// 断言与面板上的软硬度文案都要拿同一个数，写两份迟早对不上。
    static func shadeRadius(longEdge: Int, softness: Double) -> Int {
        Swift.max(2, Int((0.01 + 0.09 * BeautyParameters.unit(softness)) * Double(longEdge)))
    }
}
