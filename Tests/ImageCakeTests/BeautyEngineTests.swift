import CoreGraphics
import XCTest

@testable import ImageCake

/// 人像精修与美型的离线断言。
///
/// 这些算子全是零权重、确定性的：错了在真机上只表现为"画面怪怪的"，
/// 而在无 Xcode 的环境里连"怪怪的"都看不到。所以每一条都钉住**性质**
/// （只碰掩码内、亮度守恒、纹理不消失、锚线以上不动），而不是钉住某个
/// 具体数值——具体数值随参数微调会变，性质不会。
final class BeautyEngineTests: XCTestCase {
    // MARK: - 皮肤掩码

    func testSkinLocusAcceptsSkinAndRejectsCommonNonSkin() {
        XCTAssertTrue(SkinMask.isSkin(r: 0.85, g: 0.68, b: 0.58), "典型肤色")
        XCTAssertTrue(SkinMask.isSkin(r: 0.70, g: 0.50, b: 0.38), "偏深肤色")
        XCTAssertFalse(SkinMask.isSkin(r: 0.10, g: 0.30, b: 0.80), "蓝天")
        XCTAssertFalse(SkinMask.isSkin(r: 0.20, g: 0.50, b: 0.20), "绿叶")
        XCTAssertFalse(SkinMask.isSkin(r: 0.50, g: 0.50, b: 0.50), "中性灰（无饱和）")
        XCTAssertFalse(SkinMask.isSkin(r: 1.00, g: 1.00, b: 1.00), "纯白")
        XCTAssertFalse(SkinMask.isSkin(r: 0.05, g: 0.04, b: 0.04), "近黑")
        // 深木色：色相与明度都像皮肤，只有饱和度能把它挡住。
        XCTAssertFalse(SkinMask.isSkin(r: 0.25, g: 0.15, b: 0.08), "高饱和木头不该算皮肤")
    }

    func testSkinMaskBuildSeparatesFaceFromBody() {
        let size = PixelSize(width: 32, height: 32)
        // 整张都是肤色，人脸框只圈住上半：能单独考验“脸/身分家”这一步。
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            pixels[i * 4] = 0.85
            pixels[i * 4 + 1] = 0.68
            pixels[i * 4 + 2] = 0.58
            pixels[i * 4 + 3] = 1
        }
        let image = DisplayImage(size: size, pixels: pixels)
        let layers = SkinMask.build(image, personMask: nil, faceBoxes: [CGRect(x: 0, y: 0, width: 1, height: 0.5)])
        XCTAssertTrue(layers.hasFaceConstraint)
        let face = SkinMask.weights(layers.face, size: size)
        let body = SkinMask.weights(layers.body, size: size)
        XCTAssertGreaterThan(face[8 * 32 + 16], 0.5, "脸框内的肤色归到脸")
        XCTAssertLessThan(body[8 * 32 + 16], 0.1, "脸框内的皮肤不该同时算身体")
        XCTAssertGreaterThan(body[24 * 32 + 16], 0.5, "脸框外的肤色归到身体")
        XCTAssertLessThan(face[24 * 32 + 16], 0.1)
    }

    func testSkinMaskIntersectsWithPersonAlpha() {
        let size = PixelSize(width: 16, height: 16)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for i in 0 ..< size.pixelCount {
            pixels[i * 4] = 0.85
            pixels[i * 4 + 1] = 0.68
            pixels[i * 4 + 2] = 0.58
            pixels[i * 4 + 3] = 1
        }
        let image = DisplayImage(size: size, pixels: pixels)
        // α：只有左半是人。
        var alpha = [UInt8](repeating: 0, count: size.pixelCount)
        for y in 0 ..< size.height {
            for x in 0 ..< 8 { alpha[y * size.width + x] = 255 }
        }
        let layers = SkinMask.build(image, personMask: MaskBuffer(size: size, data: Data(alpha)), faceBoxes: [])
        let weights = SkinMask.weights(layers.all, size: size)
        XCTAssertGreaterThan(weights[2 * 16 + 1], 0.7, "α 内的皮肤仍在")
        XCTAssertLessThan(weights[2 * 16 + 15], 0.1, "α 外的同款颜色要被切掉（不然沙色背景会被磨皮）")
        XCTAssertFalse(layers.hasFaceConstraint, "没给关键点就不能谎称分得开脸和身")
    }

    // MARK: - 对立色往返

    func testOpponentRoundTripIsExact() {
        let samples: [(Double, Double, Double)] = [(0.85, 0.68, 0.58), (0, 0, 0), (1, 1, 1), (0.2, 0.9, 0.4)]
        for (r, g, b) in samples {
            let opp = BeautyEngine.opponent(r: r, g: g, b: b)
            let back = BeautyEngine.fromOpponent(l: opp.l, a: opp.a, b: opp.b)
            XCTAssertEqual(back.r, r, accuracy: 1e-12)
            XCTAssertEqual(back.g, g, accuracy: 1e-12)
            XCTAssertEqual(back.b, b, accuracy: 1e-12)
        }
    }

    // MARK: - 磨皮

    func testBeautyNeutralIsBitExactNoop() {
        let image = TestImage.gradient(width: 16, height: 16)
        let layers = fullSkinLayers(size: image.size)
        let result = BeautyEngine.apply(image, skin: layers, beauty: BeautyParameters())
        XCTAssertEqual(result.pixels, image.pixels)
    }

    func testSmoothReducesNoiseButKeepsTexture() {
        let size = PixelSize(width: 24, height: 24)
        let image = noisySkin(size: size, amplitude: 0.03)
        let layers = fullSkinLayers(size: size)
        var beauty = BeautyParameters()
        beauty.skinSmooth = 80
        let result = BeautyEngine.apply(image, skin: layers, beauty: beauty)

        let before = meanAdjacentDifference(result.size, image.pixels)
        let after = meanAdjacentDifference(result.size, result.pixels)
        XCTAssertLessThan(after, before, "满力度磨皮必须让高频噪声方差下降")
        XCTAssertGreaterThan(after, 0, "纹理不能被打磨成零——那正是「磨到毛孔消失」的样子")
    }

    func testSmoothOnlyTouchesSkinMask() {
        let size = PixelSize(width: 16, height: 16)
        let image = noisySkin(size: size, amplitude: 0.03)
        // 只有左半是皮肤。
        var face = [UInt8](repeating: 0, count: size.pixelCount)
        for y in 0 ..< size.height {
            for x in 0 ..< 8 { face[y * size.width + x] = 255 }
        }
        let layers = SkinMask.Layers(all: MaskBuffer(size: size, data: Data(face)),
                                     face: MaskBuffer(size: size, data: Data(face)),
                                     body: MaskBuffer.filled(size, value: 0),
                                     hasFaceConstraint: true)
        var beauty = BeautyParameters()
        beauty.skinSmooth = 100
        beauty.blemish = 100
        beauty.whitening = 100
        let result = BeautyEngine.apply(image, skin: layers, beauty: beauty)
        for y in 0 ..< size.height {
            for x in 8 ..< size.width {
                let o = (y * size.width + x) * 4
                XCTAssertEqual(result.pixels[o], image.pixels[o], "掩码外的像素必须逐比特不变")
            }
        }
    }

    func testBlemishFillsIsolatedSpotButNotSmoothRamp() {
        let size = PixelSize(width: 16, height: 16)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        func set(_ x: Int, _ y: Int, _ v: Float) {
            let o = (y * size.width + x) * 4
            pixels[o] = v
            pixels[o + 1] = v * 0.78
            pixels[o + 2] = v * 0.66
            pixels[o + 3] = 1
        }
        for y in 0 ..< size.height {
            for x in 0 ..< size.width { set(x, y, 0.80) }
        }
        set(8, 8, 0.55)                       // 一颗暗痘
        let dot = (8 * size.width + 8) * 4
        let before = pixels[dot]

        let image = DisplayImage(size: size, pixels: pixels)
        let layers = fullSkinLayers(size: size)
        var beauty = BeautyParameters()
        beauty.blemish = 100
        let result = BeautyEngine.apply(image, skin: layers, beauty: beauty)
        XCTAssertGreaterThan(result.pixels[dot], before + 0.1, "孤点暗痘要被邻域填掉")

        // 同一段力度用在大尺度渐变上：不该动中间地带。
        var ramp = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                ramp[o] = 0.5 + Float(x) * 0.01
                ramp[o + 1] = ramp[o] * 0.78
                ramp[o + 2] = ramp[o] * 0.66
                ramp[o + 3] = 1
            }
        }
        let rampImage = DisplayImage(size: size, pixels: ramp)
        let smoothed = BeautyEngine.apply(rampImage, skin: layers, beauty: beauty)
        for y in 4 ..< 12 {
            for x in 4 ..< 12 {
                let o = (y * size.width + x) * 4
                XCTAssertEqual(smoothed.pixels[o], ramp[o], accuracy: 1e-3, "平滑渐变不是瑕疵，不该被填")
            }
        }
    }

    func testToneUnifyShrinksChromaDifferenceAndKeepsLuma() {
        let size = PixelSize(width: 20, height: 20)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                let isLeftBlock = x < 10
                pixels[o] = 0.80
                pixels[o + 1] = isLeftBlock ? 0.58 : 0.68
                pixels[o + 2] = isLeftBlock ? 0.44 : 0.56
                pixels[o + 3] = 1
            }
        }
        let image = DisplayImage(size: size, pixels: pixels)
        var beauty = BeautyParameters()
        beauty.toneUnify = 100
        let result = BeautyEngine.apply(image, skin: fullSkinLayers(size: size), beauty: beauty)

        func opp(_ x: Int, _ y: Int, _ buffer: [Float]) -> (l: Double, a: Double) {
            let o = (y * size.width + x) * 4
            let v = BeautyEngine.opponent(r: Double(buffer[o]), g: Double(buffer[o + 1]), b: Double(buffer[o + 2]))
            return (v.l, v.a)
        }
        let leftBefore = opp(6, 10, pixels), rightBefore = opp(14, 10, pixels)
        let leftAfter = opp(6, 10, result.pixels), rightAfter = opp(14, 10, result.pixels)
        XCTAssertLessThan(abs(leftAfter.a - rightAfter.a), abs(leftBefore.a - rightBefore.a), "两块色度差必须收敛")
        XCTAssertEqual(leftAfter.l, leftBefore.l, accuracy: 1e-5, "匀肤色不该改亮度")
        XCTAssertEqual(rightAfter.l, rightBefore.l, accuracy: 1e-5)
    }

    func testRednessOnlyPullsRedderPixels() {
        let size = PixelSize(width: 21, height: 21)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                let red = x == 10
                pixels[o] = red ? 0.90 : 0.80
                pixels[o + 1] = 0.62
                pixels[o + 2] = 0.50
                pixels[o + 3] = 1
            }
        }
        let image = DisplayImage(size: size, pixels: pixels)
        var beauty = BeautyParameters()
        beauty.redness = 100
        let result = BeautyEngine.apply(image, skin: fullSkinLayers(size: size), beauty: beauty)

        func redness(_ x: Int, _ buffer: [Float]) -> Double {
            let o = (10 * size.width + x) * 4
            return Double(buffer[o]) - Double(buffer[o + 1])
        }
        XCTAssertLessThan(redness(10, result.pixels), redness(10, pixels), "偏红那列要被拉回局部均值")
        XCTAssertEqual(result.pixels[(5 * size.width + 5) * 4], pixels[(5 * size.width + 5) * 4], accuracy: 1e-5,
                       "不偏红的列不该被推成绿色")
    }

    func testDeShinePressesBrightDesaturatedSpotOnly() {
        let size = PixelSize(width: 20, height: 20)
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let o = (y * size.width + x) * 4
                let shine = x >= 6 && x < 14 && y >= 6 && y < 14
                pixels[o] = shine ? 0.95 : 0.78
                pixels[o + 1] = shine ? 0.94 : 0.60
                pixels[o + 2] = shine ? 0.92 : 0.48
                pixels[o + 3] = 1
            }
        }
        let image = DisplayImage(size: size, pixels: pixels)
        var beauty = BeautyParameters()
        beauty.deShine = 100
        let result = BeautyEngine.apply(image, skin: fullSkinLayers(size: size), beauty: beauty)

        func luma(_ x: Int, _ y: Int, _ buffer: [Float]) -> Double {
            let o = (y * size.width + x) * 4
            return Double(ColorMath.luma(Float(buffer[o]), Float(buffer[o + 1]), Float(buffer[o + 2])))
        }
        XCTAssertLessThan(luma(10, 10, result.pixels), luma(10, 10, pixels), "油光亮斑要被压下去")
        XCTAssertEqual(luma(1, 1, result.pixels), luma(1, 1, pixels), accuracy: 1e-5, "非亮斑不该被动")
    }

    func testWhiteningLiftsSkinButNotAlreadyWhite() {
        let size = PixelSize(width: 8, height: 8)
        let skin = TestImage.solid(width: 8, height: 8, r: 0.70, g: 0.55, b: 0.45)
        var beauty = BeautyParameters()
        beauty.whitening = 100
        let lifted = BeautyEngine.apply(skin, skin: fullSkinLayers(size: size), beauty: beauty)
        XCTAssertGreaterThan(lifted.pixels[0], skin.pixels[0], "皮肤要更亮")
        XCTAssertLessThanOrEqual(lifted.pixels[0], 1)

        let white = TestImage.solid(width: 8, height: 8, r: 1, g: 1, b: 1)
        let kept = BeautyEngine.apply(white, skin: fullSkinLayers(size: size), beauty: beauty)
        XCTAssertEqual(kept.pixels[0], 1, accuracy: 1e-6, "已经到顶的不该被推出值域")
    }

    // MARK: - 关键点几何

    func testFaceGeometryRejectsWrongPointCount() {
        XCTAssertNil(FaceGeometry.from(points: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 477)))
    }

    func testFaceGeometryDerivesSemanticAnchors() {
        let geometry = FaceGeometry.from(points: Self.syntheticFacePoints())
        XCTAssertNotNil(geometry)
        guard let geometry else { return }
        XCTAssertEqual(geometry.irisCenters[0].x, 0.40, accuracy: 1e-9)
        XCTAssertEqual(geometry.irisCenters[1].x, 0.60, accuracy: 1e-9)
        XCTAssertEqual(geometry.irisRadius, 0.02, accuracy: 1e-9, "虹膜半径 = 圆心到虹膜环的平均距离")
        XCTAssertEqual(geometry.chin.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(geometry.chin.y, 0.72, accuracy: 1e-9)
        XCTAssertEqual(geometry.mouthCorners.count, 2)
        XCTAssertFalse(geometry.jawPoints.isEmpty, "下颌点从轮廓里按 y 挑，必须挑到东西")
        XCTAssertTrue(geometry.jawPoints.allSatisfy { $0.y > 0.60 }, "只该要嘴角连线以下的轮廓点")
        // 颊部 = 鼻翼—嘴角中点再向外让开 0.5 × 0.32 × 两眼外角距离（此处 0.20 → 0.032）。
        XCTAssertEqual(geometry.cheekCenters[0].x, 0.445 - 0.032, accuracy: 1e-6)
        XCTAssertEqual(geometry.cheekCenters[1].x, 0.555 + 0.032, accuracy: 1e-6)
        XCTAssertEqual(geometry.cheekCenters[0].y, 0.56, accuracy: 1e-6)
        XCTAssertGreaterThan(geometry.faceWidth, 0.3)
        XCTAssertLessThan(geometry.faceWidth, 0.45)
    }

    func testPolygonRasterizerFillsExactlyItsArea() {
        let size = PixelSize(width: 100, height: 100)
        let square = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                      CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.25, y: 0.75)]
        let mask = RegionRaster.polygon(square, size: size)
        XCTAssertTrue(abs(mask.coveredCount - 2500) <= 60, "扫描线偶奇填充应等于 50×50，实际 \(mask.coveredCount)")
        XCTAssertEqual(Int(mask.data[50 * 100 + 50]), 255)
        XCTAssertEqual(Int(mask.data[10 * 100 + 10]), 0)
        XCTAssertLessThan(RegionRaster.polygon([CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2)], size: size).coveredCount,
                          1, "两个点围不出面积，不该被当成一条线填充")
    }

    func testDiskMaskIsCenteredAndSmooth() {
        let size = PixelSize(width: 41, height: 41)
        let disk = RegionRaster.disk(center: CGPoint(x: 20, y: 20), radiusX: 10, radiusY: 10, size: size)
        XCTAssertEqual(Int(disk.data[20 * 41 + 20]), 255)
        XCTAssertEqual(Int(disk.data[20 * 41 + 35]), 0, "半径外为 0")
        let center = Double(disk.data[20 * 41 + 20]), edge = Double(disk.data[20 * 41 + 27])
        XCTAssertGreaterThan(center, edge, "从中心到边缘单调落下")
    }

    // MARK: - 区域美化

    func testEyeBrightRespectsPupilGuardAndMaskBoundary() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: Self.syntheticFacePoints())
        XCTAssertNotNil(geometry)

        let bright = TestImage.solid(width: 100, height: 100, r: 0.80, g: 0.76, b: 0.70)
        var beauty = BeautyParameters()
        beauty.eyeBright = 100
        let lifted = RegionEnhance.apply(bright, geometry: geometry, beauty: beauty)
        XCTAssertGreaterThan(lifted.pixels[(43 * 100 + 40) * 4], bright.pixels[(43 * 100 + 40) * 4], "虹膜周围要亮起来")
        XCTAssertEqual(lifted.pixels[(80 * 100 + 80) * 4], bright.pixels[(80 * 100 + 80) * 4], "区域外逐比特不动")

        let dark = TestImage.solid(width: 100, height: 100, r: 0.05, g: 0.05, b: 0.05)
        let kept = RegionEnhance.apply(dark, geometry: geometry, beauty: beauty)
        XCTAssertEqual(kept.pixels[(43 * 100 + 40) * 4], dark.pixels[(43 * 100 + 40) * 4], accuracy: 1e-5,
                       "瞳孔核心不能被提亮成灰瞳")
    }

    func testTeethWhitenIgnoresHighSaturationLipPixels() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: Self.syntheticFacePoints())
        var beauty = BeautyParameters()
        beauty.teethWhiten = 100

        let teethColor = TestImage.solid(width: 100, height: 100, r: 0.90, g: 0.88, b: 0.85)
        let whitened = RegionEnhance.apply(teethColor, geometry: geometry, beauty: beauty)
        let inside = (60 * 100 + 50) * 4
        XCTAssertGreaterThan(whitened.pixels[inside], teethColor.pixels[inside], "唇内的亮像素要更白")
        XCTAssertGreaterThan(whitened.pixels[inside + 2] - whitened.pixels[inside],
                             teethColor.pixels[inside + 2] - teethColor.pixels[inside],
                             "去黄 = 蓝黄轴往中性靠，B−(R+G)/2 要上升")

        let lipColorImage = TestImage.solid(width: 100, height: 100, r: 0.75, g: 0.30, b: 0.35)
        let untouched = RegionEnhance.apply(lipColorImage, geometry: geometry, beauty: beauty)
        XCTAssertEqual(untouched.pixels[inside], lipColorImage.pixels[inside], accuracy: 1e-5,
                       "高饱和的唇线不该被当成牙齿刷白")
    }

    func testLipColorOnlyInsideLipRing() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: Self.syntheticFacePoints())
        var beauty = BeautyParameters()
        beauty.lipColor = 100
        let base = TestImage.solid(width: 100, height: 100, r: 0.72, g: 0.45, b: 0.45)
        let result = RegionEnhance.apply(base, geometry: geometry, beauty: beauty)
        let ring = (60 * 100 + 44) * 4          // 外唇内、唇环上
        let outside = (20 * 100 + 50) * 4        // 额头方向
        XCTAssertGreaterThan(result.pixels[ring] - result.pixels[ring + 1],
                             base.pixels[ring] - base.pixels[ring + 1], "唇环内的红绿差要拉开（更饱和）")
        XCTAssertEqual(result.pixels[outside], base.pixels[outside], "唇外逐比特不动")
    }

    // MARK: - 位移场与预设形变

    func testEmptyFieldResamplingIsBitExact() {
        let size = PixelSize(width: 16, height: 16)
        let image = TestImage.gradient(width: 16, height: 16)
        var field = WarpField(size: size)
        XCTAssertTrue(field.isEmpty)
        field.clampMagnitude()
        let result = field.resample(image)
        XCTAssertEqual(result.pixels, image.pixels, "零位移场不该引入任何插值损耗")
    }

    func testAddPushConvertsNormalizedLengthToPixels() {
        let size = PixelSize(width: 100, height: 100)
        var field = WarpField(size: size)
        field.addPush(center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2,
                      dx: 0.1, dy: 0, strength: 1)
        // 中心处衰减 = 1，位移 0.1 个"画布宽" = 10 像素，反向记进采样偏移。
        XCTAssertEqual(field.offsetX[50 * 100 + 50], -10, accuracy: 0.5)
        XCTAssertEqual(field.offsetX[50 * 100 + 5], 0, "作用域外必须为 0")
    }

    func testSlimFacePushesCheeksTowardAxis() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: Self.syntheticFacePoints())
        var beauty = BeautyParameters()
        beauty.slimFace = 100
        let field = ShapeWarp.build(size: size, face: geometry, body: nil, beauty: beauty)
        XCTAssertNotNil(field)
        guard let field else { return }
        // 左颊（x≈0.413 < 中轴 0.5）要被推向右 → 采样偏移为负。
        XCTAssertLessThan(field.offsetX[56 * 100 + 40], 0)
        XCTAssertGreaterThan(field.offsetX[56 * 100 + 60], 0, "右颊对称地向左")
        XCTAssertEqual(field.offsetX[2 * 100 + 2], 0, "远离脸的角落不该被推")
    }

    func testEnlargeEyesMagnifiesOutwardFromIrisCenter() {
        let size = PixelSize(width: 100, height: 100)
        let geometry = FaceGeometry.from(points: Self.syntheticFacePoints())
        var beauty = BeautyParameters()
        beauty.enlargeEyes = 100
        let field = ShapeWarp.build(size: size, face: geometry, body: nil, beauty: beauty)
        XCTAssertNotNil(field)
        guard let field else { return }
        let centerRow = 43
        let centerIndex = centerRow * 100 + 40
        let rightIndex = centerRow * 100 + 42
        XCTAssertLessThan(abs(field.offsetX[centerIndex]), abs(field.offsetX[rightIndex]),
                          "圆心处 (q − c) ≈ 0，瞳孔几乎不被挪走；越靠外推得越多")
        XCTAssertLessThan(field.offsetX[rightIndex], 0, "圆心右侧的内容向外推 = 放大")
    }

    func testShapeWarpSkipsWhenAnchorsMissing() {
        let size = PixelSize(width: 100, height: 100)
        var beauty = BeautyParameters()
        beauty.slimFace = 100
        XCTAssertNil(ShapeWarp.build(size: size, face: nil, body: nil, beauty: beauty),
                     "没关键点就整段不跑，调用侧点名 [no_landmarks]")
        var bodyOnly = BeautyParameters()
        bodyOnly.heighten = 100
        XCTAssertNil(ShapeWarp.build(size: size, face: nil, body: nil, beauty: bodyOnly))
        XCTAssertTrue(beauty.isBodyShapeNeutral, "只动脸的项不该被算成身体项")
    }

    func testVerticalStretchHoldsAboveAnchor() {
        let size = PixelSize(width: 100, height: 100)
        var field = WarpField(size: size)
        field.addVerticalStretch(anchorY: 0.5, length: 0.4, scale: 1.1)
        for x in stride(from: 0, to: size.width, by: 7) {
            XCTAssertEqual(field.offsetY[10 * 100 + x], 0, "锚线以上逐比特不动")
        }
        let above = field.offsetY[60 * 100 + 50]
        let further = field.offsetY[80 * 100 + 50]
        XCTAssertLessThan(above, 0, "锚线以下采样往上偏 → 内容向下摊开")
        XCTAssertLessThan(further, above, "离锚线越远位移越大")
        XCTAssertEqual(above, -Float((60.5 - 50) * (1 - 1 / 1.1)), accuracy: 1.0)
    }

    func testHeightenAnchorsAtHipsAndKeepsHeadStill() {
        let size = PixelSize(width: 100, height: 100)
        let body = BodyAnchors.from(joints: Self.syntheticBodyJoints())
        XCTAssertNotNil(body)
        var beauty = BeautyParameters()
        beauty.heighten = 100
        let field = ShapeWarp.build(size: size, face: nil, body: body, beauty: beauty)
        XCTAssertNotNil(field)
        guard let field else { return }
        let hipRow = Int(body!.hipCenter.y * 100)
        XCTAssertEqual(field.offsetY[10 * 100 + 50], 0, "头与躯干不参与长腿")
        XCTAssertLessThanOrEqual(field.offsetY[95 * 100 + 50], field.offsetY[hipRow * 100 + 50])
    }

    func testBodyAnchorsRejectDegeneratePose() {
        let flat = Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 17)
        XCTAssertNil(BodyAnchors.from(joints: flat), "肩宽为 0 的姿态不配用来推身体")
        XCTAssertNil(BodyAnchors.from(joints: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 16)))
    }

    // MARK: - 辅助

    /// 造一份"整张都是皮肤"的三层掩码（身体留空），让算子测试只考验算子本身。
    private func fullSkinLayers(size: PixelSize) -> SkinMask.Layers {
        SkinMask.Layers(all: MaskBuffer.filled(size, value: 255),
                        face: MaskBuffer.filled(size, value: 255),
                        body: MaskBuffer.filled(size, value: 0),
                        hasFaceConstraint: true)
    }

    private func noisySkin(size: PixelSize, amplitude: Double) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        var state = UInt64(20261031)
        for i in 0 ..< size.pixelCount {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let jitter = (Double(state >> 33) / Double(1 << 31) - 0.5) * 2 * amplitude
            let o = i * 4
            pixels[o] = Float(0.80 + jitter)
            pixels[o + 1] = Float(0.62 + jitter * 0.6)
            pixels[o + 2] = Float(0.50 + jitter * 0.4)
            pixels[o + 3] = 1
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    /// 相邻像素的平均绝对差（R 通道）——高频噪声的粗略尺度。
    private func meanAdjacentDifference(_ size: PixelSize, _ pixels: [Float]) -> Double {
        var sum = 0.0
        var n = 0
        for y in 0 ..< size.height {
            for x in 0 ..< (size.width - 1) {
                let a = Double(pixels[(y * size.width + x) * 4])
                let b = Double(pixels[(y * size.width + x + 1) * 4])
                sum += abs(a - b)
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : 0
    }

    /// 合成一张"够用"的 478 点脸：只给实现真正消费的那些下标赋语义坐标，
    /// 其余留在脸中心。测的是**派生几何**，不是解剖精度。
    static func syntheticFacePoints() -> [CGPoint] {
        var points = Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 478)
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
        // 轮廓：绕 (0.5,0.5) 的椭圆（宽 0.4、高 0.48），从正上方按序排。
        let oval = FaceGeometry.Index.faceOval
        for (slot, index) in oval.enumerated() {
            let angle = -Double.pi / 2 + Double(slot) * (2 * Double.pi / Double(oval.count))
            points[index] = point(0.5 + 0.2 * cos(angle), 0.5 + 0.24 * sin(angle))
        }
        // 虹膜：两颗圆心 + 环上四点（半径 0.02）。
        points[468] = point(0.40, 0.43)
        points[469] = point(0.42, 0.43); points[470] = point(0.40, 0.45)
        points[471] = point(0.38, 0.43); points[472] = point(0.40, 0.41)
        points[473] = point(0.60, 0.43)
        points[474] = point(0.62, 0.43); points[475] = point(0.60, 0.45)
        points[476] = point(0.58, 0.43); points[477] = point(0.60, 0.41)
        // 眼轮廓（外角/内角 + 上下缘）。
        points[33] = point(0.35, 0.43); points[133] = point(0.45, 0.43)
        points[7] = point(0.37, 0.40); points[160] = point(0.40, 0.39)
        points[158] = point(0.43, 0.40); points[157] = point(0.44, 0.415)
        points[173] = point(0.44, 0.45); points[155] = point(0.43, 0.465)
        points[154] = point(0.40, 0.47); points[153] = point(0.37, 0.465)
        points[145] = point(0.36, 0.45); points[144] = point(0.355, 0.44)
        points[362] = point(0.65, 0.43); points[263] = point(0.55, 0.43)
        points[398] = point(0.63, 0.40); points[384] = point(0.60, 0.39)
        points[385] = point(0.57, 0.40); points[386] = point(0.56, 0.415)
        points[387] = point(0.56, 0.45); points[373] = point(0.57, 0.465)
        points[380] = point(0.60, 0.47); points[381] = point(0.63, 0.465)
        points[382] = point(0.64, 0.45); points[363] = point(0.645, 0.44)
        // 唇：外环 20 点、内环 20 点（中心 0.5,0.60）。
        for (slot, index) in FaceGeometry.Index.lipsOuterRing.enumerated() {
            let angle = Double(slot) * (2 * Double.pi / Double(FaceGeometry.Index.lipsOuterRing.count))
            points[index] = point(0.5 + 0.07 * cos(angle), 0.60 + 0.025 * sin(angle))
        }
        for (slot, index) in FaceGeometry.Index.lipsInnerRing.enumerated() {
            let angle = Double(slot) * (2 * Double.pi / Double(FaceGeometry.Index.lipsInnerRing.count))
            points[index] = point(0.5 + 0.05 * cos(angle), 0.60 + 0.015 * sin(angle))
        }
        points[78] = point(0.43, 0.60); points[308] = point(0.57, 0.60)
        points[129] = point(0.46, 0.52); points[358] = point(0.54, 0.52)
        points[4] = point(0.50, 0.53); points[9] = point(0.50, 0.45)
        points[152] = point(0.50, 0.72); points[10] = point(0.50, 0.26)
        return points
    }

    /// 合成 17 点 COCO 姿态：正面站立，肩线 y=0.30、髋 y=0.55、膝 y=0.75、踝 y=0.95。
    static func syntheticBodyJoints() -> [CGPoint] {
        var joints: [CGPoint] = []
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
        joints = [p(0.50, 0.10),                      // 0 nose
                  p(0.47, 0.08), p(0.53, 0.08),       // 1,2 eyes
                  p(0.44, 0.12), p(0.56, 0.12),       // 3,4 ears
                  p(0.35, 0.30), p(0.65, 0.30),       // 5,6 shoulders
                  p(0.32, 0.45), p(0.68, 0.45),       // 7,8 elbows
                  p(0.32, 0.58), p(0.68, 0.58),       // 9,10 wrists
                  p(0.40, 0.55), p(0.60, 0.55),       // 11,12 hips
                  p(0.40, 0.75), p(0.60, 0.75),       // 13,14 knees
                  p(0.40, 0.95), p(0.60, 0.95)]       // 15,16 ankles
        return joints
    }
}
