import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 重复帧指纹与分组的断言。
///
/// 每个期望值都来自 Python 镜像 `dhash_mirror4`，而且是**在 256×192 上用 float32
/// 像素量的**。两个原因都踩过一次，写在这里免得再踩：
///   · 尺寸：同一内容在 64×48 上"机震 1px 差 11 位"，因为 1px 相当于格宽的 14%；
///     真实 256 缩略图上 1~3px 不到格宽的 1%，实测距离 0~4。
///   · 精度：上一版双精度镜像给的"噪声 11 / 反差 12"是**夹具并列位**造成的假象
///     （场景里有几个格均值近似相等，位翻转来自求和舍入而不是画面内容），CI 用真实
///     精度把它反证成了 0。所以夹具改成"格间无并列"（实测最小非零邻差 0.014），
///     并在 float32 下重测。
///
/// 实测距离（对同一 base）：同一帧 0、曝光 +0.05 是 0、反差 x1.10 是 0、条纹噪声
/// ±0.02 是 0、机震 3~6px 是 4、人动 24px 是 4；换构图 56、另一张片子 56、另一种
/// 内容 30。链式：0↔6px 是 4、6↔12px 是 8、0↔12px 是 12。
///
/// 断言写成"该并的 ≤ 8 / 不该并的 > 8"，不钉死位数：像素存 Float、镜像也是 Float，
/// 但求和顺序仍可能在临界处差一位，钉死位数的断言会红得没有信息量。
final class FrameHashTests: XCTestCase {
    private static let width = 256
    private static let height = 192

    /// 九个纵向波段的亮度。相邻波段差 0.08，格均值之间不留并列位。
    private static let levels = [0.08, 0.16, 0.24, 0.32, 0.44, 0.58, 0.70, 0.80, 0.90]

    struct Scene {
        var shift = 0
        var exposure = 0.0
        var gain = 1.0
        var noise = 0.0
        var moveSubject = 0
        var swap = false
        var flat = false
        var checker = false
        var monotone = false
        var lowContrast = false
    }

    /// 与镜像 `make()` 逐行同公式；像素按 Float 存，格内按行主序 Double 累加。
    private func scene(_ tweak: (inout Scene) -> Void = { _ in }) -> DisplayImage {
        var s = Scene()
        tweak(&s)
        let w = Self.width, h = Self.height
        let low = [0.48, 0.52, 0.49, 0.51, 0.48, 0.50, 0.52, 0.49, 0.51]
        var pixels = [Float](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let xs = Double(x - s.shift)
                let band = min(max(Int(xs * Double(FrameHash.columns) / Double(w)), 0),
                               FrameHash.columns - 1)
                var v: Double
                if s.flat {
                    v = 0.5
                } else if s.lowContrast {
                    v = low[band]
                } else if s.monotone {
                    v = 0.08 + 0.08 * Double(band)          // 单调：哈希应当被判无判别力
                } else {
                    v = Self.levels[band]
                    let inSubject = 3.2 * Double(w) / Double(FrameHash.columns) <= xs
                        && xs <= 5.6 * Double(w) / Double(FrameHash.columns)
                        && 0.25 * Double(h) <= Double(y) && Double(y) <= 0.75 * Double(h)
                    if inSubject {
                        v = 0.13 + 0.05 * sin((xs + Double(s.moveSubject)) / 9.0)
                    }
                    if s.checker {
                        v = ((x / 16 + y / 16) % 2 == 0) ? 0.30 : 0.90
                    }
                }
                if s.noise > 0 {
                    v += s.noise * (Double((x * 7 + y * 13) % 17) / 16.0 - 0.5)
                }
                v = (v + s.exposure) * s.gain
                let o = (y * w + x) * 4
                pixels[o] = Float(min(max(v, 0), 1))
                pixels[o + 1] = Float(min(max(v * 0.98, 0), 1))
                pixels[o + 2] = Float(min(max(v * 1.02, 0), 1))
                pixels[o + 3] = 1
            }
        }
        if s.swap {
            var flipped = pixels
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let src = (y * w + x) * 4
                    let dst = (y * w + (w - 1 - x)) * 4
                    flipped[dst] = pixels[src]
                    flipped[dst + 1] = pixels[src + 1]
                    flipped[dst + 2] = pixels[src + 2]
                    flipped[dst + 3] = pixels[src + 3]
                }
            }
            pixels = flipped
        }
        return DisplayImage(size: PixelSize(width: w, height: h), pixels: pixels)
    }

    private func printOf(_ image: DisplayImage) -> FrameHash.Fingerprint {
        if let fp = FrameHash.fingerprint(image) { return fp }
        // 不 fatalError：拿一个空指纹让断言红，比把测试宿主跑崩（本仓被“Index out of
        // range”搞过：崩溃没有可读失败信息）负责任得多。
        XCTFail("这个夹具本该有判别力，却被判成退化了 —— 说明格结构或阈值被动过")
        return FrameHash.Fingerprint(bits: 0, spread: 0)
    }

    private func frame(_ name: String, flat: Bool = false,
                       _ tweak: (inout Scene) -> Void = { _ in }) -> FrameHash.Frame {
        FrameHash.Frame(name: name, fingerprint: FrameHash.fingerprint(scene(tweak)), flat: flat)
    }

    // MARK: - 指纹与距离

    func testIdenticalScenesGiveTheSameFingerprint() {
        let a = printOf(scene()), b = printOf(scene())
        XCTAssertEqual(a, b, "同一份像素两次必须逐位相同（否则导出不可复现）")
        XCTAssertEqual(FrameHash.distance(a, b), 0)
        XCTAssertEqual(FrameHash.bitCount, 64)
        XCTAssertGreaterThan(a.spread, 0.1, "夹具要有内容，否则整组测试在比两个退化哈希")
    }

    /// 整体曝光/反差/噪点都不该改变指纹 —— 这是 dHash 的立足点（镜像实测全是 0）。
    func testGlobalExposureContrastAndNoiseBarelyMoveTheHash() {
        let base = printOf(scene())
        let cases: [(String, DisplayImage, Int)] = [
            ("曝光 +0.05", scene { $0.exposure = 0.05 }, 0),
            ("反差 x1.10", scene { $0.gain = 1.10 }, 0),
            ("条纹噪声 ±0.02", scene { $0.noise = 0.02 }, 0),
        ]
        for (name, image, mirrored) in cases {
            let d = FrameHash.distance(base, printOf(image))
            XCTAssertLessThanOrEqual(d, 4, "\(name) 不该改变判定（镜像 \(mirrored)），实际 \(d)")
        }
    }

    /// 机震与"人换姿势"都仍在阈内。**换姿势不拆开是有意的漏判方向**：去重不拆镜头。
    func testJitterAndSubjectMotionStayWithinTheLimit() {
        let base = printOf(scene())
        let cases: [(String, DisplayImage, Int)] = [
            ("机震 3px", scene { $0.shift = 3 }, 4),
            ("机震 6px", scene { $0.shift = 6 }, 4),
            ("人动 24px", scene { $0.moveSubject = 24 }, 4),
        ]
        for (name, image, mirrored) in cases {
            let d = FrameHash.distance(base, printOf(image))
            XCTAssertLessThanOrEqual(d, FrameHash.sameFrameLimit,
                                     "\(name) 应仍判同一帧（镜像 \(mirrored)），实际 \(d)")
        }
    }

    func testDifferentFramesStayOutsideTheLimit() {
        let base = printOf(scene())
        let cases: [(String, DisplayImage, Int)] = [
            ("换构图", scene { $0.swap = true }, 56),
            ("另一张片子", scene { $0.shift = 30; $0.exposure = 0.15; $0.swap = true }, 56),
            ("另一种内容", scene { $0.checker = true }, 30),
        ]
        for (name, image, mirrored) in cases {
            let d = FrameHash.distance(base, printOf(image))
            XCTAssertGreaterThan(d, FrameHash.sameFrameLimit,
                                 "\(name) 不该被并成同一帧（镜像 \(mirrored)），实际 \(d)")
        }
    }

    // MARK: - 两道必需的拒绝

    /// 纯色与"横向单调"的哈希都是全 0（镜像实测），拿去分组就是把不同的图判成重复。
    func testDegenerateScenesHaveNoUsableFingerprint() {
        XCTAssertNil(FrameHash.fingerprint(scene { $0.flat = true }), "纯色图的哈希没有判别力")
        XCTAssertNil(FrameHash.fingerprint(scene { $0.monotone = true }),
                     "从左到右单调变亮的渐变墙同样是全 0 哈希（镜像实测）")
    }

    /// 平场门不是锦上添花：两张这样的图距离是 0（镜像实测），阈值挡不住。
    func testLowContrastFramesNeedTheFlatGateBecauseDistanceCannotStopThem() {
        let twinA = scene { $0.lowContrast = true }
        let twinB = scene { $0.lowContrast = true }
        // 门用的就是 FrameTriage 那个判据（不另定口径），所以先钉住它真的会报平场：
        // 否则这个门在真实入口上根本不会触发，上面的断言就只是在测一个手标位。
        XCTAssertTrue(FrameTriage.review(twinA).tokens.contains("[flat-content]"),
                      "低对比夹具应当被 FrameTriage 判为无内容，否则去重那边的门根本不会开")
        XCTAssertEqual(FrameHash.distance(printOf(twinA), printOf(twinB)), 0,
                       "夹具前提：两张低对比图哈希相同")
        let gated = FrameHash.group([
            FrameHash.Frame(name: "wall1", fingerprint: FrameHash.fingerprint(twinA), flat: true),
            FrameHash.Frame(name: "wall2", fingerprint: FrameHash.fingerprint(twinB), flat: true),
        ])
        XCTAssertTrue(gated.groups.isEmpty, "标了平场就不许并：\(gated.groups)")
        XCTAssertEqual(gated.ignoredFlat, 2)
        XCTAssertTrue(gated.report.contains("[dup:flat_ignored] 2"), gated.report)
        // 同一对图不标平场时必须真的会被并起来 —— 否则上面那条是在测空集。
        let open = FrameHash.group([FrameHash.Frame(name: "wall1", fingerprint: FrameHash.fingerprint(twinA)),
                                    FrameHash.Frame(name: "wall2", fingerprint: FrameHash.fingerprint(twinB))])
        XCTAssertEqual(open.groups, [[0, 1]], "这道门确实在做事：不标就会被距离 0 并到一起")
    }

    /// 图太小 → 没有指纹，要数进报告而不是当成"另一组"。
    func testTooSmallImageHasNoFingerprintAndIsCounted() {
        var pixels = [Float](repeating: 0.5, count: 8 * 8 * 4)
        for i in 0 ..< 8 * 8 { pixels[i * 4 + 3] = 1 }
        let tiny = DisplayImage(size: PixelSize(width: 8, height: 8), pixels: pixels)
        XCTAssertNil(FrameHash.fingerprint(tiny), "8×8 连 2×2 的格子都凑不满")
        let result = FrameHash.group([FrameHash.Frame(name: "tiny", fingerprint: FrameHash.fingerprint(tiny))])
        XCTAssertEqual(result.ignoredUnknown, 1)
        XCTAssertTrue(result.report.contains("[dup:no_fingerprint] 1"), result.report)
        XCTAssertTrue(result.report.contains("[dup:none]"), result.report)
    }

    // MARK: - 分组

    func testConsecutiveBurstGroupsIntoOne() {
        let frames = [frame("a1"), frame("a2") { $0.shift = 3 }, frame("a3") { $0.shift = 6 },
                      frame("b1") { $0.swap = true }]
        let result = FrameHash.group(frames)
        XCTAssertEqual(result.groups, [[0, 1, 2]], "三张机震要并成一组，换构图的留在外面")
        XCTAssertEqual(result.representatives, [0], "代表取组内第一个下标（库按文件名序扫）")
        XCTAssertTrue(result.report.contains("[dup:1]"), result.report)
    }

    /// 确定性：同一输入跑 5 次必须同一分组（并查集最容易留的不是错值而是每次略有不同）。
    func testGroupingIsDeterministic() {
        let frames = [frame("x"), frame("y") { $0.shift = 6 }, frame("z") { $0.swap = true },
                      frame("w") { $0.moveSubject = 24 }]
        let first = FrameHash.group(frames)
        for _ in 0 ..< 4 {
            XCTAssertEqual(FrameHash.group(frames), first, "同一份输入两次分组不一致")
        }
        for group in first.groups {
            XCTAssertEqual(group, group.sorted(), "组内下标必须升序")
            XCTAssertGreaterThan(group.count, 1, "单张不该出现在结果里")
        }
        XCTAssertEqual(first.groups, first.groups.sorted { ($0.first ?? 0) < ($1.first ?? 0) },
                       "组间要按首个下标升序，报告才有稳定读法")
    }

    /// 传递性是并查集语义。链是实测出来的：0↔6px 是 4、6↔12px 是 8、而 0↔12px 是 12。
    /// 连拍本来就是"链式相邻"，所以判据方向由阈值表达，不靠切断传递链来表达。
    func testGroupingIsTransitive() {
        let a = printOf(scene())
        let b = printOf(scene { $0.shift = 6 })
        let c = printOf(scene { $0.shift = 12 })
        XCTAssertLessThanOrEqual(FrameHash.distance(a, b), FrameHash.sameFrameLimit, "夹具前提：A~B 在阈内（镜像 4）")
        XCTAssertLessThanOrEqual(FrameHash.distance(b, c), FrameHash.sameFrameLimit, "夹具前提：B~C 在阈内（镜像 8）")
        XCTAssertGreaterThan(FrameHash.distance(a, c), FrameHash.sameFrameLimit,
                             "夹具前提：A~C 要超阈（镜像 12），否则这条没在测传递性")
        let frames = [FrameHash.Frame(name: "a", fingerprint: a),
                      FrameHash.Frame(name: "b", fingerprint: b),
                      FrameHash.Frame(name: "c", fingerprint: c)]
        XCTAssertEqual(FrameHash.group(frames).groups, [[0, 1, 2]],
                       "A~C 超阈仍要靠传递性并成一组（连拍不是两两比较能切的）")
    }

    func testReportDistinguishesNoneFromSome() {
        let none = FrameHash.group([frame("solo"), frame("other") { $0.swap = true }])
        XCTAssertTrue(none.report.contains("[dup:none]"), none.report)
        let some = FrameHash.group([frame("a"), frame("b") { $0.shift = 3 }])
        XCTAssertTrue(some.report.contains("[dup:1]"), some.report)
        XCTAssertTrue(some.report.contains("最多一组 2 张"), some.report)
    }
}
