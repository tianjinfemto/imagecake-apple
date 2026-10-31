import Foundation

// 3D/1D 查找表滤镜（.cube）与内置风格。
//
// 为什么用 LUT 而不是继续加滑杆：滤镜是"整条色彩曲线的形状"，用滑杆表达
// 不出来（一个"胶片感"要同时抬黑、压白、给阴影加绿、把高光推向橙）。
// 一张 17³ 的表把这些压成一个确定性函数，逐点查 + 三线性插值，
// 不依赖任何网络，也不需要第三方色彩引擎。
//
// .cube 的读法照 Adobe 规范里被各家实现接受的那一套：
//   · 注释行以 # 开头；空行跳过；
//   · LUT_3D_SIZE n（或 LUT_1D_SIZE n）；DOMAIN_MIN/MAX 支持但不参与采样
//     —— 我们的输入恒在 0…1，域不是 [0,1] 时点名 `[bad_lut:domain]`；
//   · 数据行按**红最快、其次绿、最后蓝**的顺序枚举，所以
//     平坦下标 = b·n² + g·n + r。这条一旦写反，得到的症状是"红蓝通道串色"，
//     所以有一条专门的断言把它钉住。
//
// 强度不是"把表调淡"，而是原像素与查表结果线性混合：
// 这才让 0 强度是**逐比特恒等**（预设同步、批量套用都依赖这条）。

struct CubeLUT: Equatable, Sendable {
    let size: Int
    /// RGB 三元组，平坦下标 = b·size² + g·size + r。值域 [0,1]。
    let data: [Float]
    /// 1D LUT（逐通道曲线）。1D 表当"三通道共用一条曲线"处理，
    /// 所以采样时忽略 G/B 维。
    let is1D: Bool

    var isValid: Bool {
        guard size >= 2 else { return false }
        return data.count == (is1D ? size : size * size * size) * 3
    }

    @inline(__always)
    private func index(_ r: Int, _ g: Int, _ b: Int) -> Int {
        is1D ? r : (b * size + g) * size + r
    }

    /// 三线性插值取样。输入输出都是显示码 0…1（越界先夹）。
    func sample(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        guard isValid else { return (r, g, b) }
        func axis(_ v: Double) -> (i0: Int, i1: Int, f: Double) {
            let clamped = Swift.min(Swift.max(v, 0), 1)
            let pos = clamped * Double(size - 1)
            let i0 = Swift.min(Int(pos), size - 1)
            return (i0, Swift.min(i0 + 1, size - 1), pos - Double(i0))
        }
        let ra = axis(r)
        if is1D {
            // 1D 表是**逐通道各自**的一条曲线：红查红的位、绿查绿的位，
            // 三个输出分量各取自己那条。当成"一条共用曲线"会把彩色表洗成灰。
            func channelValue(_ v: Double, _ channel: Int) -> Double {
                let a = axis(v)
                let lo = Double(data[a.i0 * 3 + channel])
                let hi = Double(data[a.i1 * 3 + channel])
                return lo + (hi - lo) * a.f
            }
            return (channelValue(r, 0), channelValue(g, 1), channelValue(b, 2))
        }
        // 3D 表：红最快、绿次之、蓝最慢（与 parse 的下标同一套约定）。
        let ga = axis(g)
        let ba = axis(b)
        let fx = ra.f, fy = ga.f, fz = ba.f

        func corner(_ i: Int, _ j: Int, _ k: Int, _ channel: Int) -> Double {
            Double(data[index(i, j, k) * 3 + channel])
        }
        var result: (Double, Double, Double) = (0, 0, 0)
        for channel in 0 ..< 3 {
            let c000 = corner(ra.i0, ga.i0, ba.i0, channel)
            let c100 = corner(ra.i1, ga.i0, ba.i0, channel)
            let c010 = corner(ra.i0, ga.i1, ba.i0, channel)
            let c110 = corner(ra.i1, ga.i1, ba.i0, channel)
            let c001 = corner(ra.i0, ga.i0, ba.i1, channel)
            let c101 = corner(ra.i1, ga.i0, ba.i1, channel)
            let c011 = corner(ra.i0, ga.i1, ba.i1, channel)
            let c111 = corner(ra.i1, ga.i1, ba.i1, channel)
            let x00 = c000 + (c100 - c000) * fx
            let x10 = c010 + (c110 - c010) * fx
            let x01 = c001 + (c101 - c001) * fx
            let x11 = c011 + (c111 - c011) * fx
            let y0 = x00 + (x10 - x00) * fy
            let y1 = x01 + (x11 - x01) * fy
            let value = y0 + (y1 - y0) * fz
            if channel == 0 { result.0 = value } else if channel == 1 { result.1 = value } else { result.2 = value }
        }
        return result
    }
}

// MARK: - 解析

enum LUTParseError: LocalizedError {
    case noSize
    case count(expected: Int, got: Int)
    case badNumber(line: Int)
    case domain
    case noDirectory

    var errorDescription: String? {
        switch self {
        case .noSize: return "[bad_lut] 没有 LUT_3D_SIZE / LUT_1D_SIZE 行"
        case .count(let expected, let got): return "[bad_lut] 期望 \(expected) 项，读到 \(got) 项"
        case .badNumber(let line): return "[bad_lut] 第 \(line) 行不是三个数字"
        case .domain: return "[bad_lut:domain] 输入域不是 0…1，本引擎不接受"
        case .noDirectory: return "[no_lut_dir] 建不出 LUTs 目录，导入无法落盘"
        }
    }
}

enum LUTParser {
    /// 解析 .cube 文本。失败抛 LUTParseError（UI/报告原样显示令牌）。
    static func parse(_ text: String) throws -> CubeLUT {
        var size = 0
        var is1D = false
        var values: [Float] = []
        var lineNumber = 0

        for raw in text.split(whereSeparator: \.isNewline) {
            lineNumber += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("TITLE") { continue }
            if upper.hasPrefix("LUT_3D_SIZE") || upper.hasPrefix("LUT_1D_SIZE") {
                is1D = upper.hasPrefix("LUT_1D_SIZE")
                let parts = line.split(separator: " ").compactMap { Int($0) }
                guard let n = parts.last, n >= 2, n <= 256 else { throw LUTParseError.noSize }
                size = n
                continue
            }
            if upper.hasPrefix("DOMAIN_MIN") || upper.hasPrefix("DOMAIN_MAX") {
                let nums = line.split(separator: " ").dropFirst().compactMap { Double($0) }
                if upper.hasPrefix("DOMAIN_MIN"), nums.contains(where: { $0 > 1e-6 }) { throw LUTParseError.domain }
                if upper.hasPrefix("DOMAIN_MAX"), nums.contains(where: { abs($0 - 1) > 1e-6 }) { throw LUTParseError.domain }
                continue
            }
            let nums = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
                .filter { !$0.isEmpty }
                .map { Double($0) }
            guard nums.count == 3, let r = nums[0], let g = nums[1], let b = nums[2] else {
                throw LUTParseError.badNumber(line: lineNumber)
            }
            values += [Float(Swift.min(Swift.max(r, 0), 1)),
                       Float(Swift.min(Swift.max(g, 0), 1)),
                       Float(Swift.min(Swift.max(b, 0), 1))]
        }

        guard size >= 2 else { throw LUTParseError.noSize }
        let expected = (is1D ? size : size * size * size) * 3
        guard values.count == expected else {
            throw LUTParseError.count(expected: expected, got: values.count)
        }
        let lut = CubeLUT(size: size, data: values, is1D: is1D)
        guard lut.isValid else { throw LUTParseError.count(expected: expected, got: values.count) }
        return lut
    }

    /// 把 CubeLUT 写成 .cube 文本（导出预设包/自检用）。与 parse 互为逆：
    /// 有一条往返断言钉着，避免"读进来是对的、存出去就串色"。
    static func serialize(_ lut: CubeLUT, title: String = "ImageCake") -> String {
        var lines = ["# ImageCake 3D LUT", "TITLE \"\(title)\"", "\(lut.is1D ? "LUT_1D_SIZE" : "LUT_3D_SIZE") \(lut.size)"]
        if lut.is1D {
            for r in 0 ..< lut.size {
                let o = r * 3
                lines.append("\(lut.data[o]) \(lut.data[o + 1]) \(lut.data[o + 2])")
            }
        } else {
            for b in 0 ..< lut.size {
                for g in 0 ..< lut.size {
                    for r in 0 ..< lut.size {
                        let o = ((b * lut.size + g) * lut.size + r) * 3
                        lines.append("\(lut.data[o]) \(lut.data[o + 1]) \(lut.data[o + 2])")
                    }
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - 内置风格

/// 风格 = 一个逐点函数，采样成 17³ 的表再进 CubeLUT。
/// 为什么不直接把函数用在像素上：滑杆强度、预设往返、与 .cube 同一套混合
/// 逻辑——全部只需要一条 apply 路径。
struct FilterStyle: Sendable {
    var id: String
    var title: String
    /// 满力度的映射（显示码 0…1 进、0…1 出）。函数体必须夹到 [0,1]。
    var grade: @Sendable (Double, Double, Double) -> (Double, Double, Double)
}

/// 风格里的逐点函数共用的小工具。写成文件级私有函数而不是枚举内的
/// 静态成员，是因为它们只在 `static let styles` 的**闭包字面量**里用；
/// 那种位置上的未限定静态成员引用在不同 Swift 版本上解析得不一样。
@inline(__always)
private func lutClamp01(_ v: Double) -> Double { Swift.min(Swift.max(v, 0), 1) }

@inline(__always)
private func lutSmoothStep(_ v: Double) -> Double {
    let x = lutClamp01(v)
    return x * x * (3 - 2 * x)
}

enum FilterEngine {
    /// 采样精度。17 是"肉眼看不出分段 + 表只有 14KB"的平衡点。
    static let builtInSize = 17

    static let styles: [FilterStyle] = [
        FilterStyle(id: "teal-orange", title: "青橙") { r, g, b in
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let cold = Swift.max(0, 0.5 - y) * 0.6      // 阴影偏青：压红、抬蓝
            let warm = Swift.max(0, y - 0.5) * 0.5      // 高光偏暖：抬红、压蓝
            return (lutClamp01(r - cold * 0.30 + warm * 0.28),
                    lutClamp01(g - cold * 0.06 + warm * 0.10),
                    lutClamp01(b + cold * 0.26 - warm * 0.24))
        },
        FilterStyle(id: "film", title: "胶片") { r, g, b in
            // 每个通道走同一条一维曲线（抬黑 0.035、中间 S 形），再给阴影
            // 加一点绿。抬黑必须在**三个通道**上同时成立，否则黑场会偏色——
            // 所以不做"按亮度比例缩放"那种写法。
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            func tone(_ v: Double) -> Double {
                0.035 + lutSmoothStep(v * 1.12 - 0.06) * 0.915
            }
            let shadow = Swift.max(0, 0.35 - y) * 0.06
            return (lutClamp01(tone(r) - shadow * 0.5),
                    lutClamp01(tone(g) + shadow),
                    lutClamp01(tone(b) - shadow * 0.3))
        },
        FilterStyle(id: "mono", title: "黑白") { r, g, b in
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let v = lutClamp01(0.5 + (y - 0.5) * 1.18)
            return (v, v, v)
        },
        FilterStyle(id: "cream", title: "奶油") { r, g, b in
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let lift = Swift.max(0, 0.45 - y) * 0.22
            return (lutClamp01(r + lift + 0.02), lutClamp01(g + lift + 0.01), lutClamp01(b + lift * 0.7))
        },
        FilterStyle(id: "cool", title: "冷调") { r, g, b in
            (lutClamp01(r * 0.95), lutClamp01(g * 1.00 + 0.01), lutClamp01(b * 1.08 + 0.02))
        },
        FilterStyle(id: "warm", title: "暖阳") { r, g, b in
            (lutClamp01(r * 1.08 + 0.02), lutClamp01(g * 1.02), lutClamp01(b * 0.93))
        },
        FilterStyle(id: "bleach", title: "漂白") { r, g, b in
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            // 饱和度砍一半 + 整体提亮：经典 bleach bypass 的确定版本。
            let mix = 0.5
            return (lutClamp01(y + (r - y) * mix + 0.04),
                    lutClamp01(y + (g - y) * mix + 0.03),
                    lutClamp01(y + (b - y) * mix + 0.03))
        },
        FilterStyle(id: "kodak", title: "正片") { r, g, b in
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let contrast = lutClamp01(0.5 + (y - 0.5) * 1.10)
            let delta = y > 1e-4 ? contrast / y : 0
            return (lutClamp01(r * delta * 1.02), lutClamp01(g * delta), lutClamp01(b * delta * 0.97))
        },
    ]

    static func style(id: String) -> FilterStyle? {
        styles.first { $0.id == id }
    }

    /// 把风格的逐点函数采样成表。同一 id 每次得到同一张表（无随机、无状态）。
    static func lut(for style: FilterStyle, size: Int = FilterEngine.builtInSize) -> CubeLUT {
        let n = Swift.max(2, size)
        var data = [Float](repeating: 0, count: n * n * n * 3)
        for b in 0 ..< n {
            for g in 0 ..< n {
                for r in 0 ..< n {
                    let out = style.grade(Double(r) / Double(n - 1),
                                          Double(g) / Double(n - 1),
                                          Double(b) / Double(n - 1))
                    let o = ((b * n + g) * n + r) * 3
                    data[o] = Float(clamp01(out.0))
                    data[o + 1] = Float(clamp01(out.1))
                    data[o + 2] = Float(clamp01(out.2))
                }
            }
        }
        return CubeLUT(size: n, data: data, is1D: false)
    }

    /// 按名字找表：先内置，再问 LUTLibrary 拿导入的。找不到返回 nil，
    /// 调用侧点名 `[no_lut:name]`——滤镜"悄悄没生效"是最难查的一类问题。
    static func resolve(name: String) -> CubeLUT? {
        guard !name.isEmpty else { return nil }
        if let style = style(id: name) { return lut(for: style) }
        return LUTLibrary.imported(name: name)
    }

    /// 应用滤镜。strength = 0 或表无效 → **逐比特恒等**（原数组直接返回）。
    static func apply(_ image: DisplayImage, lut: CubeLUT, strength: Double) -> DisplayImage {
        let amount = Swift.min(Swift.max(strength, 0), 100) / 100
        guard amount > 0, lut.isValid, image.size.pixelCount > 0 else { return image }
        var pixels = image.pixels
        for i in 0 ..< image.size.pixelCount {
            let o = i * 4
            let out = lut.sample(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
            pixels[o] = Float(Double(pixels[o]) + (out.r - Double(pixels[o])) * amount)
            pixels[o + 1] = Float(Double(pixels[o + 1]) + (out.g - Double(pixels[o + 1])) * amount)
            pixels[o + 2] = Float(Double(pixels[o + 2]) + (out.b - Double(pixels[o + 2])) * amount)
        }
        return DisplayImage(size: image.size, pixels: pixels)
    }

    @inline(__always)
    static func clamp01(_ v: Double) -> Double {
        Swift.min(Swift.max(v, 0), 1)
    }
}

// MARK: - 导入表的存放

/// 导入的 .cube 落在文稿目录 ImageCake/LUTs/ 下，按文件名当 id。
/// 预设里只存名字（与 `requires` 的"外部资产只登记"口径一致）：换设备时
/// 表可能不在，那时渲染点名 `[no_lut:xxx]` 而不是给你一张没加滤镜的图。
enum LUTLibrary {
    static var directory: URL? {
        guard let base = try? FileManager.default.url(for: .documentDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        let dir = base.appendingPathComponent("ImageCake", isDirectory: true)
            .appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func importedNames() -> [String] {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "cube" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    static func imported(name: String) -> CubeLUT? {
        guard let dir = directory else { return nil }
        let url = dir.appendingPathComponent(name).appendingPathExtension("cube")
        // 渲染每帧都要拿表，所以表只读一次盘：解析 17³ 是毫秒级，
        // 但每帧读文件 + 解析在拖动滑杆时会变成明显的卡顿。
        LUTLibrary.lock.lock()
        defer { LUTLibrary.lock.unlock() }
        if let cached = LUTLibrary.cache[name] { return cached }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let lut = try? LUTParser.parse(text) else { return nil }
        LUTLibrary.cache[name] = lut
        return lut
    }

    /// 丢弃缓存（导入/删除表之后调）。
    static func invalidateCache() {
        LUTLibrary.lock.lock()
        defer { LUTLibrary.lock.unlock() }
        LUTLibrary.cache.removeAll()
    }

    private static var cache: [String: CubeLUT] = [:]
    private static let lock = NSLock()

    /// 导入一份 .cube。返回表与落盘后的名字；坏表抛错（调用侧显示令牌）。
    @discardableResult
    static func install(from url: URL) throws -> (name: String, lut: CubeLUT) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lut = try LUTParser.parse(text)
        let name = url.deletingPathExtension().lastPathComponent
        guard let dir = directory else {
            throw LUTParseError.noDirectory
        }
        let target = dir.appendingPathComponent(name).appendingPathExtension("cube")
        try text.write(to: target, atomically: true, encoding: .utf8)
        invalidateCache()
        return (name, lut)
    }
}
