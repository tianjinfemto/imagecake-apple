import CoreGraphics
import Foundation

// 慢门（长曝光）。
//
// 这一档在像素蛋糕里叫"AI 慢门"：瀑布拉成丝绸、云拖出轨迹、人从街上消失。
// 单张照片做不到这件事，任何声称能的做法都是拿模糊冒充——所以这里做的是
// **多帧堆栈**：同一个机位的 N 张连拍，按曝光方式合成一张。
//
// 为什么这是诚实的实现路径：真实慢门需要的就是"一段时间内的所有光累加"，
// 而连拍正是同一段时间内的采样。三件事由堆栈给出：
//   · average（平均）= 真正的长曝光：移动的东西被摊平（水、云），不动的东西
//     信噪比提升；
//   · brightest（取亮）= 光轨/星轨/闪电（运动的亮点保留）；
//   · darkest（取暗）= 去掉画面里路过的人与车（每格取最暗 = 众数=背景）。
// 三种模式都能被断言，而且都不需要权重。
//
// 对不齐会看到重影，所以先做**平移对齐**：在 1/8 尺寸的低分辨亮度上，
// 用 ±maxShift 的整数搜索找 SAD 最小的偏移。为什么只用整数平移：
// 真三脚架的连拍差异基本就是机身抖动造成的平移，加旋转/透视需要特征点匹配
// 与单应估计，那是另一套问题（而它失败时的症状"画面被扭了一点点"
// 比"没对齐"更难查）。所以对不齐时宁可点名，也不硬扭。
//
// 已知边界：帧数 <2 → `[frames_short]`；单帧内的大位移（手持走位）
// 超搜索窗 → 报告里写清 residual，让用户知道该上三脚架。

enum StackMode: String, Equatable, Sendable, CaseIterable, Codable, Identifiable {
    case average
    case brightest
    case darkest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .average: return "长曝光（平均）"
        case .brightest: return "光轨（取亮）"
        case .darkest: return "去路人（取暗）"
        }
    }
}

struct StackResult: Sendable {
    var image: DisplayImage
    /// 每帧相对第一帧的平移（像素，已换算回全尺寸）。
    var shifts: [CGSize]
    /// 对齐后的平均绝对差（0 = 完全重合）。给 UI 说"对得很齐/还有残差"。
    var residual: Double
    var mode: StackMode
    var frames: Int
}

enum LongExposureEngine {
    /// 对齐用的低分辨档：长边 384。为什么不是 512：搜索代价是
    /// (2w+1)² × 像素数，512 档配 ±64 窗就是几十亿次加法——堆 5 张要等几分钟。
    /// 384 档配 ±24 窗 + 隔行采样约在几十毫秒量级，而机位抖动在这个
    /// 分辨率上就是几个像素，够接住。代价：**整数**平移，步长 = scale 像素
    /// （2048 档约 5px）——残余的亚像素抖动会留一点重影。不做亚像素：那要插值，
    /// 而"同样几张图堆一起不得引入任何插值损耗"这条性质就会消失。
    static let alignLongEdge = 384
    /// 搜索窗（低分辨像素，两个轴同窗）。太窄接不住手持，太宽就是平方代价。
    static let alignWindow = 24
    /// SAD 的采样隔行：2 = 只看一半像素（两轴都是，所以是 1/4 代价）。
    static let sampleStride = 2

    /// 把 N 帧堆成一张。帧数不足或尺寸不一致 → nil（调用侧点名，不静默用第一帧）。
    static func stack(_ frames: [DisplayImage], mode: StackMode) -> StackResult? {
        guard frames.count >= 2, let reference = frames.first else { return nil }
        let size = reference.size
        guard size.pixelCount > 0 else { return nil }
        // 尺寸不一致时不悄悄重采样：那会把"拍摄时换了焦段/裁过图"这种错误
        // 变成一张糊图。让调用侧去处理（联机拍摄与素材库导入都在上游）。
        guard frames.allSatisfy({ $0.size == size }) else { return nil }

        let scale = Swift.max(1, size.longEdge / alignLongEdge)
        let small = PixelSize(width: Swift.max(1, size.width / scale), height: Swift.max(1, size.height / scale))
        let baseLuma = downsampleLuma(reference, to: small)
        var shifts: [CGSize] = [.zero]
        var residuals: [Double] = [0]
        for frame in frames.dropFirst() {
            let luma = downsampleLuma(frame, to: small)
            let best = bestShift(base: baseLuma, target: luma, size: small, window: alignWindow)
            shifts += [CGSize(width: Double(best.dx * scale), height: Double(best.dy * scale))]
            residuals += [best.cost]
        }

        var out = [Float](repeating: 0, count: size.pixelCount * 4)
        let frameBuffers = frames.map { $0.pixels }
        let count = Double(frames.count)
        for y in 0 ..< size.height {
            let row = y * size.width
            for x in 0 ..< size.width {
                let o = (row + x) * 4
                if mode == .average {
                    var acc = (r: 0.0, g: 0.0, b: 0.0, a: 0.0)
                    for (index, pixels) in frameBuffers.enumerated() {
                        let (sx, sy) = samplePoint(x: x, y: y, shift: shifts[index], size: size)
                        let s = (sy * size.width + sx) * 4
                        acc.r += Double(pixels[s]); acc.g += Double(pixels[s + 1])
                        acc.b += Double(pixels[s + 2]); acc.a += Double(pixels[s + 3])
                    }
                    out[o] = Float(acc.r / count)
                    out[o + 1] = Float(acc.g / count)
                    out[o + 2] = Float(acc.b / count)
                    out[o + 3] = Float(acc.a / count)
                } else {
                    var acc = (r: frameBuffers[0][o], g: frameBuffers[0][o + 1],
                               b: frameBuffers[0][o + 2], a: frameBuffers[0][o + 3])
                    for (index, pixels) in frameBuffers.enumerated() {
                        let (sx, sy) = samplePoint(x: x, y: y, shift: shifts[index], size: size)
                        let s = (sy * size.width + sx) * 4
                        for c in 0 ..< 4 {
                            let value = pixels[s + c]
                            acc = combine(acc, c: c, value: value, mode: mode)
                        }
                    }
                    out[o] = acc.r; out[o + 1] = acc.g; out[o + 2] = acc.b; out[o + 3] = acc.a
                }
            }
        }
        return StackResult(image: DisplayImage(size: size, pixels: out),
                           shifts: shifts,
                           residual: residuals.max() ?? 0,
                           mode: mode, frames: frames.count)
    }

    /// 报告里那句人话。`residual` 用低分辨档的平均绝对差，量级与图幅无关。
    static func report(_ result: StackResult) -> String {
        let worst = result.shifts.map { hypot($0.width, $0.height) }.max() ?? 0
        let shift = Int(worst.rounded())
        return "[stack] \(result.frames) 帧 · \(result.mode.title) · 最大位移 \(shift)px · 残差 \(String(format: "%.4f", result.residual))"
    }

    // MARK: - 内部

    private static func combine(_ acc: (r: Float, g: Float, b: Float, a: Float), c: Int,
                                value: Float, mode: StackMode) -> (r: Float, g: Float, b: Float, a: Float) {
        let pick: (Float, Float) -> Float = mode == .brightest
            ? { Swift.max($0, $1) } : { Swift.min($0, $1) }
        switch c {
        case 0: return (pick(acc.r, value), acc.g, acc.b, acc.a)
        case 1: return (acc.r, pick(acc.g, value), acc.b, acc.a)
        case 2: return (acc.r, acc.g, pick(acc.b, value), acc.a)
        default: return (acc.r, acc.g, acc.b, pick(acc.a, value))
        }
    }

    /// 反向映射：目标像素 (x,y) 从加了平移的那一帧里取哪个像素。
    /// 夹到边界而不是外推：边缘那一圈本来就不是画面内容，重影比 1px 的拉伸好接受。
    private static func samplePoint(x: Int, y: Int, shift: CGSize, size: PixelSize) -> (Int, Int) {
        let sx = Swift.min(size.width - 1, Swift.max(0, x - Int(shift.width.rounded())))
        let sy = Swift.min(size.height - 1, Swift.max(0, y - Int(shift.height.rounded())))
        return (sx, sy)
    }

    private static func downsampleLuma(_ image: DisplayImage, to small: PixelSize) -> [Float] {
        guard image.size.pixelCount > 0, small.pixelCount > 0 else { return [] }
        let scaled = image.resized(to: small)
        var out = [Float](repeating: 0, count: small.pixelCount)
        for i in 0 ..< small.pixelCount {
            let o = i * 4
            out[i] = ColorMath.luma(scaled.pixels[o], scaled.pixels[o + 1], scaled.pixels[o + 2])
        }
        return out
    }

    /// 整数平移搜索：窗口内逐点试，取 SAD 最小。返回的偏移是"target 相对 base"的位移。
    /// 代价控制靠 `sampleStride`（隔行采样）而不是缩小窗口：窗口太小会直接接不住手持。
    static func bestShift(base: [Float], target: [Float], size: PixelSize, window: Int)
        -> (dx: Int, dy: Int, cost: Double) {
        guard base.count == target.count, base.count == size.pixelCount, size.pixelCount > 0 else {
            return (0, 0, 0)
        }
        let limit = Swift.max(0, window)
        let step = Swift.max(1, sampleStride)
        var best = (dx: 0, dy: 0, cost: Double.greatestFiniteMagnitude)
        for dy in -limit ... limit {
            for dx in -limit ... limit {
                var sum = 0.0
                var n = 0
                var y = 0
                while y < size.height {
                    let sy = y - dy
                    if sy >= 0, sy < size.height {
                        let row = y * size.width
                        let srcRow = sy * size.width
                        var x = 0
                        while x < size.width {
                            let sx = x - dx
                            if sx >= 0, sx < size.width {
                                sum += abs(Double(base[row + x] - target[srcRow + sx]))
                                n += 1
                            }
                            x += step
                        }
                    }
                    y += step
                }
                let cost = n > 0 ? sum / Double(n) : .greatestFiniteMagnitude
                if cost < best.cost - 1e-12 {
                    best = (dx: dx, dy: dy, cost: cost)
                }
            }
        }
        return best
    }
}
