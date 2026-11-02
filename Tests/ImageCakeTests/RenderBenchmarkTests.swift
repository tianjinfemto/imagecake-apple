import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 渲染基准：**给第 2 步（SIMD/GPU）留一把可对比的尺子**。
///
/// 为什么现在不敢写"某阶段必须小于 X 毫秒"：我还一次都没量过。凭感觉定的阈值
/// 只有两种结局——定松了永远绿（等于没断言），定紧了在某台 runner 上随机红。
/// 所以这一批只做三件事，都是能当场成立的：
///
///   1. **把每次跑的分阶段毫秒与占比打印进 CI 日志** —— 累积成改前/改后的对照；
///   2. 一条**极宽**的上限（防的是 accidentally O(N²) 或死循环这类量级事故，
///      不是防 20% 抖动；CI runner 的绝对值会漂，所以留了数量级余量）；
///   3. 一条结构性检查：所有开着的阶段都必须量到 > 0 毫秒，否则说明计时接错了，
///      那比慢更糟——后面所有"优化有效"的结论都会建立在一份假数据上。
///
/// 阈值收紧的时机：等这台 runner 上的基线跑过几次、知道抖动范围之后，
/// 在下一个提交里把它变成真正的性能守卫（这件事写在计划里，不假装已经做完）。
final class RenderBenchmarkTests: XCTestCase {
    /// 256²（16 万子像素）而不是更大的图：基准要跟每次 push 一起跑，尺寸大了
    /// 就是每轮多花几分钟 CI。量级事故（嵌套循环、每页重建掩码）在这个尺寸上
    /// 一样能抓到的，因为它改变的是斜率不是常数。
    ///
    /// 为什么不再拿 1024² 当默认基准：那一次实测（2026-11-01，run 41300357546）
    /// 中位 **81～85 秒**/渲染，四次采样把测试单跑拖到 330 秒以上 ——
    /// 那不是守卫，那是对 CI 分钟的自残。同一份数据已经记进
    /// docs/pixcake-parity.md §7 作为 P1 性能工作的基线（慢的 8 个阶段全部
    /// 共用同一个每遍新建 16MB 缓冲的模糊原语）；要重测大图，把下面这个
    /// 临时改回 1024 并在本地跑，不要进 CI。
    /// 基准尺寸由**构建配置**决定，不由 CI 变量决定：实测 job 级 env 传不进被测
    /// App 进程（`IMAGECAKE_BENCH_SIZE: 1024` 设了，表里仍打印 256），而尺寸又必须
    /// 跟着配置走 —— Debug（-Onone + 越界检查）一次全效果渲染约 6 秒，常驻只能是 256；
    /// Release 同一段只要 102 毫秒，所以 Release 作业直接量 1024，拿真实尺寸的基线而不
    /// 是拿缩略图外推。本地用环境变量覆盖仍然生效（便于手跑）。
    private var size: PixelSize {
        let fallback = _isDebugAssertConfiguration() ? 256 : 1024
        let fromEnv = Int(ProcessInfo.processInfo.environment["IMAGECAKE_BENCH_SIZE"] ?? "")
        let edge = Swift.min(Swift.max(fromEnv ?? fallback, 64), 2048)
        return PixelSize(width: edge, height: edge)
    }

    private func makeHeavyDocument() -> ImageDocument {
        let style = FilterEngine.styles.first?.id ?? ""
        var document = PipelineWiringDocument.make(size: size) { params in
            params.contrast = 25
            params.saturation = 10
            params.denoise = 40
            params.sharpen = 35
            params.beauty.skinSmooth = 55
            params.beauty.toneUnify = 40
            params.beauty.whitening = 30
            params.beauty.eyeBright = 40
            params.beauty.lipColor = 45
            params.beauty.darkCircle = 30
            params.beauty.nasolabial = 30
            params.beauty.antiGlare = 40
            params.beauty.slimFace = 30
            params.beauty.enlargeEyes = 25
            params.makeup.styleID = MakeupEngine.looks.first?.id ?? ""
            params.makeup.strength = 70
            params.hair.smooth = 50
            params.hair.colorStrength = 40
            params.hair.tame = 40
            params.hand.smooth = 50
            params.garment.deWrinkle = 50
            params.bodyLine.deLine = 50
            params.filter.style = style
            params.lens.distortion = 12
            params.lens.chromaticAberration = 15
            params.lens.vignette = 25
            params.lens.grain = 30
            params.light.intensity = 45
            params.sky.enabled = true
            params.sky.strength = 60
            params.sky.lightMatch = 40
            params.colorMatch.enabled = true
            params.colorMatch.strength = 60
            params.bgEnabled = true
        }
        let face = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())
        document.faceGeometries = face.map { [$0] } ?? []
        document.personMask = MaskBuffer.filled(size, value: 255)
        document.skyMask = MaskBuffer.filled(size, value: 200)
        document.handHulls = [[CGPoint(x: 0.42, y: 0.86), CGPoint(x: 0.5, y: 0.82),
                               CGPoint(x: 0.58, y: 0.86), CGPoint(x: 0.55, y: 0.96),
                               CGPoint(x: 0.45, y: 0.96)]]
        document.colorReference = TestImage.solid(width: 64, height: 64, r: 0.42, g: 0.5, b: 0.56)
        document.brush.garments = [BrushStroke(points: stridePoints(y: 0.7), radius: 0.05, hardness: 0.5)]
        document.brush.lines = [BrushStroke(points: stridePoints(y: 0.55), radius: 0.05, hardness: 0.5)]
        return document
    }

    private func stridePoints(y: CGFloat) -> [CGPoint] {
        (0 ... 8).map { CGPoint(x: 0.35 + CGFloat($0) * 0.035, y: y) }
    }

    func testStageBreakdownIsMeasuredAndWithinOrderOfMagnitude() {
        let document = makeHeavyDocument()

        // 先跑一次热的：第一次含页错误与 LUT 解析，拿来当基线会系统性偏慢。
        let warmup = RenderPerf()
        _ = document.render(perf: warmup)

        // 7 次而不是 3 次，并且以**最小值**为主口径：实测同一份代码在同一类 runner
        // 上能差 21%（2367.6ms 与 2872.1ms 是同一个构建），3 次中位数分辨不出 10~20%
        // 这个档位的改动，而剩下几个热段想要的收益正好在这一档。共享机器上只有
        // 最快那次受干扰最小；中位数一并打印，两个数都留着才看得出抖动有多大。
        var totals: [Double] = []
        var last = RenderPerf()
        var bestTotal = Double.greatestFiniteMagnitude
        for _ in 0 ..< 7 {
            let perf = RenderPerf()
            _ = document.render(perf: perf)
            totals.append(perf.stageTotalMS)
            if perf.stageTotalMS < bestTotal {
                bestTotal = perf.stageTotalMS
                last = perf
            }
        }
        let sorted = totals.sorted()
        let median = sorted[sorted.count / 2]
        let minimum = sorted.first ?? median
        let spread = minimum > 0 ? (sorted.last ?? minimum) / minimum : 0

        // ① 打印分阶段表（CI 日志里累积对照）。占比的分母用最快那次的总时长，
        // 这样表里的毫秒与百分比属于同一次跑，而不是拼凑出来的。
        let medianText = String(format: "%.1f", median)
        let minText = String(format: "%.1f", minimum)
        print("=== [\(RenderPerf.buildConfig)] 渲染基准 \(size.width)×\(size.height) · 最慢/最快比 \(String(format: "%.2f", spread))× · 最小 \(minText)ms · 中位 \(medianText)ms（\(totals.count) 次）===")
        if RenderPerf.buildConfig == "DEBUG" {
            print("   ↑ 这是 Debug 构建（-Onone + 数组越界检查）：它描述开发模式，不是交付给用户的 App。")
            print("     拿它当“该不该上 SIMD/GPU”的依据会得出错结论；Release 的数走 perf job 或本地跑。")
        }
        for sample in last.samples.sorted(by: { $0.ms > $1.ms }) {
            let share = bestTotal > 0 ? sample.ms / bestTotal * 100 : 0
            print(String(format: "  %8.2f ms  %5.1f%%  %@", sample.ms, share, sample.name))
        }

        // ② 计时接上了没有：开着的阶段必须都量到正数。
        let expected = ["geometry", "tone", "colorMatch", "skinMask", "filter", "lensGeometry",
                        "denoise", "sharpen", "skin", "region", "makeup", "hand", "hair",
                        "shape", "garment", "bodyLine", "background", "sky", "relight", "overlay"]
        for name in expected {
            let ms = last.milliseconds(for: name)
            XCTAssertNotNil(ms, "阶段 \(name) 没被记录：\(last.names)")
            XCTAssertGreaterThan(ms ?? -1, 0, "阶段 \(name) 记录为 0 毫秒，说明计时没接上")
        }

        // ③ 量级上限。基准值会在 CI 日志里逐次累积，知道抖动范围后再收紧；
        // 现在留的是"一个数量级"的余量，防的是从百毫秒变成十秒那种事故。
        XCTAssertLessThan(median, 20_000,
                          "256² 一次渲染中位 \(median)ms：这个量级不可能是慢，而是嵌套循环或每页重建缓冲")

        // ③b 同一次跑内部的抖动上限。这台机器曾量到同一构建差 21%，所以 3× 以内的
        // 波动当作可接受的噪声；超过它就不是“慢了一点”，而是有东西不定性地重做了
        // （比如缓存没复用、或某个阶段开始每次分配）。这个上限故意宽松，防的是事故。
        XCTAssertLessThan(spread, 3.0,
                          "\(totals.count) 次里最慢/最快 = \(String(format: "%.2f", spread))×（\(totals.map { Int($0) })）"
                              + "：超过 3× 就不是抖动而是有不确定的额外工作")
        XCTAssertGreaterThan(minimum, 0)

        // ④ 结构性检查：几何阶段不该是主要开销（它是恒等跳过的路径）。
        if let geometry = last.milliseconds(for: "geometry"), geometry > median * 0.5 {
            XCTFail("恒等几何占了 \(geometry)ms / \(median)ms —— 恒等时应当整段跳过（不插值）")
        }
    }
}
