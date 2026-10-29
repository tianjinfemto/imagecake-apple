import CoreGraphics
import ImageIO
import XCTest
@testable import ImageCake

final class ImagingTests: XCTestCase {
    /// 造一张确定的斜纹图：尺寸与每个像素都可核对。
    private func makeDisplay(width: Int, height: Int) -> DisplayImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let o = (y * width + x) * 4
                pixels[o] = Float(x) / Float(max(1, width - 1))
                pixels[o + 1] = Float(y) / Float(max(1, height - 1))
                pixels[o + 2] = ((x + y) % 2 == 0) ? 0.25 : 0.75
                pixels[o + 3] = 1
            }
        }
        return DisplayImage(size: PixelSize(width: width, height: height), pixels: pixels)
    }

    func testRGBA8RoundTripIsStable() {
        let display = makeDisplay(width: 8, height: 6)
        let bytes = display.rgba8()
        let back = DisplayImage(displayRGBA8: bytes)
        XCTAssertNotNil(back)
        for i in 0 ..< display.pixels.count {
            XCTAssertEqual(back!.pixels[i], display.pixels[i], accuracy: 1.0 / 255)
        }
    }

    func testPNG16IsReadableByImageIO() throws {
        let display = makeDisplay(width: 8, height: 6)
        let data = try PNG16Writer.encode(display)
        XCTAssertEqual(data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("ImageIO 读不了自家 PNG-16")
        }
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 6)

        // 画进 8bit 上下文核对颜色（16bit → 8bit 有一次量化）。
        let buffer = ImageLoader.drawRGBA8(image)
        XCTAssertNotNil(buffer)
        let bytes = [UInt8](buffer!.data)
        let first = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        XCTAssertLessThanOrEqual(abs(first.0 - 0), 2)
        XCTAssertLessThanOrEqual(abs(first.1 - 0), 2)
        let lastIndex = (5 * 8 + 7) * 4
        XCTAssertGreaterThan(Int(bytes[lastIndex]), 250)
    }

    func testResizeKeepsRequestedSizeAndAlpha() {
        let linear = LinearImage(size: PixelSize(width: 40, height: 30),
                                 pixels: Array(repeating: [Float(0.5), 0.5, 0.5, 1], count: 40 * 30).flatMap { $0 })
        let resized = linear.resized(to: PixelSize(width: 20, height: 15))
        XCTAssertEqual(resized.size, PixelSize(width: 20, height: 15))
        XCTAssertEqual(resized.pixels.count, 20 * 15 * 4)
        XCTAssertEqual(resized.pixels[3], 1, accuracy: 1e-5)
    }

    func testMaskCropAndResize() {
        let mask = MaskBuffer.filled(PixelSize(width: 10, height: 10), value: 255)
        let cropped = mask.cropped(to: PixelRect(x: 2, y: 3, width: 4, height: 5))
        XCTAssertEqual(cropped.size, PixelSize(width: 4, height: 5))
        XCTAssertEqual([UInt8](cropped.data).allSatisfy { $0 == 255 }, true)

        let resized = mask.resized(to: PixelSize(width: 5, height: 5))
        XCTAssertEqual(resized.size, PixelSize(width: 5, height: 5))
        XCTAssertEqual(resized.coveredCount, 25)
    }
}

final class GeometryTests: XCTestCase {
    func testTileGridCoversEveryPixelExactlyOnce() {
        let size = PixelSize(width: 700, height: 500)
        let tiles = TileGrid.interiors(size: size, tile: 256)
        XCTAssertFalse(tiles.isEmpty)
        var counts = [Int](repeating: 0, count: size.pixelCount)
        for tile in tiles {
            XCTAssertGreaterThan(tile.width, 0)
            XCTAssertGreaterThan(tile.height, 0)
            XCTAssertLessThanOrEqual(tile.maxX, size.width)
            XCTAssertLessThanOrEqual(tile.maxY, size.height)
            for y in tile.y ..< tile.maxY {
                for x in tile.x ..< tile.maxX {
                    counts[y * size.width + x] += 1
                }
            }
        }
        XCTAssertTrue(counts.allSatisfy { $0 == 1 }, "有像素被覆盖 0 次或多次")
    }

    func testPaddedTileStaysInsideImageAndContainsInterior() {
        let size = PixelSize(width: 300, height: 200)
        for interior in TileGrid.interiors(size: size, tile: 128) {
            let padded = TileGrid.padded(interior, overlap: 16, in: size)
            XCTAssertGreaterThanOrEqual(padded.x, 0)
            XCTAssertGreaterThanOrEqual(padded.y, 0)
            XCTAssertLessThanOrEqual(padded.maxX, size.width)
            XCTAssertLessThanOrEqual(padded.maxY, size.height)
            XCTAssertLessThanOrEqual(padded.x, interior.x)
            XCTAssertLessThanOrEqual(padded.y, interior.y)
            XCTAssertGreaterThanOrEqual(padded.maxX, interior.maxX)
            XCTAssertGreaterThanOrEqual(padded.maxY, interior.maxY)
        }
    }

    func testMaskBoundingBoxDilateAndFeather() {
        var bytes = [UInt8](repeating: 0, count: 64 * 64)
        for y in 20 ..< 30 {
            for x in 10 ..< 20 {
                bytes[y * 64 + x] = 255
            }
        }
        let mask = MaskBuffer(size: PixelSize(width: 64, height: 64), data: Data(bytes))
        let box = MaskOps.boundingBox(mask)
        XCTAssertEqual(box, PixelRect(x: 10, y: 20, width: 10, height: 10))

        let dilated = MaskOps.dilated(mask, radius: 4)
        let dilatedBox = MaskOps.boundingBox(dilated)
        XCTAssertEqual(dilatedBox, PixelRect(x: 6, y: 16, width: 18, height: 18))

        // 羽化用单独的大块：radius 3 的三次盒式模糊等效 σ ≈ 3.5、扩散半径约 9 像素，
        // 10×10 的块中心距边界只有 5 像素，被削到 0.7 是数学必然（不是实现错）。
        // 32×32 的块中心距边界 15 像素，才真的碰不到边界，断言才有意义。
        var bigBytes = [UInt8](repeating: 0, count: 64 * 64)
        for y in 16 ..< 48 {
            for x in 16 ..< 48 {
                bigBytes[y * 64 + x] = 255
            }
        }
        let bigMask = MaskBuffer(size: PixelSize(width: 64, height: 64), data: Data(bigBytes))
        let feathered = MaskOps.feathered(bigMask, radius: 3)
        let values = [UInt8](feathered.data)
        XCTAssertGreaterThan(values[32 * 64 + 32], 250, "中心不该被羽化削掉")
        XCTAssertEqual(values[0], 0)
    }

    func testInpaintPatchComposeMovesOnlyInsideMask() {
        var fillBytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        var baseBytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        var alphaBytes = [UInt8](repeating: 0, count: 4 * 4)
        for i in 0 ..< 16 {
            fillBytes[i * 4] = 200
            baseBytes[i * 4] = 100
            alphaBytes[i] = (i % 4 == 0) ? 255 : 0
        }
        let patch = InpaintPatch(rect: PixelRect(x: 1, y: 1, width: 4, height: 4),
                                 reference: PixelSize(width: 10, height: 10),
                                 fill: RGBA8Buffer(size: PixelSize(width: 4, height: 4), data: Data(fillBytes)),
                                 base: RGBA8Buffer(size: PixelSize(width: 4, height: 4), data: Data(baseBytes)),
                                 alpha: MaskBuffer(size: PixelSize(width: 4, height: 4), data: Data(alphaBytes)))
        XCTAssertTrue(patch.isValid)

        let bottom = RGBA8Buffer.filled(PixelSize(width: 10, height: 10), value: 50)
        let out = InpaintTask.compose(bottom: bottom, patch: patch)
        let bytes = [UInt8](out.data)
        // rect 内 α=255 的像素：50 + (200-100) = 150
        XCTAssertEqual(bytes[(1 * 10 + 1) * 4], 150)
        // rect 内 α=0 的像素：逐位不变
        XCTAssertEqual(bytes[(1 * 10 + 2) * 4], 50)
        // rect 外：逐位不变
        XCTAssertEqual(bytes[0], 50)
    }

    func testPatchScalesWithCanvas() {
        let fill = RGBA8Buffer.filled(PixelSize(width: 4, height: 4), value: 200)
        let base = RGBA8Buffer.filled(PixelSize(width: 4, height: 4), value: 100)
        let alpha = MaskBuffer.filled(PixelSize(width: 4, height: 4), value: 255)
        let patch = InpaintPatch(rect: PixelRect(x: 10, y: 20, width: 4, height: 4),
                                 reference: PixelSize(width: 100, height: 100),
                                 fill: fill, base: base, alpha: alpha)
        let scaled = patch.scaled(to: PixelSize(width: 200, height: 200))
        XCTAssertNotNil(scaled)
        XCTAssertEqual(scaled?.rect, PixelRect(x: 20, y: 40, width: 8, height: 8))
        XCTAssertEqual(scaled?.fill.size, PixelSize(width: 8, height: 8))
    }
}

private extension RGBA8Buffer {
    static func filled(_ size: PixelSize, value: UInt8) -> RGBA8Buffer {
        RGBA8Buffer(size: size, data: Data(repeating: value, count: size.pixelCount * 4))
    }
}
