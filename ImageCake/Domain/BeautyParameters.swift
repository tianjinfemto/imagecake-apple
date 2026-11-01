import Foundation

// 人像精修 / 滤镜 / 镜头三组参数。
//
// 为什么不把这些键平铺进 EditParameters：皮肤与美型加起来二十多项，平铺会把
// 「调色」这条链的字段和「人像」这条链的字段混在同一屏里，读代码时分不清
// 哪个闸门管哪一段。分组后每组自带中性判定与夹取，EditParameters 只负责
// 「有没有活要干」。
//
// 与 imagecake 预设格式的关系：这三组是本仓扩展（与 denoise/sharpen 同一待遇），
// 键名是嵌套对象 beauty / filter / lens。
//   · 读对方或旧版预设：缺这三组 → 全部落出厂值（= 关），行为与现在一致；
//   · 我们写出的预设被对方读：这三键会被点名为未知键并写进它的报告——
//     这是**故意的**，比让对方猜这些值是什么意思要好。
// preset_version 因此**不动**（仍是 37）：一旦升到 38，旧程序会直接拒收我们的文件。
//
// 量纲统一：所有滑杆都是 −100…100 或 0…100 的"人话刻度"，算子内部再换算。
// 0 = 关，且必须让对应算子整段跳过（不是"跑一遍近似恒等"）——与 ToneEngine
// 的闸门同一条规矩，否则预览拖滑杆会变成幻灯片。

// MARK: - 人像精修 + 美型

public struct BeautyParameters: Equatable, Sendable {
    // —— 皮肤（零权重、确定性；靠皮肤掩码定区） ——
    /// 0…100 脸部磨皮。实现是频率分离：压掉中低频的不均匀光影，
    /// 保留高频纹理（毛孔/绒毛），所以不是"糊一层"。
    public var skinSmooth: Double = 0
    /// 0…100 身体磨皮。身体皮肤面积大、细节少，力度与脸分开给。
    public var bodySmooth: Double = 0
    /// 0 = 平整（连光影一起抹平，广告级"瓷肌"），1 = 立体（只压中频噪点，
    /// 保留低频的明暗过渡）。像素蛋糕的同一条产品区分，这里用两种高频
    /// 重建方式实现，而不是两套网络。
    public var smoothMode: Int = 0
    /// 0…100 祛瑕疵（痘印/斑点：小而幅度大的异常 → 用邻域低频填掉）。
    public var blemish: Double = 0
    /// 0…100 肤色统一（把皮肤像素的色度往区域均值收，亮度结构不动）。
    public var toneUnify: Double = 0
    /// 0…100 祛红血丝（只收回"比皮肤均值更红"的那部分，不整体偏绿）。
    public var redness: Double = 0
    /// 0…100 祛油光（高亮度 + 低饱和的皮肤亮斑压下去，顺带回补饱和）。
    public var deShine: Double = 0
    /// 0…100 美白（皮肤内提亮，趋向白而不是加白）。
    public var whitening: Double = 0

    // —— 五官区域美化（需要人脸关键点） ——
    public var eyeBright: Double = 0
    public var teethWhiten: Double = 0
    public var lipColor: Double = 0
    public var blush: Double = 0
    /// 0…100 祛黑眼圈。专项目标是“下睑区的亮度差”：把比局部皮肤均值暗
    /// 出来的那一段抬回去，而不是把眼下磨平（纹理在高光里，不在这里）。
    public var darkCircle: Double = 0
    /// 0…100 祛法令纹。方向与磨皮相反：只填"比邻域暗得多的细线"，
    /// 颧骨的阴影（低频）一律不动——不然脸会扁一块。
    public var nasolabial: Double = 0
    /// 0…100 眼镜祛反光。只压**镜片区里比邻域亮出来且低饱和**的那一段，
    /// 不编造反光底下的颜色（那张图里没有这个信息），也不碰彩色镜片与瞳孔。
    public var antiGlare: Double = 0

    // —— 五官形变（需要人脸关键点） ——
    public var slimFace: Double = 0      // 瘦颊：颊点向脸部中轴推
    public var enlargeEyes: Double = 0   // 大眼：以虹膜圆心向外放大
    public var noseSlim: Double = 0      // 缩鼻翼：鼻翼向鼻梁轴推
    public var jawSlim: Double = 0       // 收下颌：下颌轮廓向内推
    public var smileLift: Double = 0     // 微笑唇：嘴角向上向外
    public var chinAdjust: Double = 0    // −100 缩短 … +100 加长

    // —— 美体形变（需要身形关键点） ——
    public var waistSlim: Double = 0     // 细腰
    public var legsSlim: Double = 0      // 瘦腿
    public var heighten: Double = 0      // 增高/长腿（髋线以下为锚的纵向拉伸）
    public var neckSlim: Double = 0      // 天鹅颈
    public var shoulderLift: Double = 0  // 直角肩（肩部上提 + 斜方肌收窄）

    public init() {}

    // MARK: 中性闸门

    public var isSkinNeutral: Bool {
        skinSmooth == 0 && bodySmooth == 0 && blemish == 0 && toneUnify == 0
            && redness == 0 && deShine == 0 && whitening == 0
    }

    public var isRegionNeutral: Bool {
        eyeBright == 0 && teethWhiten == 0 && lipColor == 0 && blush == 0
            && darkCircle == 0 && nasolabial == 0 && antiGlare == 0
    }

    public var isFaceShapeNeutral: Bool {
        slimFace == 0 && enlargeEyes == 0 && noseSlim == 0 && jawSlim == 0
            && smileLift == 0 && chinAdjust == 0
    }

    public var isBodyShapeNeutral: Bool {
        waistSlim == 0 && legsSlim == 0 && heighten == 0 && neckSlim == 0 && shoulderLift == 0
    }

    public var isShapeNeutral: Bool { isFaceShapeNeutral && isBodyShapeNeutral }

    public var isNeutral: Bool { isSkinNeutral && isRegionNeutral && isShapeNeutral }

    /// 关键点数 = 0…100 的刻度换算（统一入口，免得各算子自己除一遍）。
    @inline(__always)
    public static func unit(_ value: Double) -> Double {
        Swift.min(Swift.max(value, -100), 100) / 100
    }

    /// 逐脸力度的作用域：**只缩放靠关键点定位的那两组**——五官区域美化（七项）
    /// 与五官形变（六项）。不动皮肤组与身形组：
    ///   · 皮肤磨皮/美白是整片皮肤一个掩码，逐张脸拆不开（拆了会在脸与脸之间
    ///     出现质感不一致，比力度相同更难看得出）；
    ///   · 身形项靠的是身体关节点，不属于任何一张脸。
    ///
    /// 返回新值而不是就地改：这个函数在渲染链里按脸循环调用，拿一份改过的副本
    /// 比在循环里改 `inout` 参数更难写错。
    public func scaled(by k: Double) -> BeautyParameters {
        guard k != 1 else { return self }
        var out = self
        func scale(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            (value * k).clamped(to: range)
        }
        out.eyeBright = scale(eyeBright, 0 ... 100)
        out.teethWhiten = scale(teethWhiten, 0 ... 100)
        out.lipColor = scale(lipColor, 0 ... 100)
        out.blush = scale(blush, 0 ... 100)
        out.darkCircle = scale(darkCircle, 0 ... 100)
        out.nasolabial = scale(nasolabial, 0 ... 100)
        out.antiGlare = scale(antiGlare, 0 ... 100)
        out.slimFace = scale(slimFace, -100 ... 100)
        out.enlargeEyes = scale(enlargeEyes, -100 ... 100)
        out.noseSlim = scale(noseSlim, -100 ... 100)
        out.jawSlim = scale(jawSlim, -100 ... 100)
        out.smileLift = scale(smileLift, -100 ... 100)
        out.chinAdjust = scale(chinAdjust, -100 ... 100)
        return out
    }

    public mutating func clamp() {
        skinSmooth = skinSmooth.clamped(to: 0 ... 100)
        bodySmooth = bodySmooth.clamped(to: 0 ... 100)
        if smoothMode != 0, smoothMode != 1 { smoothMode = 0 }
        blemish = blemish.clamped(to: 0 ... 100)
        toneUnify = toneUnify.clamped(to: 0 ... 100)
        redness = redness.clamped(to: 0 ... 100)
        deShine = deShine.clamped(to: 0 ... 100)
        whitening = whitening.clamped(to: 0 ... 100)
        eyeBright = eyeBright.clamped(to: 0 ... 100)
        teethWhiten = teethWhiten.clamped(to: 0 ... 100)
        lipColor = lipColor.clamped(to: 0 ... 100)
        blush = blush.clamped(to: 0 ... 100)
        darkCircle = darkCircle.clamped(to: 0 ... 100)
        nasolabial = nasolabial.clamped(to: 0 ... 100)
        antiGlare = antiGlare.clamped(to: 0 ... 100)
        slimFace = slimFace.clamped(to: -100 ... 100)
        enlargeEyes = enlargeEyes.clamped(to: -100 ... 100)
        noseSlim = noseSlim.clamped(to: -100 ... 100)
        jawSlim = jawSlim.clamped(to: -100 ... 100)
        smileLift = smileLift.clamped(to: -100 ... 100)
        chinAdjust = chinAdjust.clamped(to: -100 ... 100)
        waistSlim = waistSlim.clamped(to: -100 ... 100)
        legsSlim = legsSlim.clamped(to: -100 ... 100)
        heighten = heighten.clamped(to: -100 ... 100)
        neckSlim = neckSlim.clamped(to: -100 ... 100)
        shoulderLift = shoulderLift.clamped(to: -100 ... 100)
    }
}

// MARK: - 逐脸力度（合影用）

/// 合影里每张脸一份力度缩放。按 `faceGeometries` 的**位置**对应（脸数按面积从大到小排序，
/// 所以下标稳定），值含义：
///
///   · 100 = 跟随全局（出厂）；0 = 这张脸完全不动；可以拉到 200 让某张脸比全局更强。
///   · **数组比脸数短**：多出来的脸跟随全局；**比脸数长**：多出来的值被忽略。
///     这两条都是故意的：换一张人更多的图不能 silently 把上一张的设定扫到不相干的人头上。
///
/// 为什么不做成"脸的身份证"（按关键点位置匹配）：关键点每次重测，浮点位置不会逐比特相等，
/// 所谓身份只能是"按面积排下来的序号"——那就直说它是序号，不假装有更稳的身份。
public struct FaceStrengthParameters: Equatable, Sendable {
    /// 下标 = 第几张脸（面积从大到小），值 = 0…200 的百分比。空数组 = 全部跟随。
    public var scales: [Double] = []

    /// 单张脸最多放到全局的几倍。超过 2 倍的症状是脸变形到不像同一个人。
    public static let maxPercent = 200.0

    public init() {}

    /// 不参与 `EditParameters.isNeutral`：它是**修正量**而不是效果——没有其他人脸项
    /// 开着时它什么也不动，把它算进中性判定只会让渲染快路径白白多跑一整遍。
    public var isNeutral: Bool { scales.isEmpty || scales.allSatisfy { $0 == 100 } }

    /// 第 index 张脸的缩放因子。越界与未设都是 1.0（跟随全局）。
    public func factor(for index: Int) -> Double {
        guard scales.indices.contains(index) else { return 1 }
        return Swift.max(0.0, Swift.min(Self.maxPercent, scales[index])) / 100
    }

    /// 设第 index 张脸的力度。不够长就补 100，而不是存个稀疏结构——
    /// 补平之后数组就是"逐脸力度"的完整快照，往返与同步都不需要特殊处理。
    public mutating func setFactor(_ percent: Double, for index: Int) {
        guard index >= 0 else { return }
        while scales.count <= index { scales.append(100) }
        scales[index] = percent.clamped(to: 0 ... Self.maxPercent)
    }

    public mutating func clamp() {
        scales = scales.map { $0.clamped(to: 0 ... Self.maxPercent) }
        if scales.count > 64 { scales = Array(scales.prefix(64)) }   // 防有人往预设里塑上百万个值
    }
}

extension FaceStrengthParameters: Codable {
    enum CodingKeys: String, CodingKey { case scales }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scales = try c.decodeIfPresent([Double].self, forKey: .scales) ?? scales
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scales, forKey: .scales)
    }
}

// MARK: - 滤镜 / 风格

public struct FilterParameters: Equatable, Sendable {
    /// 风格名。内置风格用 `FilterEngine.builtInNames` 里的 id；导入的 .cube
    /// 用文件名（不含扩展）。空串 = 不用滤镜。
    public var style: String = ""
    /// 0…100，滤镜强度：按原像素与结果线性混合（不是"把 LUT 调淡"）。
    public var strength: Double = 100

    public init() {}

    public var isNeutral: Bool { style.isEmpty || strength == 0 }

    public mutating func clamp() {
        strength = strength.clamped(to: 0 ... 100)
    }
}

// MARK: - 镜头校正与画质层

public struct LensParameters: Equatable, Sendable {
    /// −100…100：正 = 桶形（画面往外鼓），负 = 枕形。中心不动。
    public var distortion: Double = 0
    /// −100…100：色差。正 = 红边向外、蓝边向内（常见于广角边缘）。
    public var chromaticAberration: Double = 0
    /// 0…100 暗角力度。
    public var vignette: Double = 0
    /// 1…10 暗角过渡带软硬（越大越硬）。
    public var vignetteFalloff: Double = 2
    /// 0…100 颗粒力度（确定性哈希噪声，同参数两次导出结果逐比特一致）。
    public var grain: Double = 0

    public init() {}

    public var isNeutral: Bool {
        distortion == 0 && chromaticAberration == 0 && vignette == 0 && grain == 0
    }

    /// 只有改像素位置的项（畸变/色差）需要在管线早期跑。
    public var isGeometryNeutral: Bool { distortion == 0 && chromaticAberration == 0 }

    /// 输出层的项（暗角/颗粒）在最后一道跑。
    public var isOverlayNeutral: Bool { vignette == 0 && grain == 0 }

    public mutating func clamp() {
        distortion = distortion.clamped(to: -100 ... 100)
        chromaticAberration = chromaticAberration.clamped(to: -100 ... 100)
        vignette = vignette.clamped(to: 0 ... 100)
        vignetteFalloff = vignetteFalloff.clamped(to: 1 ... 10)
        grain = grain.clamped(to: 0 ... 100)
    }
}

// MARK: - 预设编解码（三组各占一个嵌套键）

extension BeautyParameters: Codable {
    enum CodingKeys: String, CodingKey {
        case skinSmooth = "skin_smooth", bodySmooth = "body_smooth", smoothMode = "smooth_mode"
        case blemish, toneUnify = "tone_unify", redness, deShine = "de_shine", whitening
        case eyeBright = "eye_bright", teethWhiten = "teeth_whiten", lipColor = "lip_color", blush
        case darkCircle = "dark_circle", nasolabial, antiGlare = "anti_glare"
        case slimFace = "slim_face", enlargeEyes = "enlarge_eyes", noseSlim = "nose_slim"
        case jawSlim = "jaw_slim", smileLift = "smile_lift", chinAdjust = "chin_adjust"
        case waistSlim = "waist_slim", legsSlim = "legs_slim", heighten
        case neckSlim = "neck_slim", shoulderLift = "shoulder_lift"
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skinSmooth = try c.decodeIfPresent(Double.self, forKey: .skinSmooth) ?? skinSmooth
        bodySmooth = try c.decodeIfPresent(Double.self, forKey: .bodySmooth) ?? bodySmooth
        smoothMode = try c.decodeIfPresent(Int.self, forKey: .smoothMode) ?? smoothMode
        blemish = try c.decodeIfPresent(Double.self, forKey: .blemish) ?? blemish
        toneUnify = try c.decodeIfPresent(Double.self, forKey: .toneUnify) ?? toneUnify
        redness = try c.decodeIfPresent(Double.self, forKey: .redness) ?? redness
        deShine = try c.decodeIfPresent(Double.self, forKey: .deShine) ?? deShine
        whitening = try c.decodeIfPresent(Double.self, forKey: .whitening) ?? whitening
        eyeBright = try c.decodeIfPresent(Double.self, forKey: .eyeBright) ?? eyeBright
        teethWhiten = try c.decodeIfPresent(Double.self, forKey: .teethWhiten) ?? teethWhiten
        lipColor = try c.decodeIfPresent(Double.self, forKey: .lipColor) ?? lipColor
        blush = try c.decodeIfPresent(Double.self, forKey: .blush) ?? blush
        darkCircle = try c.decodeIfPresent(Double.self, forKey: .darkCircle) ?? darkCircle
        nasolabial = try c.decodeIfPresent(Double.self, forKey: .nasolabial) ?? nasolabial
        antiGlare = try c.decodeIfPresent(Double.self, forKey: .antiGlare) ?? antiGlare
        slimFace = try c.decodeIfPresent(Double.self, forKey: .slimFace) ?? slimFace
        enlargeEyes = try c.decodeIfPresent(Double.self, forKey: .enlargeEyes) ?? enlargeEyes
        noseSlim = try c.decodeIfPresent(Double.self, forKey: .noseSlim) ?? noseSlim
        jawSlim = try c.decodeIfPresent(Double.self, forKey: .jawSlim) ?? jawSlim
        smileLift = try c.decodeIfPresent(Double.self, forKey: .smileLift) ?? smileLift
        chinAdjust = try c.decodeIfPresent(Double.self, forKey: .chinAdjust) ?? chinAdjust
        waistSlim = try c.decodeIfPresent(Double.self, forKey: .waistSlim) ?? waistSlim
        legsSlim = try c.decodeIfPresent(Double.self, forKey: .legsSlim) ?? legsSlim
        heighten = try c.decodeIfPresent(Double.self, forKey: .heighten) ?? heighten
        neckSlim = try c.decodeIfPresent(Double.self, forKey: .neckSlim) ?? neckSlim
        shoulderLift = try c.decodeIfPresent(Double.self, forKey: .shoulderLift) ?? shoulderLift
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(skinSmooth, forKey: .skinSmooth)
        try c.encode(bodySmooth, forKey: .bodySmooth)
        try c.encode(smoothMode, forKey: .smoothMode)
        try c.encode(blemish, forKey: .blemish)
        try c.encode(toneUnify, forKey: .toneUnify)
        try c.encode(redness, forKey: .redness)
        try c.encode(deShine, forKey: .deShine)
        try c.encode(whitening, forKey: .whitening)
        try c.encode(eyeBright, forKey: .eyeBright)
        try c.encode(teethWhiten, forKey: .teethWhiten)
        try c.encode(lipColor, forKey: .lipColor)
        try c.encode(blush, forKey: .blush)
        try c.encode(darkCircle, forKey: .darkCircle)
        try c.encode(nasolabial, forKey: .nasolabial)
        try c.encode(antiGlare, forKey: .antiGlare)
        try c.encode(slimFace, forKey: .slimFace)
        try c.encode(enlargeEyes, forKey: .enlargeEyes)
        try c.encode(noseSlim, forKey: .noseSlim)
        try c.encode(jawSlim, forKey: .jawSlim)
        try c.encode(smileLift, forKey: .smileLift)
        try c.encode(chinAdjust, forKey: .chinAdjust)
        try c.encode(waistSlim, forKey: .waistSlim)
        try c.encode(legsSlim, forKey: .legsSlim)
        try c.encode(heighten, forKey: .heighten)
        try c.encode(neckSlim, forKey: .neckSlim)
        try c.encode(shoulderLift, forKey: .shoulderLift)
    }
}

extension FilterParameters: Codable {
    enum CodingKeys: String, CodingKey { case style, strength }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? style
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(strength, forKey: .strength)
    }
}

extension LensParameters: Codable {
    enum CodingKeys: String, CodingKey {
        case distortion, chromaticAberration = "chromatic_aberration"
        case vignette, vignetteFalloff = "vignette_falloff", grain
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        distortion = try c.decodeIfPresent(Double.self, forKey: .distortion) ?? distortion
        chromaticAberration = try c.decodeIfPresent(Double.self, forKey: .chromaticAberration) ?? chromaticAberration
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? vignette
        vignetteFalloff = try c.decodeIfPresent(Double.self, forKey: .vignetteFalloff) ?? vignetteFalloff
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? grain
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(distortion, forKey: .distortion)
        try c.encode(chromaticAberration, forKey: .chromaticAberration)
        try c.encode(vignette, forKey: .vignette)
        try c.encode(vignetteFalloff, forKey: .vignetteFalloff)
        try c.encode(grain, forKey: .grain)
    }
}
