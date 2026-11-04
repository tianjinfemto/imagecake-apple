import CoreGraphics
import Foundation

// 换天空。
//
// 先说什么不实现：**光照方向的真实重建、带阴影一致性的合成、镜面水面的
// 二次反射**——这些要生成式/深度权重，本项目不做假实现。这里做的是
// "确定性的天空替换"：区域 → 合成 → 色温靠拢，三步都能离线断言。
//
// 天空区域怎么定（不要分割网络也能站得住的三条判据）：
//   1. **颜色在天空区**：亮度够高（v ≥ 0.30），并且要么偏蓝青（色相 165…265°、
//      饱和上限放到 0.92）、要么接近无彩（s ≤ 0.14，白云/灰天）；
//      饱和上限不能收紧：晴天的蓝在 sRGB 上就是 s ≈ 0.7（实测 0.24/0.47/0.80），
//      拿 0.55 当顶会把一大片真天拒之门外；
//   2. **从画面顶边种子出发**做连通生长（4 邻域）：这一条才是防误判的主力——
//      同一块蓝色如果出现在画面下半部（蓝裙子、蓝车、地上的水洼），它不与顶边
//      连通，就不会被当成天空。所以“蓝的饱和度放宽”不会把蓝裙子换掉；
//   3. 有人像 α 时 α 内不算天空（人不可能是天）。
// 已知边界：紧贴顶边的蓝色物体（如贴着画面上沿的蓝遮光板）会被当成天；
// 色域方案给不出“它是天”这件事，只有连通性可以——这是它的原理性上限。
//
// 已知边界（写清楚，别当成 AI）：
//   · 天空不与顶边相连时（被裁掉的构图、室内天花板）得不到掩码，
//     整段不跑并点名 `[no_sky_mask]`；
//   · 雪景/白墙会满足判据 1，如果它连到顶边就会被换掉——所以掩码占比超过
//     85% 时判为"这不是天，是整面墙"，同样点名不跑；
//   · 建筑边缘、树枝这类细碎轮廓只能靠羽化近似，没有发丝级精度
//     （那需要天空分割权重，缺件时点名 `[fallback:sky-colour-locus]`）。

enum SkyMask {
    /// 蓝青天的饱和上限。给到 0.92 而不是 0.55：晴天的蓝在 sRGB 上本来就
    /// 很浓（实测 0.24/0.47/0.80 的 s = 0.70），收太紧会拒掉真天。
    static let saturatedBlueCeiling = 0.92

    /// 天空候选（显示码 HSV 口径，与 `SkinMask.isSkin` 同一套色域判定的路子）。
    static func isSkyCandidate(r: Double, g: Double, b: Double) -> Bool {
        let (h, s, v) = ColorMath.rgbToHSV(Float(r), Float(g), Float(b))
        guard v >= 0.30 else { return false }
        if s <= 0.14 { return true }                              // 白云 / 灰天
        return s <= Float(saturatedBlueCeiling) && h >= 165 && h <= 265
    }

    /// 从顶边种子做 4 邻域连通生长，返回 0…1 权重图（含羽化）。
    static func build(_ image: DisplayImage, personMask: MaskBuffer? = nil) -> [Float] {
        let size = image.size
        guard size.pixelCount > 0, image.pixels.count >= size.pixelCount * 4 else { return [] }
        let width = size.width, height = size.height
        var candidate = [Bool](repeating: false, count: size.pixelCount)
        image.pixels.withUnsafeBufferPointer { src in
            for i in 0 ..< size.pixelCount {
                let o = i * 4
                candidate[i] = isSkyCandidate(r: Double(src[o]), g: Double(src[o + 1]), b: Double(src[o + 2]))
            }
        }
        var personBytes: [UInt8]? = nil
        if let personMask {
            let resized = personMask.resized(to: size)
            if !resized.isEmpty { personBytes = [UInt8](resized.data) }
        }

        var visited = [Bool](repeating: false, count: size.pixelCount)
        var queue: [Int] = []
        // 种子：顶边那一行里所有满足色域的像素。
        for x in 0 ..< width {
            if candidate[x], !blocked(x, personBytes) {
                visited[x] = true
                queue.append(x)
            }
        }
        guard !queue.isEmpty else { return [] }

        var grown = 0
        while let index = queue.popLast() {
            grown += 1
            let x = index % width, y = index / width
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let next = ny * width + nx
                guard !visited[next], candidate[next], !blocked(next, personBytes) else { continue }
                visited[next] = true
                queue.append(next)
            }
        }
        // 占满整幅：多半是一面白墙或雪原，不是一天。宁可不做，不要把整张图换掉。
        guard grown > 0, Double(grown) / Double(size.pixelCount) < 0.85 else { return [] }

        var bytes = [UInt8](repeating: 0, count: size.pixelCount)
        for i in 0 ..< size.pixelCount where visited[i] { bytes[i] = 255 }
        let mask = MaskOps.feathered(MaskBuffer(size: size, data: Data(bytes)),
                                      radius: Swift.max(1, size.longEdge / 260))
        return SkinMask.weights(mask, size: size)
    }

    private static func blocked(_ index: Int, _ personBytes: [UInt8]?) -> Bool {
        guard let personBytes, index < personBytes.count else { return false }
        return personBytes[index] > 200        // 实心人像内不可能是天空
    }
}

enum SkyEngine {
    /// 合成：把天空权重区换成渐变/导入的那张天，再按 lightMatch 把主体的
    /// 色度往新天的地平线色靠拢。
    static func apply(_ image: DisplayImage, weights: [Float], sky: SkyParameters,
                      photo: DisplayImage?) -> DisplayImage {
        let size = image.size
        guard size.pixelCount > 0, !sky.isNeutral, weights.count == size.pixelCount,
              image.pixels.count >= size.pixelCount * 4 else { return image }
        var maxWeight = Float(0)
        for value in weights { maxWeight = Swift.max(maxWeight, value) }
        guard maxWeight > 0 else { return image }

        let strength = BeautyParameters.unit(sky.strength)
        var pixels = image.pixels
        // 地平线锚点：掩码里"最后一行还有天空"的那一行。用它而不是画面高的固定
        // 比例——俯拍与仰拍的真正地平线差很远，固定比例的症状是渐变天在地平线
        // 处出现一条与画面无关的硬边。
        let horizonY = horizonRow(weights, size: size)
        for i in 0 ..< size.pixelCount {
            let weight = Double(weights[i]) * strength
            guard weight > 0.001 else { continue }
            let x = i % size.width, y = i / size.width
            let target: (r: Double, g: Double, b: Double)
            if sky.mode == .photo, let photo, photo.size.pixelCount > 0 {
                let o = (y * photo.size.width + x) * 4
                guard photo.pixels.count > o + 2 else { continue }
                target = (Double(photo.pixels[o]), Double(photo.pixels[o + 1]), Double(photo.pixels[o + 2]))
            } else {
                target = gradientColor(row: y, horizonRow: horizonY, size: size, sky: sky)
            }
            let o = i * 4
            for c in 0 ..< 3 {
                let source = Double(pixels[o + c])
                let value: Double
                switch c {
                case 0: value = target.r
                case 1: value = target.g
                default: value = target.b
                }
                pixels[o + c] = Float(Swift.min(Swift.max(source + (value - source) * weight, 0), 1))
            }
        }
        if sky.lightMatch > 0 {
            matchLight(&pixels, size: size, weights: weights, sky: sky)
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 渐变天：从画面顶到地平线做一次插值，地平线以下继续往地平线色收。
    /// t = 0 在顶、1 在地平线；超过地平线后保持 1（近地面处仍是天光色，
    /// 因为这一段通常本来就被掩码覆盖了）。
    static func gradientColor(row y: Int, horizonRow: Int, size: PixelSize, sky: SkyParameters)
        -> (r: Double, g: Double, b: Double) {
        let (tr, tg, tb) = HexColor.rgb(sky.topHex)
        let (hr, hg, hb) = HexColor.rgb(sky.horizonHex)
        let span = Swift.max(1.0, Double(horizonRow))
        let t = Swift.min(1.0, Swift.max(0.0, Double(y) / span))
        // smoothstep：线性渐变在照片里会被看成"一条一条的带"，天光本来就不是线性变的。
        let e = t * t * (3 - 2 * t)
        return (tr + (hr - tr) * e, tg + (hg - tg) * e, tb + (hb - tb) * e)
    }

    /// 掩码的最底行（地平线锚点）。全零时返回画布高，让渐变仍能算出比例。
    static func horizonRow(_ weights: [Float], size: PixelSize) -> Int {
        guard size.height > 0, weights.count == size.pixelCount else { return max(1, size.height) }
        var last = 0
        for y in 0 ..< size.height {
            let row = y * size.width
            for x in 0 ..< size.width where weights[row + x] > 0.5 {
                last = y
            }
        }
        return Swift.max(1, last)
    }

    /// 光照匹配：只改**非天空**像素的色度，把主体往"新天地平线色的方向"推一点。
    ///
    /// 不动亮度：这条算子的目的只是消掉"人在暖光下、天是新的一天"的色彩脱节，
    /// 顺手改亮度就等于动了曝光，那是调色栏的事。
    static func matchLight(_ pixels: inout [Float], size: PixelSize, weights: [Float], sky: SkyParameters) {
        let count = size.pixelCount
        guard count > 0, weights.count == count, pixels.count >= count * 4 else { return }
        let k = BeautyParameters.unit(sky.lightMatch) * 0.5
        guard k > 0.001 else { return }
        let (hr, hg, hb) = HexColor.rgb(sky.horizonHex)
        let target = BeautyEngine.opponent(r: hr, g: hg, b: hb)
        for i in 0 ..< count {
            // 天空区不参与（那里已经是新天）；只把主体带向新天光。
            guard Double(weights[i]) < 0.35 else { continue }
            let o = i * 4
            let source = BeautyEngine.opponent(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
            let rgb = BeautyEngine.fromOpponent(l: source.l,
                                                a: source.a + (target.a - source.a) * k,
                                                b: source.b + (target.b - source.b) * k)
            pixels[o] = Float(Swift.min(Swift.max(rgb.r, 0), 1))
            pixels[o + 1] = Float(Swift.min(Swift.max(rgb.g, 0), 1))
            pixels[o + 2] = Float(Swift.min(Swift.max(rgb.b, 0), 1))
        }
    }
}

// MARK: - 导入的天空图

/// 与 `LUTLibrary` 同一套路子：导入的文件落在 App 的文档目录里，参数只存
/// **文件名**；找不到就点名 `[no_sky:名字]` 并整段不跑，绝不拿内置渐变冒充
/// "用户导入的那张天"。
enum SkyLibrary {
    static var directory: URL? {
        guard let base = try? FileManager.default.url(for: .documentDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        let dir = base.appendingPathComponent("ImageCake", isDirectory: true)
            .appendingPathComponent("Skies", isDirectory: true)
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

    /// 读并缩放到画布尺寸（cover 语义：等比填满后居中裁，天空不留黑边）。
    static func load(name: String, canvas: PixelSize) async -> DisplayImage? {
        guard let dir = directory else { return nil }
        let base = dir.appendingPathComponent(name)
        let candidates = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff"].map { base.appendingPathExtension($0) }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let loaded = try? await ImageLoader.load(url: url, maxEdge: 0) else { return nil }
            return coverFit(display(from: loaded.linear), to: canvas)
        }
        return nil
    }

    /// 线性档 → 显示域。天空图要走的是与主图同一层的合成（都在 ToneEngine 之后
    /// 的显示域逐像素混合），所以它必须先过 sRGB OETF；拿线性值直接合成会得
    /// 到"天比主体暗得多"的假天。
    static func display(from linear: LinearImage) -> DisplayImage {
        linear.toDisplay()
    }

    /// 等比填满 + 居中裁。与 `CollageEngine.fit(.aspectFill)` 同语义，但作用在
    /// 显示域（天空要参与后续逐像素合成，不该先量化成 8bit）。
    static func coverFit(_ image: DisplayImage, to canvas: PixelSize) -> DisplayImage {
        guard image.size.pixelCount > 0, canvas.pixelCount > 0 else { return image }
        let sx = Double(canvas.width) / Double(image.size.width)
        let sy = Double(canvas.height) / Double(image.size.height)
        let scale = Swift.max(sx, sy)
        let upscaled = image.resized(to: PixelSize(
            width: Swift.max(canvas.width, Int((Double(image.size.width) * scale).rounded())),
            height: Swift.max(canvas.height, Int((Double(image.size.height) * scale).rounded()))))
        let offsetX = (upscaled.size.width - canvas.width) / 2
        let offsetY = (upscaled.size.height - canvas.height) / 2
        return upscaled.cropped(to: PixelRect(x: Swift.max(0, offsetX), y: Swift.max(0, offsetY),
                                              width: canvas.width, height: canvas.height))
    }
}
