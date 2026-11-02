import CoreGraphics
import Foundation

/// 好片初筛（P1-② 的确定性部分）：全本地、无权重、不宣称美学判断。
///
/// 只做三件能量出来的事，每件都能被测试反驳：
///   · 清晰度 —— 拉普拉斯方差**除以画面自身方差**（归一化）。不除的话低对比画面会被
///     判成"糊"，那正是这类指标最常见的误报；归一化之后仍然分不开"软"与"本来就没
///     边缘"（平涂渐变两者数值一样），所以另外单独给一个 `[flat-content]`，
///     而不是假装它能区分。
///   · 截幅 —— 三个通道同时顶到端的像素占比（死白/死黑），按占比判。
///   · 曝光 —— 亮度均值。
///
/// 阈值不是拍的：镜像脚本算过一组夹具，硬边棋盘 5.70、糊 8 半径 0.19、平涂 0.0，
/// 所以"糊"的下限取 0.45；白场 hi=1.0、灰图 hi=0，取 0.25 才算截幅成片。
///
/// 明确不提供：美学评分（需要权重）、闭眼与构图（需要关键点，本轮没做，见
/// docs/pixcake-parity.md）。这块的作用是"批量连拍里先把明显废片挑出来",
/// 不是替人做决定。
enum FrameTriage {
    struct Verdict: Equatable, Sendable {
        /// 归一化清晰度：拉普拉斯方差 / 画面方差。
        var sharpness: Double
        /// 画面亮度方差（对比度）。低于 `flatLimit` 时清晰度不作判据。
        var contrast: Double
        /// 亮度均值 0…1。
        var exposure: Double
        var clippedHighlights: Double
        var clippedShadows: Double
        /// 圈高/圈宽（nil = 没有可用关键点）。
        var eyeOpenness: Double?
        /// 主体框到最近画布边的距离（归一化；nil = 算不出）。
        var framingMargin: Double?
        /// 机器可读的判定令牌，与 `[no_*]` / `[fallback:*]` 同一套风格。
        var tokens: [String]
        /// 是否建议保留：只被"糊 / 闭眼"这类硬伤否决，曝光、截幅与构图只提示。
        var keep: Bool

        /// 给人看的一行，进导出报告与状态栏。
        ///
        /// 分成几个显式 `String` 子表达式不是风格问题：写成一串 `+` 拼
        /// `String(format:)` + `map` + `??` 时，类型推断会直接超时，报
        /// "unable to type-check this expression in reasonable time"（本仓真红了一轮）。
        func summary() -> String {
            let head = String(format: "初筛 清晰%.2f 对比%.4f 曝光%.2f 截幅%.1f%%/%.1f%%",
                              sharpness, contrast, exposure,
                              clippedHighlights * 100, clippedShadows * 100)
            let eyes: String = eyeOpenness.map { String(format: " 眼开%.2f", $0) } ?? " 眼开无"
            let margin: String = framingMargin.map { String(format: " 边距%.3f", $0) } ?? ""
            let tag: String = tokens.isEmpty ? "[clean]" : tokens.joined(separator: " ")
            return head + eyes + margin + " · " + tag
        }
    }

    /// 归一化清晰度低于它就是"没有边缘"。
    static let blurryLimit = 0.45
    /// 对比度低于它就不该谈清晰度（平涂/纯色本来就没什么边缘可测）。
    static let flatLimit = 0.0015
    /// 三通道同时顶到端的像素占比超过它才算"截幅成片"。
    static let clipLimit = 0.25
    static let underLimit = 0.22
    static let overLimit = 0.80

    // MARK: - 几何两轴（闭眼 / 构图）
    //
    // 无量纲是硬要求：FaceGeometry 的坐标空间跟着输入走（本应用喂归一化点），
    // 任何"半径乘像素距离"的混合算法都会从定义上就错 —— 本仓在镜片区已经栽过一次。

    /// 圈高 / 圈宽。睁眼约 0.3…0.45，闭眼时上下眼皮并成一条线，比值趋近 0。
    static func eyeOpenness(ring: [CGPoint]) -> Double? {
        guard ring.count >= 4 else { return nil }
        let xs = ring.map { Double($0.x) }
        let ys = ring.map { Double($0.y) }
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard width > 1e-9 else { return nil }
        return height / width
    }

    /// 两只眼里取更闭的那只（"一只眼被头发挡住只测另一只"不该算通过）。
    static func eyeOpenness(rings: [[CGPoint]]) -> Double? {
        let values = rings.compactMap { eyeOpenness(ring: $0) }
        return values.min()
    }

    /// 关键点包围盒到最近画布边的距离（只在归一化空间算得出；点不像归一化时给 nil）。
    static func framingMargin(points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              minX >= -0.0001, minY >= -0.0001, maxX <= 1.0001, maxY <= 1.0001 else {
            // 点不像是归一化空间（可能是像素坐标）。这时“到边的距离”毫无意义,
            // 硬算出的大数会被当成“构图很好”—— 那是假数，给 nil 让调用侧点名。
            return nil
        }
        return min(minX, minY, 1 - maxX, 1 - maxY)
    }

    static func geometryReview(_ geometry: FaceGeometry?) -> GeometryVerdict {
        guard let geometry else {
            return GeometryVerdict(eyeOpenness: nil, framingMargin: nil,
                                   tokens: ["[no_landmarks]"], keep: true)
        }
        let openness = eyeOpenness(rings: geometry.eyeRings)
        let subject = geometry.eyeRings.joined()
            + geometry.lipsOuter + [geometry.noseTip, geometry.chin, geometry.forehead]
        let margin = framingMargin(points: subject)
        var tokens: [String] = []
        var keep = true
        if let openness {
            if openness < closedEyeLimit {
                tokens.append("[closed-eyes]")
                keep = false
            } else if openness < halfOpenLimit {
                // 半闭只提示不否决：宁漏判不误杀，误杀一张好片的代价比留一张废片大。
                tokens.append("[eyes-half-open]")
            } else {
                tokens.append("[eyes-open]")
            }
        } else {
            tokens.append("[no_eye_ring]")
        }
        if let margin, margin < cropLimit { tokens.append("[subject-at-edge]") }
        return GeometryVerdict(eyeOpenness: openness, framingMargin: margin,
                              tokens: tokens, keep: keep)
    }

    static let closedEyeLimit = 0.14
    static let halfOpenLimit = 0.22
    static let cropLimit = 0.01

    static func review(_ image: DisplayImage, geometry: FaceGeometry? = nil) -> Verdict {
        let size = image.size
        let count = size.pixelCount
        guard count > 2 else {
            return Verdict(sharpness: 0, contrast: 0, exposure: 0,
                           clippedHighlights: 0, clippedShadows: 0,
                           eyeOpenness: nil, framingMargin: nil,
                           tokens: ["[no_image]"], keep: false)
        }
        let px = image.pixels
        var lum = [Double](repeating: 0, count: count)
        var sum: Double = 0
        var hi = 0, lo = 0
        for i in 0 ..< count {
            let o = i * 4
            let r = Double(px[o]), g = Double(px[o + 1]), b = Double(px[o + 2])
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lum[i] = l
            sum += l
            if r >= 0.995, g >= 0.995, b >= 0.995 { hi += 1 }
            if r <= 0.005, g <= 0.005, b <= 0.005 { lo += 1 }
        }
        let mean = sum / Double(count)
        var variance = 0.0
        for l in lum { variance += (l - mean) * (l - mean) }
        variance /= Double(count)

        // 四邻域拉普拉斯方差的均值（只算内部像素，边界处邻居不全，方差会被人为放大）。
        var lapSum = 0.0
        var lapCount = 0
        var lapValues: [Double] = []
        let w = size.width
        let h = size.height
        guard w > 2, h > 2 else {
            return Verdict(sharpness: 0, contrast: variance, exposure: mean,
                           clippedHighlights: Double(hi) / Double(count),
                           clippedShadows: Double(lo) / Double(count),
                           eyeOpenness: nil, framingMargin: nil,
                           tokens: ["[too_small]"], keep: false)
        }
        for y in 1 ..< h - 1 {
            for x in 1 ..< w - 1 {
                let c = lum[y * w + x]
                let v = 4 * c - lum[y * w + x - 1] - lum[y * w + x + 1]
                    - lum[(y - 1) * w + x] - lum[(y + 1) * w + x]
                lapValues.append(v)
                lapSum += v
                lapCount += 1
            }
        }
        let lapMean = lapSum / Double(max(lapCount, 1))
        var lapVar = 0.0
        for v in lapValues { lapVar += (v - lapMean) * (v - lapMean) }
        lapVar /= Double(max(lapCount, 1))
        let sharpness = lapVar / (variance + 1e-6)

        var tokens: [String] = []
        var keep = true
        // 两个判据各自独立：“没边缘”与“软”在数值上分不开（平涂与强糊图的归一化
        // 清晰度都接近 0），所以**两者都否决**，而不是拿平涂当“豁免”——镜像算过：
        // 半径 8 的模糊会把亮度方差压到 0.00042，低于平涂线，若平涂不否决就会把
        // 一帧彻头彻尾糊掉的片子当成“正常，只是没内容”而放行，那是初筛最贵的漏判。
        if variance < flatLimit { tokens.append("[flat-content]") }
        if sharpness < blurryLimit {
            tokens.append("[blurry]")
            keep = false
        }
        let clipHi = Double(hi) / Double(count)
        let clipLo = Double(lo) / Double(count)
        if clipHi > clipLimit { tokens.append("[clipped-highlights]") }
        if clipLo > clipLimit { tokens.append("[clipped-shadows]") }
        if mean < underLimit { tokens.append("[underexposed]") }
        if mean > overLimit { tokens.append("[overexposed]") }
        let geo = geometryReview(geometry)
        tokens += geo.tokens.filter { $0 != "[eyes-open]" }
        let verdict = Verdict(sharpness: sharpness, contrast: variance, exposure: mean,
                              clippedHighlights: clipHi, clippedShadows: clipLo,
                              eyeOpenness: geo.eyeOpenness, framingMargin: geo.framingMargin,
                              tokens: tokens, keep: keep && geo.keep)
        return verdict
    }
}

/// 只有几何两轴时的判定（面板在拿不到像素的情况下也能先给结论）。
struct GeometryVerdict: Equatable, Sendable {
    var eyeOpenness: Double?
    var framingMargin: Double?
    var tokens: [String]
    var keep: Bool

    func summary() -> String {
        // 同上：拆成显式子表达式，否则类型推断超时报错。
        let eyes: String = eyeOpenness.map { String(format: "眼开度 %.2f", $0) }
            ?? "眼开度 无关键点"
        let margin: String = framingMargin.map { String(format: " · 最近边距 %.3f", $0) } ?? ""
        let tag: String = tokens.isEmpty ? "[clean]" : tokens.joined(separator: " ")
        return eyes + margin + " · " + tag
    }
}
