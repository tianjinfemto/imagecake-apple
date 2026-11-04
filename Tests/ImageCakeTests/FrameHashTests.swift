import CoreGraphics
import Foundation
import XCTest

@testable import ImageCake

/// 重复帧指纹与分组的断言。
///
/// 距离的期望值全部来自 Python 镜像（`dhash_mirror2`），而且**夹具尺寸必须是
/// 256×192**：同一份夹具在 64×48 上量到"机震 1px 差 11 位"，因为 1px 相当于格宽的
/// 14%，而 256 缩略图上机震 1~3px 不到格宽的 1% —— 夹具尺寸会直接改变阈值结论，
/// 所以这一组测试不能在随手的小图上做。
///
/// 断言写成"该并的 ≤ 8 / 不该并的 > 8"这种带余量的形式，不钉死每一位：像素存 Float、
/// 镜像用 Double，格平均在临界处可能翻一位，钉死位数的断言会红得没有意义。
///
/// 实测距离（镜像，全部对同一 base）：同一帧 0、机震 1px 0、机震 3px 0、机震 6px 5、
/// 曝光 +0.05 是 4、人动 10px 是 2；换构图 19、另一张片子 30、棋盘内容 35。
/// 明知落在 8 之外因此**不并**的：条纹噪声 ±0.02 是 11、反差 +10% 是 12、人动 30px 是 10。
/// 这三类漏判是有意的取舍，所以也在这里钉住，不让后人把它当成"阈值太紧，放宽一点"。
final class FrameHashTests: XCTestCase {
    private static let width = 256
    private static let height = 192

    struct Scene {
        var shift = 0
        var exposure = 0.0
        var gain = 1.0
        var noise = 0.0
        var moveSubject = 0
        var swap = false
        var flat = false
        var checker = false
    }

    private func scene(_ tweak: (inout Scene) -> Void = { _ in }) -> DisplayImage {
        var s = Scene()
        tweak(&s)
        let w = Self.width, h = Self.height
        var pixels = [Float](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let xs = Double(x - s.shift)
                let base = 0.78 - 0.5 * (Double(y) / Double(h - 1))
                var v: Double
                if s.flat {
                    v = 0.5
                } else {
                    let inSubject = 0.31 * Double(w) <= xs && xs <= 0.53 * Double(w)
                        && 0.2 * Double(h) <= Double(y) && Double(y) <= 0.88 * Double(h)
                    let off = inSubject ? Double(s.moveSubject) : 0
                    v = base
                    if inSubject { v = 0.46 + 0.05 * sin((xs + off) / 16.0) }
                    if 0.68 * Double(w) <= xs, xs <= 0.82 * Double(w),
                       0.25 * Double(h) <= Double(y), Double(y) <= 0.46 * Double(h) {
                        v = 0.94
                    }
                    if s.checker { v = ((x / 16 + y / 16) % 2 == 0) ? 0.30 : 0.70 }
                }
                if s.noise > 0 {
                    v += s.noise * (Double((x * 7 + y * 13) % 17) / 16.0 - 0.5)
                }
                v = (v + s.exposure) * s.gain
                let o = (y * w + x) * 4
                let r = min(max(v, 0), 1), g = min(max(v * 0.98, 0), 1), b = min(max(v * 1.02, 0), 1)
                pixels[o] = Float(r); pixels[o + 1] = Float(g)
                pixels[o + 2] = Float(b); pixels[o + 3] = 1
            }
        }
        if s.swap {
            // 整幅左右翻转：行主序搬运，与镜像里 reversed(row) 同一件事。
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

    private func print_(_ image: DisplayImage) -> FrameHash.Fingerprint {
        guard let fp = FrameHash.fingerprint(image) else {
            fatalError("256×192 的夹具必须能出指纹，出不来就是 minCellSide 判定写错了")
        }
        return fp
    }

    private func frame(_ name: String, _ tweak: (inout Scene) -> Void = { _ in }) -> FrameHash.Frame {
        let image = scene(tweak)
        return FrameHash.Frame(name: name, fingerprint: FrameHash.fingerprint(image))
    }

    // MARK: - 指纹与距离

    func testIdenticalScenesGiveTheSameFingerprint() {
        let a = print_(scene()), b = print_(scene())
        XCTAssertEqual(a, b, "同一份像素两次必须逐位相同（否则导出不可复现）")
        XCTAssertEqual(FrameHash.distance(a, b), 0)
        XCTAssertEqual(FrameHash.bitCount, 64)
        XCTAssertGreaterThan(a.spread, 0.3, "夹具要有内容，否则这组测试全在比两个平场")
    }

    /// 该并的：机震 1~6px、曝光微调、人小动。
    func testJitterAndExposureStayWithinTheSameFrameLimit() {
        let base = print_(scene())
        let cases: [(String, DisplayImage, Int)] = [
            ("机震 1px", scene { $0.shift = 1 }, 0),
            ("机震 3px", scene { $0.shift = 3 }, 0),
            ("曝光 +0.05", scene { $0.exposure = 0.05 }, 4),
            ("人动 10px", scene { $0.moveSubject = 10 }, 2),
        ]
        for (name, image, mirrored) in cases {
            let distance = FrameHash.distance(base, print_(image))
            XCTAssertLessThanOrEqual(distance, FrameHash.sameFrameLimit,
                                     "\(name) 应当还判为同一帧（镜像 \(mirrored)），实际 \(distance)")
        }
    }

    /// 不该并的：换构图、另一张片子、另一种内容。
    func testDifferentFramesStayOutsideTheLimit() {
        let base = print_(scene())
        let cases: [(String, DisplayImage, Int)] = [
            ("换构图", scene { $0.swap = true }, 19),
            ("另一张片子", scene { $0.shift = 40; $0.exposure = 0.2; $0.swap = true }, 30),
            ("棋盘内容", scene { $0.checker = true }, 35),
        ]
        for (name, image, mirrored) in cases {
            let distance = FrameHash.distance(base, print_(image))
            XCTAssertGreaterThan(distance, FrameHash.sameFrameLimit,
                                 "\(name) 不该被并成同一帧（镜像 \(mirrored)），实际 \(distance)")
        }
    }

    /// 钉住"有意的漏判"：这几类确实是同一机位，但距离超过 8，本仓**选择不并**。
    /// 放宽阈值会换来另一件事：把"同景别另一次拍摄"（镜像 14）并掉，那会真的丢片子。
    func testKnownMissesAreDeliberateNotBugs() {
        let base = print_(scene())
        let misses: [(String, DisplayImage, Int)] = [
            ("条纹噪声 ±0.02", scene { $0.noise = 0.02 }, 11),
            ("反差 +10%", scene { $0.gain = 1.10 }, 12),
            ("人动 30px", scene { $0.moveSubject = 30 }, 10),
        ]
        for (name, image, mirrored) in misses {
            let distance = FrameHash.distance(base, print_(image))
            XCTAssertGreaterThan(distance, FrameHash.sameFrameLimit,
                                 "\(name) 是明知会漏判的一类（镜像 \(mirrored)）；如果这条变绿了，"
                                 + "说明有人放宽了阈值，那就得同时改文档里的代价说明")
        }
    }

    // MARK: - 分组

    func testConsecutiveBurstGroupsIntoOne() {
        let frames = [frame("a1") { _ in }, frame("a2") { $0.shift = 1 }, frame("a3") { $0.shift = 3 },
                      frame("b1") { $0.swap = true }]
        let result = FrameHash.group(frames)
        XCTAssertEqual(result.groups, [[0, 1, 2]], "三张机震要并成一组，另一张构图不同的要留在外面")
        XCTAssertEqual(result.representatives, [0], "代表取组内第一个下标（库是按文件名序扫的）")
        XCTAssertTrue(result.report.contains("[dup:1]"), result.report)
    }

    /// 平场必须排除。为什么需要这道门而不是只靠距离：两张互不相干的纯色图
    /// 哈希是相同的（镜像实测：flat 0.5 与 flat 0.7 距离 0，因为网格每一格都比不出大小、
    /// 并列位全由浮点舍入决定），而平场对一张有内容的图距离是 27 —— 所以门要拦的
    /// 不是“平场误并成普通图”，而是“两张不同的纯色图被判为同一机位”。
    func testFlatFramesNeverGroupEvenWhenTheirHashesMatch() {
        let flatA = scene { $0.flat = true }
        let flatB = scene { $0.flat = true }
        XCTAssertEqual(FrameHash.distance(print_(flatA), print_(flatB)), 0,
                       "夹具前提：两张平场图哈希相同（并列位靠舍入定，所以不靠它做判据）")
        let frames = [FrameHash.Frame(name: "wall1", fingerprint: FrameHash.fingerprint(flatA), flat: true),
                      FrameHash.Frame(name: "wall2", fingerprint: FrameHash.fingerprint(flatB), flat: true)]
        let result = FrameHash.group(frames)
        XCTAssertTrue(result.groups.isEmpty, "平场不得并组：\(result.groups)")
        XCTAssertEqual(result.ignoredFlat, 2)
        XCTAssertTrue(result.report.contains("[dup:flat_ignored] 2"), result.report)
        // 不把 flat 标上时，同一对图就必须被并起来 —— 否则上面那条断言是在测空集。
        let unguarded = FrameHash.group([FrameHash.Frame(name: "wall1", fingerprint: FrameHash.fingerprint(flatA)),
                                         FrameHash.Frame(name: "wall2", fingerprint: FrameHash.fingerprint(flatB))])
        XCTAssertEqual(unguarded.groups, [[0, 1]], "不靠平场门时它们会被距离 0 并到一起（这道门确实在做事）")
    }

    /// 图太小 → 没有指纹，要数进报告而不是当成"另一组"。
    func testTooSmallImageHasNoFingerprintAndIsCounted() {
        var pixels = [Float](repeating: 0.5, count: 8 * 8 * 4)
        for i in 0 ..< 8 * 8 { pixels[i * 4 + 3] = 1 }
        let tiny = DisplayImage(size: PixelSize(width: 8, height: 8), pixels: pixels)
        XCTAssertNil(FrameHash.fingerprint(tiny), "8×8 连 2×2 的格子都凑不满，不能给一个能比较的哈希")
        let result = FrameHash.group([FrameHash.Frame(name: "tiny", fingerprint: FrameHash.fingerprint(tiny))])
        XCTAssertEqual(result.ignoredUnknown, 1)
        XCTAssertTrue(result.report.contains("[dup:no_fingerprint] 1"), result.report)
        XCTAssertTrue(result.report.contains("[dup:none]"), result.report)
    }

    /// 确定性：同一输入跑 5 次必须给同一个分组（并查集 + 字典序最容易留的
    /// 不是错值而是每次略有不同）。
    func testGroupingIsDeterministic() {
        let frames = [frame("x") { _ in }, frame("y") { $0.shift = 2 }, frame("z") { $0.swap = true },
                      frame("w") { $0.exposure = 0.05 }]
        let first = FrameHash.group(frames)
        for _ in 0 ..< 4 {
            XCTAssertEqual(FrameHash.group(frames), first, "同一份输入两次分组不一致")
        }
        for group in first.groups {
            XCTAssertEqual(group, group.sorted(), "组内下标必须升序")
            XCTAssertGreaterThan(group.count, 1, "单张不成组，不该出现在结果里")
        }
        XCTAssertEqual(first.groups, first.groups.sorted { ($0.first ?? 0) < ($1.first ?? 0) },
                       "组间要按首个下标升序，报告才有稳定读法")
    }

    /// 传递性是并查集语义：A~B、B~C 时三张归一组，即使 A~C 刚好超阈。
    /// 实测（镜像）：0→5px 是 5、5px→9px 是 5、而 0→9px 是 10 —— 超开的 8。
    /// 这条不是顺手为之 —— 连拍本来就是“链式相邻”，所以判据方向由阈值表达，
    /// 不靠切断传递链来表达。
    func testGroupingIsTransitive() {
        let a = print_(scene())
        let b = print_(scene { $0.shift = 5 })
        let c = print_(scene { $0.shift = 9 })
        XCTAssertLessThanOrEqual(FrameHash.distance(a, b), FrameHash.sameFrameLimit, "夹具前提：A~B 在阈内（镜像 5）")
        XCTAssertLessThanOrEqual(FrameHash.distance(b, c), FrameHash.sameFrameLimit, "夹具前提：B~C 在阈内（镜像 5）")
        XCTAssertGreaterThan(FrameHash.distance(a, c), FrameHash.sameFrameLimit,
                             "夹具前提：A~C 要刚好超阈（镜像 10），否则这条没在测传递性")
        let frames = [FrameHash.Frame(name: "a", fingerprint: a),
                      FrameHash.Frame(name: "b", fingerprint: b),
                      FrameHash.Frame(name: "c", fingerprint: c)]
        XCTAssertEqual(FrameHash.group(frames).groups, [[0, 1, 2]],
                       "A~C 超阈仍要靠传递性并成一组（连拍不是两两比较能切的）")
    }

    func testReportDistinguishesNoneFromSome() {
        let none = FrameHash.group([frame("solo") { _ in }, frame("other") { $0.swap = true }])
        XCTAssertTrue(none.report.contains("[dup:none]"), none.report)
        let some = FrameHash.group([frame("a") { _ in }, frame("b") { $0.shift = 1 }])
        XCTAssertTrue(some.report.contains("[dup:1]"), some.report)
        XCTAssertTrue(some.report.contains("最多一组 2 张"), some.report)
    }
}
