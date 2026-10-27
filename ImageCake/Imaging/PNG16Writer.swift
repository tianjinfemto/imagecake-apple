import Foundation

// 16bit PNG 写入器。
//
// 为什么不用 ImageIO：CGImageDestination 对 16bit RGBA 的字节序处理随平台/
// 色彩空间配置变化（同一份 buffer 在 macOS 与 iPadOS 上可能一个正常一个
// 通道错位），而 16bit 交付件是这个项目对"印刷/后期"的承诺。自己写容器
// 之后，端序、filter、压缩策略都在源码里能读出来。
//
// 压缩用 zlib 的 stored 块（不压缩）：与 imagecake 的 encode_png16_rgba
// 同一条立场——不为了省体积引第三方库，文件偏大但每个字节都可解释。

enum PNG16Writer {
    /// 显示域 RGBA → PNG-16（RGBA，8 字节/像素）。失败只在尺寸非法时发生。
    static func encode(_ image: DisplayImage) throws -> Data {
        guard image.size.pixelCount > 0, image.pixels.count == image.size.pixelCount * 4 else {
            throw ImageLoadError.empty
        }
        let width = image.size.width
        let height = image.size.height

        // 扫描线：每行 1 字节 filter（0=None）+ w*8 字节（RGBA 各 16bit 大端）
        let samples = image.rgba16()
        let rowBytes = 1 + width * 8
        var raw = [UInt8](repeating: 0, count: height * rowBytes)
        raw.withUnsafeMutableBufferPointer { out in
            samples.withUnsafeBufferPointer { src in
                for y in 0 ..< height {
                    let rowStart = y * rowBytes
                    out[rowStart] = 0
                    for x in 0 ..< width {
                        let i = (y * width + x) * 4
                        let o = rowStart + 1 + x * 8
                        // 逐通道写，不建临时数组：48MP 的图建一次数组就是
                        // 4800 万次分配，16bit 导出会从“等一分钟”变“等十分钟”。
                        let r = src[i], g = src[i + 1], b = src[i + 2], a = src[i + 3]
                        out[o] = UInt8((r >> 8) & 0xFF)
                        out[o + 1] = UInt8(r & 0xFF)
                        out[o + 2] = UInt8((g >> 8) & 0xFF)
                        out[o + 3] = UInt8(g & 0xFF)
                        out[o + 4] = UInt8((b >> 8) & 0xFF)
                        out[o + 5] = UInt8(b & 0xFF)
                        out[o + 6] = UInt8((a >> 8) & 0xFF)
                        out[o + 7] = UInt8(a & 0xFF)
                    }
                }
            }
        }

        var out = Data(capacity: raw.count + 128)
        // PNG 签名
        out.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // IHDR：宽/高/位深 16/颜色类型 6（RGBA）/压缩 0/过滤 0/交错 0
        var ihdr = Data()
        ihdr.append(be32(UInt32(width)))
        ihdr.append(be32(UInt32(height)))
        ihdr.append(contentsOf: [16, 6, 0, 0, 0])
        appendChunk("IHDR", ihdr, to: &out)

        // IDAT：zlib 头 + stored 块 + Adler-32
        var idat = Data()
        idat.append(contentsOf: [0x78, 0x01]) // CMF/FLG：deflate、32K 窗口、无预设字典
        var offset = 0
        let maxBlock = 65535
        while offset < raw.count {
            let length = min(maxBlock, raw.count - offset)
            let isFinal: UInt8 = offset + length >= raw.count ? 1 : 0
            idat.append(isFinal)
            idat.append(UInt8(length & 0xFF))
            idat.append(UInt8((length >> 8) & 0xFF))
            let inv = ~UInt16(length)
            idat.append(UInt8(inv & 0xFF))
            idat.append(UInt8((inv >> 8) & 0xFF))
            idat.append(contentsOf: raw[offset ..< (offset + length)])
            offset += length
        }
        idat.append(be32(adler32(raw)))
        appendChunk("IDAT", idat, to: &out)

        appendChunk("IEND", Data(), to: &out)
        return out
    }

    // MARK: - 容器细节

    private static func appendChunk(_ type: String, _ payload: Data, to out: inout Data) {
        let typeBytes = Array(type.utf8)
        precondition(typeBytes.count == 4, "PNG chunk 类型必须是 4 字节 ASCII")
        out.append(be32(UInt32(payload.count)))
        out.append(contentsOf: typeBytes)
        out.append(payload)
        var crcInput = Data(typeBytes)
        crcInput.append(payload)
        out.append(be32(crc32(crcInput)))
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}
