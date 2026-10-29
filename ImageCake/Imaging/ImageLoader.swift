import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 打开一张图。三条路按"能不能给出线性工作容器"排序，与 imagecake 的
// ImageEngine::load_linear 同序：
//
//   RAW（CIRAWFilter 能力内）→ 解码成 sRGB 线性；
//   JPEG/PNG/HEIC/TIFF（含 16bit）→ ImageIO，EXIF 方向在缩略图阶段就转正；
//   其它 → 报错并点名，不"尽量试试"。
//
// 预览与导出走同一个函数，差别只有 maxEdge：0 = 全量。两条路各写一遍的
// 下场是"预览转正了、导出躺着"（imagecake 在 RAW 预览档上踩过一次）。

struct LoadedImage: Sendable {
    var linear: LinearImage
    var originalSize: PixelSize
    var isRAW: Bool
    /// 人读的诊断（空 = 正常）。RAW 解不出来时的具体原因写在这里，
    /// 不换成一句"无法打开图片"——那是唯一能自证的信息。
    var note: String
    var captureDate: String
}

enum ImageLoadError: LocalizedError {
    case notFound
    case unreadable(String)
    case empty
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "[not_found] 文件不存在或没有读取权限"
        case .unreadable(let detail): return "[decode_failed] \(detail)"
        case .empty: return "[empty_image] 这张图没有像素"
        case .unsupported(let ext): return "[unsupported:\(ext)] 这个格式本机解不了"
        }
    }
}

enum ImageLoader {
    /// 本机 Core Image 支持的 RAW 后缀。判不了的交给 ImageIO 试——
    /// 那份名单只影响"要不要先走 RAW 那条更慢的路"。
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw",
        "x3f", "3fr", "erf", "kdc", "mrw", "raw", "rwl", "sr2", "iiq", "mos",
        "mef", "nrw", "gpr", "braw", "ari", "dcr", "k25", "mdc", "pxn", "r3d",
        "bay", "cap", "cs1", "dcs", "drf", "eip", "fff", "mfw", "ptx", "rpn",
    ]

    static func load(url: URL, maxEdge: Int) async throws -> LoadedImage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: url.path) else { throw ImageLoadError.notFound }
        let ext = url.pathExtension.lowercased()
        let isRAW = rawExtensions.contains(ext)

        // RAW 走 Core Image 的 RAW 解码；其它格式先试 ImageIO 缩略图（带方向转正）。
        if isRAW {
            return try loadWithCoreImage(url: url, maxEdge: maxEdge)
        }
        return try loadWithImageIO(url: url, maxEdge: maxEdge)
    }

    // MARK: - ImageIO

    private static func loadWithImageIO(url: URL, maxEdge: Int) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoadError.unreadable("ImageIO 打不开这个容器")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let pixelW = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let pixelH = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        let originalSize = PixelSize(width: pixelW, height: pixelH)

        // 属性读不出时不能把 ThumbnailMaxPixelSize 算成 0：那会解出一张
        // 1×1 的图，而用户看到的是"打开成功但图没了"。
        let longEdge = max(pixelW, pixelH)
        let target: Int
        if longEdge > 0 {
            target = (maxEdge > 0 && longEdge > maxEdge) ? maxEdge : longEdge
        } else {
            target = maxEdge > 0 ? maxEdge : 4096
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, target),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoadError.unreadable("缩略图阶段解不出来（可能是不完整的文件）")
        }
        guard let rgba = drawRGBA8(cgImage) else { throw ImageLoadError.empty }
        guard let linear = LinearImage(rgba8: rgba) else { throw ImageLoadError.empty }

        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let captureDate = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String ?? ""
        return LoadedImage(linear: linear,
                           originalSize: originalSize == .zero ? linear.size : originalSize,
                           isRAW: false,
                           note: "",
                           captureDate: captureDate)
    }

    // MARK: - RAW

    private static func loadWithCoreImage(url: URL, maxEdge: Int) throws -> LoadedImage {
        // CIRAWFilter 在 iOS 15 / macOS 12 起可用；这里只做"能不能解码"，
        // 不做镜头校正与降噪——那是另一批（S-6 的 GPU 档）。失败原因原样透传。
        guard var ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ImageLoadError.unreadable("RAW 解码器拒绝了这份文件（机型或压缩方式不受支持）")
        }
        let extent = ci.extent
        let originalSize = PixelSize(width: Int(extent.width.rounded()), height: Int(extent.height.rounded()))
        if maxEdge > 0, max(originalSize.width, originalSize.height) > maxEdge {
            let scale = CGFloat(maxEdge) / CGFloat(max(originalSize.width, originalSize.height))
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let rect = ci.extent.integral
        guard let cgImage = context.createCGImage(ci, from: rect) else {
            throw ImageLoadError.unreadable("RAW 解出来是空图")
        }
        guard let rgba = drawRGBA8(cgImage), let linear = LinearImage(rgba8: rgba) else {
            throw ImageLoadError.empty
        }
        return LoadedImage(linear: linear,
                           originalSize: originalSize == .zero ? linear.size : originalSize,
                           isRAW: true,
                           note: "RAW 走单次线性解码；底片增益与镜头校正不在 v1 范围",
                           captureDate: "")
    }

    // MARK: - CGImage → RGBA8

    /// 画进 sRGB 的 RGBA8 上下文：顺带完成一次色彩空间转换（带 ICC 的输入
    /// 在这里被解释成 sRGB，而不是"看着差不多"）。
    static func drawRGBA8(_ image: CGImage) -> RGBA8Buffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // 让 CGContext 自己分配内存：若用外部 [UInt8] 的指针建上下文，
        // 指针生命周期与上下文不同步，读回来是未定义行为。
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = ctx.data else { return nil }
        let byteCount = width * height * 4
        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes.withUnsafeMutableBytes { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: base, count: byteCount))
        }
        // 预乘数据还原成直通 alpha：下游（AI 模型/合成）吃的是直通语义，
        // 带着预乘进去会让"半透明边缘"变成一圈偏暗的边。
        for i in 0 ..< (width * height) {
            let a = Int(bytes[i * 4 + 3])
            if a == 0 || a == 255 { continue }
            bytes[i * 4] = UInt8(min(255, Int(bytes[i * 4]) * 255 / a))
            bytes[i * 4 + 1] = UInt8(min(255, Int(bytes[i * 4 + 1]) * 255 / a))
            bytes[i * 4 + 2] = UInt8(min(255, Int(bytes[i * 4 + 2]) * 255 / a))
        }
        return RGBA8Buffer(size: PixelSize(width: width, height: height), data: Data(bytes))
    }
}

// MARK: - 写盘

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png8
    case png16
    case tiff16
    case jpeg
    case heif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png8: return "PNG 8bit"
        case .png16: return "PNG 16bit"
        case .tiff16: return "TIFF 16bit"
        case .jpeg: return "JPEG"
        case .heif: return "HEIF"
        }
    }

    var fileExtension: String {
        switch self {
        case .png8, .png16: return "png"
        case .tiff16: return "tiff"
        case .jpeg: return "jpg"
        case .heif: return "heic"
        }
    }
}

enum ImageExporter {
    static func write(_ image: DisplayImage, to url: URL, format: ExportFormat, quality: Double) throws {
        let data: Data
        switch format {
        case .png16:
            data = try PNG16Writer.encode(image)
        case .tiff16:
            data = try TIFF16Writer.encode(image)
        case .png8:
            data = try encodeWithImageIO(image, type: .png, quality: 1, flatten: false)
        case .jpeg:
            data = try encodeWithImageIO(image, type: .jpeg, quality: quality, flatten: true)
        case .heif:
            data = try encodeWithImageIO(image, type: .heic, quality: quality, flatten: false)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func encodeWithImageIO(_ image: DisplayImage, type: UTType, quality: Double, flatten: Bool) throws -> Data {
        guard var cg = image.cgImage() else { throw ImageLoadError.empty }
        if flatten, let space = CGColorSpace(name: CGColorSpace.sRGB) {
            // JPEG 没有 alpha：垫白再画，避免透明区被编码器涂成黑。
            if let ctx = CGContext(data: nil, width: image.size.width, height: image.size.height,
                                   bitsPerComponent: 8, bytesPerRow: image.size.width * 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
                if let flattened = ctx.makeImage() {
                    cg = flattened
                }
            }
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ImageLoadError.unsupported(type.identifier)
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageLoadError.unreadable("编码器拒绝了这张图（HEIF 在部分机型上不可用）")
        }
        return out as Data
    }
}
