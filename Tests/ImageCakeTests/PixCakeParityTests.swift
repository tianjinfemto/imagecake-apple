import CoreGraphics
import XCTest

@testable import ImageCake

/// 本轮"补像素蛋糕差距"的断言集：逐脸美化、黑眼圈/法令纹专项目、
/// 直方图与溢出诊断、拼图入口、素材库。
///
/// 写法沿用仓里那条规矩——**能离线断言的一律写死数值**，凡依赖网络权重的
/// 只测"缺件必须点名"，不测效果。区域类断言不硬写关键点派生出的坐标，
/// 而是先向被测的权重函数要峰值位置再下笔，这样改公式不会让测试假红。
final class PixCakeParityTests: XCTestCase {
    private var skinColor: (r: Double, g: Double, b: Double) { (0.70, 0.55, 0.45) }

    private func solidFace(_ size: PixelSize) -> DisplayImage {
        TestImage.solid(width: size.width, height: size.height,
                        r: skinColor.r, g: skinColor.g, b: skinColor.b)
    }

    private func shiftedFacePoints(dx: CGFloat, dy: CGFloat = 0) -> [CGPoint] {
        BeautyEngineTests.syntheticFacePoints().map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// 权重图里的峰值位置（区域算子的断言落点）。
    private func argmax(_ weights: [Float]) -> Int {
        var best = 0
        for (index, value) in weights.enumerated() where value > weights[best] { best = index }
        return best
    }

    // MARK: - 1. 逐脸美化（合影里每张脸都动）

    func testFaceGeometryDerivesUnderEyeAndNasolabialRegions() {
        let geometry = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())
        XCTAssertNotNil(geometry)
        guard let geometry else { return }
        XCTAssertEqual(geometry.underEyes.count, 2, "两张下睑椭圆，与眼睛同序")
        // 半眼宽由完整 12 点眼轮廓的 x 跨度算出，而不是只看两个写死的内外角：
        // 合成脸的 oval 循环把 155/145 这类下缘点也按椭圆铺开了，半宽 0.05110
        // 比"内外角 0.35→0.45"的 0.05 宽——眼睛轮廓是个椭圆，不是水平线段。
        // 数值由镜像脚本核对后回填；写死而不在测试里重算，因为公式自己就是被测对象。
        XCTAssertEqual(geometry.underEyes[0].center.x, 0.40, accuracy: 1e-9)
        XCTAssertEqual(geometry.underEyes[0].center.y, 0.47610, accuracy: 1e-5)
        XCTAssertEqual(geometry.underEyes[0].radiusX, 0.06403, accuracy: 1e-5)
        XCTAssertEqual(geometry.underEyes[0].radiusY, 0.03842, accuracy: 1e-5)
        XCTAssertEqual(geometry.nasolabialBands.count, 2)
        // 法令纹带长轴贴"鼻翼 → 嘴角"的连线：斜率 (0.60−0.52)/(0.43−0.46) = −8/3。
        XCTAssertEqual(geometry.nasolabialBands[0].angle, atan2(0.08, -0.03), accuracy: 1e-9)
        XCTAssertEqual(geometry.nasolabialBands[0].radiusX, hypot(0.03, 0.08) * 0.58, accuracy: 1e-9)
        XCTAssertTrue(geometry.nasolabialBands.allSatisfy { $0.radiusY > 0 && $0.radiusY < $0.radiusX },
                      "带必须是扁的（半径 y < x），否则盖不住一条斜纹")
    }

    func testDegenerateLandmarksYieldNoNasolabialBands() {
        // 右鼻翼与右嘴角重合 → 那一条带的方向无意义（用 78/129 这一对，
        // 带是按"鼻翼→同侧嘴角"配的）。两条带是一起收的，所以整张脸都不给，
        // 而不是拿一个猜出来的角度去推脸。
        var points = BeautyEngineTests.syntheticFacePoints()
        points[78] = points[129]
        let geometry = FaceGeometry.from(points: points)
        XCTAssertNotNil(geometry, "其他语义量仍然可用")
        XCTAssertEqual(geometry?.nasolabialBands.count ?? -1, 0,
                       "退化的一对点不该派生出法令纹带")
        XCTAssertEqual(geometry?.underEyes.count, 2, "下睑椭圆不依赖嘴角")
    }

    func testTwoFacesDeriveTwoBoxesOrderedByArea() {
        let size = PixelSize(width: 100, height: 100)
        let big = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())
        let small = FaceGeometry.from(points: shiftedFacePoints(dx: 0.25))
        XCTAssertNotNil(big)
        XCTAssertNotNil(small)
        var document = PipelineWiringDocument.make(size: size)
        document.faceGeometries = [big!, small!]
        XCTAssertEqual(document.faceBoxes.count, 2, "皮肤掩码要拿到两张脸框")
        XCTAssertEqual(document.faceGeometry, big, "主脸 = 数组第一格（调用侧按面积排序后写入）")
        XCTAssertTrue(document.pipelineWarnings.isEmpty,
                      "两张脸都派生成功时不该再点名，实际：\(document.pipelineWarnings)")
    }

    func testShapeWarpPushesEveryFaceNotJustTheLargest() {
        let size = PixelSize(width: 100, height: 100)
        let left = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())!
        let right = FaceGeometry.from(points: shiftedFacePoints(dx: 0.25))!
        var beauty = BeautyParameters()
        beauty.enlargeEyes = 100
        let both = ShapeWarp.build(size: size, faces: [left, right], body: nil, beauty: beauty)
        XCTAssertNotNil(both)
        guard let both else { return }
        let alone = ShapeWarp.build(size: size, faces: [left], body: nil, beauty: beauty)
        XCTAssertNotNil(alone)
        guard let alone else { return }

        // 第一张脸：圆心右侧的内容向外推（放大）= 采样偏移为负。
        XCTAssertLessThan(both.offsetX[43 * 100 + 42], 0, "第一张脸的大眼生效")
        XCTAssertGreaterThan(both.offsetX[43 * 100 + 38], 0, "圆心左侧反向")
        // 第二张脸：不拿具体像素值赌平滑流程的幅度，而是要求"两张脸都比
        // 只给一张脸多做了事"——第二张脸的作用域必须有像素被改动。
        let secondFacePixels = (39 ..< 48).flatMap { y in (60 ..< 70).map { x in y * size.width + x } }
        let changed = secondFacePixels.filter { abs(both.offsetX[$0] - alone.offsetX[$0]) > 1e-6 }
        XCTAssertGreaterThan(changed.count, 30,
                             "第二张脸完全没被推：它的作用域里只改了 \(changed.count) 个像素")
        XCTAssertEqual(both.offsetX[2 * 100 + 2], 0, "离两张脸都远的角落不被推")
    }

    func testRegionEnhanceAppliesToEveryFaceAndKeepsOutsideBitExact() {
        let size = PixelSize(width: 100, height: 100)
        let left = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())!
        let right = FaceGeometry.from(points: shiftedFacePoints(dx: 0.25))!
        let base = solidFace(size)
        var beauty = BeautyParameters()
        beauty.eyeBright = 100

        let lifted = RegionEnhance.apply(base, geometries: [left, right], beauty: beauty)
        XCTAssertGreaterThan(lifted.pixels[(43 * 100 + 40) * 4], base.pixels[(43 * 100 + 40) * 4],
                             "第一张脸的虹膜亮起来")
        XCTAssertGreaterThan(lifted.pixels[(43 * 100 + 65) * 4], base.pixels[(43 * 100 + 65) * 4],
                             "第二张脸的虹膜同样亮起来")
        XCTAssertEqual(lifted.pixels[(90 * 100 + 90) * 4], base.pixels[(90 * 100 + 90) * 4],
                       "两张脸之外逐比特不动")

        // 只给一张脸时，另一张脸的位置必须回到原值（不是"少做一点"而是"没做过"）。
        let oneFace = RegionEnhance.apply(base, geometries: [left], beauty: beauty)
        XCTAssertEqual(oneFace.pixels[(43 * 100 + 65) * 4], base.pixels[(43 * 100 + 65) * 4])
    }

    func testSkinMaskSeparatesEveryFaceFromBody() {
        let size = PixelSize(width: 100, height: 60)
        let image = TestImage.solid(width: size.width, height: size.height,
                                    r: skinColor.r, g: skinColor.g, b: skinColor.b)
        let left = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())!
        let right = FaceGeometry.from(points: shiftedFacePoints(dx: 0.25))!
        var document = PipelineWiringDocument.make(size: size)
        document.faceGeometries = [left, right]
        XCTAssertEqual(document.faceBoxes.count, 2, "皮肤掩码要拿到两张脸框")
        let layers = SkinMask.build(image, personMask: nil, faceBoxes: document.faceBoxes)
        let face = SkinMask.weights(layers.face, size: size)
        let body = SkinMask.weights(layers.body, size: size)
        // 两张脸的轮廓框在 x 上分别是 30…70 与 55…95，行 30（归一化 0.5）在两张
        // 脸的纵向范围内；x=5 在两张脸之外 → 只能落到身体层。
        XCTAssertGreaterThan(face[30 * size.width + 40], 0, "第一张脸框内是脸部皮肤")
        XCTAssertGreaterThan(face[30 * size.width + 80], 0, "第二张脸框内也是（否则合影只磨一张）")
        XCTAssertEqual(body[30 * size.width + 40], 0, "脸框内不该落到身体层")
        XCTAssertEqual(body[30 * size.width + 80], 0, "同上，第二张脸")
        XCTAssertGreaterThan(body[30 * size.width + 5], 0, "两张脸之外的皮肤归到身体层")
        XCTAssertTrue(layers.hasFaceConstraint)
    }

    func testDocumentPipelineCarriesAllFacesIntoRender() {
        let size = PixelSize(width: 100, height: 100)
        let left = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())!
        let right = FaceGeometry.from(points: shiftedFacePoints(dx: 0.25))!
        let baseline = PipelineWiringDocument.make(size: size)
        var styled = PipelineWiringDocument.make(size: size) { params in
            params.beauty.eyeBright = 80
            params.beauty.slimFace = 80
        }
        styled.faceGeometries = [left, right]
        let render = styled.render()
        let plain = baseline.render()
        XCTAssertNotEqual(render.pixels, plain.pixels, "有语义量时参数必须真的动画面")
        XCTAssertGreaterThan(render.pixels[(43 * 100 + 65) * 4], plain.pixels[(43 * 100 + 65) * 4],
                             "预览链要把第二张脸也吃进去（否则合影只动最大那张）")
    }

    // MARK: - 2. 祛黑眼圈

    func testDarkCircleLiftsOnlyTheDarkBandAndNeverPressesBright() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())!
        let weights = RegionEnhance.underEyeWeights(geometry, size: size)
        let peak = argmax(weights)
        XCTAssertGreaterThan(weights[peak], 0.5, "下睑椭圆必须有实权重，实际 \(weights[peak])")
        let peakY = peak / size.width
        let peakX = peak % size.width

        var pixels = solidFace(size).pixels
        // 暗带（模拟黑眼圈）+ 亮带（模拟脸骨高光），都画在作用区内。
        // 为什么先取峰值坐标再下笔：下睑椭圆的落点是关键点派生的结果，
        // 写死像素会让"公式调整"变成假红。
        func paint(_ xRange: Range<Int>, _ value: Float) {
            for y in (peakY - 1) ... (peakY + 1) {
                for x in xRange {
                    let o = (y * size.width + x) * 4
                    pixels[o] = value; pixels[o + 1] = value; pixels[o + 2] = value
                }
            }
        }
        paint((peakX - 6) ..< (peakX - 2), 0.40)   // 暗
        paint((peakX + 2) ..< (peakX + 8), 0.95)   // 亮
        let input = DisplayImage(size: size, pixels: pixels)

        var beauty = BeautyParameters()
        beauty.darkCircle = 100
        let result = RegionEnhance.apply(input, geometries: [geometry], beauty: beauty)

        let dark = (peakY * size.width + (peakX - 4)) * 4
        let bright = (peakY * size.width + (peakX + 4)) * 4
        let untouched = (95 * size.width + 95) * 4
        XCTAssertGreaterThan(result.pixels[dark], input.pixels[dark], "暗带要被抬亮")
        XCTAssertEqual(result.pixels[bright], input.pixels[bright], accuracy: 1e-6,
                       "只抬不压：比参考值亮的像素一律不动")
        XCTAssertEqual(result.pixels[untouched], input.pixels[untouched], "作用区外逐比特不变")
    }

    func testDarkCircleKeepsLashLineUntouched() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())!
        let weights = RegionEnhance.underEyeWeights(geometry, size: size)
        let peak = argmax(weights)
        let peakY = peak / size.width
        let peakX = peak % size.width
        var pixels = solidFace(size).pixels
        // 睫毛级黑线（L < 0.15）落在作用区正中的峰值行上。
        for x in (peakX - 4) ... (peakX + 4) {
            let o = (peakY * size.width + x) * 4
            pixels[o] = 0.05; pixels[o + 1] = 0.05; pixels[o + 2] = 0.05
        }
        let input = DisplayImage(size: size, pixels: pixels)
        var beauty = BeautyParameters()
        beauty.darkCircle = 100
        let result = RegionEnhance.apply(input, geometries: [geometry], beauty: beauty)
        let o = (peakY * size.width + peakX) * 4
        XCTAssertEqual(result.pixels[o], input.pixels[o], accuracy: 1e-6,
                       "极暗像素不抬，否则眼下会出现一圈白边")
    }

    // MARK: - 3. 祛法令纹

    func testNasolabialFillsThinDarkLineButLeavesBroadShadingAlone() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())!
        let weights = RegionEnhance.nasolabialWeights(geometry, size: size)
        let peak = argmax(weights)
        XCTAssertGreaterThan(weights[peak], 0.3, "法令纹带必须有实权重，实际 \(weights[peak])")
        let peakY = peak / size.width
        let peakX = peak % size.width

        var beauty = BeautyParameters()
        beauty.nasolabial = 100

        // (a) 一列宽的暗线 → 应被填亮。
        var linePixels = solidFace(size).pixels
        for y in (peakY - 6) ... (peakY + 6) {
            let o = (y * size.width + peakX) * 4
            linePixels[o] = 0.40; linePixels[o + 1] = 0.32; linePixels[o + 2] = 0.26
        }
        let line = DisplayImage(size: size, pixels: linePixels)
        let filled = RegionEnhance.apply(line, geometries: [geometry], beauty: beauty)
        let lineIndex = (peakY * size.width + peakX) * 4
        XCTAssertGreaterThan(filled.pixels[lineIndex], line.pixels[lineIndex], "细暗线要向低频填")

        // (b) 一大块均匀暗区（脸型的低频阴影）→ 不得被动。
        var blockPixels = solidFace(size).pixels
        for y in (peakY - 12) ... (peakY + 12) {
            for x in (peakX - 12) ... (peakX + 12) {
                let o = (y * size.width + x) * 4
                blockPixels[o] = 0.40; blockPixels[o + 1] = 0.32; blockPixels[o + 2] = 0.26
            }
        }
        let block = DisplayImage(size: size, pixels: blockPixels)
        let kept = RegionEnhance.apply(block, geometries: [geometry], beauty: beauty)
        XCTAssertEqual(kept.pixels[lineIndex], block.pixels[lineIndex], accuracy: 1e-6,
                       "低频阴影落在参考值里，填它等于把脸弄扁")

        // (c) 亮线不压（只处理暗的一侧）。
        var brightPixels = solidFace(size).pixels
        for y in (peakY - 6) ... (peakY + 6) {
            let o = (y * size.width + peakX) * 4
            brightPixels[o] = 0.98; brightPixels[o + 1] = 0.96; brightPixels[o + 2] = 0.94
        }
        let bright = DisplayImage(size: size, pixels: brightPixels)
        let brightOut = RegionEnhance.apply(bright, geometries: [geometry], beauty: beauty)
        XCTAssertEqual(brightOut.pixels[lineIndex], bright.pixels[lineIndex], accuracy: 1e-6,
                       "亮边不该被压成灰")
    }

    func testRotatedDiskRasterizesAlongItsAngle() {
        let size = PixelSize(width: 41, height: 41)
        let disk = RegionRaster.disk(center: CGPoint(x: 20, y: 20), radiusX: 10, radiusY: 2,
                                     angle: Double.pi / 4, size: size)
        let bytes = [UInt8](disk.data)
        func value(_ x: Int, _ y: Int) -> Int { Int(bytes[y * 41 + x]) }
        // 不钉具体字节（smoothstep + 像素中心采样的组合值容易让人猜错），
        // 钉的是结构：中心满、沿长轴单调落下、两个未旋转轴上都是空。
        XCTAssertGreaterThanOrEqual(value(20, 20), 250, "中心格")
        XCTAssertLessThan(value(18, 18), value(20, 20), "往外单调落下")
        XCTAssertLessThan(value(24, 24), value(18, 18), "继续落下")
        // 像素中心是 x+0.5，所以与 (18,18) 对称的是 (21,21)（都是 1.5px 偏），
        // 而不是 (22,22)（2.5px）。
        XCTAssertEqual(value(18, 18), value(21, 21), "沿长轴对称")
        XCTAssertEqual(value(28, 28), 0, "45° 方向已出带（短轴只 2）")
        XCTAssertEqual(value(30, 20), 0, "未旋转的长轴端点在带外")
        XCTAssertEqual(value(20, 30), 0, "未旋转的短轴端点在带外")
    }

    // MARK: - 4. 直方图与溢出诊断

    private func assertBinsMatchEncoding(_ image: DisplayImage) {
        let histogram = HistogramBuilder.build(image)
        let encoded = image.rgba8().rgbaArrays()
        XCTAssertEqual(histogram.red.count, encoded.r.count)
        for index in 0 ..< histogram.red.count {
            XCTAssertEqual(histogram.red[index], encoded.r[index], "第 \(index) 箱与编码口径不一致")
            XCTAssertEqual(histogram.green[index], encoded.g[index])
            XCTAssertEqual(histogram.blue[index], encoded.b[index])
        }
    }

    func testHistogramBinsMatchEightBitEncodingExactly() {
        let size = PixelSize(width: 8, height: 8)
        // 覆盖 <0、=0、中间值、>1 四类，证明"直方图预测的就是文件里的结果"。
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        let probes: [Float] = [-0.2, 0, 0.1234, 0.5, 0.999, 1.0, 1.5, 0.50196]
        for (index, value) in probes.enumerated() {
            let o = index * 4
            pixels[o] = value
            pixels[o + 1] = value * 0.5
            pixels[o + 2] = min(1.4, value * 1.2)
            pixels[o + 3] = 1
        }
        assertBinsMatchEncoding(DisplayImage(size: size, pixels: pixels))
    }

    func testHistogramCountsAndSampling() {
        let size = PixelSize(width: 40, height: 20)
        let white = TestImage.solid(width: size.width, height: size.height, r: 1, g: 1, b: 1)
        let histogram = HistogramBuilder.build(white)
        XCTAssertEqual(histogram.sampleCount, size.pixelCount)
        XCTAssertEqual(histogram.red.reduce(0, +), size.pixelCount, "每像素正好进一箱")
        XCTAssertEqual(histogram.red.last, size.pixelCount, "全白 → 255 箱")
        XCTAssertEqual(histogram.clippedHighlightPixels, size.pixelCount)
        XCTAssertEqual(histogram.clippedHighlightRatio, 1, accuracy: 1e-12)
        XCTAssertEqual(histogram.shadowPeak, 0)

        let sampled = HistogramBuilder.build(white, stride: 4)
        XCTAssertEqual(sampled.sampleCount, size.pixelCount / 4, "抽样只减样本不改形状")

        XCTAssertEqual(HistogramBuilder.suggestedStride(pixelCount: 1000), 1)
        XCTAssertEqual(HistogramBuilder.suggestedStride(pixelCount: 1_000_000), 2)
    }

    func testHistogramFlagsOutOfRangeWithoutSilentClampingStory() {
        let size = PixelSize(width: 4, height: 1)
        var pixels = [Float](repeating: 0.5, count: size.pixelCount * 4)
        pixels[0] = 1.8
        pixels[5] = -0.3
        let histogram = HistogramBuilder.build(DisplayImage(size: size, pixels: pixels))
        XCTAssertEqual(histogram.outOfRangeCount, 2, "越界像素要单独点名，不能静默夹走")
        XCTAssertEqual(histogram.red.last, 1, "1.8 进 255 箱")
        XCTAssertEqual(histogram.green.first, 1, "−0.3 进 0 箱")
    }

    func testLumaHistogramUsesRec709OnClampedValues() {
        let size = PixelSize(width: 2, height: 1)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        pixels[0] = 1; pixels[1] = 1; pixels[2] = 1; pixels[3] = 1
        pixels[4] = 0; pixels[5] = 0; pixels[6] = 0; pixels[7] = 1
        let histogram = HistogramBuilder.build(DisplayImage(size: size, pixels: pixels))
        XCTAssertEqual(histogram.luma[255], 1)
        XCTAssertEqual(histogram.luma[0], 1)
        XCTAssertEqual(histogram.normalized(histogram.luma).max() ?? 0, 1, accuracy: 1e-12)
        XCTAssertTrue(Histogram.empty.isEmpty)
    }

    func testClippingOverlayMarksBothEndsAndDimsTheRest() {
        let size = PixelSize(width: 4, height: 1)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        pixels[0] = 1; pixels[1] = 1; pixels[2] = 1
        pixels[4] = 0; pixels[5] = 0; pixels[6] = 0
        pixels[8] = 0.5; pixels[9] = 0.5; pixels[10] = 0.5
        pixels[12] = 0.5; pixels[13] = 0.5; pixels[14] = 0.5
        let overlay = ClippingOverlay.mask(DisplayImage(size: size, pixels: pixels))
        let bytes = [UInt8](overlay.data)
        XCTAssertEqual(bytes[0], 255)
        XCTAssertEqual(bytes[1], 46, "高光溢出标红")
        XCTAssertEqual(bytes[4], 46)
        XCTAssertEqual(bytes[5], 120, "暗部溢出标蓝")
        XCTAssertEqual(bytes[12], 20)
        XCTAssertLessThan(bytes[15], 120, "正常像素只被压暗，不标色")
        XCTAssertEqual(overlay.size, size)
    }

    // MARK: - 5. 拼图入口

    func testCollageAspectFillKeepsStructureAndSize() {
        // 绿心 + 红环：等比裁切后必须还是"红边包绿心"，而不是被拉成别的构图。
        let size = PixelSize(width: 4, height: 4)
        var data = [UInt8](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                let border = x == 0 || y == 0 || x == size.width - 1 || y == size.height - 1
                data[o] = border ? 220 : 20
                data[o + 1] = border ? 20 : 220
                data[o + 2] = 20
                data[o + 3] = 255
            }
        }
        let image = RGBA8Buffer(size: size, data: Data(data))
        let rect = PixelRect(x: 0, y: 0, width: 100, height: 100)
        let filled = CollageEngine.fit(image, to: rect, mode: .aspectFill)
        XCTAssertEqual(filled.size, rect.size, "fit 的产物必须正好是槽位尺寸")
        let bytes = [UInt8](filled.data)
        func color(_ x: Int, _ y: Int) -> (UInt8, UInt8) {
            let o = (y * rect.width + x) * 4
            return (bytes[o], bytes[o + 1])
        }
        XCTAssertEqual(color(0, 0).0, 220, "左上仍是红边")
        XCTAssertEqual(color(99, 99).0, 220, "右下仍是红边")
        XCTAssertEqual(color(50, 50).1, 220, "中心仍是绿")
    }

    func testCollageAspectFitLetterboxesWithBackground() {
        let image = TestImage.solidRGBA8(width: 200, height: 50, r: 200, g: 10, b: 10)
        let rect = PixelRect(x: 0, y: 0, width: 100, height: 100)
        let fitted = CollageEngine.fit(image, to: rect, mode: .aspectFit)
        XCTAssertEqual(fitted.size, rect.size)
        let bytes = [UInt8](fitted.data)
        func red(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * rect.width + x) * 4] }
        XCTAssertGreaterThan(red(50, 50), 150, "中间那条带是图")
        XCTAssertEqual(red(50, 2), 0, "上下留白（此处底色为 0）")
        XCTAssertEqual(red(50, 97), 0)
    }

    func testCollageComposePlacesEverySlot() {
        let size = PixelSize(width: 100, height: 100)
        let template = CollageEngine.templates.first { $0.name.contains("2×2") }!
        let images = [
            TestImage.solidRGBA8(width: 20, height: 20, r: 255, g: 0, b: 0),
            TestImage.solidRGBA8(width: 20, height: 20, r: 0, g: 255, b: 0),
            TestImage.solidRGBA8(width: 20, height: 20, r: 0, g: 0, b: 255),
            TestImage.solidRGBA8(width: 20, height: 20, r: 255, g: 255, b: 0)
        ]
        var filled = template
        filled.background = RGBA8(r: 255, g: 255, b: 255)
        let canvas = CollageEngine.compose(images: images, template: filled, canvasSize: size)
        XCTAssertNotNil(canvas)
        guard let canvas else { return }
        let bytes = [UInt8](canvas.data)
        func channel(_ x: Int, _ y: Int, _ c: Int) -> UInt8 { bytes[((y * size.width + x) * 4) + c] }
        XCTAssertEqual(channel(25, 25, 0), 255, "左上格 = 红")
        XCTAssertEqual(channel(75, 25, 1), 255, "右上格 = 绿")
        XCTAssertEqual(channel(25, 75, 2), 255, "左下格 = 蓝")
        XCTAssertEqual(channel(75, 75, 0), 255, "右下格 = 黄")
        XCTAssertEqual(channel(75, 75, 2), 0)
        // 满铺模板不该露出底色（元组不能当 Equatable 比较，逐通道判）。
        for y in stride(from: 1, to: 99, by: 9) {
            for x in stride(from: 1, to: 99, by: 9) where channel(x, y, 0) == 255 {
                XCTAssertFalse(channel(x, y, 1) == 255 && channel(x, y, 2) == 255,
                               "\(x),\(y) 露出了底色")
            }
        }
    }

    func testCollageShortfallIsNamedInsteadOfFaked() {
        // 模板缺失与图不够是两件独立的错：前者由 `CollageComposition.missingTemplateNote`
        // 管（导出侧先查模板），后者由 `shortfallWarning` 管（底栏提前提示）。
        let missing = CollageComposition(templateID: UUID())
        XCTAssertTrue(CollageComposition.missingTemplateNote.contains("[collage_no_template]"),
                      "模板找不到也要点名，实际：\(CollageComposition.missingTemplateNote)")
        XCTAssertTrue((missing.shortfallWarning(slots: 4) ?? "").contains("[collage_short]"),
                      "只有主图时 4 格就是不够，不管模板对不对都得说")

        var two = CollageComposition(templateID: UUID(), extraURLs: [URL(fileURLWithPath: "/a.jpg"),
                                                                    URL(fileURLWithPath: "/b.jpg")])
        XCTAssertNil(two.shortfallWarning(slots: 3), "2 张副图 + 主图正好填满 3 格")
        XCTAssertNotNil(two.shortfallWarning(slots: 4)?.contains("[collage_short]"), "4 格只有 3 张要点名")
        two.allowMainRepeat = true
        XCTAssertNil(two.shortfallWarning(slots: 4), "显式允许重复后不再算缺图")
    }

    func testCollageWarningReachesDocumentAndExportCarriesIt() async {
        let size = PixelSize(width: 16, height: 16)
        let template = CollageEngine.templates.first { $0.name.contains("2×2") }!
        var document = PipelineWiringDocument.make(size: size)
        document.collage = CollageComposition(templateID: template.id)
        XCTAssertTrue(document.pipelineWarnings.contains { $0.contains("[collage_short]") },
                      "拼图缺图要在底栏就被看见，实际：\(document.pipelineWarnings)")
        document.collage?.extraURLs = (1 ... 3).map { URL(fileURLWithPath: "/missing-\($0).jpg") }
        XCTAssertFalse(document.pipelineWarnings.contains { $0.contains("[collage_short]") },
                       "图数够了就不该再报")

        // 读不到的图源 → 不排版、点名、画面保持原样（不能让导出静默变半张）。
        let store = ModelStore(manifest: .emptyForTests)
        let outcome = await ExportPipeline.render(document, store: store,
                                                 ort: ORTEngine.shared, fullResolution: false)
        XCTAssertTrue(outcome.notes.contains { $0.hasPrefix("[collage_failed]") },
                      "实际报告：\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains { $0.hasPrefix("[collage] ") }, "未排版不得报成功")
        XCTAssertEqual(outcome.display.size, size, "排版失败时输出仍是主图原尺寸")
    }

    // MARK: - 6. 素材库

    func testSidecarNamingAndCollision() {
        XCTAssertEqual(ImageLibrary.sidecarName(for: URL(fileURLWithPath: "/a/b/photo.jpg")),
                       "photo.imagecake.json")
        XCTAssertEqual(ImageLibrary.sidecarName(for: URL(fileURLWithPath: "/a/b/raw.dng")),
                       "raw.imagecake.json")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imagecake-library-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.jpg", "a.png", "note.txt", "IMG_2.jpeg"] {
            try? Data([0xFF]).write(to: directory.appendingPathComponent(name))
        }
        let items = ImageLibrary.scan(folder: directory)
        XCTAssertEqual(items.map(\.fileName), ["a.jpg", "a.png", "IMG_2.jpeg"],
                       "只列图片、按文件名排序（大小写不敏感）")
        XCTAssertEqual(items.first(where: { $0.fileName == "a.png" })?.sidecarName, nil,
                       "重名图的 sidecar 要冲突点名，而不是共用一份参数")
        XCTAssertNotNil(items.first(where: { $0.fileName == "a.jpg" })?.sidecarName)
        XCTAssertTrue(ImageLibrary.scan(folder: directory.appendingPathComponent("nope")).isEmpty)
    }

    func testLibraryStatusDerivesFromDocumentFacts() {
        let size = PixelSize(width: 8, height: 8)
        XCTAssertEqual(ImageLibrary.derive(document: nil), .unedited)
        XCTAssertEqual(ImageLibrary.derive(document: PipelineWiringDocument.make(size: size)), .unedited)

        var toned = PipelineWiringDocument.make(size: size)
        toned.params.exposure = 0.2
        XCTAssertEqual(ImageLibrary.derive(document: toned), .edited, "参数动过就是已修")

        var masked = PipelineWiringDocument.make(size: size)
        masked.personMask = MaskBuffer.filled(size, value: 255)
        XCTAssertEqual(ImageLibrary.derive(document: masked), .edited, "抠过图也是动过这张图")

        var strokes = PipelineWiringDocument.make(size: size)
        strokes.localAdjustments = [LocalAdjustment(mask: .radial(center: CGPoint(x: 0.5, y: 0.5), radius: 0.3))]
        XCTAssertEqual(ImageLibrary.derive(document: strokes), .edited)
    }

    func testProgressSidecarRoundTripAndRejections() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imagecake-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("photo.jpg")
        try Data([0xFF]).write(to: imageURL)
        let item = LibraryItem(url: imageURL, sidecarName: ImageLibrary.sidecarName(for: imageURL))

        var params = EditParameters()
        params.exposure = 0.75
        params.beauty.darkCircle = 33
        XCTAssertNotNil(ProjectStore.save(params: params, status: .edited, to: item))
        let loaded = ProjectStore.load(from: item)
        XCTAssertEqual(loaded?.params.exposure ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(loaded?.params.beauty.darkCircle ?? 0, 33, accuracy: 1e-9, "专项目也得跟着续作")
        XCTAssertEqual(loaded?.status, .edited)

        // 坏文件不抛、不猜。
        try Data("not json".utf8).write(to: item.sidecarURL!)
        XCTAssertNil(ProjectStore.load(from: item))

        // 比本程序新的预设拒收。
        var future = ProjectStore.ProgressFile()
        future.presetVersion = EditParameters.presetVersion + 1
        future.params = params
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(future).write(to: item.sidecarURL!)
        XCTAssertNil(ProjectStore.load(from: item), "未来的版本不能猜字段")

        // 重名冲突的条目不写 sidecar。
        let conflicted = LibraryItem(url: imageURL, sidecarName: nil)
        XCTAssertNil(ProjectStore.save(params: params, status: .edited, to: conflicted))
    }

    func testLibraryFilterAndCounts() {
        let items = [
            LibraryItem(url: URL(fileURLWithPath: "/a.jpg"), status: .unedited),
            LibraryItem(url: URL(fileURLWithPath: "/b.jpg"), status: .edited),
            LibraryItem(url: URL(fileURLWithPath: "/c.jpg"), status: .edited),
            LibraryItem(url: URL(fileURLWithPath: "/d.jpg"), status: .exported)
        ]
        XCTAssertEqual(ImageLibrary.filter(items, by: .all).count, 4)
        XCTAssertEqual(ImageLibrary.filter(items, by: .edited).count, 2)
        XCTAssertEqual(ImageLibrary.filter(items, by: .unedited).first?.fileName, "a.jpg")
        XCTAssertEqual(ImageLibrary.counts(items)[.exported] ?? 0, 1)
        XCTAssertEqual(ImageLibrary.counts([])[.edited] ?? 0, 0)
    }

    // MARK: - 7. 预设契约（新增三键）

    func testNewBeautyKeysRoundTripAndDefaultToOff() throws {
        let json = "{\"dark_circle\": 40, \"nasolabial\": 60}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BeautyParameters.self, from: json)
        XCTAssertEqual(decoded.darkCircle, 40)
        XCTAssertEqual(decoded.nasolabial, 60)
        XCTAssertEqual(decoded.eyeBright, 0, "缺键落出厂值")

        let empty = try JSONDecoder().decode(BeautyParameters.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(empty.isRegionNeutral, "新键出厂必须是关，否则旧预设一载入就推脸")

        var full = BeautyParameters()
        full.darkCircle = 55
        full.nasolabial = 66
        let encoded = try JSONEncoder().encode(full)
        let roundTrip = try JSONDecoder().decode(BeautyParameters.self, from: encoded)
        XCTAssertEqual(roundTrip, full)

        XCTAssertTrue(BeautyParameters().isRegionNeutral)
        var onlyDark = BeautyParameters()
        onlyDark.darkCircle = 1
        XCTAssertFalse(onlyDark.isRegionNeutral, "专项目必须能单独驱动区域段")
    }

    func testParamSyncCarriesNewSpecialItemsWithSkinGroup() {
        var source = EditParameters()
        source.beauty.darkCircle = 70
        source.beauty.nasolabial = 80
        let merged = ParamSync.merge(source: source, into: EditParameters(), groups: [.skin])
        XCTAssertEqual(merged.beauty.darkCircle, 70)
        XCTAssertEqual(merged.beauty.nasolabial, 80)
        let notMerged = ParamSync.merge(source: source, into: EditParameters(), groups: [.tone])
        XCTAssertEqual(notMerged.beauty.darkCircle, 0, "只勾调色不该把专项目抄过去")
    }
}

// MARK: - 测试辅助

/// 造一个只带最小资产的文档（与 PipelineWiringTests 里的 `doc` 同一条路径，
/// 抽出来给两个测试类共用，免得两份"怎么造文档"漂移成两套口径）。
enum PipelineWiringDocument {
    static func make(size: PixelSize, _ tune: (inout EditParameters) -> Void = { _ in }) -> ImageDocument {
        var params = EditParameters()
        tune(&params)
        // 底色就是皮肤色：让"造文档"不牵动皮肤掩码/调色那些无关分支。
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            pixels[o] = 0.70; pixels[o + 1] = 0.55; pixels[o + 2] = 0.45; pixels[o + 3] = 1
        }
        return ImageDocument(linear: LinearImage(size: size, pixels: pixels),
                             originalSize: size,
                             params: params,
                             sourceURL: nil,
                             isRAW: false,
                             loadNote: "",
                             personMask: nil,
                             maskReference: size,
                             patches: [])
    }
}

extension RGBA8Buffer {
    /// 把四个通道拆成 R/G/B 计数数组（直方图对照用）。
    func rgbaArrays() -> (r: [Int], g: [Int], b: [Int], a: [Int]) {
        let bytes = [UInt8](data)
        var r = [Int](repeating: 0, count: 256)
        var g = [Int](repeating: 0, count: 256)
        var b = [Int](repeating: 0, count: 256)
        var a = [Int](repeating: 0, count: 256)
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            r[Int(bytes[o])] += 1
            g[Int(bytes[o + 1])] += 1
            b[Int(bytes[o + 2])] += 1
            a[Int(bytes[o + 3])] += 1
        }
        return (r, g, b, a)
    }
}

extension ModelManifest {
    /// 一份空清单：只为了拿一个合法的 ModelStore 去跑导出链（不下载、不推理）。
    static let emptyForTests = ModelManifest(schema: 1, defaultTier: .core, models: [])
}
