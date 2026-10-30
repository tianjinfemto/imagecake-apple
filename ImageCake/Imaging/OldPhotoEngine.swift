import CoreGraphics
import Foundation

// 老照片修复：褪色恢复 + 划痕去除。
//
// 褪色恢复：老照片整体偏黄/偏褐（银盐化学褪变），用灰世界假设反推
// 白平衡偏移，再拉回中性。不是 AI——是确定性算子，零权重、离线、
// 确定性，适合放在调色链之前当一步预处理。
//
// 划痕去除：老照片上的细长亮线（划痕）用形态学方法检测——开运算
// （先腐蚀再膨胀）去掉细线，差分出划痕位置，再用邻域中值填充。
// 不是 LaMa 那种语义修复，但对付物理划痕够用且零权重。

enum OldPhotoEngine {
    /// 褪色恢复。返回处理后的图 + 检测到的偏色量（给 UI 显示）。
    static func restoreFade(_ image: DisplayImage) -> (DisplayImage, colorShift: CGPoint) {
        let avg = averageColor(image)
        let targetGray = (avg.r + avg.g + avg.b) / 3
        let shiftR = targetGray - avg.r
        let shiftG = targetGray - avg.g
        let shiftB = targetGray - avg.b
        let floats = image.floats
        let c = image.channels
        var result = floats
        for i in 0..<(floats.count / c) {
            if c >= 3 {
                result[i * c] = max(0, min(1, floats[i * c] + Float(shiftR)))
                result[i * c + 1] = max(0, min(1, floats[i * c + 1] + Float(shiftG)))
                result[i * c + 2] = max(0, min(1, floats[i * c + 2] + Float(shiftB)))
            }
        }
        return (DisplayImage(width: image.size.width, height: image.size.height,
                             channels: c, floats: result),
                CGPoint(x: shiftR, y: shiftB))
    }

    /// 划痕去除。threshold 控制检测灵敏度（0...1，默认 0.15）。
    static func removeScratches(_ image: DisplayImage, threshold: Double = 0.15) -> DisplayImage {
        let w = image.size.width
        let h = image.size.height
        let c = image.channels
        let src = image.floats
        let opened = morphologicalOpen(src, width: w, height: h, channels: c, radius: 1)
        var result = src
        for i in 0..<(w * h * c) {
            let diff = abs(src[i] - opened[i])
            if Double(diff) > threshold {
                result[i] = opened[i]
            }
        }
        return DisplayImage(width: w, height: h, channels: c, floats: result)
    }

    /// 一步完成：先去划痕再恢复褪色。
    static func restore(_ image: DisplayImage, scratchThreshold: Double = 0.15) -> (DisplayImage, colorShift: CGPoint) {
        let cleaned = removeScratches(image, threshold: scratchThreshold)
        return restoreFade(cleaned)
    }

    // MARK: - 内部

    private static func averageColor(_ image: DisplayImage) -> (r: Double, g: Double, b: Double) {
        let floats = image.floats
        let c = image.channels
        let count = floats.count / c
        guard count > 0, c >= 3 else { return (0.5, 0.5, 0.5) }
        var sr: Double = 0, sg: Double = 0, sb: Double = 0
        for i in 0..<count {
            sr += Double(floats[i * c])
            sg += Double(floats[i * c + 1])
            sb += Double(floats[i * c + 2])
        }
        return (sr / Double(count), sg / Double(count), sb / Double(count))
    }

    /// 形态学开运算（先腐蚀再膨胀），radius=1 的十字结构元。
    private static func morphologicalOpen(_ src: [Float], width: Int, height: Int,
                                          channels: Int, radius: Int) -> [Float] {
        let eroded = morphologicalErode(src, width: width, height: height, channels: channels, radius: radius)
        return morphologicalDilate(eroded, width: width, height: height, channels: channels, radius: radius)
    }

    private static func morphologicalErode(_ src: [Float], width: Int, height: Int,
                                           channels: Int, radius: Int) -> [Float] {
        var dst = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                for ch in 0..<channels {
                    var minVal: Float = .greatestFiniteMagnitude
                    for dy in -radius...radius {
                        for dx in -radius...radius {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                            let val = src[(ny * width + nx) * channels + ch]
                            if val < minVal { minVal = val }
                        }
                    }
                    dst[(y * width + x) * channels + ch] = minVal
                }
            }
        }
        return dst
    }

    private static func morphologicalDilate(_ src: [Float], width: Int, height: Int,
                                            channels: Int, radius: Int) -> [Float] {
        var dst = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                for ch in 0..<channels {
                    var maxVal: Float = -.greatestFiniteMagnitude
                    for dy in -radius...radius {
                        for dx in -radius...radius {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                            let val = src[(ny * width + nx) * channels + ch]
                            if val > maxVal { maxVal = val }
                        }
                    }
                    dst[(y * width + x) * channels + ch] = maxVal
                }
            }
        }
        return dst
    }
}