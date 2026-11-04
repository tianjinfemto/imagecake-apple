import CoreGraphics
import Foundation

// 重复帧指纹（好片初筛的第四轴）：把连拍里"同一机位几乎没动的几张"并成一组，
// 让批量修图与出片只处理每组的一张。全本地、零权重、不宣称美学判断。
//
// 为什么值得做：棚拍一次快门按下就是 3~8 张，逐张同步参数与逐张出片的成本是
// 白付的。像素蛋糕把这件事叫"AI 挑图"，其中**能确定性判定的只有"是不是同一帧"**；
// "哪张更好看"要权重，本仓不装会挑（所以组内只按输入序给一个代表，见 `Grouping.representatives`）。
//
// 做法是 dHash：把显示域亮度分成 9×8 的**盒平均**网格（不是每格取一个像素——
// 单像素采样对噪点敏感到会淹没信号），每行比较左右相邻格，`左 > 右` 记 1。
// 盒平均而不是重采样到 9×8：本仓的 `Resampler` 是带 alpha 加权的面积平均，
// 指纹不需要那套，多一层依赖就多一处会随重构变掉的地方。
//
// 阈值 8 是实测出来的，不是抄来的数（镜像脚本 dhash_mirror2，夹具 256×192，
// 与真实管线同一尺寸；为什么必须是这个尺寸：同一份夹具在 64×48 上量到"机震 1px
// 差 11 位"，因为 1px 相当于格宽的 14%，而 256 缩略图上机震 1~3px 不到格宽的 1%
// —— 夹具尺寸会直接改变结论，所以断言必须在真实尺寸上做）：
//   · 该并的：同一帧 0、机震 1~3px 0、机震 6px 5、曝光 +0.05 是 4、人动 10px 是 2
//   · 不该并的：换了构图 19、另一张片子 30、另一种内容 35
//   · **明知判错的**：高 ISO 条纹噪声 ±0.02 是 11、反差 +10% 是 12、人动了 30px 是 10
//     —— 这三类落在阈值外，会被判成不同帧。这是有意的取舍：**漏判只是多修一张，
//     误判会让人只修代表张而丢掉一张真不同的片子**。代价写在这里而不是藏起来。
//
// 平场必须排除，而且不许自定口径：两张毫无关系的纯色图哈希**完全相同**（镜像实测
// 距离 0，因为每一格都比不出大小、所有位都是 0）。是否"没有内容"复用 `FrameTriage`
// 的逐像素亮度方差与同一个 `flatLimit`（0.0015），不在这里另定一个"格极差"阈值——
// 格极差会把棋盘格这类高频内容误判成平场（镜像实测极差只有 0.0188），而同一件事
// 出现两个口径迟早对不上。

/// 重复帧指纹与分组。纯函数、零依赖、可离线断言。
enum FrameHash {
    /// 网格列数/行数。位数 = rows × (columns − 1) = 64。
    static let columns = 9
    static let rows = 8
    static let bitCount = rows * (columns - 1)

    /// 判"同一机位几乎没动"的位数上限，全部依据见文件头的实测表。
    static let sameFrameLimit = 8

    /// 一格至少要 2×2 像素才做盒平均；比这更小的图量不出指纹（返回 nil 并点名，
    /// 不拿单像素采样冒充一个能比较的哈希）。
    static let minCellSide = 2

    /// 一张图的指纹。
    struct Fingerprint: Equatable, Sendable {
        var bits: UInt64
        /// 网格里最亮格与最暗格的差，只用于诊断（不参与分组判定）。
        var spread: Double
    }

    /// 一个待分组的候选帧。
    struct Frame: Equatable, Sendable {
        var name: String
        /// nil = 图太小或读不到，不参与分组，但要数进报告。
        var fingerprint: Fingerprint?
        /// 由调用侧按 `FrameTriage` 的方差口径判定：平场不参与分组。
        var flat: Bool

        init(name: String, fingerprint: Fingerprint?, flat: Bool = false) {
            self.name = name
            self.fingerprint = fingerprint
            self.flat = flat
        }
    }

    /// 9×8 盒平均亮度网格。逐格在像素矩形内累加（行主序、Double 累加），
    /// 覆盖整个画幅且每格互不重叠，所以同图同指纹是构造事实。
    static func grid(_ image: DisplayImage) -> [[Double]]? {
        let w = image.size.width
        let h = image.size.height
        guard w >= columns * minCellSide, h >= rows * minCellSide,
              image.pixels.count >= w * h * 4 else { return nil }
        let px = image.pixels
        var out: [[Double]] = []
        out.reserveCapacity(rows)
        for r in 0 ..< rows {
            let y0 = r * h / rows
            let y1 = (r + 1) * h / rows
            var line: [Double] = []
            line.reserveCapacity(columns)
            for c in 0 ..< columns {
                let x0 = c * w / columns
                let x1 = (c + 1) * w / columns
                var sum = 0.0
                var taken = 0
                for y in y0 ..< y1 {
                    let rowOffset = y * w
                    for x in x0 ..< x1 {
                        let o = (rowOffset + x) * 4
                        sum += Double(ColorMath.luma(px[o], px[o + 1], px[o + 2]))
                        taken += 1
                    }
                }
                line.append(taken > 0 ? sum / Double(taken) : 0)
            }
            out.append(line)
        }
        return out
    }

    /// 指纹。图太小或像素数与画幅不符时返回 nil（调用侧数进报告，不静默）。
    static func fingerprint(_ image: DisplayImage) -> Fingerprint? {
        guard let cells = grid(image) else { return nil }
        var bits: UInt64 = 0
        var low = Double.infinity
        var high = -Double.infinity
        for r in 0 ..< rows {
            let row = cells[r]
            for v in row {
                low = Swift.min(low, v)
                high = Swift.max(high, v)
            }
            for c in 0 ..< columns - 1 where row[c] > row[c + 1] {
                // 相等时记 0：比较是 strict `>`，所以并列格给的是确定的 0 而不是
                // 依赖遍历顺序的结果（平场图因此得到全 0 的哈希，也正是它必须被排除的原因）。
                bits |= 1 << UInt64(r * (columns - 1) + c)
            }
        }
        guard low.isFinite, high.isFinite else { return nil }
        return Fingerprint(bits: bits, spread: high - low)
    }

    /// 汉明距离：两个指纹有多少位不同。
    static func distance(_ a: Fingerprint, _ b: Fingerprint) -> Int {
        (a.bits ^ b.bits).nonzeroBitCount
    }

    /// 分组结果。
    struct Grouping: Equatable, Sendable {
        /// 每组的下标（升序），只保留 ≥2 张的组；组间按首个下标升序。
        var groups: [[Int]]
        /// 平场跳过的张数（与 `FrameTriage.flatLimit` 同一个判据）。
        var ignoredFlat: Int
        /// 量不出指纹的张数（图太小/读不到）。
        var ignoredUnknown: Int

        /// 每组给一个代表下标。**这只是"这组修一张就够"的位置**，按输入序取第一个；
        /// 挑哪张更好看需要美学权重，本仓不装会挑（见 pixcake-parity §7 第 2 条）。
        var representatives: [Int] { groups.compactMap { $0.min() } }

        /// 给人看的一行，进状态栏与导出报告。
        var report: String {
            var line: String
            if groups.isEmpty {
                line = "重复帧 没有 · [dup:none]"
            } else {
                let biggest = groups.map { $0.count }.max() ?? 0
                line = "重复帧 \(groups.count) 组（最多一组 \(biggest) 张）· [dup:\(groups.count)]"
            }
            if ignoredFlat > 0 { line += " · [dup:flat_ignored] \(ignoredFlat) 张平场不参与" }
            if ignoredUnknown > 0 { line += " · [dup:no_fingerprint] \(ignoredUnknown) 张量不出" }
            return line
        }
    }

    /// 并查集分组：距离 ≤ `threshold` 的两帧归一组。
    ///
    /// 传递性是有意的：连拍里 A~B、B~C 而 A~C 刚好超阈时，仍然把三张归一组——
    /// 因为它们本来就是同一次快门序列。判据方向（宁可漏并不宁可错并）体现在
    /// 阈值本身，不靠切断传递链来实现。
    static func group(_ frames: [Frame], threshold: Int = sameFrameLimit) -> Grouping {
        var parent = [Int](repeating: -1, count: frames.count)
        var flat = 0
        var unknown = 0
        for (i, frame) in frames.enumerated() {
            guard let mine = frame.fingerprint else { unknown += 1; continue }
            if frame.flat { flat += 1; continue }
            parent[i] = i
            for j in 0 ..< i where parent[j] >= 0 {
                guard let other = frames[j].fingerprint else { continue }
                if distance(mine, other) <= threshold { union(&parent, i, j) }
            }
        }
        var buckets: [Int: [Int]] = [:]
        for i in 0 ..< frames.count where parent[i] >= 0 {
            buckets[find(&parent, i), default: []].append(i)
        }
        let groups = buckets.values.filter { $0.count >= 2 }.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
        return Grouping(groups: groups, ignoredFlat: flat, ignoredUnknown: unknown)
    }

    private static func find(_ parent: inout [Int], _ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        // 路径压缩：不压缩的话最坏是 O(n) 每次 find，而素材库可能有几百张。
        var cur = x
        while parent[cur] != root {
            let next = parent[cur]
            parent[cur] = root
            cur = next
        }
        return root
    }

    private static func union(_ parent: inout [Int], _ a: Int, _ b: Int) {
        let ra = find(&parent, a), rb = find(&parent, b)
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
    }
}
