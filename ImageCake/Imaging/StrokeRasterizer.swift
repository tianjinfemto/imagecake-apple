import CoreGraphics
import Foundation

// 笔迹与栅格化。
//
// 液化、仿制图章、保护笔刷、局部调节共用同一套「笔迹」：一串归一化坐标的点
// + 恒定半径 + 硬度。它们之间只差「拿这个掩码去做什么」——所以先把笔迹
// 本身和它的栅格化做对，上面几个工具就只剩各自的算子。
//
// 为什么坐标存归一化（0..1，y 向下）：预览是 2048 档、导出是全量，用像素存
// 会让同一条笔迹在导出时整块跑偏；换一张分辨率不同的图也不必换算。
// 半径同理，按长边比例存。
//
// 为什么栅格化单独一个类型：它不碰 UI、不碰 AI、不碰权重，纯几何 + 像素，
// 是这一批里唯一能被完整断言的部分。真机上「笔刷边缘毛毛的」这种问题，
// 得先排除是栅格化错了还是渲染错了。
//
// 内部一律用 Double：点在模型里是归一化 Double、半径是 Double，只有最外层
// 才换成 CGPoint。混用 CGFloat 会让 `CGFloat * Double` 这类表达式散落在
// 循环里，而且很难一眼看出是哪一个乘错了。

/// 一笔。点按时间顺序排列，坐标为归一化（0..1）。
struct BrushStroke: Equatable {
    var points: [CGPoint]
    /// 归一化半径（相对长边）。0.02 在 2048 长边上约 40px 直径。
    var radius: Double
    /// 0...1。1 = 硬边，0 = 从中心一路衰减到边缘。
    var hardness: Double

    init(points: [CGPoint], radius: Double = 0.02, hardness: Double = 0.6) {
        self.points = points
        self.radius = radius
        self.hardness = hardness
    }
}

enum StrokeRasterizer {
    /// 把若干笔合成一张 0...255 的掩码（255 = 完全覆盖）。
    ///
    /// 重叠取**最大值**而不是叠加：同一处来回涂两次不该变成「两倍覆盖」，
    /// 否则重复笔迹会让掩码提前饱和，液化的强度就不可控了。
    static func mask(strokes: [BrushStroke], size: PixelSize) -> MaskBuffer {
        guard size.pixelCount > 0, !strokes.isEmpty else {
            return MaskBuffer(size: size, data: Data(repeating: 0, count: max(0, size.pixelCount)))
        }
        var bytes = [UInt8](repeating: 0, count: size.pixelCount)
        let width = Double(size.width)
        let height = Double(size.height)
        let longEdge = Double(size.longEdge)

        bytes.withUnsafeMutableBufferPointer { dst in
            for stroke in strokes {
                guard !stroke.points.isEmpty else { continue }
                let pixelRadius = stroke.radius * longEdge
                guard pixelRadius > 0.5 else { continue }
                let hardness = min(max(stroke.hardness, 0), 1)

                let pixels: [(x: Double, y: Double)] = stroke.points.map {
                    (x: Double($0.x) * width, y: Double($0.y) * height)
                }
                if pixels.count == 1 {
                    stamp(into: dst, at: pixels[0], radius: pixelRadius,
                          hardness: hardness, size: size)
                    continue
                }
                // 沿线插值：步长取半径的一半，相邻两个圆至少重叠 50%，
                // 中间不会出现断层。
                let step = max(0.75, pixelRadius * 0.5)
                for index in 0 ..< (pixels.count - 1) {
                    let a = pixels[index]
                    let b = pixels[index + 1]
                    let dx = b.x - a.x
                    let dy = b.y - a.y
                    let length = (dx * dx + dy * dy).squareRoot()
                    let count = max(1, Int((length / step).rounded(.up)))
                    for i in 0 ... count {
                        let t = Double(i) / Double(count)
                        stamp(into: dst, at: (x: a.x + dx * t, y: a.y + dy * t),
                              radius: pixelRadius, hardness: hardness, size: size)
                    }
                }
            }
        }
        return MaskBuffer(size: size, data: Data(bytes))
    }

    // MARK: - 单个笔刷印记

    private static func stamp(into dst: UnsafeMutableBufferPointer<UInt8>,
                              at center: (x: Double, y: Double),
                              radius: Double,
                              hardness: Double,
                              size: PixelSize) {
        let inner = radius * hardness
        let x0 = max(0, Int((center.x - radius).rounded(.down)))
        let x1 = min(size.width - 1, Int((center.x + radius).rounded(.up)))
        let y0 = max(0, Int((center.y - radius).rounded(.down)))
        let y1 = min(size.height - 1, Int((center.y + radius).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }

        // hardness = 1 时 inner == radius，衰减分母为 0；硬边单独走一条。
        let isHard = hardness >= 0.999

        for y in y0 ... y1 {
            let row = y * size.width
            for x in x0 ... x1 {
                let dx = Double(x) + 0.5 - center.x
                let dy = Double(y) + 0.5 - center.y
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance < radius else { continue }

                let coverage: Double
                if isHard || distance <= inner {
                    coverage = 1
                } else {
                    coverage = (radius - distance) / (radius - inner)
                }
                let value = UInt8(min(255, max(0, (coverage * 255).rounded())))
                let index = row + x
                if value > dst[index] {
                    dst[index] = value
                }
            }
        }
    }
}
