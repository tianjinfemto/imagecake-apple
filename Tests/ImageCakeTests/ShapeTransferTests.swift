import CoreGraphics
import XCTest

@testable import ImageCake

/// 影调形状匹配（追色第二档）的断言。
///
/// 核心那条是**两档的分工**，而且带镜像跑出来的数（`histo_mirror4.py`）：
/// 单峰客片（亮度 std 0.031）对双峰样片（std 0.381）时，64 分箱的 L1 距离
/// 起点 2.0000（两个分布完全不重叠）——
///   · 跑第一档（均值/反差，增益被 1.8 夹住）**仍是 2.0000**；
///   · 跑第二档是 0.0600。
/// 这个数字差就是"为什么要加第二档"的全部理由，所以它必须是断言而不是注释。
///
/// 其余每条都是关系型/恒等型：保序、连续、恒等逐比特、越界不外插、纯色跳过、
/// 强度 0 逐比特、关了亮度轴时不生效且点名。不抄自推的像素值。
final class ShapeTransferTests: XCTestCase {

    // MARK: - 夹具（与镜像脚本逐字同公式）

    /// 平光单峰：0.45 附近一条正弦，亮度 std ≈ 0.031。
    private func singlePeak() -> DisplayImage {
        let values = (0 ..< 400).map { 0.45 + 0.10 * sin(Double($0) / 399.0 * Double.pi) }
        return gray(values)
    }

    /// 硬光双峰：一半压在 0.12，一半压在 0.88，亮度 std ≈ 0.381。
    private func twoPeak() -> DisplayImage {
        let values = (0 ..< 400).map { i in
            i % 2 == 0 ? 0.12 + 0.01 * Double(i % 3) / 3.0 : 0.88 + 0.01 * Double(i % 4) / 4.0
        }
        return gray(values)
    }

    /// 灰图：r=g=b，所以 `opponent(...).l` ≈ 该值（luma 权重和为 1）。
    /// 尺寸随样本数走：拿 20×20 装 4 个像素会让 pixels.count 与画幅不一致，
    /// 那类夹具在引擎里只会拿到空结果，测不出任何东西。
    private func gray(_ values: [Double], size: PixelSize = PixelSize(width: 20, height: 20)) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: values.count * 4)
        for (i, v) in values.enumerated() {
            pixels[i * 4] = Float(v)
            pixels[i * 4 + 1] = Float(v)
            pixels[i * 4 + 2] = Float(v)
            pixels[i * 4 + 3] = 1
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 64 分箱归一化直方图 + L1 距离。箱宽与截断口径同镜像脚本。
    private func bins(of image: DisplayImage) -> [Double] {
        let n = 64
        var counts = [Int](repeating: 0, count: n)
        for v in ShapeTransfer.lumaSamples(image) {
            counts[min(max(Int(v * Double(n)), 0), n - 1)] += 1
        }
        let total = Double(Swift.max(counts.reduce(0, +), 1))
        return counts.map { Double($0) / total }
    }

    private func distance(_ a: [Double], _ b: [Double]) -> Double {
        // 写成显式参数名而不是 `$0 + abs($1 - $2)`：`zip` 的元素是一个元组，
        // 两参数闭包里 `$1` 就是整个元组，“`$1 - $2`”单拿不到两个分量
        //（CI 报 cannot convert '(Double, Double)' to 'Double'）。
        zip(a, b).reduce(0.0) { total, pair in total + abs(pair.0 - pair.1) }
    }

    private func curve(of subject: DisplayImage, against reference: DisplayImage) -> ShapeTransfer.Curve {
        switch ShapeTransfer.curve(source: ShapeTransfer.lumaSamples(subject),
                                   reference: ShapeTransfer.lumaSamples(reference)) {
        case .success(let c): return c
        case .failure(let skip):
            XCTFail("夹具应该能构造曲线，实际被跳过：\(skip)")
            return ShapeTransfer.Curve(source: [], target: [])
        }
    }

    private func match(shape: Bool, strength: Double = 100, luma: Bool = true) -> ColorMatchParameters {
        var m = ColorMatchParameters()
        m.enabled = true
        m.strength = strength
        m.matchLuma = luma
        m.shapeMatch = shape
        return m
    }

    // MARK: - 核心：第二档补上第一档补不了的差距

    func testShapeTierClosesGapThatStatsTierCannot() {
        let subject = singlePeak(), reference = twoPeak()
        let target = bins(of: reference)
        let before = distance(bins(of: subject), target)
        XCTAssertEqual(before, 2.0, accuracy: 1e-9, "夹具的两个分布必须完全不重叠（L1 = 2）")

        // 第一档：均值/反差。增益被 gainRange 夹到 1.8，跨不到两个峰。
        let statsOnly = ColorTransfer.apply(subject, reference: reference, match: match(shape: false))
        XCTAssertEqual(distance(bins(of: statsOnly), target), 2.0, accuracy: 1e-9,
                       "只对齐一阶/二阶统计量时形状距离一点没动 —— 这正是加第二档的理由")

        // 第二档：分位数传递。镜像实测 0.0600。
        let shaped = ColorTransfer.apply(subject, reference: reference, match: match(shape: true))
        let after = distance(bins(of: shaped), target)
        XCTAssertLessThan(after, 0.10, "形状档必须把距离从 2.0 压到 0.1 以下（镜像 0.0600），实际 \(after)")
        XCTAssertGreaterThan(after, 0.0, "压到 0 反而说明夹具被复制成了样片，那是另一类错")
    }

    /// 形状匹配蕴含统计匹配：反差（std）一定跟着靠近样片。
    func testShapeTierAlsoMovesSpreadTowardReference() {
        let subject = singlePeak(), reference = twoPeak()
        let shaped = ColorTransfer.apply(subject, reference: reference, match: match(shape: true))
        guard let cur = ColorTransfer.stats(subject),
              let ref = ColorTransfer.stats(reference),
              let out = ColorTransfer.stats(shaped) else {
            return XCTFail("夹具统计不出来")
        }
        XCTAssertLessThan(abs(out.lStd - ref.lStd), abs(cur.lStd - ref.lStd),
                          "亮度反差必须往样片靠（镜像：本张 0.0309 → 追完 0.3763，样片 0.3808）")
        // 均值只断言“落在样片附近”，**不断言“比原来更近”**：夹具的本张均值 0.5135
        // 本来就与样片 0.5042 只差 0.0093，而形状匹配后是 0.0113 —— 写成“更近”会红，
        // 而那个红不是 bug，是把巧合当成了性质（镜像的三个数就写在这里）。
        XCTAssertLessThan(abs(out.lMean - ref.lMean), 0.02,
                          "追完的亮度均值应在样片附近（镜像 0.5155 对 0.5042）")
    }

    // MARK: - 曲线的三条性质

    func testKnotsAreMonotoneAndSameDistributionIsIdentity() {
        let c = curve(of: singlePeak(), against: twoPeak())
        XCTAssertEqual(c.source.count, ShapeTransfer.knots)
        XCTAssertEqual(c.target.count, ShapeTransfer.knots)
        for i in 1 ..< c.source.count {
            XCTAssertGreaterThanOrEqual(c.source[i], c.source[i - 1] - 1e-12, "源分位数必须不减")
            XCTAssertGreaterThanOrEqual(c.target[i], c.target[i - 1] - 1e-12, "参考分位数必须不减")
        }
        let same = curve(of: singlePeak(), against: singlePeak())
        XCTAssertTrue(same.identity, "同一分布必须判成恒等（否则声称不了逐比特）")
        XCTAssertEqual(same.apply(0.37), 0.37, accuracy: 1e-12, "恒等曲线不得动值")
    }

    /// 保序 = 不会出现"亮部被映得比暗部更暗"。这是追色最常见的炸法。
    func testCurvePreservesOrder() {
        let c = curve(of: singlePeak(), against: twoPeak())
        var previous = -Double.infinity
        var i = 0
        while i <= 4000 {
            let value = Double(i) / 4000.0
            let mapped = c.apply(value)
            XCTAssertGreaterThanOrEqual(mapped, previous - 1e-12, "在 \(value) 处出现反转")
            previous = mapped
            i += 1
        }
    }

    /// 连续 = 算子自己不产生台阶（台阶的唯一来源是样片自身的分布形状）。
    func testCurveIsContinuousAtKnotBoundaries() {
        let c = curve(of: singlePeak(), against: twoPeak())
        for k in 1 ..< (c.source.count - 1) {
            let x = c.source[k]
            let left = c.apply(x - 1e-12)
            let right = c.apply(x + 1e-12)
            XCTAssertLessThanOrEqual(abs(right - left), 1e-6,
                                     "knot \(k) 处左右极限不等，等于凭空造了一条硬边")
        }
    }

    /// 越界值（显示域里确实存在，另有 `[out_of_range]` 点名）**不外插**。
    func testOutOfRangeInputIsClampedToEndpointValues() {
        let c = curve(of: singlePeak(), against: twoPeak())
        XCTAssertEqual(c.apply(-0.3), c.target.first ?? 0, accuracy: 1e-12)
        XCTAssertEqual(c.apply(1.4), c.target.last ?? 0, accuracy: 1e-12)
    }

    // MARK: - 跳过与点名

    /// 纯色防护。镜像实测：一堵 0.4 的墙若不跳过，会被整幅搬到样片的第一个
    /// 分位 0.12 —— 那正是第一档用 stdFloor 防的"炸成一块"，两档必须同一个口径。
    func testFlatSourceSkipsShapeTierInsteadOfExploding() {
        let flat = gray([Double](repeating: 0.4, count: 400))
        switch ShapeTransfer.curve(source: ShapeTransfer.lumaSamples(flat),
                                   reference: ShapeTransfer.lumaSamples(twoPeak())) {
        case .success(let c):
            XCTFail("纯色源不该构造出曲线，实际给了 \(c.source.prefix(3)) → \(c.target.prefix(3))")
        case .failure(let skip):
            XCTAssertEqual(skip, .flatSource)
            XCTAssertTrue(ShapeTransfer.note(skip).contains("[shape:flat]"),
                          "跳过必须带机器可读的令牌：\(ShapeTransfer.note(skip))")
        }
        // 跳过之后必须与“没开第二档”逐比特相同：两档的差只允许发生在曲线存在时。
        // （不是“等于原图”：第一档本来就会把纯色墙的均值往样片靠，那是已有设计。）
        let out = ColorTransfer.apply(flat, reference: twoPeak(), match: match(shape: true))
        let statsOnly = ColorTransfer.apply(flat, reference: twoPeak(), match: match(shape: false))
        XCTAssertEqual(out.pixels, statsOnly.pixels, "形状档被跳过时不得留下任何额外改动")
    }

    func testTooFewSamplesIsNamed() {
        let tiny = gray([0.2, 0.9, 0.4, 0.6], size: PixelSize(width: 2, height: 2))
        XCTAssertEqual(ShapeTransfer.curve(source: ShapeTransfer.lumaSamples(tiny),
                                           reference: ShapeTransfer.lumaSamples(twoPeak())),
                       .failure(.tooFewSamples))
    }

    /// 形状档只动亮度轴。关了"连亮度一起追"时它必须**不生效且被点名**，
    /// 而不是出现"开关开着、滑杆拉着、画面不动"（本仓踩过 isNeutral 漏项那一类）。
    func testShapeTierInertAndReportedWhenLumaOff() {
        let subject = singlePeak(), reference = twoPeak()
        let plan = ColorTransfer.shapePlan(image: subject, reference: reference,
                                           match: match(shape: true, luma: false))
        XCTAssertNil(plan.curve)
        XCTAssertEqual(plan.status, .lumaOff)
        XCTAssertTrue(plan.status.text.contains("[shape:luma_off]"), plan.status.text)
        let out = ColorTransfer.apply(subject, reference: reference, match: match(shape: true, luma: false))
        let statsOut = ColorTransfer.apply(subject, reference: reference, match: match(shape: false, luma: false))
        XCTAssertEqual(out.pixels, statsOut.pixels, "亮度轴关着时两档必须给出同一张图")
    }

    func testStrengthZeroIsBitExactWithShapeOn() {
        let subject = singlePeak()
        let out = ColorTransfer.apply(subject, reference: twoPeak(), match: match(shape: true, strength: 0))
        XCTAssertEqual(out.pixels, subject.pixels, "强度 0 的承诺不能因为加了三档而漏掉形状档")
    }

    func testReportCarriesShapeState() {
        let subject = singlePeak(), reference = twoPeak()
        guard let cur = ColorTransfer.stats(subject), let ref = ColorTransfer.stats(reference) else {
            return XCTFail("夹具统计不出来")
        }
        let applied = ColorTransfer.shapePlan(image: subject, reference: reference, match: match(shape: true))
        XCTAssertTrue(applied.status.text.contains("knot"), applied.status.text)
        XCTAssertTrue(ColorTransfer.report(current: cur, reference: ref,
                                           match: match(shape: true), shape: applied.status)
                        .contains("knot"))
        let off = ColorTransfer.shapePlan(image: gray([Double](repeating: 0.4, count: 400)),
                                          reference: reference, match: match(shape: true))
        XCTAssertTrue(off.status.text.contains("[shape:flat]"), off.status.text)
    }

    // MARK: - 参数面

    /// 新键必须真的进预设：键名 `shape_match`、缺键落出厂（false）。
    func testShapeMatchRoundTripsThroughPreset() throws {
        var params = EditParameters()
        params.colorMatch.shapeMatch = true
        let back = try JSONDecoder().decode(EditParameters.self, from: JSONEncoder().encode(params))
        XCTAssertTrue(back.colorMatch.shapeMatch, "开了第二档存一次就丢，等于批量同步拿不到它")

        let legacy = Data(#"{"color_match":{"strength":80}}"#.utf8)
        let older = try JSONDecoder().decode(EditParameters.self, from: legacy)
        XCTAssertFalse(older.colorMatch.shapeMatch, "旧预设里没这个键时必须落出厂（关）")
        XCTAssertEqual(older.colorMatch.strength, 80, accuracy: 1e-9)

        let keyed = Data(#"{"color_match":{"shape_match":true}}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(EditParameters.self, from: keyed).colorMatch.shapeMatch,
                      "序列化键名必须是 shape_match")
    }
}
