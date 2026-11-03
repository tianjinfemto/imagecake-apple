import CoreGraphics
import XCTest
@testable import ImageCake

/// 新增引擎的离线断言。
///
/// 动机：这些算子都是确定性的（零权重），错了在真机上只表现为
/// "画面怪怪的"。离线钉住基本性质：旋转不丢像素、翻转可逆、
/// 老照片恢复不崩、XMP 映射对、拼图槽位对。
final class NewEnginesTests: XCTestCase {
    // MARK: - GeometryEngine

    func testRotate90ChangesDimensions() {
        let image = TestImage.solid(width: 4, height: 2, r: 1, g: 0, b: 0)
        let rotated = GeometryEngine.rotate90(image, clockwise: true)
        XCTAssertEqual(rotated.size.width, 2)
        XCTAssertEqual(rotated.size.height, 4)
    }

    func testFlipHorizontalIsInvolutive() {
        let image = TestImage.gradient(width: 4, height: 4)
        let flipped = GeometryEngine.flip(image, horizontal: true)
        let back = GeometryEngine.flip(flipped, horizontal: true)
        XCTAssertEqual(back.pixels, image.pixels, "翻转两次应回到原图")
    }

    func testFlipVerticalIsInvolutive() {
        let image = TestImage.gradient(width: 4, height: 4)
        let flipped = GeometryEngine.flip(image, horizontal: false)
        let back = GeometryEngine.flip(flipped, horizontal: false)
        XCTAssertEqual(back.pixels, image.pixels)
    }

    func testRotate360IsIdentity() {
        let image = TestImage.solid(width: 4, height: 4, r: 0.5, g: 0.3, b: 0.8)
        let rotated = GeometryEngine.rotate(image, degrees: 360)
        XCTAssertEqual(rotated.size, image.size)
    }

    func testGeometryIdentityIsNoop() {
        XCTAssertTrue(GeometryTransform.identity.isIdentity)
        let nonIdentity = GeometryTransform(rotation: 90)
        XCTAssertFalse(nonIdentity.isIdentity)
    }

    // MARK: - OldPhotoEngine

    func testRestoreFadeDoesNotCrash() {
        let image = TestImage.solid(width: 8, height: 8, r: 0.6, g: 0.5, b: 0.3)
        let (restored, _) = OldPhotoEngine.restoreFade(image)
        XCTAssertEqual(restored.size, image.size)
    }

    func testRemoveScratchesDoesNotCrash() {
        let image = TestImage.gradient(width: 8, height: 8)
        let cleaned = OldPhotoEngine.removeScratches(image, threshold: 0.15)
        XCTAssertEqual(cleaned.size, image.size)
    }

    func testRestoreIsCompose() {
        let image = TestImage.solid(width: 8, height: 8, r: 0.7, g: 0.6, b: 0.4)
        let (restored, _) = OldPhotoEngine.restore(image)
        XCTAssertEqual(restored.size, image.size)
    }

    // MARK: - PatchEngine

    func testPatchEngineNoStrokesIsIdentity() {
        let image = TestImage.gradient(width: 8, height: 8)
        let result = PatchEngine.apply(image, strokes: [])
        XCTAssertEqual(result.pixels, image.pixels)
    }

    // MARK: - SmartCropEngine

    func testSmartCropReturnsNilForEmptyInput() {
        let size = PixelSize(width: 100, height: 100)
        let result = SmartCropEngine.suggest(imageSize: size, landmarks: [], personMask: nil)
        XCTAssertNil(result)
    }

    func testSmartCropWithLandmarks() {
        let size = PixelSize(width: 100, height: 100)
        let face = FaceLandmarks(faceBox: PixelRect(x: 20, y: 20, width: 40, height: 40),
                                 points: [CGPoint(x: 30, y: 30), CGPoint(x: 50, y: 50)],
                                 eyeOpenRatio: 0.3)
        let result = SmartCropEngine.suggest(imageSize: size, landmarks: [face], personMask: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.reason, "基于 1 张脸关键点")
    }

    // MARK: - XMPImporter

    func testXMPImportExposure() {
        let xmp = """
        <rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
            crs:Exposure2012="1.5"
            crs:Temperature="3000"
            crs:Contrast2012="20"
        </rdf:Description>
        """
        var params = EditParameters()
        let (result, unknown) = XMPImporter.import_(xmp, into: params)
        XCTAssertEqual(result.exposure, 1.5, accuracy: 0.001)
        XCTAssertEqual(result.temperature, -70, accuracy: 0.001, "3000K → (3000-6500)/50 = -70")
        XCTAssertEqual(result.contrast, 20, accuracy: 0.001)
        XCTAssertEqual(unknown.count, 0)
    }

    func testXMPImportUnknownKeys() {
        let xmp = """
        <rdf:Description>
            crs:Exposure2012="0.5"
            crs:SomeUnknownKey="42"
        </rdf:Description>
        """
        var params = EditParameters()
        let (result, unknown) = XMPImporter.import_(xmp, into: params)
        XCTAssertEqual(result.exposure, 0.5, accuracy: 0.001)
        XCTAssertTrue(unknown.contains("SomeUnknownKey"))
    }

    /// 分区调色（split toning）的两端都必须接上。以前只接了阴影与平衡，
    /// `.whHue/.whSat/.whLum` 三个 case 存在却没有任何 mapKey 返回它们，
    /// 症状是“导入完画面差一口气”而状态栏只说已导入 —— 所以两边各给一格断言。
    func testXMPImportSplitToningBothEnds() {
        let xmp = """
        <rdf:Description>
            crs:SplitToningShadowHue="30"
            crs:SplitToningHighlightHue="-150"
            crs:SplitToningHighlightSaturation="12"
            crs:SplitToningHighlightLuminance="-8"
        </rdf:Description>
        """
        let params = EditParameters()
        let (result, unknown) = XMPImporter.import_(xmp, into: params)
        XCTAssertEqual(result.wshHue, 30, accuracy: 0.001)
        XCTAssertEqual(result.whlHue, -150, accuracy: 0.001, "高光染色落 whlHue")
        XCTAssertEqual(result.whlSat, 12, accuracy: 0.001)
        XCTAssertEqual(result.whlLum, -8, accuracy: 0.001)
        XCTAssertTrue(unknown.isEmpty, "这四个键都认得：\(unknown)")
    }

    /// 入口的 `[xmp_no_mapping]` 判定拿的是“参数动没动”，所以这一条必须钉住：
    /// 一个认不出的键都映不上时，参数逐字段等于出厂，而不是“看起来成功了”。
    func testXMPWithOnlyUnknownKeysLeavesParamsUnchanged() {
        let xmp = """
        <rdf:Description>
            crs:CropAspect="4x6"
            crs:LensProfileEnable="0"
        </rdf:Description>
        """
        let params = EditParameters()
        let (result, unknown) = XMPImporter.import_(xmp, into: params)
        XCTAssertEqual(result, params, "没映到任何键时必须逐字段不变（入口靠这条点名）")
        XCTAssertEqual(unknown.count, 2)
    }

    /// sidecar 命名规则（图名换 `.xmp`，Lightroom 约定）。入口只读这个路径，
    /// 所以规则本身必须可断言，不能“拿掉最后一个点后的东西”这类口径飘掉。
    func testXMPSidecarURLNaming() {
        let raw = URL(fileURLWithPath: "/photos/IMG_1234.CR3")
        let sidecar = XMPImporter.sidecarURL(forImage: raw)
        XCTAssertEqual(sidecar.lastPathComponent, "IMG_1234.xmp")
        XCTAssertEqual(sidecar.deletingLastPathComponent(), raw.deletingLastPathComponent(),
                       "sidecar 必须在图旁边那个目录里")
        // 多层后缀只剥最后一层：A.CR2.cr3 -> A.CR2.xmp（与 Lightroom 一致）。
        XCTAssertEqual(XMPImporter.sidecarURL(forImage: URL(fileURLWithPath: "/p/A.CR2.cr3"))
                         .lastPathComponent, "A.CR2.xmp")
    }

    // MARK: - CollageEngine

    func testCollageTemplates() {
        XCTAssertEqual(CollageEngine.templates.count, 4)
        XCTAssertTrue(CollageEngine.templates.contains { $0.name.contains("2×2") })
    }

    func testCollageComposeReturnsNilForInsufficientImages() {
        let images = [TestImage.solidRGBA8(width: 4, height: 4, r: 255, g: 0, b: 0)]
        let template = CollageEngine.templates[2]
        let result = CollageEngine.compose(images: images, template: template,
                                           canvasSize: PixelSize(width: 100, height: 100))
        XCTAssertNil(result, "图不够应返回 nil")
    }

    // MARK: - ICCProfile

    func testICCProfileDataExists() {
        let data = ICCProfile.sRGBProfileData()
        XCTAssertNotNil(data, "sRGB ICC profile 数据应该可获取")
        XCTAssertGreaterThan(data?.count ?? 0, 0)
    }

    // MARK: - OverlayEngine

    func testOverlayNoElementsIsIdentity() {
        let image = TestImage.solidRGBA8(width: 8, height: 8, r: 100, g: 150, b: 200)
        let result = OverlayEngine.apply(image, elements: [])
        XCTAssertEqual(result.data, image.data)
    }

    func testOverlayBorder() {
        let image = TestImage.solidRGBA8(width: 8, height: 8, r: 100, g: 150, b: 200)
        let element = OverlayElement(id: UUID(),
                                     kind: .border(color: RGBA8(r: 255, g: 0, b: 0), widthRatio: 0.1))
        let result = OverlayEngine.apply(image, elements: [element])
        let w = image.size.width
        let firstPixel = result.data[0]
        XCTAssertEqual(firstPixel, 255, "边框像素应为红色 R=255")
        let centerPixel = result.data[((4 * w + 4) * 4)]
        XCTAssertEqual(centerPixel, 100, "中心像素应不变")
    }

    // MARK: - LocalAdjustment

    func testLocalAdjustmentNeutralIsNoop() {
        let image = TestImage.gradient(width: 8, height: 8)
        let adj = LocalAdjustment(mask: BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.1))
        XCTAssertTrue(adj.isNeutral)
        let linear = LinearImage(size: image.size, pixels: image.pixels)
        let result = LocalAdjustmentEngine.apply(image, adjustments: [adj], linear: linear)
        XCTAssertEqual(result.pixels, image.pixels, "中性本地调节不应改变画面")
    }
}

// MARK: - 测试辅助

enum TestImage {
    static func solid(width: Int, height: Int, r: Double, g: Double, b: Double) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = Float(r)
            pixels[i * 4 + 1] = Float(g)
            pixels[i * 4 + 2] = Float(b)
            pixels[i * 4 + 3] = 1.0
        }
        return DisplayImage(size: PixelSize(width: width, height: height), pixels: pixels)
    }

    static func gradient(width: Int, height: Int) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                pixels[idx] = Float(x) / Float(width)
                pixels[idx + 1] = Float(y) / Float(height)
                pixels[idx + 2] = 0.5
                pixels[idx + 3] = 1.0
            }
        }
        return DisplayImage(size: PixelSize(width: width, height: height), pixels: pixels)
    }

    static func solidRGBA8(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> RGBA8Buffer {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            data[i * 4] = r
            data[i * 4 + 1] = g
            data[i * 4 + 2] = b
            data[i * 4 + 3] = 255
        }
        return RGBA8Buffer(size: PixelSize(width: width, height: height), data: Data(data))
    }
}