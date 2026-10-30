import CoreGraphics
import Foundation

// ICC 色彩空间：输出时嵌入 sRGB profile。
//
// Core Graphics 在编码时可以嵌 ICC profile。我们固定输出 sRGB——
// 整条管线都在 sRGB 域里算，嵌别的 profile 等于撒谎。
//
// ImageIO 的 CGImageDestinationSetProperties 可以带 ICC，
// 但更可靠的是在 CGImage 上设 colorSpace，编码器会自动提取。

enum ICCProfile {
    /// 给 CGImage 打上 sRGB color space 标记。
    /// 编码时 ImageIO 会自动把 color space 写进 ICC profile 块。
    static func tagSRGB(_ cgImage: CGImage) -> CGImage? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return cgImage }
        let w = cgImage.width
        let h = cgImage.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let context = CGContext(data: &pixels,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return cgImage
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// 导出时给 properties 字典加 ICC 数据（备用路径，用于不经过 CGImage 的编码）。
    static func sRGBProfileData() -> Data? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return sRGB.iccData as Data?
    }
}