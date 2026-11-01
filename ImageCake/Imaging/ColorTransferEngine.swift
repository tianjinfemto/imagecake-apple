import CoreGraphics
import Foundation

// 追色（AI 追色 / 样片对齐）：把"这一张"的色彩统计搬到"那一张样片"的统计上。
//
// 为什么值得做，而且能确定性做好：影楼批量出片的一半工作量不在"逐张细调"，
// 而在"让第 300 张客片和那张被挑出来的样片一个调性"。这件事的本质是**三个轴的
// 一阶/二阶统计量对齐**，不需要网络：
//
//   x' = (x − 本图均值) × (参考图标准差 / 本图标准差) + 参考图均值
//   x'' = x + (x' − x) × 强度
//
// 轴用 `BeautyEngine.opponent` 那套对立色（L=亮度、A=红绿、B=蓝黄）而不是 R/G/B：
// 用 RGB 做增益会把色温和饱和度混在一起——一张偏暖的客片要变冷，G 通道的增益
// 会顺手把饱和度也改掉。L/A/B 分离之后，"追白平衡"落在 A/B 的均值上、
// "追反差"落在 std 上，两件事互不干扰，也才敢分别开关。
//
// 三条防炸约定（都各有断言钉住）：
//   1. **std 下限** `stdFloor`：本图某轴几乎是常数时（纯色背景、黑场），
//      `参考/本图` 会趋无穷，症状是一整片突然炸成参考图的颜色。此时增益锁 1，
//      只追均值不追反差。
//   2. **增益夹范围** `gainRange`：反差的传递本来就不是无损的，1.8 倍以上的
//      增益出来的图一定断层，宁可少追。
//   3. **恒等轴跳过**：`isIdentity` 时逐比特不动。这条不是为了省时间，
//      是为了"参考图就是本图"这个测试场景真的能拿到逐比特原图
//      （往返对立色本身有 1e-16 级误差，不跳就宣称不了恒等）。
//
// 已知边界（写清楚，别当成 AI）：
//   · 只对齐一阶/二阶统计量。**不匹配直方图形状**：样片是双峰（高反差硬光）
//     而客片是单峰时，追完只是均值反差对了，影调分布仍然不像。真解是直方图
//     规定化，代价是要存排序后的样本，且断层风险高，这一版不做。
//   · 空间无关：样片里的构图、人脸位置完全不参与。
//   · 保护皮肤用**色域**判定（与 `SkinMask.isSkin` 同一个口径），不用分割网络。
//     症状可预期：暖色墙会被误判成皮肤而少追色度（保守方向，比把人追绿安全）；
//     真正需要的是分割权重，缺件时点名 `[fallback:colour-locus]`。

/// 追色的统计量。三轴各自的均值与标准差，来自同一套等距采样。
struct ColorStats: Equatable, Sendable {
    var lMean: Double
    var lStd: Double
    var aMean: Double
    var aStd: Double
    var bMean: Double
    var bStd: Double
    /// 参与统计的像素数（诊断用：小样图与全图口径要能对上）。
    var samples: Int
}

enum ColorTransfer {
    /// 统计采样上限。100MP 的图逐像素算三轴均值没有任何意义，
    /// 5 万个等距样本的均值标准差误差在 1e-4 以下（远小于下面夹范围的粒度）。
    static let maxSamples = 50_000
    /// 本图某轴的标准差低于这个值时不参与增益计算（见文件头约定 1）。
    static let stdFloor = 0.015
    /// 反差增益的夹取区间（约定 2）。
    static let gainRange: ClosedRange<Double> = 0.55 ... 1.8
    /// 皮肤像素只吃剩下这部分色度位移。0.6 = 只追四成。
    /// 不做成"完全豁免"：皮肤本来就该跟着整体调性走，一点不动的症状是
    /// "背景和样片一样了，人还是原来那张脸"。
    static let skinChromaKeep = 0.4

    /// 等距抽样步长。步长由像素总数决定，所以同一张图永远采到同一批样本
    /// （确定性：两次导出、预览与导出的统计必须一致）。
    static func sampleStride(for pixelCount: Int) -> Int {
        guard pixelCount > maxSamples else { return 1 }
        // 上取整，保证样本数不超过 maxSamples。
        return Swift.max(1, (pixelCount + maxSamples - 1) / maxSamples)
    }

    /// 三轴统计。空图返回 nil（调用侧据此跳过，不猜值）。
    static func stats(_ image: DisplayImage) -> ColorStats? {
        let count = image.size.pixelCount
        guard count > 0, image.pixels.count >= count * 4 else { return nil }
        let stride = sampleStride(for: count)
        var sumL = 0.0, sumA = 0.0, sumB = 0.0
        var sqL = 0.0, sqA = 0.0, sqB = 0.0
        var taken = 0
        var index = 0
        while index < count {
            let o = index * 4
            let axis = BeautyEngine.opponent(r: Double(image.pixels[o]),
                                             g: Double(image.pixels[o + 1]),
                                             b: Double(image.pixels[o + 2]))
            sumL += axis.l; sumA += axis.a; sumB += axis.b
            sqL += axis.l * axis.l; sqA += axis.a * axis.a; sqB += axis.b * axis.b
            taken += 1
            index += stride
        }
        guard taken > 0 else { return nil }
        let n = Double(taken)
        // 方差用 E[x²] − E[x]²，浮点下可能给出一丁点负数，开方前收 0。
        func std(_ sumSq: Double, _ mean: Double) -> Double {
            Swift.max(0.0, sumSq / n - mean * mean).squareRoot()
        }
        let lMean = sumL / n, aMean = sumA / n, bMean = sumB / n
        return ColorStats(lMean: lMean, lStd: std(sqL, lMean),
                          aMean: aMean, aStd: std(sqA, aMean),
                          bMean: bMean, bStd: std(sqB, bMean),
                          samples: taken)
    }

    /// 一条轴上的映射。`(x − selfMean)·gain + refMean`，再按强度混合。
    struct AxisMap: Equatable, Sendable {
        var selfMean: Double
        var refMean: Double
        var gain: Double

        /// 恒等 = 增益 1 且均值相同。命中就逐比特不动（见文件头约定 3）。
        var isIdentity: Bool {
            abs(gain - 1.0) < 1e-9 && abs(refMean - selfMean) < 1e-9
        }

        func apply(_ x: Double, strength: Double) -> Double {
            if isIdentity { return x }
            let moved = (x - selfMean) * gain + refMean
            return x + (moved - x) * strength
        }
    }

    /// 增益：参考 std / 本图 std，带 std 下限保护与夹范围。
    static func gain(reference: Double, current: Double) -> Double {
        guard current >= stdFloor else { return 1.0 }
        return (reference / current).clamped(to: gainRange)
    }

    /// 由两组统计量得出映射计划。纯函数，可单独断言。
    static func plan(current: ColorStats, reference: ColorStats) -> (l: AxisMap, a: AxisMap, b: AxisMap) {
        (AxisMap(selfMean: current.lMean, refMean: reference.lMean,
                 gain: gain(reference: reference.lStd, current: current.lStd)),
         AxisMap(selfMean: current.aMean, refMean: reference.aMean,
                 gain: gain(reference: reference.aStd, current: current.aStd)),
         AxisMap(selfMean: current.bMean, refMean: reference.bMean,
                 gain: gain(reference: reference.bStd, current: current.bStd)))
    }

    /// 按已算好的计划改一张图。拆成两个入口是因为面板要能"预览这一步会动多少"
    /// 而不再读一次参考图。
    static func apply(_ image: DisplayImage, plan maps: (l: AxisMap, a: AxisMap, b: AxisMap),
                      match: ColorMatchParameters) -> DisplayImage {
        let size = image.size
        let count = size.pixelCount
        let strength = BeautyParameters.unit(match.strength)
        // 强度 0 必须是逐比特原图，不是"近似原图"：闸门放在这里而不是只放在
        // 调用侧，面板与导出才共用同一个承诺。
        guard count > 0, strength > 0, image.pixels.count >= count * 4 else { return image }
        var pixels = image.pixels
        let protect = match.protectSkin
        let matchLuma = match.matchLuma
        for i in 0 ..< count {
            let o = i * 4
            let r = Double(pixels[o]), g = Double(pixels[o + 1]), b = Double(pixels[o + 2])
            let source = BeautyEngine.opponent(r: r, g: g, b: b)
            // 皮肤保护只减色度位移：亮度追不追是曝光一致性问题，与人是不是皮肤无关。
            let chromaKeep = protect && SkinMask.isSkin(r: r, g: g, b: b) ? Self.skinChromaKeep : 1.0
            let l = matchLuma ? maps.l.apply(source.l, strength: strength) : source.l
            let a = maps.a.apply(source.a, strength: strength * chromaKeep)
            let bb = maps.b.apply(source.b, strength: strength * chromaKeep)
            let rgb = BeautyEngine.fromOpponent(l: l, a: a, b: bb)
            pixels[o] = Float(rgb.0.clamped(to: 0 ... 1))
            pixels[o + 1] = Float(rgb.1.clamped(to: 0 ... 1))
            pixels[o + 2] = Float(rgb.2.clamped(to: 0 ... 1))
            // alpha 不动：追色是色彩操作，改不透明度等于改了合成结果。
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 一步到位：从参考图算统计再应用。参考图缺失/为空时**原样返回**，
    /// 缺件由调用侧点名（引擎不造文案，免得同一个缺失出现两种说法）。
    static func apply(_ image: DisplayImage, reference: DisplayImage?,
                      match: ColorMatchParameters) -> DisplayImage {
        guard match.enabled, BeautyParameters.unit(match.strength) > 0,
              let reference, let refStats = Self.stats(reference),
              let curStats = Self.stats(image) else { return image }
        return apply(image, plan: plan(current: curStats, reference: refStats), match: match)
    }

    /// 给人看的一句话：动了多少、哪几轴被夹过。写进状态栏与导出报告，
    /// 免得"追色"变成一个只能靠肉眼验收的黑箱。
    static func report(current: ColorStats, reference: ColorStats, match: ColorMatchParameters) -> String {
        let maps = plan(current: current, reference: reference)
        // 哪一轴被夹过必须说出来：不说就只能看到“追了但没追到”，然后怀疑算子。
        var clipped: [String] = []
        if maps.l.gain >= gainRange.upperBound - 1e-9 { clipped.append("L") }
        if maps.a.gain >= gainRange.upperBound - 1e-9 { clipped.append("A") }
        if maps.b.gain >= gainRange.upperBound - 1e-9 { clipped.append("B") }
        let clipNote = clipped.isEmpty ? "" : " · \(clipped.joined(separator: "/"))轴反差已夹顶（样片反差大得多）"
        return String(format: "追色 ΔL %+.3f ΔA %+.3f ΔB %+.3f · 反差增益 %.2f/%.2f/%.2f · 强度 %d%%%@",
                      reference.lMean - current.lMean,
                      reference.aMean - current.aMean,
                      reference.bMean - current.bMean,
                      maps.l.gain, maps.a.gain, maps.b.gain,
                      Int(match.strength.rounded()), clipNote)
    }
}

/// 参考图素材库。与 `.cube` / 导入的天空同一套处理：**名字进参数，字节进文档**。
///
/// 只存不缩：参考图仅用于统计，不需要和画布对齐，所以既不做 cover-fit 也不
/// 做重采样——省下一次全图缩放，而且"同一张样片在任何画幅上都给同一个均值"
/// 这个性质才成立（缩放会改统计量，虽然改得很小）。
enum ColorReferenceLibrary {
    static var directory: URL? {
        guard let base = try? FileManager.default.url(for: .documentDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        let dir = base.appendingPathComponent("ImageCake", isDirectory: true)
            .appendingPathComponent("ColorRefs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func importedNames() -> [String] {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        let readable: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff"]
        return files.filter { readable.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    @discardableResult
    static func install(from url: URL) throws -> String {
        guard let dir = directory else { throw ImageLoadError.notFound }
        let name = url.deletingPathExtension().lastPathComponent
        let target = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        try FileManager.default.copyItem(at: url, to: target)
        return name
    }

    /// 读成显示域图（与主图同一层口径）。取不到返回 nil，调用侧点名。
    static func load(name: String) async -> DisplayImage? {
        guard let dir = directory else { return nil }
        let base = dir.appendingPathComponent(name)
        let candidates = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff"]
            .map { base.appendingPathExtension($0) }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let loaded = try? await ImageLoader.load(url: url, maxEdge: 0) else { return nil }
            return display(from: loaded.linear)
        }
        return nil
    }

    /// 线性 → 显示码。统计必须在显示域算：线性域的均值和"人眼看到的明暗"
    /// 差一个 OETF，拿线性统计去追会得到"客片比样片暗半档"的错觉。
    static func display(from linear: LinearImage) -> DisplayImage {
        let size = linear.size
        guard size.pixelCount > 0, linear.pixels.count >= size.pixelCount * 4 else {
            return DisplayImage(size: size, pixels: linear.pixels)
        }
        var pixels = linear.pixels
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            for c in 0 ..< 3 { pixels[o + c] = ColorMath.encode(pixels[o + c]) }
        }
        return DisplayImage(size: size, pixels: pixels)
    }
}
