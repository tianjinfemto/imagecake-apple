import Dispatch
import Foundation

/// 渲染阶段耗时记录器 —— P1 性能工作的第一步：**先有可测的数字，再谈优化**。
///
/// 现状（故意不写死“全仓共几处并行”——这类计数注释本身就是下一处漂移）：分带并行有两类底座。
/// 一类是 `PixelParallel`：双边降噪与锐化按行，以及衣物/妆容/区域/头发/手/皮肤掩码
/// 那几个逐像素热段。另一类是内核里就地的 `DispatchQueue.concurrentPerform`：
/// 两处三遍盒式模糊（`BeautyEngine` 的单通道、`ImageDocument` 的 RGBA）按行与按列，
/// 以及 `ToneEngine` 的分带。**但仍然全是 CPU 标量循环**：全仓没有 vImage/Accelerate，
/// 也没有 MPS，单个像素那一圈还是逐元素算。而"感觉变快了"这件事目前是没法验收的 ——
/// 这个类型就是为了把它变成能验收的东西：
///
///   · 每次预览渲染产出一串 `(阶段名, 毫秒)`，顺序即渲染顺序；
///   · 中性参数下被闸门跳过的阶段**根本不出现在列表里** —— 于是"改一个滑杆
///     只重算受影响阶段"这句承诺第一次变成可断言的事实（见 `RenderPerfTests`）；
///   · 导出报告与底栏都能看到同一份数据，来源只有一处，不会出现"面板说 12ms、
///     导出说 30ms"这种两套口径。
///
/// 为什么是引用类型 + `stage(_:_:)` 包一层闭包，而不是让 `render()` 返回时间戳：
/// 渲染链是一条 `display = X.apply(...)` 的长序列，包闭包是**每处只加几个词**；
/// 改返回值要把每一段拆开，还会把 `let skinLayers` 这类中途量搞乱。
///
/// 为什么默认值是 `.disabled` 而不是 `nil`：绝大多数调用点（面板重渲染、导出、
/// 测试）不关心耗时，可选链会逼它们每处都写 `perf?.stage`。disabled 只透传，
/// 不取时钟也不追加数组，关掉时的开销就是一次函数调用。
///
/// 线程约定：**一次渲染一个实例**，且只在该渲染所在的那个工作线程里读写
/// （预览跑在 `Task.detached` 的一个闭包里）。`@unchecked Sendable` 成立的前提
/// 就是不把同一个实例交给两次并发渲染 —— `PreviewRender.produce` 的默认参数
/// 每次新建一个，正是为了把这条约束落在类型上而不是靠自觉。
final class RenderPerf: @unchecked Sendable {
    struct Sample: Equatable, Sendable {
        var name: String
        var ms: Double
    }

    /// 关闭状态的共享实例。它不写任何状态，所以跨线程共享是安全的。
    static let disabled = RenderPerf(enabled: false)

    let enabled: Bool
    private(set) var samples: [Sample] = []
    private var lastNanos: UInt64 = 0

    init(enabled: Bool = true) {
        self.enabled = enabled
        if enabled { lastNanos = RenderPerf.now() }
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// 计时执行一段渲染工作。`T` 泛型而不是只收 `DisplayImage`：
    /// 掩码构建这类阶段返回的是 `SkinMask.Layers?`，不强推出同一种返回形状。
    @inline(__always)
    func stage<T>(_ name: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let result = body()
        let timestamp = RenderPerf.now()
        samples.append(Sample(name: name, ms: Double(timestamp - lastNanos) / 1_000_000))
        lastNanos = timestamp
        return result
    }

    /// 异步版本：导出里的重绘/超清都是 `await` 的 AI 任务，而导出耗时恰恰主要
    /// 花在这里 —— 没有它就只能量到渲染部分，会得到一个好看但无关的数字。
    @inline(__always)
    func stageAsync<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let result = try await body()
        guard enabled else { return result }
        let timestamp = RenderPerf.now()
        samples.append(Sample(name: name, ms: Double(timestamp - lastNanos) / 1_000_000))
        lastNanos = timestamp
        return result
    }

    // MARK: 读取

    /// 本次实际跑过的阶段名（按执行顺序）。
    var names: [String] { samples.map(\.name) }
    var stageCount: Int { samples.count }

    func didRun(_ name: String) -> Bool { samples.contains { $0.name == name } }

    /// 同名阶段的毫秒合计（正常情况下名字唯一；求和只是不让重复名字变成静默丢失）。
    func milliseconds(for name: String) -> Double? {
        let matched = samples.filter { $0.name == name }
        guard !matched.isEmpty else { return nil }
        return matched.reduce(0) { $0 + $1.ms }
    }

    /// 各阶段之和。不含阶段之间的空隙（那部分是调度与分配，不在这里归因）。
    var stageTotalMS: Double { samples.reduce(0) { $0 + $1.ms } }

    /// 最慢的 n 个阶段（排查时的第一眼看的东西）。
    func slowest(_ n: Int) -> [Sample] {
        Array(samples.sorted { $0.ms > $1.ms }.prefix(max(0, n)))
    }

    /// 构建配置标签。**任何一张计时表都必须带它**：同一堆代码在 Debug（`-Onone` +
    /// 数组越界检查）与 Release 下可以差一个数量级 —— 这一点本仓已经亲自踩过：
    /// 第一次 1024² 基线量到 81～85 秒，看着像"必须上 SIMD/GPU"，实际那个数
    /// 是 CI 测试 jobs 默认的 Debug 构建，它描述的是开发模式而不是交付给用户的 App。
    /// （当时据此改的模糊核行主序因量不出收益已回退。）
    static var buildConfig: String { _isDebugAssertConfiguration() ? "DEBUG" : "RELEASE" }

    /// 给人看的一行。底栏、状态栏与导出报告共用这一份文案。
    func summary() -> String {
        guard enabled else { return "[perf_off] 未计时" }
        let top = slowest(3).map { String(format: "%@ %.1f", $0.name, $0.ms) }.joined(separator: " · ")
        return String(format: "[%@] 渲染 %.1fms / %d 段", Self.buildConfig, stageTotalMS, stageCount)
            + (top.isEmpty ? "" : " · 最慢 " + top)
    }
}
