import Foundation

// 造型与场景参数（本仓的第二批扩展组，与 BeautyParameters 同一待遇）。
//
// 为什么单独成文件而不是塞进 BeautyParameters：BeautyParameters 那三组都是
// "改人像本身"，而这一批改的是**妆、发、手、衣、天、光**——它们的依赖完全不
// 一样（妆容要关键点、手部要 Vision 姿态、衣物要用户涂选区、天空要区域生长、
// 打光是重建亮度场）。混在一组里会出现"磨皮滑杆旁边站着换天空"这种既看不出
// 依赖、也没法整组同步的界面。
//
// 与 imagecake 预设格式的关系同 BeautyParameters：
//   · 键名 snake_case、每组自带 `isNeutral` 与 `clamp()`；
//   · 读对方或旧版预设时缺这六组 → 全部落出厂值（= 关），行为与现在一致；
//   · `preset_version` 不动（37），升到 38 会让旧程序直接拒收我们的文件。
//
// 颜色一律存 24bit RGB hex（`UInt32`）而不是自定义 RGBA8 结构：hex 是 JSON
// 原生数，不需要给 RGBA8 加 Codable 负担，而且面板上"取色 → 落盘 → 读回"
// 必须逐比特等值，少一层浮点换算就少一处可能漂移的地方。

// MARK: - 妆容模板

public struct MakeupParameters: Equatable, Sendable {
    /// 模板 id（见 `MakeupEngine.looks`）。空 = 不用模板。
    public var styleID: String = ""
    /// 0…100 整体浓淡：所有层的力度按它缩放，0 时必须逐比特恒等。
    public var strength: Double = 100

    public init() {}

    public var isNeutral: Bool { styleID.isEmpty || strength == 0 }

    public mutating func clamp() {
        strength = strength.clamped(to: 0 ... 100)
    }
}

// MARK: - 头发

public struct HairParameters: Equatable, Sendable {
    /// 0…100 去毛躁：只压发区内的**高频**对比，发丝边缘（低频轮廓）不动。
    public var smooth: Double = 0
    /// −100…100：负 = 压掉过曝的亮丝，正 = 提起光泽。
    public var shine: Double = 0
    /// 0…100 发色饱和（只作用于发区，不会顺手把皮肤染黄）。
    public var tint: Double = 0
    /// 换发色的目标色（24bit hex）。只当 `colorStrength > 0` 时才有意义。
    /// 默认给一个自然深棕而不是黑：黑发追黑看不出效果，验收时容易误判成"没跑"。
    public var colorHex: UInt32 = 0x6B_4A_34
    /// 0…100 换发色力度：发区内把色度往目标色的 A/B 靠，**亮度逐比特不动**。
    /// 保亮度不是保守：发色的体积感全靠高光与阴影，连亮度一起换就成了一片塑料。
    public var colorStrength: Double = 0
    /// 0…100 祛碎发：只作用于发区掩码的**边界环带**（环带外与发团内部逐比特不动）。
    public var tame: Double = 0

    public init() {}

    public var isNeutral: Bool { smooth == 0 && shine == 0 && tint == 0
        && colorStrength == 0 && tame == 0 }

    public mutating func clamp() {
        smooth = smooth.clamped(to: 0 ... 100)
        shine = shine.clamped(to: -100 ... 100)
        colorStrength = colorStrength.clamped(to: 0 ... 100)
        tame = tame.clamped(to: 0 ... 100)
        colorHex = colorHex & 0xFF_FFFF
        tint = tint.clamped(to: 0 ... 100)
    }
}

// MARK: - 手部

public struct HandParameters: Equatable, Sendable {
    /// 0…100 手部磨皮（关节处的褶皱与干皮）。
    public var smooth: Double = 0
    /// 0…100 匀亮度：把手背与指缝的明暗差收敛到手部自身均值。
    public var evenTone: Double = 0
    /// 0…100 祛红（手经常比脸红；只收回偏红的一半，不整体偏绿）。
    public var redness: Double = 0

    public init() {}

    public var isNeutral: Bool { smooth == 0 && evenTone == 0 && redness == 0 }

    public mutating func clamp() {
        smooth = smooth.clamped(to: 0 ... 100)
        evenTone = evenTone.clamped(to: 0 ... 100)
        redness = redness.clamped(to: 0 ... 100)
    }
}

// MARK: - 衣物

public struct GarmentParameters: Equatable, Sendable {
    /// 0…100 祛褶：只在涂抹过的选区内起作用（见 `BrushState.garments`）。
    public var deWrinkle: Double = 0

    public init() {}

    public var isNeutral: Bool { deWrinkle == 0 }

    public mutating func clamp() {
        deWrinkle = deWrinkle.clamped(to: 0 ... 100)
    }
}

// MARK: - 天空

public enum SkyMode: String, Equatable, Sendable, CaseIterable, Codable, Identifiable {
    /// 程序化渐变天（不额外要文件，确定性可断言）。
    case gradient
    /// 用户导入的那张天图（落在 Documents/ImageCake/Skies）。
    case photo

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .gradient: return "渐变天"
        case .photo: return "导入天图"
        }
    }
}

public struct SkyParameters: Equatable, Sendable {
    public var enabled: Bool = false
    public var mode: SkyMode = .gradient
    /// 天顶色与地平线色（24bit hex）。默认是一组不刺眼的晴天天光。
    public var topHex: UInt32 = 0x2E6FB7
    public var horizonHex: UInt32 = 0xCFE3F2
    /// `mode == .photo` 时的文件名（不含扩展）。找不到就点名，不拿渐变冒充。
    public var sourceName: String = ""
    /// 0…100 替换力度（原图像素与结果线性混合）。
    public var strength: Double = 100
    /// 0…100 光照匹配：把主体的色温往新天的地平线色靠拢，
    /// 只改色度不改亮度——"人还是原来的人，但不再漂在新天上"。
    public var lightMatch: Double = 0

    public init() {}

    /// 光照匹配是独立效果： strength = 0 是“**只借光不借天**”这个常见用法，
    /// 不能因为强度为 0 就把整组当成关（症状：拉 lightMatch 完全没反应）。
    public var isNeutral: Bool { !enabled || (strength == 0 && lightMatch == 0) }

    public mutating func clamp() {
        strength = strength.clamped(to: 0 ... 100)
        lightMatch = lightMatch.clamped(to: 0 ... 100)
        topHex = topHex & 0xFF_FFFF
        horizonHex = horizonHex & 0xFF_FFFF
    }
}

// MARK: - 虚拟打光

public struct LightParameters: Equatable, Sendable {
    /// −180…180 度：0 = 光从画面右侧来，90 = 从下方（y 向下系）。
    public var direction: Double = 0
    /// 0…100 光强。
    public var intensity: Double = 0
    /// 1…100 软硬度：越大法线越平滑 = 光越散（硬光留边缘，软光糊边缘）。
    public var softness: Double = 60
    /// −100…100 光色冷暖（正 = 暖）。
    public var warmth: Double = 0
    /// 0…100 只照亮暗部/中间调的程度；100 = 高光和暗部一样加光，
    /// 0 = 只加暗部（"补光"而不是"加曝光"）。
    public var spread: Double = 50

    public init() {}

    public var isNeutral: Bool { intensity == 0 }

    public mutating func clamp() {
        direction = direction.clamped(to: -180 ... 180)
        intensity = intensity.clamped(to: 0 ... 100)
        softness = softness.clamped(to: 1 ... 100)
        warmth = warmth.clamped(to: -100 ... 100)
        spread = spread.clamped(to: 0 ... 100)
    }
}

// MARK: - 编解码（每组一个嵌套键，缺键落出厂值）

extension MakeupParameters: Codable {
    enum CodingKeys: String, CodingKey { case styleID = "style_id", strength }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        styleID = try c.decodeIfPresent(String.self, forKey: .styleID) ?? styleID
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(styleID, forKey: .styleID)
        try c.encode(strength, forKey: .strength)
    }
}

extension HairParameters: Codable {
    enum CodingKeys: String, CodingKey {
        case smooth, shine, tint
        case colorHex = "color_hex", colorStrength = "color_strength", tame
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smooth = try c.decodeIfPresent(Double.self, forKey: .smooth) ?? smooth
        shine = try c.decodeIfPresent(Double.self, forKey: .shine) ?? shine
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        colorHex = try c.decodeIfPresent(UInt32.self, forKey: .colorHex) ?? colorHex
        colorStrength = try c.decodeIfPresent(Double.self, forKey: .colorStrength) ?? colorStrength
        tame = try c.decodeIfPresent(Double.self, forKey: .tame) ?? tame
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(smooth, forKey: .smooth)
        try c.encode(shine, forKey: .shine)
        try c.encode(tint, forKey: .tint)
        try c.encode(colorHex, forKey: .colorHex)
        try c.encode(colorStrength, forKey: .colorStrength)
        try c.encode(tame, forKey: .tame)
    }
}

extension HandParameters: Codable {
    enum CodingKeys: String, CodingKey { case smooth, evenTone = "even_tone", redness }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smooth = try c.decodeIfPresent(Double.self, forKey: .smooth) ?? smooth
        evenTone = try c.decodeIfPresent(Double.self, forKey: .evenTone) ?? evenTone
        redness = try c.decodeIfPresent(Double.self, forKey: .redness) ?? redness
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(smooth, forKey: .smooth)
        try c.encode(evenTone, forKey: .evenTone)
        try c.encode(redness, forKey: .redness)
    }
}

extension GarmentParameters: Codable {
    enum CodingKeys: String, CodingKey { case deWrinkle = "de_wrinkle" }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deWrinkle = try c.decodeIfPresent(Double.self, forKey: .deWrinkle) ?? deWrinkle
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deWrinkle, forKey: .deWrinkle)
    }
}

extension SkyParameters: Codable {
    enum CodingKeys: String, CodingKey {
        case enabled, mode
        case topHex = "top_hex", horizonHex = "horizon_hex"
        case sourceName = "source_name", strength, lightMatch = "light_match"
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        mode = try c.decodeIfPresent(SkyMode.self, forKey: .mode) ?? mode
        topHex = try c.decodeIfPresent(UInt32.self, forKey: .topHex) ?? topHex
        horizonHex = try c.decodeIfPresent(UInt32.self, forKey: .horizonHex) ?? horizonHex
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? sourceName
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        lightMatch = try c.decodeIfPresent(Double.self, forKey: .lightMatch) ?? lightMatch
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(mode, forKey: .mode)
        try c.encode(topHex, forKey: .topHex)
        try c.encode(horizonHex, forKey: .horizonHex)
        try c.encode(sourceName, forKey: .sourceName)
        try c.encode(strength, forKey: .strength)
        try c.encode(lightMatch, forKey: .lightMatch)
    }
}

extension LightParameters: Codable {
    enum CodingKeys: String, CodingKey {
        case direction, intensity, softness, warmth, spread
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.decodeIfPresent(Double.self, forKey: .direction) ?? direction
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? intensity
        softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? softness
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? warmth
        spread = try c.decodeIfPresent(Double.self, forKey: .spread) ?? spread
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(direction, forKey: .direction)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(softness, forKey: .softness)
        try c.encode(warmth, forKey: .warmth)
        try c.encode(spread, forKey: .spread)
    }
}

// MARK: - 追色（样片对齐）

/// 把本图的色彩统计量往参考图那一张靠。实现见 `ColorTransferEngine`。
///
/// 为什么单独一组而不是挂到滤镜下：滤镜是**固定映射**（.cube 表），追色是
/// **从另一张图现场量出来的映射**。两者可以叠加但必须能分开开关：批量对齐调性
/// 用追色，最后的个人风格用滤镜。它们的依赖也不同（前者要一张图，后者要一张表）。
public struct ColorMatchParameters: Equatable, Sendable {
    /// 总开关。关时整组恒等，而且强度拉满也不跑。
    public var enabled: Bool = false
    /// 参考（样片）的文件名。名字进参数、字节进文档，与 `.cube` / 导入的天
    /// 同一套处理：预设里只存名字，换机器读不到时点名而不是默默落回无色。
    public var sourceName: String = ""
    /// 0…100 追多少。100 = 完全按参考图的均值/反差；0 = 逐比特本图。
    public var strength: Double = 100
    /// 亮度轴要不要追。关掉只追白平衡不追反差，适用于“样片只是色调对我
    /// 但曝光是故意差的”（比如夜景样片对到日光客片）。
    public var matchLuma: Bool = true
    /// 皮肤保护：皮肤像素只吃一部分色度位移。默认开，因为默认使用场景是
    /// 人像批量——把人脸追绿是最显眼的失败。
    public var protectSkin: Bool = true
    /// 第二档：亮度轴的**整个分布形状**也搬到样片上（分位数传递）。
    /// 默认关：它等价于拉一条重 S 曲线，样片反差极大时会在渐变里留下硬边
    /// （实测最陡段斜率 ~189）。实现与边界见 `ShapeTransfer`。
    ///
    /// 它不开新的“力度旋钮”：强度共用 `strength`，且只动亮度轴（`matchLuma` 关时
    /// 自动不生效并在报告里点名 `[shape:luma_off]`），所以 `isNeutral` 不需要为它加条件。
    public var shapeMatch: Bool = false

    public init() {}

    /// 强度 0 与开关关都算中性。`sourceName` 不参与中性判定：
    /// “选了样片但没启用”应当被当成关（不报警），而“启用了但图不见了”
    /// 才需要被 `pipelineWarnings` 点名。
    public var isNeutral: Bool { !enabled || strength == 0 }

    public mutating func clamp() {
        strength = strength.clamped(to: 0 ... 100)
    }
}

extension ColorMatchParameters: Codable {
    enum CodingKeys: String, CodingKey {
        case enabled
        case sourceName = "source_name"
        case strength
        case matchLuma = "match_luma"
        case protectSkin = "protect_skin"
        case shapeMatch = "shape_match"
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? sourceName
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        matchLuma = try c.decodeIfPresent(Bool.self, forKey: .matchLuma) ?? matchLuma
        protectSkin = try c.decodeIfPresent(Bool.self, forKey: .protectSkin) ?? protectSkin
        shapeMatch = try c.decodeIfPresent(Bool.self, forKey: .shapeMatch) ?? shapeMatch
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(sourceName, forKey: .sourceName)
        try c.encode(strength, forKey: .strength)
        try c.encode(matchLuma, forKey: .matchLuma)
        try c.encode(protectSkin, forKey: .protectSkin)
        try c.encode(shapeMatch, forKey: .shapeMatch)
    }
}

// MARK: - 身体细纹（颈纹 / 妊娠纹）

/// 涂一片皮肤，只把那里的**细暗线**填掉（颈纹、妊娠纹、疤痕同一类）。
///
/// 为什么不自动：哪些线是纹、哪些是身体自身的结构阴影（锁骨、孕肚轮廓），
/// 在没有分割权重的情况下从图里看不出来。自动版把低频阴影一起抹平的代价
/// 是把人抹“扁”，比留几条纹严重得多。选区由用户涂，力度可同步（见 ParamSync）。
public struct BodyLineParameters: Equatable, Sendable {
    /// 0…100 祛细纹力度。与法令纹共用同一个算子（`RegionEnhance.thinDarkLinePass`）。
    public var deLine: Double = 0

    public init() {}

    public var isNeutral: Bool { deLine == 0 }

    public mutating func clamp() {
        deLine = deLine.clamped(to: 0 ... 100)
    }
}

extension BodyLineParameters: Codable {
    enum CodingKeys: String, CodingKey { case deLine = "de_line" }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deLine = try c.decodeIfPresent(Double.self, forKey: .deLine) ?? deLine
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deLine, forKey: .deLine)
    }
}

// MARK: - hex 颜色工具

/// 24bit hex ↔ 归一 RGB。妆容/天空的颜色落盘走 hex，因此这里的换算必须
/// 是纯整数/纯浮点的往返，不能有第二条路径（第二条迟早和第一条对不上）。
enum HexColor {
    static func rgb(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255,
         Double((hex >> 8) & 0xFF) / 255,
         Double(hex & 0xFF) / 255)
    }

    static func toRGBA8(_ hex: UInt32, alpha: UInt8 = 255) -> RGBA8 {
        let (r, g, b) = rgb(hex)
        return RGBA8(r: UInt8((r * 255).rounded()), g: UInt8((g * 255).rounded()),
                     b: UInt8((b * 255).rounded()), a: alpha)
    }
}
