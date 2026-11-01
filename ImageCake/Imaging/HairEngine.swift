import CoreGraphics
import Foundation

// 头发美化。三件事：去毛躁、压/提光泽、发色饱和。
//
// 为什么这里没有分割权重也能做：发区的**位置**有一个不需要网络的判据组合——
//   1. 不在皮肤色域里（`SkinMask.isSkin`，同一套判定，不另开第二条口径）；
//   2. 在"头部框"里：以人脸外接框为基准向上放大 0.55 个脸高、左右各让开
//      0.35 个脸宽（发型比头宽是常态，不能只框到脸轮廓）；
//   3. 落在额头线以上，或者落在脸轮廓之外的侧区。
// 三条都成立才算头发。条件 3 是关键：少了它，头顶上方的那面灰墙会被当成头发
// 一起磨；只按色域判又会把背景里任何暗色当头发。
//
// 已知边界（写清楚，别当成 AI）：
//   · 穿黑衣的人，衣服会落进"头部框之外的侧区"吗？不会——框上沿在头顶，
//     但侧区只取脸轮廓左右 0.35 个脸宽的**带状**范围，衣领在更下方；
//     齐肩短发与衣领交界处仍会误判，这是色域方案的固有边界；
//   · 没有人脸框（没检测过关键点）时整段不跑，并点名 `[no_landmarks]`——
//     头发位置完全靠脸来定位，没有脸就只能猜。
//   · 真正的发丝级蒙版要分割权重（清单里有槽位），缺件时走上面这套色域几何
//     并点名 `[fallback:hair-colour-locus]`。

enum HairMask {
    /// 头部框（归一化）。脸宽/脸高由人脸外接框给；拿不到就是 nil。
    static func headBox(faceBounds: CGRect) -> CGRect? {
        guard faceBounds.width > 0.01, faceBounds.height > 0.01 else { return nil }
        let up = faceBounds.height * 0.55
        let side = faceBounds.width * 0.35
        let box = CGRect(x: faceBounds.minX - side,
                         y: faceBounds.minY - up,
                         width: faceBounds.width + side * 2,
                         height: faceBounds.height + up + faceBounds.height * 0.25)
        return box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 按上面三条口径生成发区权重图（0…1）。
    static func build(_ image: DisplayImage, faceBounds: CGRect,
                      personMask: MaskBuffer? = nil) -> [Float] {
        let size = image.size
        guard size.pixelCount > 0, image.pixels.count >= size.pixelCount * 4,
              let box = headBox(faceBounds: faceBounds) else {
            return [Float](repeating: 0, count: size.pixelCount)
        }
        let person: MaskBuffer? = personMask.flatMap { mask in
            let resized = mask.resized(to: size)
            return resized.isEmpty ? nil : resized
        }
        let personBytes = person.map { [UInt8]($0.data) }
        // 额头线：脸框顶部往下 18% 脸高。这条以上算"头顶以下、额头以上"的发区；
        // 这条以下只承认脸轮廓左右侧带里的头发（鬓角、垂发）。
        let browLine = box.minY + faceBounds.height * 0.18
        let ovalLeft = faceBounds.minX + faceBounds.width * 0.06
        let ovalRight = faceBounds.maxX - faceBounds.width * 0.06

        var hits = [UInt8](repeating: 0, count: size.pixelCount)
        image.pixels.withUnsafeBufferPointer { src in
            for y in 0 ..< size.height {
                let ny = Double(y) + 0.5
                let normalizedY = ny / Double(size.height)
                for x in 0 ..< size.width {
                    let nx = (Double(x) + 0.5) / Double(size.width)
                    guard nx >= box.minX, nx <= box.maxX,
                          normalizedY >= box.minY, normalizedY <= box.maxY else { continue }
                    let o = (y * size.width + x) * 4
                    // 条件 1：不是皮肤。
                    guard !SkinMask.isSkin(r: Double(src[o]), g: Double(src[o + 1]), b: Double(src[o + 2])) else { continue }
                    // 条件 3：额头线以上，或脸轮廓的左右侧带。
                    let inSideBand = (Double(x) < ovalLeft * Double(size.width))
                        || (Double(x) > ovalRight * Double(size.width))
                    guard normalizedY <= browLine || inSideBand else { continue }
                    // 有人像 α 时按 α 相与：背景里那面暗墙不是头发。
                    if let personBytes, personBytes[y * size.width + x] < 40 { continue }
                    hits[y * size.width + x] = 255
                }
            }
        }
        let mask = MaskOps.feathered(MaskBuffer(size: size, data: Data(hits)),
                                      radius: Swift.max(1, size.longEdge / 220))
        return SkinMask.weights(mask, size: size)
    }
}

enum HairEngine {
    /// 小振幅细节的**软阈值阻尼**（去毛躁）。
    ///
    /// 为什么不是直接磨：发丝的结构就是中高频，全压掉会得到一坨塑料。
    /// 只把"比阈值更小的抖动"（毛躁的碎边）压向 0，超过阈值的真实发丝
    /// 逐比特保留——所以力度拉满也不会把头发磨成一片。
    static func apply(_ image: DisplayImage, weights: [Float], hair: HairParameters) -> DisplayImage {
        let size = image.size
        guard size.pixelCount > 0, !hair.isNeutral, weights.count == size.pixelCount,
              image.pixels.count >= size.pixelCount * 4 else { return image }
        var pixels = image.pixels

        if hair.smooth > 0 {
            dampFrizz(&pixels, size: size, weights: weights,
                      amount: BeautyParameters.unit(hair.smooth))
        }
        if hair.shine != 0 {
            shapeShine(&pixels, size: size, weights: weights,
                       amount: BeautyParameters.unit(hair.shine))
        }
        if hair.tint > 0 {
            saturate(&pixels, size: size, weights: weights,
                     amount: BeautyParameters.unit(hair.tint))
        }
        // 换色在上、碎发收尾：碎发动的是亮度，先上色就不会因为后一步
        // 压亮度而看上去“颜色淡了一层”。
        if hair.colorStrength > 0 {
            recolor(&pixels, size: size, weights: weights,
                    amount: BeautyParameters.unit(hair.colorStrength), hex: hair.colorHex)
        }
        if hair.tame > 0 {
            tameFlyaways(&pixels, size: size, weights: weights,
                         amount: BeautyParameters.unit(hair.tame))
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    // MARK: 换发色

    /// 发区内把**色度**往目标色的 A/B 靠，亮度逐比特不动。
    ///
    /// 保亮度不是保守：发色的体积感全靠高光与阴影，连亮度一起换就成了一片
    /// 塑料发片。与换天那个光照匹配用的是同一段数学（对立色里只推 A/B）。
    /// `maxShift` 防止把深棕一路推到荧光蓝：0.22 大致是“深棕 → 酒红”的
    /// 色度距离，再大就不属于头发了。
    static func recolor(_ pixels: inout [Float], size: PixelSize, weights: [Float],
                        amount: Double, hex: UInt32) {
        guard amount > 0, size.pixelCount > 0, weights.count == size.pixelCount,
              pixels.count >= size.pixelCount * 4 else { return }
        let (r, g, b) = HexColor.rgb(hex)
        let target = BeautyEngine.opponent(r: r, g: g, b: b)
        let maxShift = 0.22
        for i in 0 ..< size.pixelCount {
            let w = Double(weights[i]) * amount
            guard w > 0.001 else { continue }
            let o = i * 4
            let source = BeautyEngine.opponent(r: Double(pixels[o]),
                                               g: Double(pixels[o + 1]),
                                               b: Double(pixels[o + 2]))
            let da = Swift.min(maxShift, Swift.max(-maxShift, target.a - source.a)) * w
            let db = Swift.min(maxShift, Swift.max(-maxShift, target.b - source.b)) * w
            let rgb = BeautyEngine.fromOpponent(l: source.l, a: source.a + da, b: source.b + db)
            pixels[o] = Float(Swift.min(Swift.max(rgb.r, 0), 1))
            pixels[o + 1] = Float(Swift.min(Swift.max(rgb.g, 0), 1))
            pixels[o + 2] = Float(Swift.min(Swift.max(rgb.b, 0), 1))
        }
    }

    // MARK: 祛碎发

    /// 只作用在发区掩码的**边界环带**上：碎发就是发团轮廓外那些细亮线，
    /// 既不该动发团内部（里面是真头发），也不该动背景。
    ///
    /// 环带用三角窗 `1 − |2w − 1| / 0.35` 而不是 `w(1−w)`：后者在 w = 0.9（发团
    /// 内部）仍有 0.36 的权重，症状是把整片头发的边缘啃进一圈。三角窗在
    /// w ≤ 0.325 与 w ≥ 0.675 处正好为 0，那两处逐比特不动，能当断言钉住。
    /// 方向仍只降不升：压往邻域低频亮度，不会把碎发顶成更亮的白丝。
    static func tameFlyaways(_ pixels: inout [Float], size: PixelSize, weights: [Float],
                             amount: Double) {
        guard amount > 0, size.pixelCount > 0, weights.count == size.pixelCount,
              pixels.count >= size.pixelCount * 4 else { return }
        let radius = Swift.max(2, Int(Double(size.longEdge) * 0.015))
        let luma = RegionEnhance.lumaChannel(pixels, size: size)
        guard luma.count == size.pixelCount else { return }
        let base = BeautyEngine.blurredChannel(luma, size: size, radius: radius)
        for i in 0 ..< size.pixelCount {
            let w = Double(weights[i])
            // 三角窗环带。
            let band = Swift.max(0.0, 1.0 - abs(2.0 * w - 1.0) / 0.35)
            let k = band * amount
            guard k > 0.001 else { continue }
            let o = i * 4
            let l = Double(luma[i])
            let refL = Double(base[i])
            let excess = l - refL
            guard excess > 0.05 else { continue }        // 只处理亮于邻域的碎丝
            let soft = Swift.min(1.0, (excess - 0.05) / 0.12)
            let drop = (excess - 0.05) * 0.75 * k * soft
            guard drop > 0 else { continue }
            for c in 0 ..< 3 {
                pixels[o + c] = Float(Swift.max(0, Double(pixels[o + c]) - drop))
            }
        }
    }

    // MARK: 去毛躁

    static func dampFrizz(_ pixels: inout [Float], size: PixelSize, weights: [Float], amount: Double) {
        guard amount > 0 else { return }
        // 低频参考：半径约为长边的 1.5%，比一根发丝的抖动宽、比一缕头发窄。
        let radius = Swift.max(2, Int(Double(size.longEdge) * 0.015))
        let base = ImageDocument.blurred(pixels, size: size, radius: radius)
        // 阈值（显示码）：0.02 ≈ 5 级灰阶。小于这个幅度的抖动就是毛躁。
        let threshold = 0.02
        for i in 0 ..< size.pixelCount {
            let k = amount * Double(weights[i])
            guard k > 0.001 else { continue }
            let o = i * 4
            for c in 0 ..< 3 {
                let source = Double(pixels[o + c])
                let detail = source - Double(base[o + c])
                let amplitude = abs(detail)
                guard amplitude > 0 else { continue }
                // 软阈值：超过阈值的部分原样保留，只削阈值以内的那一段。
                let kept = amplitude <= threshold ? detail * (1 - k)
                    : detail - threshold * (1 - k) * (detail > 0 ? 1 : -1)
                pixels[o + c] = Float(Swift.min(Swift.max(Double(base[o + c]) + kept, 0), 1))
            }
        }
    }

    // MARK: 光泽

    /// 正 = 提亮"已经接近高光的那一段"并按高光方向加对比（看起来更亮更顺）；
    /// 负 = 压掉过曝的亮丝（亮到顶的细节不可能靠提亮找回来，只能收亮度）。
    static func shapeShine(_ pixels: inout [Float], size: PixelSize, weights: [Float], amount: Double) {
        guard amount != 0 else { return }
        let radius = Swift.max(2, Int(Double(size.longEdge) * 0.012))
        let luma = RegionEnhance.lumaChannel(pixels, size: size)
        let low = BeautyEngine.blurredChannel(luma, size: size, radius: radius)
        for i in 0 ..< size.pixelCount {
            let k = abs(amount) * Double(weights[i])
            guard k > 0.001 else { continue }
            let l = Double(luma[i])
            guard l > 0.45 else { continue }        // 只处理高光侧，暗部不参与
            let o = i * 4
            // 高光的"软顶"：以 0.72 为膝点，roll-off 压掉过冲。
            let over = Swift.max(0, l - 0.72)
            if amount < 0 {
                // 压得多少只跟"超过膝点多少"有关，且带上限（不会把亮丝压成灰块）。
                let press = k * 0.55 * over / Swift.max(over, 0.28)
                for c in 0 ..< 3 {
                    pixels[o + c] = Float(Swift.min(1, Swift.max(0, Double(pixels[o + c]) - press * (0.06 + over))))
                }
            } else {
                // 提亮量随"比局部均值亮多少"走：亮的地方更亮，平的地方不动，
                // 所以不会把整片头发洗白。
                let lift = k * 0.30 * Swift.max(0, l - Double(low[i]))
                for c in 0 ..< 3 {
                    pixels[o + c] = Float(Swift.min(1, Double(pixels[o + c]) + lift))
                }
            }
        }
    }

    // MARK: 发色

    /// 只推色度（A/B 两轴按比例放大），亮度不动——"加深发色"不是"把头发变暗"。
    static func saturate(_ pixels: inout [Float], size: PixelSize, weights: [Float], amount: Double) {
        guard amount > 0 else { return }
        for i in 0 ..< size.pixelCount {
            let k = amount * Double(weights[i])
            guard k > 0.001 else { continue }
            let o = i * 4
            let source = BeautyEngine.opponent(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
            let rgb = BeautyEngine.fromOpponent(l: source.l,
                                                a: source.a * (1 + 0.45 * k),
                                                b: source.b * (1 + 0.45 * k))
            pixels[o] = Float(Swift.min(Swift.max(rgb.r, 0), 1))
            pixels[o + 1] = Float(Swift.min(Swift.max(rgb.g, 0), 1))
            pixels[o + 2] = Float(Swift.min(Swift.max(rgb.b, 0), 1))
        }
    }
}
