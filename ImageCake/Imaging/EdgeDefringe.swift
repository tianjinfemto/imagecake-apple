import Foundation

// 边缘去色溢出（defringe）。
//
// 抠图边缘那圈半透明像素的 RGB 并不是「纯主体色」——它混着原背景：
// 白底发白、绿幕发绿。straight alpha 合成会把这圈脏色按 (1−α) 留下来，
// 表现就是主体轮廓上一圈说不清来源的色边。
//
// 修法：对 0 < α < 1 的像素，在半径内找 α≈1 的**实心**邻居，用它们的
// 平均色替换 RGB，α 原样保留。
//
// 找不到实心邻居（极细的发丝、孤立点）就原样保留：猜一个颜色比留一点
// 脏边更糟——猜错了会在头发边缘出现一块不存在的色斑。
//
// 只在合成前跑：它修的是「颜色」，掩码质量问题（缺发丝、多一块背景）
// 不在这里修。

enum EdgeDefringe {
    /// 搜索半径。3 = 7×7 窗口：够跨过大多数边缘过渡带，
    /// 又不至于把隔着一根头发丝的另一侧颜色拉过来。
    static let radius = 3

    static func apply(_ display: DisplayImage, alpha: MaskBuffer, strength: Double) -> DisplayImage {
        let amount = Float(min(max(strength, 0), 100) / 100)
        guard amount > 0, display.size.pixelCount > 0 else { return display }

        let mask = alpha.resized(to: display.size)
        guard !mask.isEmpty, mask.data.count == display.size.pixelCount else { return display }

        let width = display.size.width
        let height = display.size.height
        let source = display.pixels
        var output = source

        mask.data.withUnsafeBytes { raw in
            let alphaBytes = raw.bindMemory(to: UInt8.self)
            source.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    for y in 0 ..< height {
                        for x in 0 ..< width {
                            let index = y * width + x
                            let a = alphaBytes[index]
                            // 只处理真正的边缘：全实与全透都不是「混了背景色」的像素。
                            guard a > 2, a < 253 else { continue }

                            var sumR: Float = 0
                            var sumG: Float = 0
                            var sumB: Float = 0
                            var count: Float = 0
                            for dy in -radius ... radius {
                                let yy = min(max(y + dy, 0), height - 1)
                                for dx in -radius ... radius {
                                    let xx = min(max(x + dx, 0), width - 1)
                                    let neighbor = yy * width + xx
                                    guard alphaBytes[neighbor] >= 253 else { continue }
                                    let o = neighbor * 4
                                    sumR += src[o]
                                    sumG += src[o + 1]
                                    sumB += src[o + 2]
                                    count += 1
                                }
                            }
                            guard count > 0 else { continue }

                            let o = index * 4
                            let keep = 1 - amount
                            dst[o] = (sumR / count) * amount + src[o] * keep
                            dst[o + 1] = (sumG / count) * amount + src[o + 1] * keep
                            dst[o + 2] = (sumB / count) * amount + src[o + 2] * keep
                            // alpha 不动：这一层只改颜色。
                        }
                    }
                }
            }
        }

        return DisplayImage(size: display.size, pixels: output)
    }
}
