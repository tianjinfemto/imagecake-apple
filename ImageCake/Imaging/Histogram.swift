import CoreGraphics
import Foundation

// 直方图与溢出诊断。像素蛋糕（以及任何商业修图软件）的画布边上一直挂着
// 这条东西，理由不是"好看"：拖曝光的人需要知道**高光已经死了**，而肉眼在
// 一块 25% 亮度的屏幕上看不出一片 254 和一片 255 的区别。
//
// 这一层是纯数据、零依赖、可离线断言：
//   · 分箱口径必须和 `DisplayImage.rgba8(dither: false)` 完全一致
//     （夹取到 [0,1] 再 ×255 四舍五入），否则直方图与导出件两说——
//     那条"屏幕上没溢出、文件里死了"的裂缝就是这么来的；
//   · 越界值（显示域里可能出现 <0 或 >1）不静默夹走：单独计入
//     `outOfRangeCount`，UI 上点名为"超出可显示范围 N 像素"；
//   · 抽样步长只影响耗时不影响形状，所以默认按 `suggestedStride` 抽，
//     把一帧的统计代价压在 ~40 万样本以内。
//
// UI 入口在两处：直方图卡片（调色面板）+ 溢出高亮叠层（画布）。

struct Histogram: Equatable, Sendable {
    /// R/G/B 三通道各 256 箱，外加一条亮度（Rec.709 权重）。
    var red: [Int]
    var green: [Int]
    var blue: [Int]
    var luma: [Int]
    /// 参与统计的像素数（抽样时小于画布像素数）。
    var sampleCount: Int
    /// 夹取之前越界的像素数（任一通道 <0 或 >1）。
    var outOfRangeCount: Int
    /// 任一通道 = 255 / = 0 的像素数（统计时顺手数，不在这里重扫一遍像素）。
    var clippedHighlightPixels: Int
    var clippedShadowPixels: Int

    static let bins = 256

    static let empty = Histogram(red: [], green: [], blue: [], luma: [],
                                 sampleCount: 0, outOfRangeCount: 0,
                                 clippedHighlightPixels: 0, clippedShadowPixels: 0)

    var isEmpty: Bool { sampleCount == 0 || luma.count != Self.bins }

    /// 通道 255 箱的峰值（三通道里最大的那个）。
    var highlightPeak: Int { Swift.max(red.last ?? 0, Swift.max(green.last ?? 0, blue.last ?? 0)) }
    /// 通道 0 箱的峰值（三通道里最大的那个）。
    var shadowPeak: Int { Swift.max(red.first ?? 0, Swift.max(green.first ?? 0, blue.first ?? 0)) }

    /// 高光溢出比例（0…1）：任一通道落到 255 的像素占样本的比例。
    /// 亮度单独不算——纯白天空的亮度是 255 而三通道也是 255，两者不必各说一遍。
    var clippedHighlightRatio: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(clippedHighlightPixels) / Double(sampleCount)
    }

    var clippedShadowRatio: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(clippedShadowPixels) / Double(sampleCount)
    }

    /// 归一化到 0…1（画柱子高度用）：按该组自己的峰值归一。
    func normalized(_ channel: [Int]) -> [Double] {
        guard let peak = channel.max(), peak > 0 else { return [Double](repeating: 0, count: channel.count) }
        return channel.map { Double($0) / Double(peak) }
    }
}

enum HistogramBuilder {
    /// 从显示域画面统计。`stride` > 1 时按像素序抽样（跳过部分像素）。
    static func build(_ image: DisplayImage, stride: Int = 1) -> Histogram {
        let size = image.size
        guard size.pixelCount > 0, image.pixels.count >= size.pixelCount * 4 else { return .empty }
        var red = [Int](repeating: 0, count: Histogram.bins)
        var green = [Int](repeating: 0, count: Histogram.bins)
        var blue = [Int](repeating: 0, count: Histogram.bins)
        var luma = [Int](repeating: 0, count: Histogram.bins)
        let step = Swift.max(1, stride)
        var sampled = 0
        var outOfRange = 0
        var clippedHigh = 0
        var clippedLow = 0

        var i = 0
        while i < size.pixelCount {
            let o = i * 4
            let r = image.pixels[o], g = image.pixels[o + 1], b = image.pixels[o + 2]
            sampled += 1
            if r < 0 || r > 1 || g < 0 || g > 1 || b < 0 || b > 1 { outOfRange += 1 }
            let rb = bin(r), gb = bin(g), bb = bin(b)
            red[rb] += 1
            green[gb] += 1
            blue[bb] += 1
            // 亮度按**已夹取**的码值算：与 rgba8 的编码同一条路径。
            luma[bin(ColorMath.luma(clamped(r), clamped(g), clamped(b)))] += 1
            if rb == 255 || gb == 255 || bb == 255 { clippedHigh += 1 }
            if rb == 0 || gb == 0 || bb == 0 { clippedLow += 1 }
            i += step
        }
        return Histogram(red: red, green: green, blue: blue, luma: luma,
                         sampleCount: sampled, outOfRangeCount: outOfRange,
                         clippedHighlightPixels: clippedHigh, clippedShadowPixels: clippedLow)
    }

    /// 分箱：与 `DisplayImage.rgba8(dither: false)` 逐比特同口径。
    static func bin(_ value: Float) -> Int {
        Int((Swift.min(Swift.max(value, 0), 1) * 255).rounded())
    }

    /// 亮度按 Float 算（`ColorMath.luma` 的入参就是 Float）：这里不再转一道
    /// Double，否则编译不过，而与 rgba8 的差别只在最终 ×255 的取整上。
    private static func clamped(_ value: Float) -> Float {
        Swift.min(Swift.max(value, 0), 1)
    }

    /// 默认抽样步长：把统计代价压到 ~40 万样本以内。预览档 2048（4MP）
    /// 时步长 10，形状与全量在肉眼层面不可分，而导出前的全量重算不付这份钱。
    static func suggestedStride(pixelCount: Int, targetSamples: Int = 400_000) -> Int {
        guard pixelCount > targetSamples, targetSamples > 0 else { return 1 }
        return pixelCount / targetSamples
    }
}

// MARK: - 溢出高亮

enum ClippingOverlay {
    /// 把"任一通道已落到 255 或 0"的像素染成标记色，其余只压暗不标色。
    ///
    /// 为什么连暗部溢出也标：两者是同一个问题（色阶死了）的两端，而
    /// 只标高光的工具会让人以为暗部随便压都没事。返回 8bit 叠层，
    /// 由画布按半透明盖在预览上——不改像素、不进导出链。
    static func mask(_ image: DisplayImage,
                     highlight: RGBA8 = RGBA8(r: 255, g: 46, b: 64),
                     shadow: RGBA8 = RGBA8(r: 46, g: 120, b: 255)) -> RGBA8Buffer {
        let size = image.size
        var bytes = [UInt8](repeating: 0, count: Swift.max(0, size.pixelCount * 4))
        guard size.pixelCount > 0, image.pixels.count >= size.pixelCount * 4 else {
            return RGBA8Buffer(size: size, data: Data(bytes))
        }
        var i = 0
        while i < size.pixelCount {
            let o = i * 4
            let rb = HistogramBuilder.bin(image.pixels[o])
            let gb = HistogramBuilder.bin(image.pixels[o + 1])
            let bb = HistogramBuilder.bin(image.pixels[o + 2])
            let isHigh = rb == 255 || gb == 255 || bb == 255
            let isLow = rb == 0 || gb == 0 || bb == 0
            let mark: RGBA8
            if isHigh { mark = highlight }
            else if isLow { mark = shadow }
            else { mark = RGBA8(r: 20, g: 20, b: 24, a: 64) }
            bytes[o] = mark.r
            bytes[o + 1] = mark.g
            bytes[o + 2] = mark.b
            bytes[o + 3] = isHigh || isLow ? 235 : 90
            i += 1
        }
        return RGBA8Buffer(size: size, data: Data(bytes))
    }
}
