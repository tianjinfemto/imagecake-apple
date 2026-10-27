import CoreGraphics
import Foundation

// 图像容器。三层的分工必须说清楚，否则"到底哪一层是线性"会变成每次改代码
// 都要重新问一遍的问题：
//
//   LinearImage  —— 场景线性、Float、RGBA（alpha 直通）。降噪/曝光/白平衡在这层。
//   DisplayImage —— 显示参照、Float、RGBA，值域 [0,1]。曲线/HSL/色轮/背景在这层。
//   RGBA8Buffer  —— sRGB 8bit 显示码。AI 预处理与编码器吃这层（模型在 sRGB 码上训练）。
//
// 尺寸一律用 PixelSize（整数像素），不出现"长边"这类含糊字段：AI 的
// 分块计划、贴回几何、遮罩尺寸都对不上时都能从这里当场看出来。

struct PixelSize: Hashable, Sendable {
    var width: Int
    var height: Int

    var pixelCount: Int { width * height }
    var longEdge: Int { max(width, height) }
    var aspect: Double { height == 0 ? 1 : Double(width) / Double(height) }

    static let zero = PixelSize(width: 0, height: 0)

    func clamped(to rect: PixelRect) -> PixelRect {
        rect.intersected(with: PixelRect(x: 0, y: 0, width: width, height: height))
    }
}

struct PixelRect: Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    var isEmpty: Bool { width <= 0 || height <= 0 }
    var maxX: Int { x + width }
    var maxY: Int { y + height }

    func intersected(with other: PixelRect) -> PixelRect {
        let x0 = max(x, other.x)
        let y0 = max(y, other.y)
        let x1 = min(maxX, other.maxX)
        let y1 = min(maxY, other.maxY)
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    func expanded(by delta: Int) -> PixelRect {
        PixelRect(x: x - delta, y: y - delta, width: width + delta * 2, height: height + delta * 2)
    }

    var size: PixelSize { PixelSize(width: width, height: height) }

    /// 归一化矩形（0..1，y 向下）→ 像素矩形，已夹到图内。
    static func fromNormalized(_ rect: CGRect, in size: PixelSize) -> PixelRect {
        let x = Int((rect.minX * CGFloat(size.width)).rounded())
        let y = Int((rect.minY * CGFloat(size.height)).rounded())
        let w = Int((rect.width * CGFloat(size.width)).rounded())
        let h = Int((rect.height * CGFloat(size.height)).rounded())
        return PixelRect(x: x, y: y, width: w, height: h)
            .intersected(with: PixelRect(x: 0, y: 0, width: size.width, height: size.height))
    }
}

// MARK: - 线性

struct LinearImage: Sendable {
    let size: PixelSize
    /// RGBA，行优先，count = w*h*4。
    var pixels: [Float]

    init(size: PixelSize, pixels: [Float]) {
        self.size = size
        self.pixels = pixels
    }

    init?(rgba8 buffer: RGBA8Buffer) {
        guard buffer.size.pixelCount > 0, buffer.data.count == buffer.size.pixelCount * 4 else { return nil }
        var out = [Float](repeating: 0, count: buffer.size.pixelCount * 4)
        let lut = ColorMath.decodeU8
        buffer.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            out.withUnsafeMutableBufferPointer { dst in
                var i = 0
                let n = buffer.size.pixelCount
                while i < n {
                    let o = i * 4
                    dst[o] = lut[Int(src[o])]
                    dst[o + 1] = lut[Int(src[o + 1])]
                    dst[o + 2] = lut[Int(src[o + 2])]
                    dst[o + 3] = Float(src[o + 3]) / 255
                    i += 1
                }
            }
        }
        self.init(size: buffer.size, pixels: out)
    }

    func resized(maxEdge: Int) -> LinearImage {
        guard maxEdge > 0, size.longEdge > maxEdge else { return self }
        let scale = Double(maxEdge) / Double(size.longEdge)
        let target = PixelSize(width: max(1, Int((Double(size.width) * scale).rounded())),
                               height: max(1, Int((Double(size.height) * scale).rounded())))
        return resized(to: target)
    }

    func resized(to target: PixelSize) -> LinearImage {
        guard target != size, target.width > 0, target.height > 0 else { return self }
        let out = Resampler.resample(pixels, channels: 4, from: size, to: target, alphaAware: true)
        return LinearImage(size: target, pixels: out)
    }

    func cropped(to rect: PixelRect) -> LinearImage {
        let r = size.clamped(to: rect)
        guard !r.isEmpty, r != PixelRect(x: 0, y: 0, width: size.width, height: size.height) else { return self }
        var out = [Float](repeating: 0, count: r.width * r.height * 4)
        for row in 0 ..< r.height {
            let srcRow = (r.y + row) * size.width + r.x
            let dstRow = row * r.width
            let srcStart = srcRow * 4
            let dstStart = dstRow * 4
            out.replaceSubrange(dstStart ..< (dstStart + r.width * 4),
                                with: pixels[srcStart ..< (srcStart + r.width * 4)])
        }
        return LinearImage(size: PixelSize(width: r.width, height: r.height), pixels: out)
    }
}

// MARK: - 显示域

struct DisplayImage: Sendable {
    let size: PixelSize
    /// RGBA，值域 [0,1]，**显示码**（已经过 sRGB 传递函数，编码前不再转换）。
    /// 这一层再 encode 一次就是双重 gamma——这是整个管线最容易写错的一处，
    /// 所以 rgba8/rgba16 都只做 ×255 / ×65535。
    var pixels: [Float]

    init(size: PixelSize, pixels: [Float]) {
        self.size = size
        self.pixels = pixels
    }

    init?(displayRGBA8 buffer: RGBA8Buffer) {
        guard buffer.size.pixelCount > 0, buffer.data.count == buffer.size.pixelCount * 4 else { return nil }
        var out = [Float](repeating: 0, count: buffer.size.pixelCount * 4)
        buffer.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            out.withUnsafeMutableBufferPointer { dst in
                var i = 0
                while i < out.count {
                    dst[i] = Float(src[i]) / 255
                    i += 1
                }
            }
        }
        self.init(size: buffer.size, pixels: out)
    }

    func resized(to target: PixelSize) -> DisplayImage {
        guard target != size, target.width > 0, target.height > 0 else { return self }
        let out = Resampler.resample(pixels, channels: 4, from: size, to: target, alphaAware: true)
        return DisplayImage(size: target, pixels: out)
    }

    func cropped(to rect: PixelRect) -> DisplayImage {
        let r = size.clamped(to: rect)
        guard !r.isEmpty, r != PixelRect(x: 0, y: 0, width: size.width, height: size.height) else { return self }
        var out = [Float](repeating: 0, count: r.width * r.height * 4)
        for row in 0 ..< r.height {
            let srcStart = ((r.y + row) * size.width + r.x) * 4
            let dstStart = row * r.width * 4
            out.replaceSubrange(dstStart ..< (dstStart + r.width * 4),
                                with: pixels[srcStart ..< (srcStart + r.width * 4)])
        }
        return DisplayImage(size: PixelSize(width: r.width, height: r.height), pixels: out)
    }

    /// 显示码（8bit）。dither 只许给屏幕用：抖动会改像素值，任何进文件的
    /// 图都必须 dither=false（与 imagecake 的 encode(buffer, dither) 同一条）。
    func rgba8(dither: Bool = false) -> RGBA8Buffer {
        var out = [UInt8](repeating: 255, count: size.pixelCount * 4)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var i = 0
                while i < size.pixelCount {
                    let o = i * 4
                    for c in 0 ..< 3 {
                        var v = src[o + c]
                        if dither {
                            // 有序抖动（Bayer 4×4）：只为消除大面积渐变的色带。
                            let x = i % size.width
                            let y = i / size.width
                            let threshold = Self.bayer4[(y & 3) * 4 + (x & 3)]
                            v += (threshold - 0.5) / 255
                        }
                        dst[o + c] = UInt8((Swift.min(Swift.max(v, 0), 1) * 255).rounded())
                    }
                    dst[o + 3] = UInt8((Swift.min(Swift.max(src[o + 3], 0), 1) * 255).rounded())
                    i += 1
                }
            }
        }
        return RGBA8Buffer(size: size, data: Data(out))
    }

    /// 显示码（16bit）——只喂自家 PNG16 写入器，不走 ImageIO。
    func rgba16() -> [UInt16] {
        var out = [UInt16](repeating: 65535, count: size.pixelCount * 4)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var i = 0
                while i < size.pixelCount {
                    let o = i * 4
                    for c in 0 ..< 3 {
                        dst[o + c] = UInt16(Swift.min(Swift.max(src[o + c], 0), 1) * 65535 + 0.5)
                    }
                    dst[o + 3] = UInt16(Swift.min(Swift.max(src[o + 3], 0), 1) * 65535 + 0.5)
                    i += 1
                }
            }
        }
        return out
    }

    func cgImage() -> CGImage? {
        rgba8(dither: false).cgImage()
    }

    private static let bayer4: [Float] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ].map { Float($0) / 16 }
}

// MARK: - 8bit

struct RGBA8Buffer: Sendable {
    let size: PixelSize
    let data: Data

    init(size: PixelSize, data: Data) {
        self.size = size
        self.data = data
    }

    init?(size: PixelSize, colors: (UInt8, UInt8, UInt8, UInt8)) {
        guard size.pixelCount > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            bytes[i * 4] = colors.0
            bytes[i * 4 + 1] = colors.1
            bytes[i * 4 + 2] = colors.2
            bytes[i * 4 + 3] = colors.3
        }
        self.init(size: size, data: Data(bytes))
    }

    var byteCount: Int { data.count }

    func cgImage() -> CGImage? {
        guard size.pixelCount > 0, data.count == size.pixelCount * 4 else { return nil }
        // CGImage 的 premultipliedLast 要求数据已乘过 alpha；照片 alpha=1，
        // 但抠图结果不是——这里统一乘一次，免得在画布上看到黑边。
        var bytes = [UInt8](data)
        let n = size.pixelCount
        for i in 0 ..< n {
            let a = Int(bytes[i * 4 + 3])
            if a == 255 { continue }
            bytes[i * 4] = UInt8(Int(bytes[i * 4]) * a / 255)
            bytes[i * 4 + 1] = UInt8(Int(bytes[i * 4 + 1]) * a / 255)
            bytes[i * 4 + 2] = UInt8(Int(bytes[i * 4 + 2]) * a / 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: size.width,
                       height: size.height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: size.width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    func resized(to target: PixelSize) -> RGBA8Buffer {
        guard target != size, target.width > 0, target.height > 0 else { return self }
        guard let display = DisplayImage(displayRGBA8: self) else { return self }
        return display.resized(to: target).rgba8()
    }

    func cropped(to rect: PixelRect) -> RGBA8Buffer {
        let r = size.clamped(to: rect)
        guard !r.isEmpty, r != PixelRect(x: 0, y: 0, width: size.width, height: size.height) else { return self }
        var out = [UInt8](repeating: 0, count: r.width * r.height * 4)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0 ..< r.height {
                    let srcStart = ((r.y + row) * size.width + r.x) * 4
                    let dstStart = row * r.width * 4
                    for i in 0 ..< (r.width * 4) {
                        dst[dstStart + i] = src[srcStart + i]
                    }
                }
            }
        }
        return RGBA8Buffer(size: PixelSize(width: r.width, height: r.height), data: Data(out))
    }
}

// MARK: - 遮罩

struct MaskBuffer: Sendable {
    let size: PixelSize
    /// 单通道 8bit：255=人像/保留，0=背景/填掉。
    let data: Data

    init(size: PixelSize, data: Data) {
        self.size = size
        self.data = data
    }

    static func filled(_ size: PixelSize, value: UInt8) -> MaskBuffer {
        MaskBuffer(size: size, data: Data(repeating: value, count: max(0, size.pixelCount)))
    }

    var isEmpty: Bool { size.pixelCount == 0 || data.count != size.pixelCount }

    func resized(to target: PixelSize) -> MaskBuffer {
        guard target != size, !isEmpty, target.width > 0, target.height > 0 else { return self }
        let floats = data.map { Float($0) / 255 }
        let out = Resampler.resample(floats, channels: 1, from: size, to: target, alphaAware: false)
        return MaskBuffer(size: target, data: Data(out.map { UInt8((Swift.min(Swift.max($0, 0), 1) * 255).rounded()) }))
    }

    func cropped(to rect: PixelRect) -> MaskBuffer {
        let r = size.clamped(to: rect)
        guard !isEmpty, !r.isEmpty else { return MaskBuffer.filled(PixelSize(width: 0, height: 0), value: 0) }
        if r == PixelRect(x: 0, y: 0, width: size.width, height: size.height) { return self }
        var out = [UInt8](repeating: 0, count: r.width * r.height)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            for row in 0 ..< r.height {
                let srcStart = (r.y + row) * size.width + r.x
                let dstStart = row * r.width
                for i in 0 ..< r.width {
                    out[dstStart + i] = src[srcStart + i]
                }
            }
        }
        return MaskBuffer(size: PixelSize(width: r.width, height: r.height), data: Data(out))
    }

    /// 被遮住的像素数（>128 记为被遮）。用于"没有选区就别跑推理"的闸门。
    var coveredCount: Int {
        guard !isEmpty else { return 0 }
        return data.reduce(into: 0) { count, value in
            if value > 128 { count += 1 }
        }
    }

    func cgImage(tint: (r: Double, g: Double, b: Double) = (1, 0.2, 0.2)) -> CGImage? {
        guard !isEmpty else { return nil }
        var bytes = [UInt8](repeating: 0, count: size.pixelCount * 4)
        let dataArr = [UInt8](data)
        // 写“直通 alpha”的颜色，交给 RGBA8Buffer.cgImage 统一预乘一次。
        // 这里先乘一次会变成双重预乘，叠层会显脏（越透越黑）。
        let r = UInt8(min(255, max(0, 255 * tint.r)))
        let g = UInt8(min(255, max(0, 255 * tint.g)))
        let b = UInt8(min(255, max(0, 255 * tint.b)))
        for i in 0 ..< size.pixelCount {
            let a = dataArr[i]
            bytes[i * 4] = r
            bytes[i * 4 + 1] = g
            bytes[i * 4 + 2] = b
            bytes[i * 4 + 3] = a
        }
        return RGBA8Buffer(size: size, data: Data(bytes)).cgImage()
    }
}

// MARK: - 缩放

enum Resampler {
    /// 分离式重采样：缩小走面积平均（不会像最近邻那样丢细节/出摩尔纹），
    /// 放大走双线性。alphaAware 时先预乘再还原——半透明边缘混色才不会发黑。
    static func resample(_ src: [Float], channels: Int, from: PixelSize, to: PixelSize, alphaAware: Bool) -> [Float] {
        guard from != to, from.width > 0, from.height > 0, to.width > 0, to.height > 0 else { return src }
        guard src.count == from.pixelCount * channels else { return src }

        let needsPremul = alphaAware && channels == 4
        var work = src
        if needsPremul {
            var i = 0
            while i < from.pixelCount {
                let o = i * 4
                let a = work[o + 3]
                work[o] *= a
                work[o + 1] *= a
                work[o + 2] *= a
                i += 1
            }
        }

        let horizontal = resampleAxis(work, channels: channels, srcW: from.width, srcH: from.height,
                                      srcLen: from.width, dstLen: to.width, horizontal: true)
        let vertical = resampleAxis(horizontal, channels: channels, srcW: to.width, srcH: from.height,
                                    srcLen: from.height, dstLen: to.height, horizontal: false)

        if needsPremul {
            var i = 0
            while i < to.pixelCount {
                let o = i * 4
                let a = vertical[o + 3]
                if a > 1e-6 {
                    vertical[o] /= a
                    vertical[o + 1] /= a
                    vertical[o + 2] /= a
                }
                i += 1
            }
        }
        return vertical
    }

    private static func resampleAxis(_ src: [Float], channels: Int, srcW: Int, srcH: Int,
                                     srcLen: Int, dstLen: Int, horizontal: Bool) -> [Float] {
        let srcStrideX = channels
        let srcStrideY = srcW * channels
        // 输出尺寸按**目标轴**算：水平通路的输出宽度是 dstLen，不是源宽。
        // 写成源宽在放大时会越界写（症状是丢像素或直接崩）。
        let outW = horizontal ? dstLen : srcW
        let outH = horizontal ? srcH : dstLen
        let outStrideY = outW * channels
        var out = [Float](repeating: 0, count: outW * outH * channels)
        let scale = Double(srcLen) / Double(dstLen)
        let lines = horizontal ? srcH : outW

        for line in 0 ..< lines {
            for d in 0 ..< dstLen {
                let srcPos = (Double(d) + 0.5) * scale - 0.5
                let i0 = Int(floor(srcPos))
                let frac = Float(srcPos - Double(i0))
                for c in 0 ..< channels {
                    func sample(_ index: Int) -> Float {
                        let clamped = min(max(index, 0), srcLen - 1)
                        if horizontal {
                            return src[line * srcStrideY + clamped * srcStrideX + c]
                        } else {
                            return src[clamped * srcStrideY + line * srcStrideX + c]
                        }
                    }
                    let value: Float
                    if scale > 1 {
                        // 面积平均：把覆盖到的源像素按重叠比例加权。
                        let start = Double(d) * scale
                        let end = start + scale
                        var sum: Float = 0
                        var weight: Float = 0
                        var p = Int(floor(start))
                        while Double(p) < end {
                            let overlap = Float(min(end, Double(p + 1)) - max(start, Double(p)))
                            if overlap > 0 {
                                sum += sample(p) * overlap
                                weight += overlap
                            }
                            p += 1
                        }
                        value = weight > 0 ? sum / weight : sample(i0)
                    } else {
                        value = sample(i0) * (1 - frac) + sample(i0 + 1) * frac
                    }
                    if horizontal {
                        out[line * outStrideY + d * channels + c] = value
                    } else {
                        out[d * outStrideY + line * channels + c] = value
                    }
                }
            }
        }
        return out
    }
}
