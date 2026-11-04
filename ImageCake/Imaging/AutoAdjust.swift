import CoreGraphics
import Foundation

// 自动增强（确定性一半）：从**原图的线性档**量出曝光与白平衡的建议值，写成现有滑杆的
// 绝对值。像素蛋糕那一栏叫"AI 一键"，本仓不叫 AI：这里没有任何网络，只有两个统计量
// 加一套自家色彩模型的闭式解，所以它能被断言，也说得清失败长什么样。
//
// 三条设计决定：
//   · **量原图，不量当前画面**。写进 `params.temperature` 的是绝对值，如果按当前画面
//     （已经含用户自己的色温）来量，同一个按钮按第二次会往同一个方向再推一次 ——
//     那才是"越点越偏"。按原图量则幂等：连按三次结果一样，这条有断言。
//   · **闭式解，不做试探**。白平衡用 `EditParameters.temperatureGain/tintGain` 那套
//     增益（r=1+0.25·t、b=1−0.25·t、g=1−0.20·t、rb=1+0.10·t）在**它自己的定义域**里
//     反解：要让参考区的 a=r−g 与 b=b−(r+g)/2 同时归零，两个未知数两条方程，解是
//     精确的（推导写在下面），不是"乘个系数试试看"。曝光同理：线性域中位数到 18% 灰
//     的 EV 差就是 log2 之比，而 `exposureGain = 2^EV` 是本仓自己的定义。
//   · **先 WB 再曝光，且在同一批样本上重算中位数**。逐通道增益不同，中位数不是简单
//     缩放；所以不是"估个修正量"，而是把增益真的作用到样本上再取中位数（一次排序，
//     零近似）。把精确代数套到近似算子上是本仓踩过的坑，这里从源头避开。
//
// 已知边界（写在这里，不当隐藏失败）：
//   · 白平衡参考区取"近无彩 + 不太暗"的像素（标准 gray-world 白色取样）。失败模式可
//     预期：一场戏里近无彩的像素本身就是暖色木墙时，会被当成白参照，把人追冷。这是
//     统计法的固有边界，不是 bug；真解要分割/白卡，缺件不假装有。参考像素不够时
//     **不做白平衡**并点名 `[auto:wb_noref]`，而不是拿全图中性硬凑。
//   · 提亮不许把 99 分位推过 1：会被压回不越界的那个 EV，并点名 `[auto:hl_cap]`。
//   · EV 与色温/色调都夹在参数域内（−2…2 EV、−100…100），夹过要在 note 里说。

/// 从原图线性档量出的自动增强建议。纯函数、零依赖、可离线断言。
enum AutoAdjust {
    /// 抽样上限。与 `ColorTransfer.maxSamples` 同一档，且**复用同一个步长函数**：
    /// 两处统计若用了不同抽样口径，"同一张图给出同一个建议"这条迟早会破。
    static let maxSamples = ColorTransfer.maxSamples
    /// 中间调目标：18% 灰（线性域）。摄影测光的标准做法，不是本仓量的数。
    static let midGrayTarget = 0.18
    /// 参数域：`exposure` 本来就是 −2…+2 EV。
    static let evRange: ClosedRange<Double> = -2 ... 2
    static let shiftRange: ClosedRange<Double> = -100 ... 100
    /// 线性域里"近无彩"的通道极差。太小的话普通照片挑不出参考像素，
    /// 太大就把有颜色的墙也当成白参照；0.06 是夹具实测能稳定选中的值。
    static let neutralBand = 0.06
    /// 低于这个数就不做白平衡（统计量太脆）。
    static let minNeutralSamples = 64
    /// 亮于此值才当白色参考（暗部噪声会把均值拖走）。
    static let minReferenceLuma = 0.03
    /// EV 小于这个量就当不用动：报告里写"已经接近中灰"而不是把滑杆推 0.01。
    static let neutralEV = 0.02

    /// 一次建议的结果。写进现有参数，不新增字段。
    struct Proposal: Equatable, Sendable {
        var exposure: Double
        var temperature: Double
        var tint: Double
        var notes: [String]

        /// 全为"不动"时调用侧可以整段跳过（也不写历史）。
        var isNoOp: Bool {
            abs(exposure) < AutoAdjust.neutralEV && temperature == 0 && tint == 0
        }
    }

    /// 等距抽样的步长：直接借 `ColorTransfer` 那一条，两处共用一个口径。
    static func sampleStride(for pixelCount: Int) -> Int {
        ColorTransfer.sampleStride(for: pixelCount)
    }

    /// 建议值。样本为空时返回 nil（调用侧点名，不猜）。
    static func proposal(linear: LinearImage) -> Proposal? {
        let count = linear.size.pixelCount
        guard count > 0, linear.pixels.count >= count * 4 else { return nil }
        let stride = sampleStride(for: count)
        var samples: [Double] = []
        samples.reserveCapacity(min(count, maxSamples) * 3)
        var index = 0
        while index < count {
            let o = index * 4
            samples.append(Double(linear.pixels[o]))
            samples.append(Double(linear.pixels[o + 1]))
            samples.append(Double(linear.pixels[o + 2]))
            index += stride
        }
        let n = samples.count / 3
        guard n > 0 else { return nil }

        func luma(_ i: Int) -> Double {
            0.2126 * samples[i * 3] + 0.7152 * samples[i * 3 + 1] + 0.0722 * samples[i * 3 + 2]
        }

        // —— 白平衡：在近无彩、不太暗的像素上取逐通道均值 ——
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, hits = 0
        for i in 0 ..< n {
            let r = samples[i * 3], g = samples[i * 3 + 1], b = samples[i * 3 + 2]
            let hi = Swift.max(r, Swift.max(g, b)), lo = Swift.min(r, Swift.min(g, b))
            guard hi - lo <= neutralBand, luma(i) >= minReferenceLuma else { continue }
            sumR += r; sumG += g; sumB += b
            hits += 1
        }
        var temperature = 0.0
        var tint = 0.0
        var notes: [String] = []
        if hits >= minNeutralSamples, sumR > 0, sumG > 0, sumB > 0 {
            let rBar = sumR / Double(hits), gBar = sumG / Double(hits), bBar = sumB / Double(hits)
            // 解 (1+0.25·t1)·r = (1−0.20·t2)·g  与  (1−0.25·t1)·b = (1+0.25·t1)·r
            //（rb 因子两边同时出现，可以约掉；a'=0 与 b'=0 各对应一条）。
            // 第一条只含 tA：b − 0.25·tA·b = r + 0.25·tA·r  ⇒  tA = 4(b−r)/(b+r)
            // 名字不能叫 t1/t2：那与下面的 `t1(_:)` / `t2(_:)` 重名，局部常量会把
            // 同名静态方法遮蔽掉（同一个函数里后面还要用它反推增益）。
            let tA = 4 * (bBar - rBar) / (bBar + rBar)
            // 代回第二条，记 A = (1+0.25·tA)·r：A(1+0.10·tB) = g(1−0.20·tB)
            //  ⇒  tB = (g − A)/(0.10·A + 0.20·g)
            let kr = 1 + 0.25 * tA
            let white = kr * rBar
            let tB = (gBar - white) / (0.10 * white + 0.20 * gBar)
            let rawTemp = tA * 100, rawTint = tB * 100
            temperature = rawTemp.clamped(to: shiftRange)
            tint = rawTint.clamped(to: shiftRange)
            if rawTemp != temperature || rawTint != tint {
                notes.append("[auto:wb_clamped] 需要的色温/色调超出 ±100（算出 \(Int(rawTemp.rounded()))/\(Int(rawTint.rounded()))），已夹住")
            }
        } else {
            notes.append("[auto:wb_noref] 近无彩参考像素只有 \(hits) 个（少于 \(minNeutralSamples)），不动白平衡")
        }

        // —— 曝光：把白平衡增益先作用到样本上，再取修正后的中位数 ——
        let kb = (1 - 0.25 * t1(temperature)) * (1 + 0.10 * t2(tint))
        let kg = 1 - 0.20 * t2(tint)
        let krOut = (1 + 0.25 * t1(temperature)) * (1 + 0.10 * t2(tint))
        var corrected: [Double] = []
        corrected.reserveCapacity(n)
        for i in 0 ..< n {
            let r = samples[i * 3] * krOut
            let g = samples[i * 3 + 1] * kg
            let b = samples[i * 3 + 2] * kb
            corrected.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        corrected.sort()
        let median = percentile(corrected, 0.5)
        guard median > 0 else {
            notes.append("[auto:no_midtone] 亮度中位数为 0（全黑帧），不动曝光")
            return Proposal(exposure: 0, temperature: temperature, tint: tint, notes: notes)
        }
        var ev = log2(midGrayTarget / median)
        // 提亮不许把 99 分位推过 1（高光死了比欠曝更难救，且肉眼看得见）。
        let ceiling = percentile(corrected, 0.99)
        if ev > 0, ceiling > 0 {
            let cap = Swift.max(0, log2(1.0 / ceiling))
            if ev > cap {
                notes.append("[auto:hl_cap] 只提到不越界：\(String(format: "%+.2f", ev)) EV 会把 99 分位推过 1，改为 \(String(format: "%+.2f", cap)) EV")
                ev = cap
            }
        }
        let clamped = ev.clamped(to: evRange)
        if clamped != ev {
            notes.append("[auto:ev_clamped] 需要 \(String(format: "%+.2f", ev)) EV，超出参数域 ±2，已夹住")
        }
        if abs(clamped) < neutralEV {
            notes.append("[auto:near_mid] 中位数 \(String(format: "%.3f", median)) 已接近 18% 灰，不动曝光")
        }
        return Proposal(exposure: abs(clamped) < neutralEV ? 0 : clamped,
                        temperature: temperature, tint: tint, notes: notes)
    }

    /// 参数值 → 增益模型里的 t（= 值/100）。拆出来是为了"用夹过的值反推增益"这件事
    /// 只有一处写法。
    private static func t1(_ temperature: Double) -> Double { temperature / 100 }
    private static func t2(_ tint: Double) -> Double { tint / 100 }

    /// 已排序序列的分位数（最近秩，四舍五入）。与 `ShapeTransfer` 同一套口径：
    /// 同一个下标公式，两处统计才不会因为"一个插值一个不插"而对不上。
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = min(max(q, 0), 1) * Double(sorted.count - 1)
        return sorted[Int(position.rounded())]
    }

    /// 逐脸自动力度的**政策**：脸占画面 4% 时 = 100%（跟随全局），更小的脸按比例降。
    ///
    /// 这条不是量出来的，是选的：所以把数与理由写在名字和注释里，别让后人误以为
    /// 有个隐式的实测在背后。用 sqrt 是因为细节量随脸的尺寸（边长）线性变化，
    /// 而传进来的是面积；夹在 50…150% 是因为超过 2 倍会把脸变形到不像同一个人
    /// （`FaceStrengthParameters.maxPercent` 同一条理由）。
    static let faceAreaReference = 0.04
    static let faceScaleRange: ClosedRange<Double> = 50 ... 150

    /// - Parameter faceFraction: 脸框面积占画面的比例（`FaceGeometry.bounds` 是归一化
    ///   坐标，所以宽×高本身就是比例）。
    static func faceScale(_ faceFraction: Double) -> Double {
        guard faceFraction > 0 else { return 100 }
        let ratio = (faceFraction / faceAreaReference).squareRoot()
        return (100 * ratio).clamped(to: faceScaleRange)
    }
}
