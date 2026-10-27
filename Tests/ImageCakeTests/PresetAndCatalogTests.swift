import XCTest
@testable import ImageCake

final class PresetAndCatalogTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imagecake-tests-\(UUID().uuidString)-\(name)")
    }

    func testPresetRoundTripKeepsValues() throws {
        var params = EditParameters()
        params.exposure = 0.75
        params.contrast = -20
        params.temperature = 15
        params.saturation = 30
        params.hslSat[2] = 40
        params.curves[0] = CurveChannel(x: [0, 0.4, 1], y: [0, 0.6, 1])
        params.bgEnabled = true
        params.bgR = 58
        params.bgG = 110
        params.bgB = 165
        params.superRes = 2
        params.faceRestore = 40

        let url = tempURL("preset.json")
        try PresetStore.save(params, to: url)
        let (loaded, report) = try PresetStore.load(from: url)
        XCTAssertEqual(loaded.exposure, params.exposure, accuracy: 1e-9)
        XCTAssertEqual(loaded.contrast, params.contrast, accuracy: 1e-9)
        XCTAssertEqual(loaded.hslSat, params.hslSat)
        XCTAssertEqual(loaded.curves[0], params.curves[0])
        XCTAssertEqual(loaded.bgB, params.bgB, accuracy: 1e-9)
        XCTAssertEqual(loaded.superRes, 2)
        XCTAssertTrue(report.unknownKeys.isEmpty)
        XCTAssertEqual(report.version, EditParameters.presetVersion)
        try? FileManager.default.removeItem(at: url)
    }

    func testPresetReportsUnknownKeysInsteadOfSwallowing() throws {
        // 这是 imagecake 的预设：里面有本程序没有落点的键。
        let json = """
        {
          "preset_version": 33,
          "exposure": 0.5,
          "thin_face": 45,
          "watermark_text": "studio"
        }
        """
        let url = tempURL("foreign.json")
        try Data(json.utf8).write(to: url)
        let (params, report) = try PresetStore.load(from: url)
        XCTAssertEqual(params.exposure, 0.5, accuracy: 1e-9)
        XCTAssertEqual(report.unknownKeys, ["thin_face", "watermark_text"])
        XCTAssertFalse(report.warning.isEmpty)
        try? FileManager.default.removeItem(at: url)
    }

    func testPresetRejectsNewerVersion() throws {
        let json = """
        { "preset_version": \(EditParameters.presetVersion + 1), "exposure": 0 }
        """
        let url = tempURL("future.json")
        try Data(json.utf8).write(to: url)
        XCTAssertThrowsError(try PresetStore.load(from: url)) { error in
            guard let presetError = error as? PresetError,
                  case .tooNew = presetError else {
                return XCTFail("期望 tooNew，实际 \(error)")
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func testMissingKeysFallBackToFactory() throws {
        let json = """
        { "preset_version": 10, "exposure": 1.0 }
        """
        let url = tempURL("partial.json")
        try Data(json.utf8).write(to: url)
        let (params, _) = try PresetStore.load(from: url)
        XCTAssertEqual(params.exposure, 1.0, accuracy: 1e-9)
        XCTAssertEqual(params.contrast, 0)
        XCTAssertEqual(params.curves.count, 4)
        XCTAssertEqual(params.hslHue.count, 8)
        try? FileManager.default.removeItem(at: url)
    }

    func testManifestDecodesAndKeepsDigestFields() throws {
        let json = """
        {
          "schema": 1,
          "default_tier": "core",
          "models": [{
            "id": "demo",
            "file": "demo.onnx",
            "bytes": 3,
            "sha256": "abc",
            "license": "Apache-2.0",
            "commercialUse": "allowed",
            "tier": "onDemand",
            "purpose": "测试",
            "source": { "repo": "a/b", "path": "c/d.onnx" },
            "io": { "layout": "nchw", "valueRange": "unit", "fixedSize": 512 }
          }]
        }
        """
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.models.count, 1)
        let descriptor = manifest.models[0]
        XCTAssertEqual(descriptor.ioSpec.resolvedValueRange, .unit)
        XCTAssertEqual(descriptor.ioSpec.fixedSize, 512)
        XCTAssertEqual(descriptor.downloadURL(mirror: false)?.host, "huggingface.co")
        XCTAssertEqual(descriptor.downloadURL(mirror: true)?.host, "hf-mirror.com")
    }

    func testMattingNetSizeHonorsMultipleAndLongEdge() {
        let size = PixelSize(width: 4032, height: 3024)
        let net = MattingTask.netSize(for: size, longEdge: 512, multipleOf: 32)
        XCTAssertEqual(net.width % 32, 0)
        XCTAssertEqual(net.height % 32, 0)
        XCTAssertLessThanOrEqual(max(net.width, net.height), 512)

        let small = PixelSize(width: 100, height: 80)
        let smallNet = MattingTask.netSize(for: small, longEdge: 512, multipleOf: 32)
        XCTAssertEqual(smallNet, PixelSize(width: 96, height: 64))
        XCTAssertLessThanOrEqual(smallNet.width, small.width)
    }

    func testFaceRestoreSquareBoxStaysInsideCanvas() {
        let box = PixelRect(x: 90, y: 10, width: 40, height: 50)
        let square = FaceRestoreTask.squareBox(around: box, expand: 0.1, in: PixelSize(width: 200, height: 120))
        XCTAssertEqual(square.width, square.height)
        XCTAssertGreaterThanOrEqual(square.x, 0)
        XCTAssertGreaterThanOrEqual(square.y, 0)
        XCTAssertLessThanOrEqual(square.maxX, 200)
        XCTAssertLessThanOrEqual(square.maxY, 120)
    }
}
