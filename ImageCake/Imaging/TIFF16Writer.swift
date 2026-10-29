import Foundation

// 16bit TIFF 写入器。
//
// 为什么自己写：理由与 PNG-16 同源——CGImageDestination 对 16bit RGBA 的
// 字节序与色彩空间处理随平台/配置变化，而 16bit 交付件是项目对「印刷/后期」
// 的承诺。自己写之后，每个偏移与 tag 都能在源码里读出来。
//
// 容器选择：baseline TIFF 6.0、小端（"II"）、单 strip、不压缩、chunky。
// · 不压缩：与 PNG-16 同一条立场——不为了省体积引第三方库，文件偏大但
//   每个字节都可解释；
// · 单 strip：TIFF 的 strip 本来是为流式读写设计的，而我们手里已经是完整
//   内存图，单 strip 能省掉一整套偏移计算，出错面更小；
// · 小端：本机与 iPad 都是小端，写出来与内存同序，排查时可以直接对照。
//
// 固定写 4 个 sample（RGB + 未预乘 alpha），ExtraSamples 标 2。这样
// 有透明区域的图不会在导出时丢掉 alpha，也不必为「有没有透明」分两条路径。

enum TIFF16Writer {
    /// 显示域 RGBA → TIFF-16（RGBA，8 字节/像素）。失败只在尺寸非法时发生。
    static func encode(_ image: DisplayImage) throws -> Data {
        guard image.size.pixelCount > 0, image.pixels.count == image.size.pixelCount * 4 else {
            throw ImageLoadError.empty
        }
        let width = image.size.width
        let height = image.size.height
        let samples = image.rgba16()

        // —— 布局 ——
        //   0        header（8 字节）
        //   8        IFD（2 + 14×12 + 4）
        //   之后     BitsPerSample / XRes / YRes，然后才是像素
        let entryCount = 14
        let ifdOffset = 8
        let ifdSize = 2 + entryCount * 12 + 4
        let bitsOffset = ifdOffset + ifdSize
        let xResolutionOffset = bitsOffset + 8          // 4 个 SHORT
        let yResolutionOffset = xResolutionOffset + 8   // 一个 RATIONAL
        let dataOffset = yResolutionOffset + 8
        let dataBytes = width * height * 8

        var bytes = [UInt8](repeating: 0, count: dataOffset + dataBytes)

        // —— header：II（小端）+ 42 + IFD 偏移 ——
        bytes[0] = 0x49
        bytes[1] = 0x49
        put16(42, &bytes, at: 2)
        put32(UInt32(ifdOffset), &bytes, at: 4)

        // —— IFD ——
        put16(UInt16(entryCount), &bytes, at: ifdOffset)
        var cursor = ifdOffset + 2
        // tag 必须按数值升序，否则有些读图器会直接放弃这个 IFD。
        writeEntry(&bytes, at: cursor, tag: 256, type: 4, count: 1, value: UInt32(width))      // ImageWidth
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 257, type: 4, count: 1, value: UInt32(height))     // ImageLength
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 258, type: 3, count: 4, value: UInt32(bitsOffset)) // BitsPerSample
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 259, type: 3, count: 1, value: 1)                  // Compression = none
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 262, type: 3, count: 1, value: 2)                  // Photometric = RGB
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 273, type: 4, count: 1, value: UInt32(dataOffset)) // StripOffsets
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 277, type: 3, count: 1, value: 4)                  // SamplesPerPixel = 4
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 278, type: 4, count: 1, value: UInt32(height))     // RowsPerStrip
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 279, type: 4, count: 1, value: UInt32(dataBytes))  // StripByteCounts
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 282, type: 5, count: 1, value: UInt32(xResolutionOffset)) // XResolution
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 283, type: 5, count: 1, value: UInt32(yResolutionOffset)) // YResolution
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 284, type: 3, count: 1, value: 1)                  // PlanarConfiguration = chunky
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 296, type: 3, count: 1, value: 2)                  // ResolutionUnit = inch
        cursor += 12
        writeEntry(&bytes, at: cursor, tag: 338, type: 3, count: 1, value: 2)                  // ExtraSamples = unassociated alpha
        cursor += 12
        put32(0, &bytes, at: cursor)                                                            // 没有下一个 IFD

        // —— 外部数据：BitsPerSample（4×16）+ 72/1 dpi ——
        for index in 0 ..< 4 {
            put16(16, &bytes, at: bitsOffset + index * 2)
        }
        put32(72, &bytes, at: xResolutionOffset)
        put32(1, &bytes, at: xResolutionOffset + 4)
        put32(72, &bytes, at: yResolutionOffset)
        put32(1, &bytes, at: yResolutionOffset + 4)

        // —— 像素：RGBA 16bit 小端，与内存同序 ——
        bytes.withUnsafeMutableBufferPointer { dst in
            samples.withUnsafeBufferPointer { src in
                var offset = dataOffset
                for value in src {
                    dst[offset] = UInt8(value & 0xFF)
                    dst[offset + 1] = UInt8((value >> 8) & 0xFF)
                    offset += 2
                }
            }
        }

        return Data(bytes)
    }

    // MARK: - 容器细节

    private static func writeEntry(_ bytes: inout [UInt8], at offset: Int,
                                   tag: UInt16, type: UInt16, count: UInt32, value: UInt32) {
        put16(tag, &bytes, at: offset)
        put16(type, &bytes, at: offset + 2)
        put32(count, &bytes, at: offset + 4)
        put32(value, &bytes, at: offset + 8)
    }

    private static func put16(_ value: UInt16, _ bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func put32(_ value: UInt32, _ bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
