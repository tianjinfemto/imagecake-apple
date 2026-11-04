import CoreGraphics
import Foundation

// 影调形状匹配（追色的第二档）：把亮度轴的**整个分布形状**搬到样片上，
// 而不只是均值与反差。做法是分位数传递（quantile transfer）——取两侧各 `knots`
// 个分位数，第 i 个 knot 把"源的第 i 分位"映到"参考的第 i 分位"，knot 之间线性插值。
//
// 为什么要单独一档，而且有实测数字支撑（镜像脚本 histo_mirror，全部可复现）：
// 第一档只做 `(x − 本图均值)·增益 + 参考均值`，而增益夹在 1.8。单峰客片（亮度
// std 0.031）对双峰样片（std 0.381）时比值 12.3 被夹到 1.8，**根本跨不到两个峰**：
// 64 分箱的 L1 距离从 2.0000（完全不重叠）跑完第一档仍是 2.0000，跑第二档是 0.0600。
// 这一条就是文档里"只对齐一阶/二阶统计量，不匹配直方图形状"那条边界的补法。
//
// 三条性质（各有断言，不是承诺）：
//   · **保序**：两侧分位数序列都单调不减，所以曲线单调 —— 不会出现"亮部被映得
//     比暗部更暗"这种反转（反转才是追色最常见的炸法）。
//   · **连续**：knot 之间线性插值，边界处左右极限一致 → 算子自己不产生台阶。
//     映射后最陡段的相邻样本跳变实测 0.172（knot=33），斜率约 189 —— 台阶的来源
//     是"样片本来就把像素推向两端"（等价于拉一条重 S 曲线），不是量化缺陷。
//     因此这一档**默认关**，要的人自己打开，面板上把这句写出来。
//   · **纯色防护**：源的亮度分布几乎是常数时整条曲线跳过。镜像实测：一堵 0.4 的
//     墙会被搬到样片的第一个分位 0.12 —— 那正是第一档用 `stdFloor` 防的"炸成一块"，
//     第二档必须用同一个数防同一件事，不能两套口径。
//
// 只动亮度轴。A/B 两轴继续走第一档：色度分布窄且与饱和度耦合，对它做形状匹配
// 会把皮肤推向样片里最饱和的那一段，收益不明而失败很显眼。

/// 亮度分布的形状匹配曲线与它的构造。纯函数，零依赖，可离线断言。
enum ShapeTransfer {
    /// knot 数。实测：33 → 形状距离 0.0600、最陡段跳变 0.172；65 → 0.0355 但跳变
    /// 翻倍到 0.343；129 → 0.0160、跳变 0.342。取 33：距离已经近到肉眼分不出，
    /// 陡段减半。加密度换距离是错的方向（台阶跟着翻倍）。
    static let knots = 33

    /// 源的亮度标准差低于这个值时不做形状匹配。与第一档同一个常量、同一个理由。
    static let minSpread = ColorTransfer.stdFloor

    /// 跳过形状匹配的原因。调用侧把它写进报告，不静默降级。
    /// （带 `Error` 是因为它要作为 `Result` 的失败分支，而 `Result` 的 Failure
    /// 必须是 `Swift.Error`；这里不是“抛错”，只是借用同一个类型做“曲线造不出来”。）
    enum Skip: Equatable, Sendable, Error {
        /// 样本比 knot 还少（小图/极端抽样），形状量不出来。
        case tooFewSamples
        /// 源的亮度几乎是常数（纯色墙、黑场），搬过去就是一块死色。
        case flatSource
    }

    /// 一条分位数传递曲线。两端各自单调不减。
    struct Curve: Equatable, Sendable {
        var source: [Double]
        var target: [Double]
        /// 每个 knot 都不动 = 恒等，`apply` 逐比特跳过。构造时算一次：
        /// 这个判定在逐像素循环里，留成计算属性就是每像素 33 次比较。
        var identity: Bool

        init(source: [Double], target: [Double]) {
            self.source = source
            self.target = target
            self.identity = source.count == target.count
                && zip(source, target).allSatisfy { abs($0 - $1) < 1e-9 }
        }

        /// 二分定位所在段 + 线性插值。越界**不外插**（夹到端点值）：
        /// 显示域里确实会出现 <0 或 >1 的值（越界像素另有 `out_of_range` 点名），
        /// 外插会把它们抛得更远，而曲线在两端的取值就是那两个分位数。
        func apply(_ value: Double) -> Double {
            guard !identity, !source.isEmpty, !target.isEmpty else { return value }
            if value <= source[0] { return target[0] }
            if value >= source[source.count - 1] { return target[target.count - 1] }
            var lo = 0
            var hi = source.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if source[mid] <= value { lo = mid } else { hi = mid }
            }
            let span = source[hi] - source[lo]
            // 并列分位（源里那一段没有像素）时区间宽为 0：直接给右端值，
            // 不做除法，否则 0/0 得到一个 NaN 然后整片消失。
            if span <= 1e-12 { return target[hi] }
            let t = (value - source[lo]) / span
            return target[lo] + (target[hi] - target[lo]) * t
        }
    }

    /// 亮度轴的等距抽样。**步长与轴的定义都和 `ColorTransfer.stats` / 应用时同一个
    /// 口径**（同一个 `sampleStride`、同一个 `BeautyEngine.opponent(...).l`），否则
    /// "曲线按这批样本量出来，像素按另一批算"这种双口径迟早对不上。
    static func lumaSamples(_ image: DisplayImage) -> [Double] {
        let count = image.size.pixelCount
        guard count > 0, image.pixels.count >= count * 4 else { return [] }
        let stride = ColorTransfer.sampleStride(for: count)
        var out: [Double] = []
        out.reserveCapacity(min(count, ColorTransfer.maxSamples))
        var index = 0
        while index < count {
            let o = index * 4
            out.append(BeautyEngine.opponent(r: Double(image.pixels[o]),
                                             g: Double(image.pixels[o + 1]),
                                             b: Double(image.pixels[o + 2])).l)
            index += stride
        }
        return out
    }

    /// 第 i 个分位数：最近秩（nearest-rank，四舍五入到最近的样本下标）。
    /// 用固定的下标公式而不是插值，是为了让"同一批样本永远给出同一组 knot"
    /// 成为构造事实（两次导出、预览与导出必须逐比特一致）。
    static func quantile(_ sortedValues: [Double], _ index: Int, of count: Int) -> Double {
        guard !sortedValues.isEmpty, count > 1 else { return sortedValues.first ?? 0 }
        let position = Double(index) / Double(count - 1) * Double(sortedValues.count - 1)
        let rank = Int(position.rounded())
        return sortedValues[min(max(rank, 0), sortedValues.count - 1)]
    }

    /// 由两组样本构造曲线。样本不足或源是纯色时返回 `.failure(原因)`——
    /// 调用侧据此跳过并点名，不拿"曲线全 0"当"没效果"。
    static func curve(source: [Double], reference: [Double]) -> Result<Curve, Skip> {
        guard source.count >= knots, reference.count >= knots else { return .failure(.tooFewSamples) }
        let s = source.sorted()
        let r = reference.sorted()
        guard spread(s) > minSpread else { return .failure(.flatSource) }
        var xs: [Double] = []
        var ys: [Double] = []
        xs.reserveCapacity(knots)
        ys.reserveCapacity(knots)
        for i in 0 ..< knots {
            xs.append(quantile(s, i, of: knots))
            ys.append(quantile(r, i, of: knots))
        }
        return .success(Curve(source: xs, target: ys))
    }

    /// 标准差（总体口径，与 `ColorTransfer.stats` 一致：除 n 不是 n−1）。
    static func spread(_ sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let n = Double(sortedValues.count)
        let mean = sortedValues.reduce(0, +) / n
        let variance = sortedValues.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / n
        return variance.squareRoot()
    }

    /// 跳过原因的一句话。进报告，让"这一档没生效"看得见。
    static func note(_ skip: Skip) -> String {
        switch skip {
        case .tooFewSamples:
            return "[shape:too_few] 亮度样本不足 \(knots) 个，形状档跳过（只走均值/反差）"
        case .flatSource:
            return "[shape:flat] 这张图的亮度几乎是常数，形状档跳过（防纯色墙被搬成一块）"
        }
    }
}
