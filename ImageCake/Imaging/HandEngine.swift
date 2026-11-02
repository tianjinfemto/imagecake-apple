import CoreGraphics
import Foundation

// 手部美化。
//
// 手为什么不需要额外权重就能定区域：AVFoundation/Vision 在双端都自带
// 21 点手部姿态（`VNDetectHumanHandPoseRequest`，iOS 14+/macOS 11+），
// 拿它取到的关节点做**凸包**就是手的地盘。零下载、离线、硬件加速——与
// 人像分割走 Vision 兜底是同一条路子。
//
// 为什么用凸包而不是把关节连成骨架再撑粗：手的形状差异极大（握拳、张掌、
// 侧放、只露三根手指），任何"按骨架撑一条固定宽度"的做法都会在某些姿态上
// 漏掉指缝或多框到手腕外的袖子。凸包是唯一"无论手怎么摆都包住"的形状，
// 代价是把手掌周围的一小圈背景也圈进来——所以三层力度都很温和，而且
// 磨皮/匀肤色都只在皮肤色域内叠加（见 `HandMask`）。
//
// 三个动作各治一种手的毛病：
//   · smooth：关节褶皱与干皮（频率分离，纹理留下）；
//   · evenTone：手背与指缝的明暗差（亮度往局部均值收敛）；
//   · redness：手经常比脸红（只收回偏红的一半，不整体偏绿）。
// 皮肤色域 + 凸包两个条件都成立才动，所以指甲（亮/有色但非肤色）与
// 手里的东西不会被一起磨。

enum HandHull {
    /// 归一化点集的凸包（Andrew 单调链）。少于 3 个点 → 空。
    ///
    /// 为什么自己写而不拿 Vision 的多边形：Vision 给的是**散点**，没有轮廓；
    /// 而凸包必须是确定性的（同一组点永远得到同一个多边形），否则同一张图
    /// 两次导出会不一样——那是这一整个项目最不能被破坏的性质。
    static func polygon(_ points: [CGPoint]) -> [CGPoint] {
        let unique = Dictionary(grouping: points) { "\($0.x),\($0.y)" }.values.compactMap { $0.first }
        guard unique.count >= 3 else { return [] }
        let sorted = unique.sorted { lhs, rhs in
            lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x
        }
        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        let hull = lower + upper
        return hull.count >= 3 ? hull : []
    }

    /// 凸包面积（归一化）。退化姿态（点几乎共线）时接近 0，调用侧据此丢弃。
    static func area(_ hull: [CGPoint]) -> Double {
        guard hull.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0 ..< hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    /// 外接框（归一化）。给"手部检测到了什么"这种 UI 文案用。
    static func bounds(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 用凸包外接框的短边做"手的大小"的代理量（归一化）。
    static func shortEdge(_ points: [CGPoint]) -> Double {
        guard let box = bounds(points) else { return 0 }
        return Swift.min(Double(box.width), Double(box.height))
    }

    private static func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        Double((a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x))
    }
}

enum HandMask {
    /// 手区权重 = 凸包（羽化）∧ 皮肤色域。
    ///
    /// 与皮肤掩码共用 `SkinMask.isSkin` 这一道判定，不另开第二条口径；
    /// 相与的作用是指甲、手里的物件、袖口都不会被顺手磨平。
    static func build(size: PixelSize, hulls: [[CGPoint]], pixels: [Float]) -> [Float] {
        guard size.pixelCount > 0, !hulls.isEmpty else { return [] }
        var bytes = [UInt8](repeating: 0, count: size.pixelCount)
        for hull in hulls {
            let ring = HandHull.polygon(hull)
            guard ring.count >= 3, HandHull.area(ring) > 1e-6 else { continue }
            // 外扩量用**比例**而不是固定像素：inflated 是绕质心把每个顶点推远
            // 6%，自然跟随手的大小缩放（远景的手不会被扩到袖子，近景不会漏指缘）。
            let grown = inflate(ring, by: 0.06)
            let mask = RegionRaster.polygon(grown, size: size, feather: Swift.max(2, size.longEdge / 260))
            guard !mask.isEmpty, mask.data.count == bytes.count else { continue }
            let incoming = [UInt8](mask.data)
            for i in 0 ..< bytes.count where incoming[i] > bytes[i] { bytes[i] = incoming[i] }
        }
        let base = SkinMask.weights(MaskBuffer(size: size, data: Data(bytes)), size: size)
        var out = [Float](repeating: 0, count: size.pixelCount)
        for i in 0 ..< size.pixelCount {
            guard base[i] > 0 else { continue }
            let o = i * 4
            if SkinMask.isSkin(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2])) {
                out[i] = base[i]
            }
        }
        return out
    }

    /// 外扩：绕质心按比例放大。比例而不是绝对像素——外扩量必须随手大小缩放，
    /// 否则远景的小手套不住、近景的大手糊到袖口。
    private static func inflate(_ ring: [CGPoint], by ratio: Double) -> [CGPoint] {
        guard ring.count >= 3 else { return ring }
        let cx = ring.reduce(0) { $0 + Double($1.x) } / Double(ring.count)
        let cy = ring.reduce(0) { $0 + Double($1.y) } / Double(ring.count)
        return ring.map {
            CGPoint(x: cx + (Double($0.x) - cx) * (1 + ratio),
                    y: cy + (Double($0.y) - cy) * (1 + ratio))
        }
    }
}

enum HandEngine {
    static func apply(_ image: DisplayImage, weights: [Float], hands: HandParameters) -> DisplayImage {
        let size = image.size
        guard size.pixelCount > 0, !hands.isNeutral, weights.count == size.pixelCount,
              image.pixels.count >= size.pixelCount * 4 else { return image }
        var maxWeight = Float(0)
        for value in weights { maxWeight = Swift.max(maxWeight, value) }
        guard maxWeight > 0 else { return image }
        var pixels = image.pixels

        if hands.smooth > 0 {
            // 与磨皮同一套频率分离：只平滑低频、纹理按力度留下。手背的细纹
            // 不该被抹平，那正是"看起来像塑料手"的原因。
            BeautyEngine.smoothPass(&pixels,
                                    base: ImageDocument.blurred(pixels, size: size,
                                                                radius: Swift.max(2, size.longEdge / 220)),
                                    size: size, face: weights, body: [Float](repeating: 0, count: size.pixelCount),
                                    faceAmount: BeautyParameters.unit(hands.smooth),
                                    bodyAmount: 0, volume: true)
        }
        if hands.evenTone > 0 || hands.redness > 0 {
            evenToneAndRedness(&pixels, size: size, weights: weights, hands: hands)
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 匀亮度 + 祛红：都在对立色空间里，参考值是"手部自己的局部均值"
    /// （不是全图，也不是脸——手的肤色本来就和脸不同，拿脸当基准会把手洗白）。
    static func evenToneAndRedness(_ pixels: inout [Float], size: PixelSize,
                                   weights: [Float], hands: HandParameters) {
        let count = size.pixelCount
        guard count > 0, weights.count == count else { return }
        var luma = [Float](repeating: 0, count: count)
        var chromaA = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let o = i * 4
            let opp = BeautyEngine.opponent(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
            luma[i] = Float(opp.l)
            chromaA[i] = Float(opp.a)
        }
        let radius = Swift.max(4, Int(Double(size.longEdge) * 0.03))
        let meanL = BeautyEngine.blurredChannel(luma, size: size, radius: radius)
        let meanA = BeautyEngine.blurredChannel(chromaA, size: size, radius: radius)
        let even = BeautyParameters.unit(hands.evenTone)
        let red = BeautyParameters.unit(hands.redness)

        for i in 0 ..< count {
            let weight = Swift.min(1, Double(weights[i]))
            guard weight > 0.001 else { continue }
            let l = Double(luma[i])
            var newL = l
            if even > 0 {
                // 把"比局部均值暗/亮出来的那段"往均值收：只收 85%，
                // 全收到 1 会变成一张没有结构的手背。
                newL = l + (Double(meanL[i]) - l) * even * weight * 0.85
            }
            let a = Double(chromaA[i])
            var newA = a
            if red > 0, a > Double(meanA[i]) {
                newA = a - (a - Double(meanA[i])) * red * weight * 0.8
            }
            guard newL != l || newA != a else { continue }
            let o = i * 4
            let source = BeautyEngine.opponent(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
            let rgb = BeautyEngine.fromOpponent(l: newL, a: newA, b: source.b)
            pixels[o] = Float(Swift.min(Swift.max(rgb.r, 0), 1))
            pixels[o + 1] = Float(Swift.min(Swift.max(rgb.g, 0), 1))
            pixels[o + 2] = Float(Swift.min(Swift.max(rgb.b, 0), 1))
        }
    }
}
