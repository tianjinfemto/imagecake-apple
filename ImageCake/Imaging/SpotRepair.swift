import CoreGraphics
import Foundation

/// 背景平坦区污点检出（P1-③）。
///
/// 状态：**内核已验证，尚未接 UI 动作**。镜像脚本先复现了上一轮失败的那三种尺寸
/// （3×3 / 5×5 / 7×7 灰斑各检出 1 个，平坦与细纹理各 0 个，网格被截到上限 24），
/// 并且核对了"环域统计"的两种算法一致（积分图 vs 直接累加，随机数据最大差 2e-14）。
///
/// 判据要的是**环域**统计（挖掉中心的内外盒之差）：含污点自己的窗口会被污点本身
/// 撑大方差 —— 3×3 灰点在 5×5 窗内方差 0.037，而细纹理夹具才 0.062，两者差不到两倍，
/// 阈值怎么调都是漏检或误检。
///
/// 上一轮的具体错法记录在这儿，免得再犯：那次也用环域代数，但把两个均值取自
/// `BeautyEngine.blurredChannel` —— 它是**三遍盒式≈高斯**，权重非均匀，于是
/// `(m₂·n₂ − m₁·n₁)/(n₂−n₁)` 不再是环均值。所以这里的盒均值一律用本文件内的
/// 单遍滑窗（均匀权重），不借用那个近似算子。
enum SpotRepair {
    struct Finding: Equatable, Sendable {
        var at: CGPoint
        var radius: Double
        var source: CGPoint
    }

    static let darkLimit = 0.10
    static let flatLimit = 0.0016
    static let maxFindings = 24
    static let suppression = 4

    /// 内外两半径。环必须比典型灰点大一圈，又不能大到把邻点圈进来。
    static func radii(longEdge: Int) -> (inner: Int, outer: Int) {
        let r1 = Swift.max(3, longEdge / 26)
        return (r1, Swift.max(r1 + 4, longEdge / 10))
    }

    /// 单遍可分离盒均值（均匀权重）。用 Double 累加：后面要做两次"盒差"来反解环域
    /// 统计，Float 的位数在这种减法里不够用。
    static func boxMeans(_ values: [Double], size: PixelSize, radius: Int) -> [Double] {
        let w = size.width
        let h = size.height
        let window = Double(2 * radius + 1)
        var horizontal = [Double](repeating: 0, count: values.count)
        for y in 0 ..< h {
            let row = y * w
            var sum: Double = 0
            for x in -radius ... radius {
                sum += values[row + Swift.min(Swift.max(x, 0), w - 1)]
            }
            for x in 0 ..< w {
                horizontal[row + x] = sum / window
                sum -= values[row + Swift.min(Swift.max(x - radius, 0), w - 1)]
                sum += values[row + Swift.min(Swift.max(x + radius + 1, 0), w - 1)]
            }
        }
        var out = horizontal
        for x in 0 ..< w {
            var sum: Double = 0
            for y in -radius ... radius {
                sum += horizontal[Swift.min(Swift.max(y, 0), h - 1) * w + x]
            }
            for y in 0 ..< h {
                out[y * w + x] = sum / window
                sum -= horizontal[Swift.min(Swift.max(y - radius, 0), h - 1) * w + x]
                sum += horizontal[Swift.min(Swift.max(y + radius + 1, 0), h - 1) * w + x]
            }
        }
        return out
    }

    static func detect(_ image: DisplayImage,
                       faceBounds: CGRect? = nil) -> (found: [Finding], tokens: [String]) {
        let size = image.size
        let count = size.pixelCount
        let w = size.width
        let h = size.height
        let (r1, r2) = radii(longEdge: size.longEdge)
        // 内缩 outer：靠边的窗口会被复制像素污染，环统计就不是真正的环了。
        guard count >= 64, w > 2 * r2 + 1, h > 2 * r2 + 1 else {
            return ([], ["[too_small]"])
        }
        let px = image.pixels
        var luma = [Double](repeating: 0, count: count)
        var isSkin = [Bool](repeating: false, count: count)
        for i in 0 ..< count {
            let o = i * 4
            let r = Double(px[o]), g = Double(px[o + 1]), b = Double(px[o + 2])
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            isSkin[i] = SkinMask.isSkin(r: r, g: g, b: b)
        }
        var lumaSquare = [Double](repeating: 0, count: count)
        for i in 0 ..< count { lumaSquare[i] = luma[i] * luma[i] }

        let meanInner = boxMeans(luma, size: size, radius: r1)
        let meanOuter = boxMeans(luma, size: size, radius: r2)
        let sqInner = boxMeans(lumaSquare, size: size, radius: r1)
        let sqOuter = boxMeans(lumaSquare, size: size, radius: r2)
        let n1 = Double((2 * r1 + 1) * (2 * r1 + 1))
        let n2 = Double((2 * r2 + 1) * (2 * r2 + 1))
        let cells = n2 - n1
        guard cells > 0 else { return ([], ["[too_small]"]) }

        var candidates: [(index: Int, depth: Double)] = []
        for y in (r2 + 1) ..< (h - r2 - 1) {
            for x in (r2 + 1) ..< (w - r2 - 1) {
                let i = y * w + x
                if isSkin[i] { continue }
                let ringMean = (meanOuter[i] * n2 - meanInner[i] * n1) / cells
                let ringSquare = (sqOuter[i] * n2 - sqInner[i] * n1) / cells
                let ringVariance = Swift.max(0, ringSquare - ringMean * ringMean)
                guard ringVariance < flatLimit else { continue }
                let depth = ringMean - luma[i]
                guard depth > darkLimit else { continue }
                candidates.append((i, depth))
            }
        }
        guard !candidates.isEmpty else { return ([], ["[spot-repair:none]"]) }

        if let box = faceBounds, box.width > 0, box.height > 0 {
            candidates.removeAll { entry in
                let p = CGPoint(x: CGFloat(entry.index % w) / CGFloat(w),
                                y: CGFloat(entry.index / w) / CGFloat(h))
                return box.insetBy(dx: -0.02, dy: -0.02).contains(p)
            }
            guard !candidates.isEmpty else { return ([], ["[spot-repair:none]"]) }
        }

        // 深度并列时按下标定序：Swift 的 sort 不保证稳定，只比深度的话同一输入两次
        // 可能选出不同的一个点，检出结果就不可复现（并串对照那类断言会假红）。
        candidates.sort { a, b in
            if a.depth != b.depth { return a.depth > b.depth }
            return a.index < b.index
        }
        let spotRadius = Double(Swift.max(3, size.longEdge / 120)) / Double(size.longEdge)
        var taken = Set<Int>()
        var found: [Finding] = []
        for candidate in candidates {
            if found.count >= maxFindings { break }
            if taken.contains(candidate.index) { continue }
            let x = candidate.index % w
            let y = candidate.index / w
            for dy in (-suppression)...suppression {
                for dx in (-suppression)...suppression {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, ny >= 0, nx < w, ny < h { taken.insert(ny * w + nx) }
                }
            }
            let at = CGPoint(x: CGFloat(x) / CGFloat(w), y: CGFloat(y) / CGFloat(h))
            let source = CGPoint(x: at.x, y: min(1, at.y + CGFloat(spotRadius * 4)))
            found.append(Finding(at: at, radius: spotRadius, source: source))
        }
        var tokens = ["[spot-repair:\(found.count)]"]
        if candidates.count > maxFindings { tokens.append("[spot-repair:capped]") }
        if faceBounds == nil { tokens.append("[no_face_box]") }
        return (found, tokens)
    }
}
