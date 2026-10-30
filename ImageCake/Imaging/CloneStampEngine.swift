import CoreGraphics
import Foundation

// 仿制图章。
//
// 与液化的关系：两者共用 StrokeRasterizer 的掩码语义与 ImageSampling 的采样
// 约定，差别只在「掩码里做什么」——液化移动像素，图章搬运像素。
//
// 取样锚点是笔迹起点的一个偏移：从锚点开始，笔迹走到哪，取样点就同步走到哪。
// 这是仿制图章的标准行为（先在某处取样，再到别处绘制）。
//
// 源永远取自**输入图像**，不是上一笔的输出：否则来回涂会把已经涂过的内容
// 当成源，图章会「自己吃自己」，越涂越糊。
//
// 坐标系说明：StrokeRasterizer 内部用连续坐标（像素左边缘 = 0），
// ImageSampling 用索引空间（像素中心 = 整数）。两者相差 0.5 像素，但这里
// 只用到「平移量」，而平移量与原点约定无关，所以两套约定可以共存。

/// 一次仿制操作。所有坐标为归一化（0..1，y 向下）。
struct CloneStamp: Equatable {
    /// 取样锚点。笔迹的第一个点对应这里。
    var source: CGPoint
    /// 目标笔迹。
    var points: [CGPoint]
    var radius: Double
    /// 0...1。1 = 完全覆盖，0 = 关。
    var strength: Double
    /// 0...1，透传给栅格化。
    var hardness: Double

    init(source: CGPoint, points: [CGPoint], radius: Double = 0.05,
         strength: Double = 1, hardness: Double = 0.6) {
        self.source = source
        self.points = points
        self.radius = radius
        self.strength = strength
        self.hardness = hardness
    }
}

enum CloneStampEngine {
    /// 依次应用若干次仿制。掩码外的像素必须逐字节不动。
    static func apply(_ image: DisplayImage, stamps: [CloneStamp]) -> DisplayImage {
        guard !stamps.isEmpty, image.size.pixelCount > 0 else { return image }

        let size = image.size
        let width = size.width
        let height = size.height
        // 源固定为输入：多笔之间不互相污染。
        let source = image.pixels
        var output = source

        for stamp in stamps {
            guard !stamp.points.isEmpty else { continue }
            // stamp.strength 是 Double，这里就转成 Float：后面要和
            // Float(weight) / 255 相乘，混用会让编译器去找不存在的重载
            // （报出来的错会是莫名其妙的 Duration 类型不匹配）。
            let strength = Float(min(max(stamp.strength, 0), 1))
            guard strength > 0 else { continue }

            let mask = StrokeRasterizer.mask(
                strokes: [BrushStroke(points: stamp.points,
                                      radius: stamp.radius,
                                      hardness: stamp.hardness)],
                size: size)
            guard !mask.isEmpty else { continue }

            // 锚点到笔迹起点的偏移，换成像素。
            let anchor = stamp.points[0]
            let shiftX = (Double(stamp.source.x) - Double(anchor.x)) * Double(width)
            let shiftY = (Double(stamp.source.y) - Double(anchor.y)) * Double(height)

            let maskBytes = [UInt8](mask.data)
            var scratch = [Float](repeating: 0, count: 4)

            maskBytes.withUnsafeBufferPointer { weights in
                scratch.withUnsafeMutableBufferPointer { tmp in
                    source.withUnsafeBufferPointer { src in
                        output.withUnsafeMutableBufferPointer { dst in
                            for y in 0 ..< height {
                                let row = y * width
                                for x in 0 ..< width {
                                    let index = row + x
                                    let weight = Int(weights[index])
                                    guard weight > 0 else { continue }

                                    ImageSampling.bilinear(src: src, width: width, height: height,
                                                           x: Double(x) + shiftX,
                                                           y: Double(y) + shiftY,
                                                           into: tmp, at: 0)

                                    let k = Float(weight) / 255 * strength
                                    let offset = index * 4
                                    for channel in 0 ..< 4 {
                                        dst[offset + channel] = dst[offset + channel] * (1 - k) + tmp[channel] * k
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return DisplayImage(size: size, pixels: output)
    }
}
