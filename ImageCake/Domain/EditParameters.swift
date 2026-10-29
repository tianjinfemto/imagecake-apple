import Foundation

// 调色/交付参数。键名与 imagecake 的预设 JSON 逐字对齐（snake_case），
// 目的不是"看起来一样"，而是让两边预设可互相读取：
//   · 我们写出来的文件，imagecake 读到缺键会落出厂值；
//   · imagecake 写出来的文件，我们读到不认识的键会**点名丢进报告**，
//     而不是静默吃掉（见 PresetLoadReport.unknownKeys）。
//
// 语义边界（与 imagecake 同一条）：
//   · 线性域：曝光、色温/色调；
//   · 显示域：对比、曲线、HSL、三区色轮、饱和度；
//   · 交付端：换底色/背景虚化、面部重绘、AI 超清（只挂导出）。
// 顺序写在一处：ToneEngine.render 的注释与 ImageDocument.render 的调用序。

public struct CurveChannel: Equatable, Sendable {
    public var x: [Double]
    public var y: [Double]

    public init(x: [Double] = [0, 1], y: [Double] = [0, 1]) {
        self.x = x
        self.y = y
    }

    public static let identity = CurveChannel()

    /// 恒等 = 两个锚点且都在 y=x 上。用户在中性曲线上补一个 (0.5,0.5) 的点
    /// 数学上仍是恒等，但算法照样跑一遍——那种"看着没变其实走了一遍近似"的
    /// 状态不再被当作中性，与 imagecake 的口径一致。
    public var isIdentity: Bool {
        x == [0, 1] && y == [0, 1]
    }

    /// 控制点合法性：x 严格递增、首尾锚在 0/1、点数对齐。坏曲线不进算子。
    public var isValid: Bool {
        x.count == y.count && x.count >= 2
            && x.first == 0 && x.last == 1
            && zip(x, x.dropFirst()).allSatisfy { pair in pair.0 < pair.1 }
    }
}

public struct EditParameters: Equatable, Sendable {
    public static let presetVersion = 37

    // —— 线性域 ——
    public var exposure: Double = 0        // -2 ... +2 EV
    public var temperature: Double = 0     // -100 ... +100，正=偏暖
    public var tint: Double = 0            // -100 ... +100，正=偏品红

    // —— 显示域 ——
    public var contrast: Double = 0        // -100 ... +100
    public var saturation: Double = 0      // -100 ... +100
    public var hue: Double = 0             // -180 ... +180 度

    // 补光 / 高光柔化：只动亮度、不染色（要染色请用三区色轮）。
    // 形式选“趋向白 / 趋向黑”而不是线性加减：
    //   v ← v + k·(1−v)  与  v ← v − k·v
    // 两者都不会溢出，且在两端自然饱和——不会像线性加减那样把亮部推到
    // 一片死白或者把阴影涂成灰块。
    public var fillLight: Double = 0       // 0 ... 100，抬暗部
    public var highlightSoften: Double = 0 // 0 ... 100，压高光

    // —— 显示域空间滤波 ——
    // 作用在调色**之后**（见 SpatialFilters）：要读邻域，进不了 ToneEngine 的逐像素循环。
    // 0 = 关。降噪先于锐化，反过来等于先把噪声锐化一遍。
    public var denoise: Double = 0         // 0 ... 100，双边滤波强度
    public var sharpen: Double = 0         // 0 ... 100，unsharp mask 强度

    // 三区色轮（阴影/中间调/高光）：推的方向 + 力度 + 亮度
    public var wshHue: Double = 0, wshSat: Double = 0, wshLum: Double = 0
    public var wmtHue: Double = 0, wmtSat: Double = 0, wmtLum: Double = 0
    public var whlHue: Double = 0, whlSat: Double = 0, whlLum: Double = 0

    // 八分区 HSL。下标序固定为 红/橙/黄/绿/青/蓝/紫/品红——
    // 与 imagecake 的参数序一致（它在内部按角度重排，我们在 ToneEngine 里
    // 用同一组标准色相中心，色相带中心写死在 ColorMath.bandCenters）。
    public var hslHue: [Double] = Array(repeating: 0, count: 8)
    public var hslSat: [Double] = Array(repeating: 0, count: 8)
    public var hslLum: [Double] = Array(repeating: 0, count: 8)

    // 四条曲线：0=RGB 复合、1=红、2=绿、3=蓝
    public var curves: [CurveChannel] = Array(repeating: .identity, count: 4)

    // —— 换底色 / 背景虚化（需要 person mask） ——
    public var bgEnabled: Bool = false
    public var bgR: Double = 255
    public var bgG: Double = 255
    public var bgB: Double = 255
    public var bgBlur: Double = 0          // 0...100，0 = 只换色不虚化

    // —— 交付端 ——
    public var faceRestore: Double = 0     // 0...100，只挂导出
    public var superRes: Int = 0           // 0/2/4，只挂导出

    public var presetVersion: Int = EditParameters.presetVersion
    /// 这份预设依赖的外部资产（例如 lut：名字）。v1 只登记与报告，不加载。
    public var requires: [String] = []

    public init() {}

    // MARK: - 中性判定（快路径闸门）

    public var isLinearNeutral: Bool {
        exposure == 0 && temperature == 0 && tint == 0
    }

    public var isDisplayNeutral: Bool {
        contrast == 0 && saturation == 0 && hue == 0
            && fillLight == 0 && highlightSoften == 0
            && isWheelsNeutral && isHSLNeutral && curves.allSatisfy(\.isIdentity)
            && !bgEnabled
    }

    public var isWheelsNeutral: Bool {
        [wshSat, wshLum, wmtSat, wmtLum, whlSat, whlLum].allSatisfy { $0 == 0 }
    }

    public var isHSLNeutral: Bool {
        (hslHue + hslSat + hslLum).allSatisfy { $0 == 0 }
    }

    /// 空间滤波是否全关。它们活在 ToneEngine 之外，所以单独一个谓词，
    /// 不塞进 isDisplayNeutral——那个谓词是给逐像素循环看的。
    public var isSpatialNeutral: Bool {
        denoise == 0 && sharpen == 0
    }

    public var isNeutral: Bool {
        isLinearNeutral && isDisplayNeutral && isSpatialNeutral && faceRestore == 0 && superRes == 0
    }

    /// 面板/批量用的夹取：坏值不静默通过，一律收敛到算子能吃的区间。
    public mutating func clamp() {
        exposure = exposure.clamped(to: -2 ... 2)
        temperature = temperature.clamped(to: -100 ... 100)
        tint = tint.clamped(to: -100 ... 100)
        contrast = contrast.clamped(to: -100 ... 100)
        saturation = saturation.clamped(to: -100 ... 100)
        hue = hue.clamped(to: -180 ... 180)
        fillLight = fillLight.clamped(to: 0 ... 100)
        highlightSoften = highlightSoften.clamped(to: 0 ... 100)
        wshHue = wshHue.clamped(to: -180 ... 180); wshSat = wshSat.clamped(to: 0 ... 100); wshLum = wshLum.clamped(to: -100 ... 100)
        wmtHue = wmtHue.clamped(to: -180 ... 180); wmtSat = wmtSat.clamped(to: 0 ... 100); wmtLum = wmtLum.clamped(to: -100 ... 100)
        whlHue = whlHue.clamped(to: -180 ... 180); whlSat = whlSat.clamped(to: 0 ... 100); whlLum = whlLum.clamped(to: -100 ... 100)
        hslHue = normalizeArray(hslHue, count: 8) { $0.clamped(to: -30 ... 30) }
        hslSat = normalizeArray(hslSat, count: 8) { $0.clamped(to: -100 ... 100) }
        hslLum = normalizeArray(hslLum, count: 8) { $0.clamped(to: -100 ... 100) }
        denoise = denoise.clamped(to: 0 ... 100)
        sharpen = sharpen.clamped(to: 0 ... 100)
        if curves.count != 4 { curves = Array(repeating: .identity, count: 4) }
        for i in curves.indices where !curves[i].isValid { curves[i] = .identity }
        bgR = bgR.clamped(to: 0 ... 255); bgG = bgG.clamped(to: 0 ... 255); bgB = bgB.clamped(to: 0 ... 255)
        bgBlur = bgBlur.clamped(to: 0 ... 100)
        faceRestore = faceRestore.clamped(to: 0 ... 100)
        if ![0, 2, 4].contains(superRes) { superRes = 0 }
    }
}

// MARK: - 单位换算（面板 → 算子）

public extension EditParameters {
    var exposureStops: Double { exposure }
    var temperatureGain: (r: Double, b: Double) {
        let t = temperature / 100
        return (1 + 0.25 * t, 1 - 0.25 * t)
    }
    var tintGain: (g: Double, rb: Double) {
        let t = tint / 100
        return (1 - 0.20 * t, 1 + 0.10 * t)
    }
}

// MARK: - 预设 JSON

extension EditParameters: Codable {
    enum CodingKeys: String, CodingKey {
        case exposure, contrast, temperature, tint, saturation, hue
        case fillLight = "fill_light", highlightSoften = "highlight_soften"
        case wshHue = "wsh_hue", wshSat = "wsh_sat", wshLum = "wsh_lum"
        case wmtHue = "wmt_hue", wmtSat = "wmt_sat", wmtLum = "wmt_lum"
        case whlHue = "whl_hue", whlSat = "whl_sat", whlLum = "whl_lum"
        case hslHue = "hsl_hue", hslSat = "hsl_sat", hslLum = "hsl_lum"
        // 降噪/锐化的键名沿用本仓的 snake_case。imagecake 侧四件（补光/高光柔化/
        // 降噪/锐化）的具体键名尚未逐字核对，因此这两个键按「本仓扩展」对待：
        // 读别人的预设时缺它们就落 0（关闭），不会把未知键当成自家键。
        case denoise, sharpen
        case curveX = "curve_x", curveY = "curve_y"
        case bgEnabled = "bg_enabled", bgR = "bg_r", bgG = "bg_g", bgB = "bg_b", bgBlur = "bg_blur"
        case faceRestore = "face_restore"
        case superRes = "super_res"
        case presetVersion = "preset_version"
        case requires
    }

    /// 已知键集合：读文件时用来点名"认得但没落点"的键。与 CodingKeys 同源，
    /// 加字段时这两处一起改（少改一处的症状是报告里把自家键列为未知）。
    public static let knownKeys: Set<String> = [
        "exposure", "contrast", "temperature", "tint", "saturation", "hue",
        "fill_light", "highlight_soften",
        "wsh_hue", "wsh_sat", "wsh_lum", "wmt_hue", "wmt_sat", "wmt_lum",
        "whl_hue", "whl_sat", "whl_lum", "hsl_hue", "hsl_sat", "hsl_lum",
        "denoise", "sharpen",
        "curve_x", "curve_y", "bg_enabled", "bg_r", "bg_g", "bg_b", "bg_blur",
        "face_restore", "super_res", "preset_version", "requires"
    ]

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? hue
        fillLight = try c.decodeIfPresent(Double.self, forKey: .fillLight) ?? fillLight
        highlightSoften = try c.decodeIfPresent(Double.self, forKey: .highlightSoften) ?? highlightSoften

        wshHue = try c.decodeIfPresent(Double.self, forKey: .wshHue) ?? wshHue
        wshSat = try c.decodeIfPresent(Double.self, forKey: .wshSat) ?? wshSat
        wshLum = try c.decodeIfPresent(Double.self, forKey: .wshLum) ?? wshLum
        wmtHue = try c.decodeIfPresent(Double.self, forKey: .wmtHue) ?? wmtHue
        wmtSat = try c.decodeIfPresent(Double.self, forKey: .wmtSat) ?? wmtSat
        wmtLum = try c.decodeIfPresent(Double.self, forKey: .wmtLum) ?? wmtLum
        whlHue = try c.decodeIfPresent(Double.self, forKey: .whlHue) ?? whlHue
        whlSat = try c.decodeIfPresent(Double.self, forKey: .whlSat) ?? whlSat
        whlLum = try c.decodeIfPresent(Double.self, forKey: .whlLum) ?? whlLum

        hslHue = try c.decodeIfPresent([Double].self, forKey: .hslHue) ?? hslHue
        hslSat = try c.decodeIfPresent([Double].self, forKey: .hslSat) ?? hslSat
        hslLum = try c.decodeIfPresent([Double].self, forKey: .hslLum) ?? hslLum
        denoise = try c.decodeIfPresent(Double.self, forKey: .denoise) ?? denoise
        sharpen = try c.decodeIfPresent(Double.self, forKey: .sharpen) ?? sharpen

        if let xs = try c.decodeIfPresent([[Double]].self, forKey: .curveX),
           let ys = try c.decodeIfPresent([[Double]].self, forKey: .curveY),
           xs.count == 4, ys.count == 4 {
            curves = zip(xs, ys).map { CurveChannel(x: $0, y: $1) }
        }

        bgEnabled = try c.decodeIfPresent(Bool.self, forKey: .bgEnabled) ?? bgEnabled
        bgR = try c.decodeIfPresent(Double.self, forKey: .bgR) ?? bgR
        bgG = try c.decodeIfPresent(Double.self, forKey: .bgG) ?? bgG
        bgB = try c.decodeIfPresent(Double.self, forKey: .bgB) ?? bgB
        bgBlur = try c.decodeIfPresent(Double.self, forKey: .bgBlur) ?? bgBlur
        faceRestore = try c.decodeIfPresent(Double.self, forKey: .faceRestore) ?? faceRestore
        superRes = try c.decodeIfPresent(Int.self, forKey: .superRes) ?? superRes
        presetVersion = try c.decodeIfPresent(Int.self, forKey: .presetVersion) ?? presetVersion
        requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(tint, forKey: .tint)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(hue, forKey: .hue)
        try c.encode(fillLight, forKey: .fillLight)
        try c.encode(highlightSoften, forKey: .highlightSoften)
        try c.encode(wshHue, forKey: .wshHue); try c.encode(wshSat, forKey: .wshSat); try c.encode(wshLum, forKey: .wshLum)
        try c.encode(wmtHue, forKey: .wmtHue); try c.encode(wmtSat, forKey: .wmtSat); try c.encode(wmtLum, forKey: .wmtLum)
        try c.encode(whlHue, forKey: .whlHue); try c.encode(whlSat, forKey: .whlSat); try c.encode(whlLum, forKey: .whlLum)
        try c.encode(hslHue, forKey: .hslHue)
        try c.encode(hslSat, forKey: .hslSat)
        try c.encode(hslLum, forKey: .hslLum)
        try c.encode(denoise, forKey: .denoise)
        try c.encode(sharpen, forKey: .sharpen)
        try c.encode(curves.map(\.x), forKey: .curveX)
        try c.encode(curves.map(\.y), forKey: .curveY)
        try c.encode(bgEnabled, forKey: .bgEnabled)
        try c.encode(bgR, forKey: .bgR)
        try c.encode(bgG, forKey: .bgG)
        try c.encode(bgB, forKey: .bgB)
        try c.encode(bgBlur, forKey: .bgBlur)
        try c.encode(faceRestore, forKey: .faceRestore)
        try c.encode(superRes, forKey: .superRes)
        try c.encode(presetVersion, forKey: .presetVersion)
        // 出厂预设的依赖表必须是空数组：非空就不是"出厂"了。
        try c.encode(requires, forKey: .requires)
    }
}

// MARK: - 小工具

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

func normalizeArray(_ values: [Double], count: Int, _ transform: (Double) -> Double) -> [Double] {
    var out = Array(values.prefix(count)).map(transform)
    if out.count < count { out += Array(repeating: 0, count: count - out.count) }
    return out
}
