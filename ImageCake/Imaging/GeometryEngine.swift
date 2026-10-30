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
    /// 90° 倍数旋转。快速路径：整像素搬运，不插值，不丢质量。
    static func rotate90(_ image: DisplayImage, clockwise: Bool) -> DisplayImage {
        let src = image.pixels
        let w = image.size.width
        let h = image.size.height
        let c = 4
        var dst = [Float](repeating: 0, count: w * h * c)
        if clockwise {
            for y in 0..<h {
                for x in 0..<w {
                    let nx = h - 1 - y
                    let ny = x
                    for ch in 0..<c {
                        dst[(ny * h + nx) * c + ch] = src[(y * w + x) * c + ch]
                    }
                }
            }
            return DisplayImage(size: PixelSize(width: h, height: w), pixels: dst)
        } else {
            for y in 0..<h {
                for x in 0..<w {
                    let nx = y
                    let ny = w - 1 - x
                    for ch in 0..<c {
                        dst[(ny * h + nx) * c + ch] = src[(y * w + x) * c + ch]
                    }
                }
            }
            return DisplayImage(size: PixelSize(width: h, height: w), pixels: dst)
        }
    }

    /// 水平/垂直翻转。
    static func flip(_ image: DisplayImage, horizontal: Bool) -> DisplayImage {
        let src = image.pixels
        let w = image.size.width
        let h = image.size.height
        let c = 4
        var dst = [Float](repeating: 0, count: w * h * c)
        if horizontal {
            for y in 0..<h {
                for x in 0..<w {
                    let nx = w - 1 - x
                    for ch in 0..<c {
                        dst[(y * w + nx) * c + ch] = src[(y * w + x) * c + ch]
                    }
                }
            }
        } else {
            for y in 0..<h {
                let ny = h - 1 - y
                for x in 0..<w {
                    for ch in 0..<c {
                        dst[(ny * w + x) * c + ch] = src[(y * w + x) * c + ch]
                    }
                }
            }
        }
        return DisplayImage(size: PixelSize(width: w, height: h), pixels: dst)
    }

    /// 任意角度旋转（双线性反向采样）。角度以度为单位，正 = 顺时针。
    static func rotate(_ image: DisplayImage, degrees: Double) -> DisplayImage {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        if normalized == 0 { return image }
        if normalized == 90 { return rotate90(image, clockwise: true) }
        if normalized == 180 { return flip(flip(image, horizontal: true), horizontal: false) }
        if normalized == 270 { return rotate90(image, clockwise: false) }

        let w = image.size.width
        let h = image.size.height
        let c = 4
        let rad = degrees * .pi / 180
        let cosA = cos(rad)
        let sinA = sin(rad)
        let newW = Int((abs(Double(w) * cosA) + abs(Double(h) * sinA)).rounded())
        let newH = Int((abs(Double(w) * sinA) + abs(Double(h) * cosA)).rounded())
        let cx = Double(w) / 2
        let cy = Double(h) / 2
        let ncx = Double(newW) / 2
        let ncy = Double(newH) / 2
        var dst = [Float](repeating: 0, count: newW * newH * c)
        let src = image.pixels
        src.withUnsafeBufferPointer { srcPtr in
            dst.withUnsafeMutableBufferPointer { dstPtr in
                for y in 0..<newH {
                    for x in 0..<newW {
                        let dx = Double(x) - ncx
                        let dy = Double(y) - ncy
                        let sx = dx * cosA + dy * sinA + cx
                        let sy = -dx * sinA + dy * cosA + cy
                        for ch in 0..<c {
                            ImageSampling.bilinear(src: srcPtr, width: w, height: h,
                                                   x: sx, y: sy, into: dstPtr,
                                                   at: (y * newW + x) * c + ch)
                        }
                    }
                }
            }
        }
        return DisplayImage(size: PixelSize(width: newW, height: newH), pixels: dst)
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