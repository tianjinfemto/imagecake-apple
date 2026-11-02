import CoreGraphics
import Foundation

// 衣物祛褶。
//
// 与"换正装"的分工要说清楚：**换正装是生成式能力**（要服装分割 + 合成权重，
// 本项目不做假实现）；祛褶不是——褶皱是**光影**问题，不是内容问题：一块
// 布上的褶 = 暗谷 + 亮脊 + 中间的低频起伏，把低频压平就是"熨过"，而布纹
// （高频）本来就不在那个频段里。所以它可以完全确定性实现、可以离线断言。
//
// 频段划分就是这条算子的全部要点：
//   · base = 模糊 R2（长边的 1.2%）——装着"明暗与褶皱"，装不下布纹；
//   · deep = 在 base 上再模糊 R1（长边的 5%）——连褶皱一起抹平，只剩大关系；
//   · 输出 = source + (deep − base)·k·掩码。
// 也就是说我们只把 **base 这一层的低频** 推向 deep，而
// `source − base` 那一段（布纹、织物的经纬、印花边缘）原样加回来。
// 拿普通磨皮（直接糊整张）做这件事的symptom是"衣服像塑料布"，
// 而这条算子在力度拉满时仍留得下织物纹理——有断言钉住。
//
// 为什么必须由用户涂一块区域（`BrushState.garments`）而不是全自动：
// 分辨"这是褶子"和"这是衣服上的接缝/图案/腰带阴影"需要服装分割与语义，
// 色域与几何都给不出。所以这一版明确要选区，没涂就整段不跑并点名
// `[no_garment_region]`——把接缝熨平比留一条褶更糟。

enum GarmentEngine {
    /// base 层半径（相对长边）：必须大于布纹的尺度、小于褶皱的尺度。
    static let baseRatio = 0.012
    /// deep 层半径（相对长边）：必须大于褶皱的尺度。
    static let deepRatio = 0.05

    static func apply(_ image: DisplayImage, weights: [Float], garment: GarmentParameters) -> DisplayImage {
        let size = image.size
        guard size.pixelCount > 0, !garment.isNeutral, weights.count == size.pixelCount,
              image.pixels.count >= size.pixelCount * 4 else { return image }
        var maxWeight = Float(0)
        for value in weights { maxWeight = Swift.max(maxWeight, value) }
        guard maxWeight > 0 else { return image }
        var pixels = image.pixels
        deWrinkle(&pixels, size: size, weights: weights,
                  amount: BeautyParameters.unit(garment.deWrinkle))
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 把 base 层的低频推向 deep，高频（布纹）逐比特保留。
    static func deWrinkle(_ pixels: inout [Float], size: PixelSize, weights: [Float], amount: Double) {
        guard amount > 0, size.pixelCount > 0, weights.count == size.pixelCount else { return }
        let longEdge = Double(size.longEdge)
        let baseRadius = Swift.max(1, Int(longEdge * baseRatio))
        let deepRadius = Swift.max(baseRadius + 1, Int(longEdge * deepRatio))
        let base = ImageDocument.blurred(pixels, size: size, radius: baseRadius)
        let deep = ImageDocument.blurred(base, size: size, radius: deepRadius)
        PixelParallel.forEachPixel(&pixels, size.pixelCount) { buf, i in
            // 只读已定型的 base/deep/weights 与自己那三个通道，写只落在同一下标：
            // 分带与串行逐比特相同（同一个像素的算术序列一个字节都没改）。
            let k = amount * Double(weights[i])
            guard k > 0.001 else { return }
            let o = i * 4
            for c in 0 ..< 3 {
                let source = Double(buf[o + c])
                // 只搬"base 与 deep 之差"这一段，`source − base` 原样带回。
                let texture = source - Double(base[o + c])
                let moved = Double(deep[o + c]) + texture
                buf[o + c] = Float(Swift.min(Swift.max(source + (moved - source) * k, 0), 1))
            }
        }
    }
}
