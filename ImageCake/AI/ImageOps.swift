import Foundation

// 几何与遮罩的公共算子。它们全部是纯函数、不碰网络——
// 分块、膨胀、羽化、外接框这些"真正决定品质的几何"必须能在没有权重的
// 机器上被断言（imagecake 把 LaMa 的 tiling 抽出来测，是同一条理由）。

enum MaskOps {
    /// 浮点权重图的非零外接框，四周再外扩 `padding` 个像素（供模糊限定矩形用）。
    /// 全零返回 nil 而不是 .zero：.zero 会被调用侧当成"算个空矩形"，
    /// 而 nil 才能把"干脆没选区、整段不该跑"这件事传上去。
    static func boundingRect(_ weights: [Float], size: PixelSize,
                             padding: Int = 0) -> PixelRect? {
        guard size.pixelCount > 0, weights.count == size.pixelCount else { return nil }
        var minX = size.width, minY = size.height, maxX = -1, maxY = -1
        for i in 0 ..< weights.count where weights[i] > 0 {
            let x = i % size.width
            let y = i / size.width
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let x0 = Swift.max(0, minX - padding)
        let y0 = Swift.max(0, minY - padding)
        let x1 = Swift.min(size.width - 1, maxX + padding)
        let y1 = Swift.min(size.height - 1, maxY + padding)
        return PixelRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// 非零外接框（> threshold 才算遮罩）。空图/全零返回 .zero。
    static func boundingBox(_ mask: MaskBuffer, threshold: UInt8 = 128) -> PixelRect {
        guard !mask.isEmpty else { return .zero }
        var minX = mask.size.width, minY = mask.size.height
        var maxX = -1, maxY = -1
        mask.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            for y in 0 ..< mask.size.height {
                let row = y * mask.size.width
                for x in 0 ..< mask.size.width where src[row + x] > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    maxY = y
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 方形膨胀（可分离的最大值滤波）。网输入的遮罩要外扩一圈：
    /// 只给到边缘外一像素，LaMa 会把"要补的东西"和"边界"混在一起。
    static func dilated(_ mask: MaskBuffer, radius: Int) -> MaskBuffer {
        guard radius > 0, !mask.isEmpty else { return mask }
        let w = mask.size.width
        let h = mask.size.height
        let src = [UInt8](mask.data)
        var horizontal = [UInt8](repeating: 0, count: src.count)
        for y in 0 ..< h {
            for x in 0 ..< w {
                var peak: UInt8 = 0
                let lo = max(0, x - radius)
                let hi = min(w - 1, x + radius)
                for xx in lo ... hi where src[y * w + xx] > peak {
                    peak = src[y * w + xx]
                }
                horizontal[y * w + x] = peak
            }
        }
        var out = [UInt8](repeating: 0, count: src.count)
        for x in 0 ..< w {
            for y in 0 ..< h {
                var peak: UInt8 = 0
                let lo = max(0, y - radius)
                let hi = min(h - 1, y + radius)
                for yy in lo ... hi where horizontal[yy * w + x] > peak {
                    peak = horizontal[yy * w + x]
                }
                out[y * w + x] = peak
            }
        }
        return MaskBuffer(size: mask.size, data: Data(out))
    }

    /// 羽化：三次盒式模糊近似高斯（σ ≈ radius）。只在合成权重上用，
    /// 不改变"要填哪里"，只决定边界过渡多软。
    static func feathered(_ mask: MaskBuffer, radius: Int) -> MaskBuffer {
        guard radius > 0, !mask.isEmpty else { return mask }
        let w = mask.size.width
        let h = mask.size.height
        var buffer = [Float](repeating: 0, count: w * h)
        let src = [UInt8](mask.data)
        for i in 0 ..< (w * h) { buffer[i] = Float(src[i]) / 255 }

        for _ in 0 ..< 3 {
            buffer = boxBlur(buffer, width: w, height: h, radius: radius)
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0 ..< (w * h) {
            out[i] = UInt8((Swift.min(Swift.max(buffer[i], 0), 1) * 255).rounded())
        }
        return MaskBuffer(size: mask.size, data: Data(out))
    }

    private static func boxBlur(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        let window = Float(radius * 2 + 1)
        // 水平
        for y in 0 ..< height {
            var sum: Float = 0
            for x in -radius ... radius {
                sum += src[y * width + min(max(x, 0), width - 1)]
            }
            for x in 0 ..< width {
                tmp[y * width + x] = sum / window
                let outIndex = x - radius
                let inIndex = x + radius + 1
                sum -= src[y * width + min(max(outIndex, 0), width - 1)]
                sum += src[y * width + min(max(inIndex, 0), width - 1)]
            }
        }
        // 垂直
        for x in 0 ..< width {
            var sum: Float = 0
            for y in -radius ... radius {
                sum += tmp[min(max(y, 0), height - 1) * width + x]
            }
            for y in 0 ..< height {
                out[y * width + x] = sum / window
                let outIndex = y - radius
                let inIndex = y + radius + 1
                sum -= tmp[min(max(outIndex, 0), height - 1) * width + x]
                sum += tmp[min(max(inIndex, 0), height - 1) * width + x]
            }
        }
        return out
    }

    /// 椭圆羽化权重（面部贴回用）：中心 1，边界 0，feather 控制过渡带比例。
    static func ellipseAlpha(size: PixelSize, feather: Float) -> [Float] {
        guard size.pixelCount > 0 else { return [] }
        let cx = Float(size.width - 1) / 2
        let cy = Float(size.height - 1) / 2
        let rx = max(1, cx)
        let ry = max(1, cy)
        let inner = Swift.max(0, 1 - Swift.min(Swift.max(feather, 0), 0.95))
        var out = [Float](repeating: 0, count: size.pixelCount)
        for y in 0 ..< size.height {
            let dy = (Float(y) - cy) / ry
            for x in 0 ..< size.width {
                let dx = (Float(x) - cx) / rx
                let d = (dx * dx + dy * dy).squareRoot()
                if d >= 1 {
                    out[y * size.width + x] = 0
                } else if d <= inner {
                    out[y * size.width + x] = 1
                } else {
                    let t = (1 - d) / Swift.max(1e-5, 1 - inner)
                    out[y * size.width + x] = t * t * (3 - 2 * t)
                }
            }
        }
        return out
    }
}

/// 分块计划。只做几何、不碰网络，因此可被单元测试直接量。
enum TileGrid {
    /// 互不重叠的"内部块"：每块只写自己那一片，不需要权重累加。
    /// 重叠是靠 `padded` 给每块加一圈上下文实现的——这比"重叠后按权重
    /// 融合"省一整张浮点缓冲，在 iPad 上这是几百 MB 的差别。
    static func interiors(size: PixelSize, tile: Int) -> [PixelRect] {
        guard size.width > 0, size.height > 0, tile > 0 else { return [] }
        // 内部块必须**互不重叠**：重叠的块各写一遍同一片目标像素，
        // 最后一遍覆盖前一遍——接缝会以"一条轻微错位"的形式出现，
        // 而这恰好是断言最难抓到的那种。上下文靠 padded 加，不靠重叠。
        var xs: [(Int, Int)] = []
        var x = 0
        while x < size.width {
            let w = min(tile, size.width - x)
            xs.append((x, w))
            x += w
        }
        var ys: [(Int, Int)] = []
        var y = 0
        while y < size.height {
            let h = min(tile, size.height - y)
            ys.append((y, h))
            y += h
        }

        var out: [PixelRect] = []
        for (oy, oh) in ys {
            for (ox, ow) in xs {
                out.append(PixelRect(x: ox, y: oy, width: ow, height: oh))
            }
        }
        return out
    }

    /// 给一块加一圈上下文（夹到图内）。块在图像边界时这一圈会变窄，
    /// 网络看到的仍是"真实像素"，不是补出来的黑边。
    static func padded(_ rect: PixelRect, overlap: Int, in size: PixelSize) -> PixelRect {
        let expanded = rect.expanded(by: max(0, overlap))
        return PixelRect(x: 0, y: 0, width: size.width, height: size.height).intersected(with: expanded)
    }
}

/// 统一的毫秒计时（报告里用；Date 比 mach 绝对时间更适合入日志）。
@inline(__always)
func nowMs() -> Double {
    Date().timeIntervalSince1970 * 1000
}
