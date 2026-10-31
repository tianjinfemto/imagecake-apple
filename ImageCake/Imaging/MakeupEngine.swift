import CoreGraphics
import Foundation

// 妆容模板：唇色 + 眼影 + 眼线 + 填眉（+ 腮红）四到五层的**组合预设**。
//
// 为什么这不是"把 RegionEnhance 的四个滑杆起个名字"：像素蛋糕的妆容是一层
// 一层叠上去的（唇有轮廓、眼有晕染、眉有形状），而滑杆只能改"整个脸上的某个
// 连续量"。所以这一层的实质是**区域 + 颜色 + 浓淡的组合**：区域仍然全部由
// 478 点派生（唇环、上睑弧、眼线带、眉线带），颜色是每个模板自带的一组常量。
//
// 仍然是确定性的：没有生成式权重、没有 GAN，因此可以逐比特断言。它与真实
// 商用的差别写在 docs/pixcake-parity.md 里——商用产品的"换脸级"妆容要五官
// 分割权重来分离眼皮/眼皮褶皱/眼球，我们只用关键点几何，所以：
//   · 眼影的边缘只能靠羽化近似，不会精确停在眼窝线上；
//   · 半闭眼/侧脸时上睑弧会退化，那一层就**整层不跑**（不猜）。
// 这两条是能力边界，不是缺陷：缺依据就少画一层，而不是画错地方。
//
// 混合模型（`layDown`）：在对立色空间里把像素往"颜料色"靠拢，但亮度只按
// `lumaKeep` 比例靠——这是"上粉"和"贴色块"的差别：亮度里的结构（唇纹、
// 眉骨阴影、眼睑的明暗）必须留下，否则妆会变成一个扁平的贴纸。

// MARK: - 模板

struct MakeupLook: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    /// 唇：轮廓 + 填充。
    var lipHex: UInt32
    var lipOpacity: Double
    /// 眼影（上睑晕染）。
    var shadowHex: UInt32
    var shadowOpacity: Double
    /// 眼线（贴着上睑缘的一条窄带）。
    var linerHex: UInt32
    var linerOpacity: Double
    /// 填眉（沿眉线一条带）。0 = 不画眉。
    var browHex: UInt32
    var browOpacity: Double
    /// 腮红。0 = 不上腮红。
    var blushHex: UInt32
    var blushOpacity: Double

    /// 亮度保留量：唇要留住唇纹、眉骨要留住阴影结构，所以都不是 1。
    var lipLumaKeep: Double { 0.72 }
    var shadowLumaKeep: Double { 0.55 }
    var linerLumaKeep: Double { 0.45 }
    var browLumaKeep: Double { 0.5 }
    var blushLumaKeep: Double { 0.6 }
}

enum MakeupEngine {
    /// 内置模板。都是"能出门"的浓淡，不是试色卡——满强度也只是把色叠上去，
    /// 因为 opacity 本身就压在 0.4…0.85 之间。
    static let looks: [MakeupLook] = [
        MakeupLook(id: "nude", title: "裸妆",
                   lipHex: 0xB96A5E, lipOpacity: 0.42,
                   shadowHex: 0xC9A183, shadowOpacity: 0.30,
                   linerHex: 0x4A3A34, linerOpacity: 0.34,
                   browHex: 0x6B5142, browOpacity: 0.34,
                   blushHex: 0xD18C74, blushOpacity: 0.24),
        MakeupLook(id: "red-lip", title: "红唇",
                   lipHex: 0xA61E2F, lipOpacity: 0.82,
                   shadowHex: 0xB98F79, shadowOpacity: 0.26,
                   linerHex: 0x2B1F1C, linerOpacity: 0.42,
                   browHex: 0x5C4436, browOpacity: 0.36,
                   blushHex: 0xC96C5C, blushOpacity: 0.18),
        MakeupLook(id: "smokey", title: "烟熏",
                   lipHex: 0x9A5A57, lipOpacity: 0.44,
                   shadowHex: 0x4C4248, shadowOpacity: 0.62,
                   linerHex: 0x1B1618, linerOpacity: 0.70,
                   browHex: 0x4A3B33, browOpacity: 0.42,
                   blushHex: 0xA57068, blushOpacity: 0.12),
        MakeupLook(id: "korean", title: "韩系水光",
                   lipHex: 0xD44A5A, lipOpacity: 0.55,
                   shadowHex: 0xE0A9A0, shadowOpacity: 0.34,
                   linerHex: 0x54403C, linerOpacity: 0.28,
                   browHex: 0x7A5F4C, browOpacity: 0.30,
                   blushHex: 0xE88C86, blushOpacity: 0.36),
        MakeupLook(id: "brow-only", title: "只妆眉眼",
                   lipHex: 0xB96A5E, lipOpacity: 0.0,
                   shadowHex: 0xBFA08C, shadowOpacity: 0.30,
                   linerHex: 0x3A2C28, linerOpacity: 0.45,
                   browHex: 0x63483A, browOpacity: 0.55,
                   blushHex: 0xD18C74, blushOpacity: 0.0),
    ]

    static func look(id: String) -> MakeupLook? {
        looks.first { $0.id == id }
    }

    // MARK: - 应用

    /// 逐张脸叠妆。没关键点、或模板不认识 → 整段不跑（调用侧点名）。
    static func apply(_ image: DisplayImage, geometries: [FaceGeometry],
                      makeup: MakeupParameters) -> DisplayImage {
        guard !makeup.isNeutral, !geometries.isEmpty, image.size.pixelCount > 0,
              let look = look(id: makeup.styleID) else { return image }
        let size = image.size
        let unit = BeautyParameters.unit(makeup.strength)
        guard unit > 0 else { return image }
        var pixels = image.pixels

        // 顺序固定：眼影 → 眼线 → 眉 → 唇 → 腮红。
        // 眼线压眼影（不然边界发糊），唇在底妆之后（唇色不该被腮红盖住）。
        if look.shadowOpacity > 0 {
            layDown(&pixels, size: size,
                    weight: unionWeight(size: size, geometries, shadowWeights),
                    hex: look.shadowHex, opacity: look.shadowOpacity * unit,
                    lumaKeep: look.shadowLumaKeep)
        }
        if look.linerOpacity > 0 {
            layDown(&pixels, size: size,
                    weight: unionWeight(size: size, geometries, linerWeights),
                    hex: look.linerHex, opacity: look.linerOpacity * unit,
                    lumaKeep: look.linerLumaKeep)
        }
        if look.browOpacity > 0 {
            layDown(&pixels, size: size,
                    weight: unionWeight(size: size, geometries, browWeights),
                    hex: look.browHex, opacity: look.browOpacity * unit,
                    lumaKeep: look.browLumaKeep)
        }
        if look.lipOpacity > 0 {
            layDown(&pixels, size: size,
                    weight: unionWeight(size: size, geometries, RegionEnhance.lipWeights),
                    hex: look.lipHex, opacity: look.lipOpacity * unit,
                    lumaKeep: look.lipLumaKeep)
        }
        if look.blushOpacity > 0 {
            layDown(&pixels, size: size,
                    weight: unionWeight(size: size, geometries, RegionEnhance.cheekWeights),
                    hex: look.blushHex, opacity: look.blushOpacity * unit,
                    lumaKeep: look.blushLumaKeep)
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    // MARK: - 各层的权重图

    /// 眼影：上睑弧向上让开半个眼高的一条宽带（晕染区）。
    static func shadowWeights(_ geometry: FaceGeometry, size: PixelSize) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: size.pixelCount)
        for band in shadowBands(geometry, size: size) {
            union(into: &bytes, mask: RegionRaster.polygon(band, size: size,
                                                           feather: Swift.max(2, size.longEdge / 180)))
        }
        return SkinMask.weights(MaskBuffer(size: size, data: Data(bytes)), size: size)
    }

    /// 眼线：贴着上睑缘的一条窄带。
    static func linerWeights(_ geometry: FaceGeometry, size: PixelSize) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: size.pixelCount)
        for band in linerBands(geometry, size: size) {
            union(into: &bytes, mask: RegionRaster.polygon(band, size: size,
                                                           feather: Swift.max(1, size.longEdge / 500)))
        }
        return SkinMask.weights(MaskBuffer(size: size, data: Data(bytes)), size: size)
    }

    /// 填眉：沿眉线的一条带（粗细由眉线自身的跨度决定，不写死像素）。
    static func browWeights(_ geometry: FaceGeometry, size: PixelSize) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: size.pixelCount)
        for band in browBands(geometry, size: size) {
            union(into: &bytes, mask: RegionRaster.polygon(band, size: size,
                                                           feather: Swift.max(1, size.longEdge / 400)))
        }
        return SkinMask.weights(MaskBuffer(size: size, data: Data(bytes)), size: size)
    }

    // MARK: - 区域几何（暴露给断言：位置对不对必须能单独测）

    /// 上睑弧 + 向上抬一段的晕染带。抬多少由**眼宽**决定，所以近景远景同参数。
    static func shadowBands(_ geometry: FaceGeometry, size: PixelSize) -> [[CGPoint]] {
        arcs(of: geometry).map { arc, span in
            let lifted = arc.map { CGPoint(x: $0.x, y: $0.y - span * 0.055) }
            return RegionRaster.band(lifted, halfWidth: span * 0.10, size: size)
        }
    }

    /// 眼线带：直接沿上睑缘，厚度约为眼宽的 2%。
    static func linerBands(_ geometry: FaceGeometry, size: PixelSize) -> [[CGPoint]] {
        arcs(of: geometry).map { arc, span in
            RegionRaster.band(arc, halfWidth: span * 0.020, size: size)
        }
    }

    /// 眉带：厚度取眉线自身纵向跨度的 0.45（眉弓高则带宽，平眉则带窄），
    /// 下限由眼宽兜住——合成/退化数据里纵向跨度可能为 0。
    static func browBands(_ geometry: FaceGeometry, size: PixelSize) -> [[CGPoint]] {
        guard geometry.browLines.count == 2, geometry.eyeRings.count == 2 else { return [] }
        let eyeSpan = eyeWidth(geometry, eye: 0)
        return geometry.browLines.compactMap { line in
            guard line.count >= 2, eyeSpan > 0 else { return nil }
            let ys = line.map { Double($0.y) }
            guard let low = ys.min(), let high = ys.max() else { return nil }
            let thickness = Swift.max(eyeSpan * 0.055, (high - low) * 0.45)
            return RegionRaster.band(line, halfWidth: thickness, size: size)
        }
    }

    /// 每只眼的上睑弧，连同"眼宽"（水平跨度）一起返回——所有厚度/抬量都按它算。
    private static func arcs(of geometry: FaceGeometry) -> [(arc: [CGPoint], span: Double)] {
        guard !geometry.irisCenters.isEmpty else { return [] }
        var out: [(arc: [CGPoint], span: Double)] = []
        for (index, ring) in geometry.eyeRings.enumerated() {
            let irisY = index < geometry.irisCenters.count ? Double(geometry.irisCenters[index].y) : 0
            let arc = RegionRaster.upperArc(ring, notAbove: irisY)
            let span = eyeWidth(geometry, eye: index)
            if arc.count >= 2, span > 0 {
                out.append((arc: arc, span: span))
            }
        }
        return out
    }

    /// 某只眼的眼宽（归一化，相对画面宽）。
    private static func eyeWidth(_ geometry: FaceGeometry, eye index: Int) -> Double {
        guard index < geometry.eyeRings.count else { return 0 }
        let xs = geometry.eyeRings[index].map { Double($0.x) }
        guard let low = xs.min(), let high = xs.max() else { return 0 }
        return high - low
    }

    // MARK: - 上粉

    /// 把像素往颜料色靠：色度按满 k 靠，亮度只按 `k × lumaKeep` 靠。
    ///
    /// `lumaKeep < 1` 是"留住结构"这件事的全部实现：亮度里存着唇纹、眉骨的
    /// 阴影和眼睑的明暗，一起混掉就成了贴纸。
    static func layDown(_ pixels: inout [Float], size: PixelSize, weight: [Float],
                        hex: UInt32, opacity: Double, lumaKeep: Double) {
        let count = size.pixelCount
        guard count > 0, opacity > 0, weight.count == count,
              pixels.count >= count * 4 else { return }
        let (r, g, b) = HexColor.rgb(hex)
        let pigment = BeautyEngine.opponent(r: r, g: g, b: b)
        for i in 0 ..< count {
            let k = opacity * Double(weight[i])
            guard k > 0.001 else { continue }
            let o = i * 4
            let source = BeautyEngine.opponent(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
            let l = source.l + (pigment.l - source.l) * k * lumaKeep
            let a = source.a + (pigment.a - source.a) * k
            let b2 = source.b + (pigment.b - source.b) * k
            let rgb = BeautyEngine.fromOpponent(l: l, a: a, b: b2)
            pixels[o] = Float(Swift.min(Swift.max(rgb.r, 0), 1))
            pixels[o + 1] = Float(Swift.min(Swift.max(rgb.g, 0), 1))
            pixels[o + 2] = Float(Swift.min(Swift.max(rgb.b, 0), 1))
        }
    }

    // MARK: - 小工具（与 RegionEnhance 同一口径：逐脸取大，不翻倍）

    private static func unionWeight(size: PixelSize, _ geometries: [FaceGeometry],
                                    _ body: (FaceGeometry, PixelSize) -> [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: size.pixelCount)
        for geometry in geometries {
            let weight = body(geometry, size)
            guard weight.count == out.count else { continue }
            for i in 0 ..< out.count where weight[i] > out[i] { out[i] = weight[i] }
        }
        return out
    }

    private static func union(into bytes: inout [UInt8], mask: MaskBuffer) {
        guard !mask.isEmpty, bytes.count == mask.data.count else { return }
        let incoming = [UInt8](mask.data)
        for i in 0 ..< bytes.count where incoming[i] > bytes[i] { bytes[i] = incoming[i] }
    }
}
