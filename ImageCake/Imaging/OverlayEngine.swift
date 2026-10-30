import CoreGraphics
import Foundation

// 水印 / 边框 / 文字贴纸。
//
// 作用在导出的**最后一步**（编码之前）：调色/液化/补丁/AI 都走完了，
// 再往上贴装饰元素。不进 render() 预览管线——预览看修图效果，不看水印。
//
// 三种元素：
//   · 水印：一张半透明图（logo）平铺或定位于角落
//   · 边框：纯色或渐色框，按比例算宽度
//   · 文字：一行字符串，指定字体/大小/颜色/位置

struct OverlayElement: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case watermark(imageData: Data, opacity: Double, position: OverlayPosition, scale: Double)
        case border(color: RGBA8, widthRatio: Double)
        case text(String, fontName: String, sizeRatio: Double, color: RGBA8, position: OverlayPosition)
    }

    enum OverlayPosition: String, Equatable, Sendable, CaseIterable {
        case center, topLeft, topRight, bottomLeft, bottomRight
    }

    var id: UUID
    var kind: Kind
    var enabled: Bool = true
}

struct RGBA8: Equatable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8 = 255
}

enum OverlayEngine {
    /// 把所有启用的 overlay 元素合成到画面上。
    static func apply(_ image: RGBA8Buffer, elements: [OverlayElement]) -> RGBA8Buffer {
        guard elements.contains(where: { $0.enabled }) else { return image }
        var result = image
        for element in elements where element.enabled {
            switch element.kind {
            case .border(let color, let widthRatio):
                result = drawBorder(result, color: color, widthRatio: widthRatio)
            case .text(let text, let fontName, let sizeRatio, let color, let position):
                result = drawText(result, text: text, fontName: fontName,
                                  sizeRatio: sizeRatio, color: color, position: position)
            case .watermark(let data, let opacity, let position, let scale):
                result = drawWatermark(result, imageData: data, opacity: opacity,
                                       position: position, scale: scale)
            }
        }
        return result
    }

    private static func drawBorder(_ image: RGBA8Buffer, color: RGBA8, widthRatio: Double) -> RGBA8Buffer {
        let w = image.size.width
        let h = image.size.height
        let borderWidth = max(1, Int(Double(min(w, h)) * widthRatio))
        var bytes = image.data
        bytes.withUnsafeMutableBytes { ptr in
            let p = ptr.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    if y < borderWidth || y >= h - borderWidth || x < borderWidth || x >= w - borderWidth {
                        let idx = (y * w + x) * 4
                        p[idx] = color.r
                        p[idx + 1] = color.g
                        p[idx + 2] = color.b
                        p[idx + 3] = color.a
                    }
                }
            }
        }
        return RGBA8Buffer(size: image.size, data: bytes)
    }

    private static func drawText(_ image: RGBA8Buffer, text: String, fontName: String,
                                 sizeRatio: Double, color: RGBA8,
                                 position: OverlayElement.OverlayPosition) -> RGBA8Buffer {
        let w = image.size.width
        let h = image.size.height
        let fontSize = max(8, Int(Double(min(w, h)) * sizeRatio))
        #if canImport(UIKit)
        let font = UIFont(name: fontName, size: CGFloat(fontSize)) ?? UIFont.systemFont(ofSize: CGFloat(fontSize))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(r: color.r, g: color.g, b: color.b, a: color.a)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let point = positionPoint(position, textSize: size, canvasSize: image.size)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let rendered = renderer.image { ctx in
            ctx.cgContext.draw(in: CGRect(x: 0, y: 0, width: w, height: h), image: image.cgImage() ?? CIImage().createCGImage(from: CGRect(x: 0, y: 0, width: w, height: h))!)
            (text as NSString).draw(at: point, withAttributes: attrs)
        }
        return RGBA8Buffer(cgImage: rendered.cgImage!, size: image.size) ?? image
        #elseif canImport(AppKit)
        let font = NSFont(name: fontName, size: CGFloat(fontSize)) ?? NSFont.systemFont(ofSize: CGFloat(fontSize))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: CGFloat(color.r)/255, green: CGFloat(color.g)/255, blue: CGFloat(color.b)/255, alpha: CGFloat(color.a)/255)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let point = positionPoint(position, textSize: size, canvasSize: image.size)
        guard let cgImage = image.cgImage() else { return image }
        let nsImage = NSImage(size: NSSize(width: w, height: h))
        nsImage.lockFocus()
        NSGraphicsContext.current?.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        (text as NSString).draw(at: NSPoint(x: point.x, y: h - point.y - size.height), withAttributes: attrs)
        nsImage.unlockFocus()
        guard let rep = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        return RGBA8Buffer(cgImage: rep, size: image.size) ?? image
        #else
        return image
        #endif
    }

    private static func drawWatermark(_ image: RGBA8Buffer, imageData: Data, opacity: Double,
                                      position: OverlayElement.OverlayPosition, scale: Double) -> RGBA8Buffer {
        guard let wmCG = CGImage(data: imageData),
              let wmBuffer = RGBA8Buffer(cgImage: wmCG, size: PixelSize(width: wmCG.width, height: wmCG.height)) else {
            return image
        }
        let targetW = max(1, Int(Double(image.size.width) * scale))
        let targetH = max(1, Int(Double(image.size.height) * scale))
        let resized = wmBuffer.resized(to: PixelSize(width: targetW, height: targetH))
        let offsetX: Int
        let offsetY: Int
        switch position {
        case .center:
            offsetX = (image.size.width - targetW) / 2
            offsetY = (image.size.height - targetH) / 2
        case .topLeft:
            offsetX = 0; offsetY = 0
        case .topRight:
            offsetX = image.size.width - targetW; offsetY = 0
        case .bottomLeft:
            offsetX = 0; offsetY = image.size.height - targetH
        case .bottomRight:
            offsetX = image.size.width - targetW; offsetY = image.size.height - targetH
        }
        var bytes = image.data
        bytes.withUnsafeMutableBytes { dstPtr in
            let dst = dstPtr.bindMemory(to: UInt8.self)
            resized.data.withUnsafeBytes { srcPtr in
                let src = srcPtr.bindMemory(to: UInt8.self)
                for y in 0..<targetH {
                    for x in 0..<targetW {
                        let dx = offsetX + x
                        let dy = offsetY + y
                        guard dx >= 0, dx < image.size.width, dy >= 0, dy < image.size.height else { continue }
                        let srcIdx = (y * targetW + x) * 4
                        let dstIdx = (dy * image.size.width + dx) * 4
                        let alpha = Double(src[srcIdx + 3]) / 255 * opacity
                        for ch in 0..<3 {
                            dst[dstIdx + ch] = UInt8(Double(dst[dstIdx + ch]) * (1 - alpha) + Double(src[srcIdx + ch]) * alpha)
                        }
                    }
                }
            }
        }
        return RGBA8Buffer(size: image.size, data: bytes)
    }

    private static func positionPoint(_ position: OverlayElement.OverlayPosition,
                                       textSize: CGSize, canvasSize: PixelSize) -> CGPoint {
        let margin: CGFloat = 16
        switch position {
        case .center:
            return CGPoint(x: CGFloat(canvasSize.width - Int(textSize.width)) / 2,
                           y: CGFloat(canvasSize.height - Int(textSize.height)) / 2)
        case .topLeft:
            return CGPoint(x: margin, y: margin)
        case .topRight:
            return CGPoint(x: CGFloat(canvasSize.width) - textSize.width - margin, y: margin)
        case .bottomLeft:
            return CGPoint(x: margin, y: CGFloat(canvasSize.height) - textSize.height - margin)
        case .bottomRight:
            return CGPoint(x: CGFloat(canvasSize.width) - textSize.width - margin,
                           y: CGFloat(canvasSize.height) - textSize.height - margin)
        }
    }
}