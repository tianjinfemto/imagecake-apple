import CoreGraphics
import Dispatch
import Foundation
import XCTest

@testable import ImageCake

/// 原语级归因基准：上一次的阶段表只回答"哪一段慢"（region 13s、skin 10.5s…），
/// 没回答"慢在模糊、慢在掩码、还是慢在逐像素"。这句话本来只能猜，这里把它变成测量。
///
/// 为什么不改产线代码来做这件事：把 `perf` 传进五个引擎要动十几个签名，而在还不知
/// 道钱花在哪一步之前就改结构，是最容易留下"为了测量而把代码搞复杂"的做法。
/// 这里直接对着**原语**计时，结论一样能用，代价是零改产线。
///
/// 断言只有一条是硬的，而且它是**自证式**的：
/// `blurred` 是"每边一个累加窗口"的可分离模糊，所以耗时对半径应当近乎不敏感；
/// 一旦半径 2→16（8 倍）把耗时也推到 8 倍量级，说明实现退化成了朴素窗口
/// （O(N·r²)），那时慢就不是"Swift 没上 SIMD"，而是算法量级错了 —— 这一条
/// 不需要任何凭感觉的毫秒阈值就能成立。
final class RenderPrimitivesBenchmarkTests: XCTestCase {
    /// 基准尺寸：默认 256（Debug 作业里一次全效果渲染约 6 秒，常驻再大就是自残）。
    /// Release 作业用 IMAGECAKE_BENCH_SIZE 传 1024，量到真实尺寸的数而不是外推。
    private var size: PixelSize {
        let raw = ProcessInfo.processInfo.environment["IMAGECAKE_BENCH_SIZE"]
        let edge = Swift.min(Swift.max(Int(raw ?? "") ?? 256, 64), 2048)
        return PixelSize(width: edge, height: edge)
    }

    /// 中频棋盘：既有边缘（模糊/双边要真的算）又不是纯色（纯色会被短路掉）。
    private func sampleImage() -> DisplayImage {
        let s = size
        var pixels = [Float](repeating: 0, count: s.pixelCount * 4)
        for y in 0 ..< s.height {
            for x in 0 ..< s.width {
                let block = ((x / 7) + (y / 5)) % 3
                let base: (Double, Double, Double) =
                    block == 0 ? (0.70, 0.55, 0.45) : (block == 1 ? (0.30, 0.42, 0.55) : (0.52, 0.50, 0.48))
                let noise = Double((x * 31 + y * 17) % 13) / 400
                let o = (y * s.width + x) * 4
                pixels[o] = Float(base.0 + noise); pixels[o + 1] = Float(base.1 + noise)
                pixels[o + 2] = Float(base.2 + noise); pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: s, pixels: pixels)
    }

    /// 最佳值而不是中位值：这里比的是**量级与斜率**，最佳值把系统调度噪声压掉，
    /// 让"半径 8 倍 → 耗时也 8 倍"这种结构性差异不被抖动糊掉。
    private func bestMS(samples: Int = 3, _ body: () -> Void) -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0 ..< samples {
            let start = DispatchTime.now()
            body()
            let end = DispatchTime.now()
            best = Swift.min(best, Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        return best
    }

    private func perPixel(_ ms: Double) -> Double {
        ms * 1000 / Double(size.pixelCount)
    }

    func testPrimitiveAttributionAndBlurRadiusSlope() {
        let image = sampleImage()
        let flat = image.pixels
        let mask = MaskBuffer.filled(size, value: 255)
        let strokes = [BrushStroke(points: [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)],
                                   radius: 0.12, hardness: 0.5)]
        let hulls = [[CGPoint(x: 0.4, y: 0.8), CGPoint(x: 0.55, y: 0.76), CGPoint(x: 0.62, y: 0.86),
                      CGPoint(x: 0.58, y: 0.97), CGPoint(x: 0.42, y: 0.95)]]
        let faceBounds = CGRect(x: 0.3, y: 0.28, width: 0.4, height: 0.5)

        // ① 模糊/羽化族（八个热阶段共用的就是这一族）。
        let blurSmall = bestMS { _ = ImageDocument.blurred(flat, size: size, radius: 2) }
        let blurBig = bestMS { _ = ImageDocument.blurred(flat, size: size, radius: 16) }
        let channelSmall = bestMS { _ = BeautyEngine.blurredChannel([Float](repeating: 0.5, count: size.pixelCount), size: size, radius: 2) }
        let channelBig = bestMS { _ = BeautyEngine.blurredChannel([Float](repeating: 0.5, count: size.pixelCount), size: size, radius: 16) }
        let feathered = bestMS { _ = MaskOps.feathered(mask, radius: 6) }

        // ② 掩码构建族。
        let raster = bestMS { _ = StrokeRasterizer.mask(strokes: strokes, size: size) }
        let skinLayers = bestMS { _ = SkinMask.build(image, personMask: mask, faceBoxes: [faceBounds]) }
        let hairWeights = bestMS { _ = HairMask.build(image, faceBounds: faceBounds, personMask: mask) }
        let handWeights = bestMS { _ = HandMask.build(size: size, hulls: hulls, pixels: image.pixels) }

        // ③ 逐像素与窗口族。
        let denoise = bestMS(samples: 2) { _ = SpatialFilters.denoise(image, strength: 40) }
        let sharpen = bestMS(samples: 2) { _ = SpatialFilters.sharpen(image, strength: 35) }
        var beauty = BeautyParameters()
        beauty.skinSmooth = 55
        beauty.toneUnify = 40
        beauty.whitening = 30
        let layers = SkinMask.build(image, personMask: mask, faceBoxes: [faceBounds])
        let skinApply = bestMS { _ = BeautyEngine.apply(image, skin: layers, beauty: beauty) }
        let colorMatch = bestMS { _ = ColorTransfer.stats(image) }

        var rows: [(String, Double)] = [
            ("blurred r2", blurSmall), ("blurred r16", blurBig),
            ("blurredChannel r2", channelSmall), ("blurredChannel r16", channelBig),
            ("feathered r6", feathered), ("strokeRaster", raster),
            ("skinMask", skinLayers), ("hairMask", hairWeights), ("handMask", handWeights),
            ("denoise", denoise), ("sharpen", sharpen), ("skinApply", skinApply),
            ("colorStats", colorMatch),
        ]
        rows.sort { $0.1 > $1.1 }
        print("=== [\(RenderPerf.buildConfig)] 原语归因 \(size.width)×\(size.height)（\(size.pixelCount) 像素，共 \(rows.count) 项）===")
        // 表里的 µs/px 只在当前构建配置内可比较。Debug 下数组越界检查占主导，
        // 所以"内存访问模式优化无效"这类结论在 Debug 里量不出来 —— 已踩过一次
        // （模糊核改行主序：数字没动，已回退）。要拿它做优化依据，跑 Release。
        for (name, ms) in rows {
            print(String(format: "  %-20@ %8.2f ms  %6.2f µs/px", name as NSString, ms, perPixel(ms)))
        }

        // 可分离滑窗模糊：半径 8 倍不该让耗时也跟着 8 倍。
        // 真跑成朴素窗口时这个比值就是 8 附近；累加窗口应当留在个位数倍以内。
        XCTAssertLessThan(blurBig / blurSmall, 4.0,
                          "blurred 半径 2→16（8 倍）耗时 \(String(format: "%.1f", blurSmall))→\(String(format: "%.1f", blurBig))ms，比值 \(String(format: "%.1f", blurBig / blurSmall))：累加窗口失效了，这是 O(N·r²)")
        XCTAssertLessThan(channelBig / channelSmall, 4.0,
                          "blurredChannel 同样应当对半径不敏感（比值 \(String(format: "%.1f", channelBig / channelSmall))）")

        // 每条都必须量到正数：0 毫秒意味着这个原语其实被短路了（测了个寂寞）。
        for (name, ms) in rows {
            XCTAssertGreaterThan(ms, 0, "\(name) 量到 0 毫秒，说明它走了短路或输入构造无效")
        }
    }

    /// 掩码外接框限定该不该做：如果**整幅**糊一遍比光栅化那块掩码本身贵一个数量级，
    /// 而结果只有那一小块被用到，就应当先把模糊限制到 bbox。这条断言只报事实，
    /// 不改任何产线行为。
    func testFullImageBlurDominatesRegionRaster() {
        let image = sampleImage()
        let strokes = [BrushStroke(points: [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)],
                                   radius: 0.12, hardness: 0.5)]
        let raster = bestMS { _ = StrokeRasterizer.mask(strokes: strokes, size: size) }
        let blur = bestMS { _ = ImageDocument.blurred(image.pixels, size: size, radius: 12) }
        print(String(format: "=== bbox 判定依据：raster %.2fms vs 全幅 blurred %.2fms（比值 %.1f）===",
                     raster, blur, blur / Swift.max(raster, 0.001)))
        XCTAssertGreaterThan(blur, 0)
        XCTAssertGreaterThan(raster, 0)
    }
}
