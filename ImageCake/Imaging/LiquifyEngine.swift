import CoreGraphics
import Foundation

// 液化。
//
// 一次拖动就是「把笔迹半径内的像素往某个方向推」。实现上不做正向搬运
// （forward warp）——那会留下空洞和重叠，还得额外补洞；改做**反向采样**：
// 对每个目标像素，算出它该从源图的哪个位置取色，再一次双线性插值。
// 这样输出天然是满的，没有空洞。
//
// 位移场用「反向」定义：目标像素 q 取源图上的 q - v·w，其中 v 是拖动向量、
// w 是笔迹衰减权重。所以内容看起来是沿 v 方向被推走。
//
// 衰减用 1 - (d/r)² 而不是线性的 1 - d/r：中心一段几乎平坦、边缘迅速归零，
// 手感比线性更接近「用手掌推」而不是「用圆规画圈」。两种都在测试里钉了
// 边界（中心最强、半径外为 0）。

/// 一次液化拖动。from/to 为归一化坐标（0..1，y 向下），radius 相对长边。
struct LiquifyStroke: Equatable {
    var from: CGPoint
    var to: CGPoint
    var radius: Double
    /// 0...1，通常由压感或笔刷强度给出。
    var strength: Double

    init(from: CGPoint, to: CGPoint, radius: Double = 0.08, strength: Double = 1) {
        self.from = from
        self.to = to
        self.radius = radius
        self.strength = strength
    }
}

enum LiquifyEngine {
    /// 把若干次拖动叠加成一次重采样。多次拖动先累加位移场再采样一次：
    /// 每笔都重采样一遍会让图被插值糊上很多次，视觉上「越涂越软」。
    ///
    /// `protection` 是保护笔刷的权重图（255 = 完全保护）。它乘在位移权重上，
    /// 所以被保护的区域不会被推动——而不是「推完再贴回去」，那样边缘会断层。
    static func apply(_ image: DisplayImage,
                      strokes: [LiquifyStroke],
                      protection: MaskBuffer? = nil) -> DisplayImage {
        guard !strokes.isEmpty, image.size.pixelCount > 0 else { return image }
        let width = image.size.width
        let height = image.size.height
        let longEdge = Double(image.size.longEdge)

        let protectionBytes: [UInt8]? = {
            guard let mask = protection else { return nil }
            let resized = mask.resized(to: image.size)
            guard !resized.isEmpty else { return nil }
            return [UInt8](resized.data)
        }()

        // 反向位移场（像素单位）。
        var offsetX = [Float](repeating: 0, count: width * height)
        var offsetY = [Float](repeating: 0, count: width * height)

        for stroke in strokes {
            let radius = stroke.radius * longEdge
            guard radius > 0.5 else { continue }

            let fromX = Double(stroke.from.x) * Double(width)
            let fromY = Double(stroke.from.y) * Double(height)
            let deltaX = (Double(stroke.to.x) - Double(stroke.from.x)) * Double(width)
            let deltaY = (Double(stroke.to.y) - Double(stroke.from.y)) * Double(height)
            guard deltaX != 0 || deltaY != 0 else { continue }

            let strength = min(max(stroke.strength, 0), 1)
            let x0 = max(0, Int((fromX - radius).rounded(.down)))
            let x1 = min(width - 1, Int((fromX + radius).rounded(.up)))
            let y0 = max(0, Int((fromY - radius).rounded(.down)))
            let y1 = min(height - 1, Int((fromY + radius).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }

            for y in y0 ... y1 {
                let row = y * width
                for x in x0 ... x1 {
                    let dx = Double(x) + 0.5 - fromX
                    let dy = Double(y) + 0.5 - fromY
                    let distance = (dx * dx + dy * dy).squareRoot()
                    guard distance < radius else { continue }
                    let t = distance / radius
                    let index = row + x
                    var weight = (1 - t * t) * strength
                    if let protectionBytes {
                        // 255 = 完全保护 → 乘 0；0 = 不保护 → 乘 1。
                        weight *= 1 - Double(protectionBytes[index]) / 255
                    }
                    guard weight > 0 else { continue }
                    offsetX[index] -= Float(deltaX * weight)
                    offsetY[index] -= Float(deltaY * weight)
                }
            }
        }

        let source = image.pixels
        var output = [Float](repeating: 0, count: source.count)

        offsetX.withUnsafeBufferPointer { shiftX in
            offsetY.withUnsafeBufferPointer { shiftY in
                source.withUnsafeBufferPointer { src in
                    output.withUnsafeMutableBufferPointer { dst in
                        for y in 0 ..< height {
                            for x in 0 ..< width {
                                let index = y * width + x
                                let sampleX = Double(x) + Double(shiftX[index])
                                let sampleY = Double(y) + Double(shiftY[index])
                                ImageSampling.bilinear(src: src, width: width, height: height,
                                                       x: sampleX, y: sampleY,
                                                       into: dst, at: index * 4)
                            }
                        }
                    }
                }
            }
        }

        return DisplayImage(size: image.size, pixels: output)
    }
}
