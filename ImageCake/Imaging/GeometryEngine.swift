import CoreGraphics
import Foundation

// 几何变换：旋转 / 翻转 / 裁剪。
//
// 旋转走反向采样（与 LiquifyEngine 同思路）：对输出每个像素，反查它
// 在输入图上的位置，双线性采样。正向采样会在大角度时留空洞。
//
// 90° 倍数旋转走快速路径（整像素搬运，不插值），任意角度走双线性。
// 裁剪复用各容器已有的 cropped(to:)。
//
// 自动水平：读 EXIF 方向标记，如果有非 .up 的方向，先转正。这一步
// 在 ImageLoader 里已由 kCGImageSourceCreateThumbnailWithTransform 做了，
// 但全量加载时不走缩略图，所以这里补一刀。

enum GeometryEngine {
    // MARK: - 像素级底座（DisplayImage / LinearImage 共用）
    //
    // 为什么先写 [Float] + PixelSize 的版本：几何必须在调色之前把画布转正
    // （见 ImageDocument.render），而那时手里是线性图。给 DisplayImage 单独
    // 实一套、线性图再实一套，两套旋转迟早算出不一致的边界像素。

    static func rotate90(_ pixels: [Float], size: PixelSize, clockwise: Bool) -> (pixels: [Float], size: PixelSize) {
        let w = size.width, h = size.height
        let c = 4
        guard w > 0, h > 0, pixels.count == w * h * c else { return (pixels, size) }
        var dst = [Float](repeating: 0, count: pixels.count)
        for y in 0 ..< h {
            for x in 0 ..< w {
                // 顺时针：(x,y) → (h-1-y, x)；逆时针：(x,y) → (y, w-1-x)。
                // 新图的宽度是 h，所以行乘数用 h。
                let nx = clockwise ? h - 1 - y : y
                let ny = clockwise ? x : w - 1 - x
                for ch in 0 ..< c {
                    dst[(ny * h + nx) * c + ch] = pixels[(y * w + x) * c + ch]
                }
            }
        }
        return (dst, PixelSize(width: h, height: w))
    }

    static func flip(_ pixels: [Float], size: PixelSize, horizontal: Bool) -> [Float] {
        let w = size.width, h = size.height
        let c = 4
        guard w > 0, h > 0, pixels.count == w * h * c else { return pixels }
        var dst = [Float](repeating: 0, count: pixels.count)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let nx = horizontal ? w - 1 - x : x
                let ny = horizontal ? y : h - 1 - y
                for ch in 0 ..< c {
                    dst[(ny * w + nx) * c + ch] = pixels[(y * w + x) * c + ch]
                }
            }
        }
        return dst
    }

    /// 把一组几何变换按 旋转 → 翻转 → 裁剪 的顺序作用在线性图上。
    /// 顺序写死在这里：先裁剪再旋转会让归一化裁剪框指的是转之前的画面。
    ///
    /// 只处理 90° 整数倍以外的角度：`rotate(_:size:degrees:)` 对 90/180/270
    /// 自己会走整像素快速路径，所以线性层与显示层拿到的结果是同一段代码。
    static func apply(_ transform: GeometryTransform, to linear: LinearImage) -> LinearImage {
        guard !transform.isIdentity else { return linear }
        var rotated = rotate(linear.pixels, size: linear.size, degrees: transform.rotation)
        if transform.flipHorizontal { rotated.pixels = flip(rotated.pixels, size: rotated.size, horizontal: true) }
        if transform.flipVertical { rotated.pixels = flip(rotated.pixels, size: rotated.size, horizontal: false) }
        var out = LinearImage(size: rotated.size, pixels: rotated.pixels)
        if let rect = transform.cropRect {
            out = out.cropped(to: PixelRect.fromNormalized(rect, in: rotated.size))
        }
        return out
    }

    /// 90° 倍数旋转。快速路径：整像素搬运，不插值，不丢质量。
    static func rotate90(_ image: DisplayImage, clockwise: Bool) -> DisplayImage {
        let rotated = rotate90(image.pixels, size: image.size, clockwise: clockwise)
        return DisplayImage(size: rotated.size, pixels: rotated.pixels)
    }

    /// 水平/垂直翻转。
    static func flip(_ image: DisplayImage, horizontal: Bool) -> DisplayImage {
        DisplayImage(size: image.size, pixels: flip(image.pixels, size: image.size, horizontal: horizontal))
    }

    /// 任意角度旋转（双线性反向采样）。角度以度为单位，正 = 顺时针。
    /// 像素级版本，线性/显示共用。
    ///
    /// 每个像素只调一次 `bilinear`：那个函数一次写**四个**通道。之前按
    /// `for ch in 0..<4` 各调一次，症状是后一次覆写前一次（颜色串通道），
    /// 而最后一个像素会往缓冲区外写三个 float。
    static func rotate(_ pixels: [Float], size: PixelSize, degrees: Double) -> (pixels: [Float], size: PixelSize) {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        if normalized == 0 { return (pixels, size) }
        if normalized == 90 { return rotate90(pixels, size: size, clockwise: true) }
        if normalized == 180 { return (flip(flip(pixels, size: size, horizontal: true), size: size, horizontal: false), size) }
        if normalized == 270 { return rotate90(pixels, size: size, clockwise: false) }

        let w = size.width, h = size.height
        let c = 4
        let rad = normalized * .pi / 180
        let cosA = cos(rad)
        let sinA = sin(rad)
        let newW = Int((abs(Double(w) * cosA) + abs(Double(h) * sinA)).rounded())
        let newH = Int((abs(Double(w) * sinA) + abs(Double(h) * cosA)).rounded())
        guard newW > 0, newH > 0, w > 0, h > 0, pixels.count == w * h * c else { return (pixels, size) }
        let cx = Double(w) / 2, cy = Double(h) / 2
        let ncx = Double(newW) / 2, ncy = Double(newH) / 2
        var dst = [Float](repeating: 0, count: newW * newH * c)
        pixels.withUnsafeBufferPointer { srcPtr in
            dst.withUnsafeMutableBufferPointer { dstPtr in
                for y in 0 ..< newH {
                    for x in 0 ..< newW {
                        let dx = Double(x) - ncx
                        let dy = Double(y) - ncy
                        let sx = dx * cosA + dy * sinA + cx
                        let sy = -dx * sinA + dy * cosA + cy
                        ImageSampling.bilinear(src: srcPtr, width: w, height: h,
                                               x: sx, y: sy, into: dstPtr,
                                               at: (y * newW + x) * c)
                    }
                }
            }
        }
        return (dst, PixelSize(width: newW, height: newH))
    }

    /// 任意角度旋转（显示域）。
    static func rotate(_ image: DisplayImage, degrees: Double) -> DisplayImage {
        let rotated = rotate(image.pixels, size: image.size, degrees: degrees)
        return DisplayImage(size: rotated.size, pixels: rotated.pixels)
    }

    /// 裁剪到归一化矩形。
    static func crop(_ image: DisplayImage, to normalizedRect: CGRect) -> DisplayImage {
        let w = image.size.width
        let h = image.size.height
        let rect = PixelRect.fromNormalized(normalizedRect, in: image.size)
            .intersected(with: PixelRect(x: 0, y: 0, width: w, height: h))
        return image.cropped(to: rect)
    }
}

/// 几何变换参数（存 ImageDocument 而非 EditParameters：几何改画布尺寸，
/// 不是调色参数，不进预设）。
struct GeometryTransform: Equatable, Sendable {
    /// 旋转角度（度），90 的倍数走快速路径。
    var rotation: Double = 0
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false
    /// 裁剪框（归一化）。nil = 不裁。
    var cropRect: CGRect? = nil

    var isIdentity: Bool {
        rotation == 0 && !flipHorizontal && !flipVertical && cropRect == nil
    }

    static let identity = GeometryTransform()
}