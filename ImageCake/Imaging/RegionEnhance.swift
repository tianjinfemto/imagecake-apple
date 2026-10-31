import CoreGraphics
import Foundation

// 五官区域美化：亮眼、牙齿美白、唇色、腮红，外加两个专项目（祛黑眼圈、
// 祛法令纹）。
//
// 与 BeautyEngine 的分工：那边靠**色域**找皮肤，处理"成片"的问题；这一层
// 靠**关键点**找器官，处理"局部"的问题。器官位置只有网络给得准，色域给不出
// "这是眼白"——所以整段是"有关键点才生效"的设计：没有就整段跳过并点名
// `[no_landmarks]`，绝不拿"眼睛大概是脸在上三分之一"这种猜出来的框去提亮。
//
// 四个上色算子都在 BeautyEngine 的「L + A + B」对立色空间里改（复用
// `BeautyEngine.opponent` / `fromOpponent`，往返恒等已由断言钉住）：
//   · 亮眼：虹膜椭圆内，提亮 + 加一点围绕中灰的对比；瞳孔核心（太暗）不抬，
//     否则眼睛会变"雾蒙蒙的灰瞳"。
//   · 牙齿：唇内多边形 ∧「够亮 ∧ 不太饱和」的像素。牙齿黄 = B 轴偏低（偏黄），
//     所以去黄就是把负的 B 往 0 收，再顺带提一点亮度。
//   · 唇色：唇环（外唇 − 内唇）内提饱和、给一点红底、轻微压亮——饱和度
//     拉满而不改形状，比"画一层红色"更接近真实的唇色加深。
//   · 腮红：两颊椭圆内加红、轻微去黄、轻微压亮。力度上限压得很低，
//     因为这一项最容易做脏。
//
// 两个专项目与上面四个不同：它们不是"上色"而是"去掉一种不该存在的亮度差"，
// 所以都要跟一个局部参考值比：
//   · 祛黑眼圈 = 下睑区里比**局部亮度均值**暗出来的那一段 → 只抬亮、绝不压暗。
//     参考值取"半径 = 0.35 脸宽"的亮度模糊：比一条黑眼圈宽，又比整张脸的
//     明暗过渡窄，所以量到的是周围皮肤而不是半张脸。亮度低于 0.15 的像素
//     （睫毛/瞳孔边缘）不抬，不然眼下会出现一圈白边。
//   · 祛法令纹 = 比**低频邻域**暗得多的细线 → 向低频填。频率门限（差的绝对值
//     超过阈值才动，且只动偏暗的一侧）让它只处理纹路本身；脸型自己的阴影是
//     低频，落在参考值里，不会被填掉——不然脸会扁一块。
//
// 多人脸：入参是一组语义量。全图只算一次的（亮度模糊、低频场）先算好，
// 逐张脸只栅格化自己的小椭圆/小带并往同一张掩码上**取大**（不是相加，
// 两张脸重叠处不会翻倍）。合影里每张脸都被处理，而这不是"跑了 N 遍全图"。

enum RegionEnhance {
    // MARK: - 入口

    /// 单张脸的入口（断言与只关心一张脸的调用侧用）。
    static func apply(_ image: DisplayImage, geometry: FaceGeometry?, beauty: BeautyParameters) -> DisplayImage {
        apply(image, geometries: geometry.map { [$0] } ?? [], beauty: beauty)
    }

    static func apply(_ image: DisplayImage, geometries: [FaceGeometry], beauty: BeautyParameters) -> DisplayImage {
        guard !beauty.isRegionNeutral, !geometries.isEmpty, image.size.pixelCount > 0 else { return image }
        let size = image.size
        var pixels = image.pixels

        if beauty.eyeBright > 0 {
            let weight = unionWeight(size: size, geometries) { eyeWeights($0, size: size) }
            modify(&pixels, size: size, weight: weight, amount: BeautyParameters.unit(beauty.eyeBright)) {
                (l, a, b) in
                // 瞳孔不抬：L 低于 0.12 的像素（黑瞳核心）原样保留。
                guard l > 0.12 else { return (l, a, b) }
                let lift = 0.35 * (1 - l) + 0.20 * (l - 0.5)
                return (l + lift, a * 1.05, b)
            }
        }
        if beauty.teethWhiten > 0 {
            let weight = unionWeight(size: size, geometries) { teethWeights($0, size: size, pixels: pixels) }
            modify(&pixels, size: size, weight: weight, amount: BeautyParameters.unit(beauty.teethWhiten)) {
                (l, a, b) in
                let deyellow = Swift.max(0, -b) * 0.85 + 0.03
                return (l + 0.30 * (1 - l), a * 0.9, b + deyellow)
            }
        }
        if beauty.lipColor > 0 {
            let weight = unionWeight(size: size, geometries) { lipWeights($0, size: size) }
            modify(&pixels, size: size, weight: weight, amount: BeautyParameters.unit(beauty.lipColor)) {
                (l, a, b) in
                // 提饱和 + 给一点红底（A 轴正向）。灰唇也能上到色，因为 0.05
                // 是加数而不是乘数。
                return (l - 0.05, a * 1.45 + 0.05, b * 1.2)
            }
        }
        if beauty.blush > 0 {
            let weight = unionWeight(size: size, geometries) { cheekWeights($0, size: size) }
            modify(&pixels, size: size, weight: weight, amount: BeautyParameters.unit(beauty.blush)) {
                (l, a, b) in
                (l - 0.03, a + 0.16, b - 0.04)
            }
        }
        if beauty.darkCircle > 0 {
            darkCirclePass(&pixels, size: size, geometries: geometries,
                           amount: BeautyParameters.unit(beauty.darkCircle))
        }
        if beauty.nasolabial > 0 {
            nasolabialPass(&pixels, size: size, geometries: geometries,
                           amount: BeautyParameters.unit(beauty.nasolabial))
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    // MARK: - 区域权重

    /// 亮眼权重：两个虹膜椭圆（半径 = 虹膜半径 ×2.6），smoothstep 落边。
    static func eyeWeights(_ geometry: FaceGeometry, size: PixelSize) -> [Float] {
        guard geometry.irisRadius > 0 else { return [Float](repeating: 0, count: size.pixelCount) }
        var out = [UInt8](repeating: 0, count: size.pixelCount)
        let scale = 2.6
        for center in geometry.irisCenters {
            let px = CGPoint(x: center.x * CGFloat(size.width), y: center.y * CGFloat(size.height))
            let rx = geometry.irisRadius * scale * Double(size.width)
            let ry = geometry.irisRadius * scale * Double(size.height)
            union(into: &out, disk: RegionRaster.disk(center: px, radiusX: rx, radiusY: ry, size: size))
        }
        return SkinMask.weights(MaskBuffer(size: size, data: Data(out)), size: size)
    }

    /// 腮红权重：两颊圆心、半径 = 0.55 × 颊部作用半径。
    static func cheekWeights(_ geometry: FaceGeometry, size: PixelSize) -> [Float] {
        guard geometry.cheekRadius > 0 else { return [Float](repeating: 0, count: size.pixelCount) }
        var out = [UInt8](repeating: 0, count: size.pixelCount)
        let scale = 0.55
        for center in geometry.cheekCenters {
            let px = CGPoint(x: center.x * CGFloat(size.width), y: center.y * CGFloat(size.height))
            let rx = geometry.cheekRadius * scale * Double(size.width)
            let ry = geometry.cheekRadius * scale * Double(size.height)
            union(into: &out, disk: RegionRaster.disk(center: px, radiusX: rx, radiusY: ry, size: size))
        }
        return SkinMask.weights(MaskBuffer(size: size, data: Data(out)), size: size)
    }

    /// 牙齿权重：唇内多边形 ∧「像牙齿吗」的门。多张唇不会互相干扰，所以
    /// 门是逐像素算的（唇内侧那条线虽然落在多边形里，但它的饱和度会被挡掉）。
    static func teethWeights(_ geometry: FaceGeometry, size: PixelSize, pixels: [Float]) -> [Float] {
        let region = RegionRaster.polygon(geometry.lipsInner, size: size,
                                          feather: Swift.max(1, size.longEdge / 300))
        var weight = SkinMask.weights(region, size: size)
        for i in 0 ..< size.pixelCount {
            guard weight[i] > 0 else { continue }
            let o = i * 4
            let opp = BeautyEngine.opponent(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
            let sat = (opp.a * opp.a + opp.b * opp.b).squareRoot()
            let gate = Swift.min(1, Swift.max(0, (opp.l - 0.30) / 0.20)) * Swift.min(1, Swift.max(0, (0.42 - sat) / 0.18))
            weight[i] *= Float(gate)
        }
        return weight
    }

    /// 唇色权重：外唇多边形 − 内唇多边形（唇环）。
    static func lipWeights(_ geometry: FaceGeometry, size: PixelSize) -> [Float] {
        let outer = RegionRaster.polygon(geometry.lipsOuter, size: size,
                                         feather: Swift.max(1, size.longEdge / 320))
        let inner = RegionRaster.polygon(geometry.lipsInner, size: size,
                                         feather: Swift.max(1, size.longEdge / 320))
        return SkinMask.weights(RegionRaster.subtract(outer, inner), size: size)
    }

    /// 下睑权重：两张下睑椭圆（`FaceGeometry` 里由虹膜 + 半眼宽派生）。
    /// 单独暴露给断言：黑眼圈的"位置对不对"应该能在不跑算子的情况下被钉住。
    static func underEyeWeights(_ geometry: FaceGeometry, size: PixelSize) -> [Float] {
        var out = [UInt8](repeating: 0, count: size.pixelCount)
        for region in geometry.underEyes {
            guard region.radiusX > 0, region.radiusY > 0 else { continue }
            let px = CGPoint(x: region.center.x * CGFloat(size.width),
                             y: region.center.y * CGFloat(size.height))
            union(into: &out, disk: RegionRaster.disk(center: px,
                                                      radiusX: region.radiusX * Double(size.width),
                                                      radiusY: region.radiusY * Double(size.height),
                                                      size: size))
        }
        return SkinMask.weights(MaskBuffer(size: size, data: Data(out)), size: size)
    }

    /// 法令纹带权重：两条旋转椭圆带（鼻翼 → 嘴角，略向外弧）。
    static func nasolabialWeights(_ geometry: FaceGeometry, size: PixelSize) -> [Float] {
        var out = [UInt8](repeating: 0, count: size.pixelCount)
        for band in geometry.nasolabialBands {
            guard band.radiusX > 0, band.radiusY > 0 else { continue }
            let px = CGPoint(x: band.center.x * CGFloat(size.width),
                             y: band.center.y * CGFloat(size.height))
            union(into: &out, disk: RegionRaster.disk(center: px,
                                                      radiusX: band.radiusX * Double(size.width),
                                                      radiusY: band.radiusY * Double(size.height),
                                                      angle: band.angle, size: size))
        }
        return SkinMask.weights(MaskBuffer(size: size, data: Data(out)), size: size)
    }

    // MARK: - 专项目 1：祛黑眼圈

    /// 下睑内"比局部亮度均值暗出来的那一段"抬回去。
    ///
    /// 只抬不压是硬约束：这个算子的失败模式是"把眼下压出一块灰"，而灰
    /// 比暗的黑眼圈难看得多。抬量还乘了一个 `deficit/0.22` 的软过渡，
    /// 所以本来就不暗的像素几乎不动（不会把颧骨高光顶出去）。
    static func darkCirclePass(_ pixels: inout [Float], size: PixelSize,
                               geometries: [FaceGeometry], amount: Double) {
        guard amount > 0, size.pixelCount > 0 else { return }
        let weight = unionWeight(size: size, geometries) { underEyeWeights($0, size: size) }
        guard weight.count == size.pixelCount else { return }
        var maxWeight = Float(0)
        for value in weight { maxWeight = Swift.max(maxWeight, value) }
        guard maxWeight > 0 else { return }

        let luma = lumaChannel(pixels, size: size)
        // 参考半径 = 0.35 × 脸宽（像素）。为什么用脸宽而不是长边的固定比例：
        // 近景人像里脸占满画幅、远景里只占十分之一，同一个比例在后一种情况
        // 下比黑眼圈还窄，量到的参考值就是黑眼圈本身（症状：推满滑杆没反应）。
        let faceWidth = geometries.compactMap { $0.faceWidth > 0 ? $0.faceWidth : nil }.min() ?? 0.2
        let radius = Swift.max(6, Int(faceWidth * 0.35 * Double(size.width)))
        let reference = BeautyEngine.blurredChannel(luma, size: size, radius: radius)

        for i in 0 ..< size.pixelCount {
            let w = Double(weight[i]) * amount
            guard w > 0.001 else { continue }
            let o = i * 4
            let l = Double(ColorMath.luma(pixels[o], pixels[o + 1], pixels[o + 2]))
            guard l > 0.15 else { continue }
            let deficit = Double(reference[i]) - l
            guard deficit > 0.012 else { continue }
            let soft = Swift.min(1.0, deficit / 0.22)
            let lift = deficit * 0.75 * w * soft
            for c in 0 ..< 3 {
                pixels[o + c] = Float(Swift.min(1, Double(pixels[o + c]) + lift))
            }
        }
    }

    // MARK: - 专项目 2：祛法令纹

    /// 把"比低频邻域暗得多的细线"向低频填（同方向不填亮线——眼袋的亮边、
    /// 鼻翼的高光都不该被拉下来）。
    ///
    /// 半径刻意给得**小**（长边的 1.2%，在 2048 档只有 2–3 像素）：这条算子
    /// 只允许填掉宽度在一两个像素到几个像素之间的暗线。半径一大，低频场就
    /// 把脸型本身的明暗也抹平了，症状是"法令纹淡了但脸也扁了"。
    static func nasolabialPass(_ pixels: inout [Float], size: PixelSize,
                               geometries: [FaceGeometry], amount: Double) {
        guard amount > 0, size.pixelCount > 0 else { return }
        let weight = unionWeight(size: size, geometries) { nasolabialWeights($0, size: size) }
        guard weight.count == size.pixelCount else { return }
        var maxWeight = Float(0)
        for value in weight { maxWeight = Swift.max(maxWeight, value) }
        guard maxWeight > 0 else { return }

        let low = ImageDocument.blurred(pixels, size: size,
                                        radius: Swift.max(2, Int(Double(size.longEdge) * 0.012)))
        let threshold = 0.035 - 0.015 * amount
        for i in 0 ..< size.pixelCount {
            let w = Double(weight[i]) * amount
            guard w > 0.001 else { continue }
            let o = i * 4
            let l = Double(ColorMath.luma(pixels[o], pixels[o + 1], pixels[o + 2]))
            let refL = Double(ColorMath.luma(low[o], low[o + 1], low[o + 2]))
            let deficit = refL - l
            guard deficit > threshold else { continue }
            let fill = Swift.min(1, (deficit - threshold) / (threshold * 4)) * w
            for c in 0 ..< 3 {
                let source = Double(pixels[o + c])
                pixels[o + c] = Float(source + (Double(low[o + c]) - source) * fill)
            }
        }
    }

    // MARK: - 小工具

    /// 逐张脸算权重再取大（两脸重叠处不翻倍）。
    static func unionWeight(size: PixelSize, _ geometries: [FaceGeometry],
                            _ body: (FaceGeometry) -> [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: size.pixelCount)
        for geometry in geometries {
            let weight = body(geometry)
            guard weight.count == out.count else { continue }
            for i in 0 ..< out.count where weight[i] > out[i] { out[i] = weight[i] }
        }
        return out
    }

    /// 把一个圆盘按位取大并进字节掩码。
    private static func union(into bytes: inout [UInt8], disk: MaskBuffer) {
        guard !disk.isEmpty, bytes.count == disk.data.count else { return }
        let incoming = [UInt8](disk.data)
        for i in 0 ..< bytes.count where incoming[i] > bytes[i] { bytes[i] = incoming[i] }
    }

    /// 亮度通道（显示码）。黑眼圈的参考值只需要一个标量场，没必要连着
    /// 三个通道一起模糊（代价是 1/3）。
    static func lumaChannel(_ pixels: [Float], size: PixelSize) -> [Float] {
        guard size.pixelCount > 0, pixels.count >= size.pixelCount * 4 else { return [] }
        var out = [Float](repeating: 0, count: size.pixelCount)
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            out[i] = ColorMath.luma(pixels[o], pixels[o + 1], pixels[o + 2])
        }
        return out
    }

    // MARK: - 作用器

    /// 按权重在对立色空间里改像素：`edit` 给"满力度"的目标值，实际按
    /// amount×weight 线性混合。这样上色类算子只写"做成什么样"，
    /// 混合、夹取、越界保护都只有一份。
    static func modify(_ pixels: inout [Float], size: PixelSize, weight: [Float],
                       amount: Double, edit: (Double, Double, Double) -> (Double, Double, Double)) {
        let count = size.pixelCount
        guard count > 0, amount != 0, weight.count == count, pixels.count == count * 4 else { return }
        for i in 0 ..< count {
            let k = amount * Double(weight[i])
            guard k != 0 else { continue }
            let o = i * 4
            let source = BeautyEngine.opponent(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
            let target = edit(source.l, source.a, source.b)
            let rgb = BeautyEngine.fromOpponent(l: source.l + (target.0 - source.l) * k,
                                                a: source.a + (target.1 - source.a) * k,
                                                b: source.b + (target.2 - source.b) * k)
            pixels[o] = Float(Swift.min(Swift.max(rgb.r, 0), 1))
            pixels[o + 1] = Float(Swift.min(Swift.max(rgb.g, 0), 1))
            pixels[o + 2] = Float(Swift.min(Swift.max(rgb.b, 0), 1))
        }
    }
}
