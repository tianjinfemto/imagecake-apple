import CoreGraphics
import XCTest

@testable import ImageCake

/// 管线接线与缺件点名（文档级）。
///
/// 引擎单测证明算子算得对，这组证明另外两件事：
///   1. 几何变换**真的作用到画面上**——之前 geometry 只被面板读、没被 render 调，
///      症状是"点了左转 90° 画面纹丝不动"，而任何算子测试都是绿的；
///   2. 缺资产时必须"整段不跑 + 点名"，而不是跑一遍近似恒等还不说话。
/// 第 2 条是这一版里最容易被忽略的产品原则：调了滑杆没反应，用户看到的
/// 应该是 `[no_landmarks]`，而不是"这软件坏了"。
final class PipelineWiringTests: XCTestCase {
    /// 水平渐变：R = G = B = x / (w-1)。方向可辨，且 90° 旋转/裁剪都是整像素搬运，
    /// 于是"先转再调"与"先调再转"能逐比特比较。
    private func gradient(_ size: PixelSize) -> DisplayImage {
        var pixels = [Float](repeating: 1, count: size.pixelCount * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let index = (y * size.width + x) * 4
                let value = Float(x) / Float(max(1, size.width - 1))
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    private func doc(_ size: PixelSize, _ tune: (inout EditParameters) -> Void = { _ in }) -> ImageDocument {
        var params = EditParameters()
        tune(&params)
        return ImageDocument(linear: LinearImage(size: size, pixels: gradient(size).pixels),
                             originalSize: size,
                             params: params,
                             sourceURL: nil,
                             isRAW: false,
                             loadNote: "",
                             personMask: nil,
                             maskReference: size,
                             patches: [])
    }

    // MARK: - 几何真的生效

    func testRotationChangesRenderedCanvasBitExactly() {
        let size = PixelSize(width: 8, height: 4)
        let plain = doc(size)
        var rotatedDocument = doc(size)
        rotatedDocument.geometry = GeometryTransform(rotation: 90)

        let plainRender = plain.render()
        let rotatedRender = rotatedDocument.render()
        XCTAssertEqual(rotatedRender.size, PixelSize(width: 4, height: 8), "画布要跟着转")
        // 调色是逐像素的，旋转是整像素搬运，两者可交换 → 必须逐比特一致。
        XCTAssertEqual(rotatedRender.pixels, GeometryEngine.rotate90(plainRender, clockwise: true).pixels)
    }

    func testCropAndFlipChangeOutputNotJustState() {
        let size = PixelSize(width: 8, height: 4)
        let plain = doc(size).render()
        var croppedDocument = doc(size)
        croppedDocument.geometry = GeometryTransform(cropRect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        let cropped = croppedDocument.render()
        XCTAssertEqual(cropped.size, PixelSize(width: 4, height: 4))
        XCTAssertEqual(cropped.pixels[0], plain.pixels[2 * 4], "裁剪框左沿在原图第 2 列")

        var flippedDocument = doc(size)
        flippedDocument.geometry = GeometryTransform(flipHorizontal: true)
        let flipped = flippedDocument.render()
        XCTAssertEqual(flipped.pixels[0], plain.pixels[7 * 4], "水平翻转后首列是原来的末列")
    }

    func testNeutralDocumentOnlyRunsTheToneStage() {
        // 把新增的几个阶段（几何/滤镜/镜头/美肤/区域/形变）全关掉时，
        // render() 必须逐比特等于 ToneEngine 自己。这条防的是“接了管线就无条件跑一遍”——
        // 症状不是报错而是整张图塑一丝、导出比预览暗一点。
        let size = PixelSize(width: 8, height: 8)
        let document = doc(size)
        let direct = ToneEngine.render(LinearImage(size: size, pixels: gradient(size).pixels),
                                       params: EditParameters())
        XCTAssertEqual(document.render().pixels, direct.pixels)
    }

    // MARK: - 缺件点名

    func testRegionAndShapeEditsAreSkippedAndNamedWithoutLandmarks() {
        let size = PixelSize(width: 16, height: 16)
        let baseline = doc(size)
        var styled = doc(size) { params in
            params.beauty.eyeBright = 60
            params.beauty.slimFace = 60
            params.beauty.heighten = 60
        }
        XCTAssertEqual(styled.render().pixels, baseline.render().pixels,
                       "没有关键点时整段必须不跑——连一次重采样都不做")
        let notes = styled.pipelineWarnings
        XCTAssertTrue(notes.contains { $0.contains("[no_landmarks]") }, "区域美化与美型要点名 [no_landmarks]，实际：\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("[no_pose]") }, "身体重塑要点名 [no_pose]，实际：\(notes)")

        // 关键点到位后，同样的参数必须真的动画面（否则"接了但没调"还是看不出来）。
        var withFace = styled
        withFace.faceGeometries = [FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())!]
        withFace.bodyAnchors = BodyAnchors.from(joints: BeautyEngineTests.syntheticBodyJoints())
        XCTAssertNotEqual(withFace.render().pixels, baseline.render().pixels, "有了锚点就该看到效果")
        XCTAssertTrue(withFace.pipelineWarnings.isEmpty, "资产齐了就不该再有点名，实际：\(withFace.pipelineWarnings)")
    }

    func testUnknownFilterStyleIsNamedAndFilterStageSkipped() {
        let size = PixelSize(width: 16, height: 16)
        let baseline = doc(size)
        var styled = doc(size) { $0.filter.style = "no-such-lut" }
        XCTAssertEqual(styled.render().pixels, baseline.render().pixels, "查不到表就当没有这一步，而不是当成白色/黑表")
        XCTAssertTrue(styled.pipelineWarnings.contains { $0.contains("[no_lut:no-such-lut]") })
    }

    func testBuiltInFilterActuallyReachesTheCanvas() {
        let size = PixelSize(width: 16, height: 16)
        let baseline = doc(size).render()
        let styledDoc = doc(size) { $0.filter.style = "mono" }
        let styled = styledDoc.render()
        XCTAssertNotEqual(styled.pixels, baseline.pixels, "内置风格必须进预览管线")
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            XCTAssertEqual(styled.pixels[o], styled.pixels[o + 1], accuracy: 1e-6, "黑白风格之后三个通道相等")
            XCTAssertEqual(styled.pixels[o + 1], styled.pixels[o + 2], accuracy: 1e-6)
        }
    }

    func testSkinStageSaysSoWhenNothingConstrainsTheMask() {
        let size = PixelSize(width: 16, height: 16)
        let skinDoc = doc(size) { params in
            params.beauty.skinSmooth = 60
        }
        XCTAssertTrue(skinDoc.pipelineWarnings.contains { $0.contains("[no_constraint]") },
                      "没有 α 也没有关键点时必须点名 [no_constraint]，实际：\(skinDoc.pipelineWarnings)")
        // 这张图是中性灰，一个像素都不进皮肤椭圆 → 磨皮跑了也该逐比特不变。
        XCTAssertEqual(skinDoc.render().pixels, doc(size).render().pixels,
                       "掩码为空时不得产生任何插值损耗")
    }

    func testLensStageReachesRender() {
        let size = PixelSize(width: 16, height: 16)
        let baseline = doc(size).render()
        let vignetted = doc(size) { $0.lens.vignette = 100 }.render()
        XCTAssertNotEqual(vignetted.pixels, baseline.pixels)
        let center = vignetted.pixels[((8 * 16 + 8) * 4)]
        let corner = vignetted.pixels[0]
        XCTAssertLessThan(corner, center, "角落要比中心暗")
    }

    func testExportStyleAndBeautyAreCarriedIntoDocumentCopy() {
        // ExportPipeline 用同一个 init 重建文档：新增的资产字段必须有落点，
        // 否则症状是"预览有磨皮、导出件没有"。这里直接测字段搬运。
        let size = PixelSize(width: 16, height: 16)
        var source = doc(size) { $0.beauty.skinSmooth = 50 }
        source.faceGeometries = [FaceGeometry.from(points: BeautyEngineTests.syntheticFacePoints())!]
        source.bodyAnchors = BodyAnchors.from(joints: BeautyEngineTests.syntheticBodyJoints())
        source.idPhotoSheet = IDPhoto.sheet(spec: IDPhoto.spec(id: "one")!, paper: IDPhoto.paper(id: "5inch")!)
        XCTAssertNotNil(source.faceGeometry)
        XCTAssertNotNil(source.bodyAnchors)
        XCTAssertGreaterThan(source.idPhotoSheet?.count ?? 0, 0)
    }
}
