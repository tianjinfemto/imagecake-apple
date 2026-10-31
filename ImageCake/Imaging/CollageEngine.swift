import CoreGraphics
import Foundation

// 拼图排版：把多张图按模板排到一张画布上。
//
// 模板是确定性的几何布局（不是 AI）：网格/瀑布/拼贴/相框。
// 每个槽位指定位置与尺寸（归一化），图按 contain/cover 适配。
//
// v1 提供 4 种模板：1×2、2×1、2×2、1×3。
//
// 默认走 aspectFill（等比裁切）而不是拉伸：商业出片里"把竖图拉成横格"
// 是比留白更不可接受的结果；留白只在 aspectFit 下出现。
// 图不够槽位时不拿纯色填坑，而是让调用侧点名 `[collage_short]`——
// 跟本项目"缺件必须说话"的立场一致。

struct CollageTemplate: Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var columns: Int
    var rows: Int
    /// 每个槽位的归一化矩形（0...1），按行优先序。
    var slots: [CGRect]
    /// 槽间距（归一化）。
    var gap: Double = 0.01
    /// 背景色。
    var background: RGBA8 = RGBA8(r: 255, g: 255, b: 255)
    /// 适配方式。默认等比裁切填满（aspectFill）。
    var fit: CollageFit = .aspectFill
}

enum CollageFit: String, Equatable, Sendable, CaseIterable, Identifiable {
    /// 等比裁切填满槽位（多出来的部分居中切掉）。
    case aspectFill
    /// 等比缩放留白（槽位内居中，不裁切）。
    case aspectFit
    /// 直接拉到槽位尺寸（会变形，只留给"已知同比例"的场景）。
    case stretch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .aspectFill: return "填满（等比裁切）"
        case .aspectFit: return "留白（等比不裁）"
        case .stretch: return "拉伸（会变形）"
        }
    }
}

enum CollageEngine {
    /// 可选的底色（面板上只给这几个，避免把"拾色器"当成必需项）。
    static let backgrounds: [String: RGBA8] = [
        "white": RGBA8(r: 255, g: 255, b: 255),
        "black": RGBA8(r: 0, g: 0, b: 0),
        "gray": RGBA8(r: 128, g: 128, b: 128)
    ]

    static func background(id: String) -> RGBA8 {
        backgrounds[id] ?? backgrounds["white"]!
    }

    static let templates: [CollageTemplate] = [
        CollageTemplate(name: "1×2 横排", columns: 2, rows: 1,
                        slots: [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                                CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]),
        CollageTemplate(name: "2×1 竖排", columns: 1, rows: 2,
                        slots: [CGRect(x: 0, y: 0, width: 1, height: 0.5),
                                CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]),
        CollageTemplate(name: "2×2 网格", columns: 2, rows: 2,
                        slots: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                                CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                                CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]),
        CollageTemplate(name: "1×3 横排", columns: 3, rows: 1,
                        slots: [CGRect(x: 0, y: 0, width: 1.0/3, height: 1),
                                CGRect(x: 1.0/3, y: 0, width: 1.0/3, height: 1),
                                CGRect(x: 2.0/3, y: 0, width: 1.0/3, height: 1)])
    ]

    static func template(id: UUID) -> CollageTemplate? {
        templates.first { $0.id == id }
    }

    /// 槽位在画布上的像素矩形（已夹到画布内）。
    static func slotRects(for template: CollageTemplate, canvas: PixelSize) -> [PixelRect] {
        template.slots.map { PixelRect.fromNormalized($0, in: canvas) }
    }

    /// 把一张图适配到一个槽位：返回与槽位同尺寸的图。
    /// 槽位退化（宽或高 ≤ 0）或空图时原样返回而不是崩。
    static func fit(_ image: RGBA8Buffer, to rect: PixelRect, mode: CollageFit) -> RGBA8Buffer {
        guard !rect.isEmpty, image.size.pixelCount > 0 else { return image }
        switch mode {
        case .stretch:
            return image.resized(to: rect.size)
        case .aspectFill:
            // 取"两边都不小于目标"的最小缩放，再居中裁掉多出的部分。
            let sx = Double(rect.width) / Double(image.size.width)
            let sy = Double(rect.height) / Double(image.size.height)
            let scale = Swift.max(sx, sy)
            let scaled = image.resized(to: PixelSize(
                width: Swift.max(rect.width, Int((Double(image.size.width) * scale).rounded())),
                height: Swift.max(rect.height, Int((Double(image.size.height) * scale).rounded()))))
            let offsetX = (scaled.size.width - rect.width) / 2
            let offsetY = (scaled.size.height - rect.height) / 2
            return scaled.cropped(to: PixelRect(x: Swift.max(0, offsetX), y: Swift.max(0, offsetY),
                                                width: rect.width, height: rect.height))
        case .aspectFit:
            // 取"两边都不超出目标"的最大缩放，居中贴在槽位上；留白是背景色。
            let sx = Double(rect.width) / Double(image.size.width)
            let sy = Double(rect.height) / Double(image.size.height)
            let scale = Swift.min(sx, sy)
            let target = PixelSize(width: Swift.max(1, Int((Double(image.size.width) * scale).rounded())),
                                   height: Swift.max(1, Int((Double(image.size.height) * scale).rounded())))
            let scaled = image.resized(to: target)
            let offsetX = max(0, (rect.width - scaled.size.width) / 2)
            let offsetY = max(0, (rect.height - scaled.size.height) / 2)
            guard offsetX + scaled.size.width <= rect.width,
                  offsetY + scaled.size.height <= rect.height else { return image }
            var out = [UInt8](repeating: 0, count: rect.size.pixelCount * 4)
            scaled.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let src = raw.bindMemory(to: UInt8.self)
                for y in 0 ..< scaled.size.height {
                    let dstRow = ((y + offsetY) * rect.width + offsetX) * 4
                    let srcRow = y * scaled.size.width * 4
                    for i in 0 ..< (scaled.size.width * 4) {
                        out[dstRow + i] = src[srcRow + i]
                    }
                }
            }
            return RGBA8Buffer(size: rect.size, data: Data(out))
        }
    }

    /// 把多张图按模板排到一张画布上。
    /// canvasSize 是输出画布尺寸；images 数量必须 >= slots 数量，
    /// 不足时返回 nil（调用侧点名，不拿纯色假装排好了）。
    static func compose(images: [RGBA8Buffer], template: CollageTemplate,
                        canvasSize: PixelSize) -> RGBA8Buffer? {
        guard images.count >= template.slots.count, canvasSize.pixelCount > 0 else { return nil }
        var canvas = [UInt8](repeating: 0, count: canvasSize.pixelCount * 4)
        for i in 0 ..< canvasSize.pixelCount {
            let idx = i * 4
            canvas[idx] = template.background.r
            canvas[idx + 1] = template.background.g
            canvas[idx + 2] = template.background.b
            canvas[idx + 3] = 255
        }
        for (slot, image) in zip(template.slots, images) {
            let rect = PixelRect.fromNormalized(slot, in: canvasSize)
            guard !rect.isEmpty else { continue }
            var fitted = fit(image, to: rect, mode: template.fit)
            // 兼容取整缝：3 格模板在 100px 宽上会算出 33/34/33，最后一格的
            // fit 可能差一个像素。这里补一次而不是丢弃 —— 丢弃的症状是
            // "那一格露出了底色"，比多缩一个像素难查得多。
            if fitted.size != rect.size {
                fitted = fitted.resized(to: rect.size)
            }
            guard fitted.data.count >= rect.size.pixelCount * 4 else { continue }
            fitted.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let src = raw.bindMemory(to: UInt8.self)
                for y in 0 ..< rect.height {
                    let dstRow = ((rect.y + y) * canvasSize.width + rect.x) * 4
                    let srcRow = y * rect.width * 4
                    for i in 0 ..< (rect.width * 4) {
                        canvas[dstRow + i] = src[srcRow + i]
                    }
                }
            }
        }
        return RGBA8Buffer(size: canvasSize, data: Data(canvas))
    }
}

// MARK: - 一次拼图导出

/// 拼图导出的输入：模板 + 底色 + 其余槽位的图源。
///
/// 为什么不存像素而存 URL：导出是全分辨率重渲染，拿预览档的字节去排版
/// 会得到"屏幕上清楚、文件里模糊"。存 URL 才能把每张图各自走一遍
/// `ExportPipeline`（主图排第一格）。
///
/// 默认**不拿主图重复填坑**：图不够就是不够，`shortfallWarning` 会把这件事
/// 在导出报告与底栏都点名 `[collage_short]`；只有用户显式勾了
/// `allowMainRepeat`（比如证件照式的"同图四连"）才允许重复。
struct CollageComposition: Equatable, Sendable, Codable {
    var templateID: UUID
    var backgroundID: String = "white"
    var extraURLs: [URL] = []
    var allowMainRepeat: Bool = false
    /// 输出画布长边（像素）。0 = 用主图当前画布尺寸。
    var longEdge: Int = 0

    /// 图不够时的点名（nil = 够用）。模板不存在也算不出来，因为那时根本
    /// 不会走到排版（调用侧先查模板）。
    func shortfallWarning(slots: Int) -> String? {
        let supply = extraURLs.count + 1
        if supply >= slots { return nil }
        if allowMainRepeat { return nil }
        return "[collage_short] 模板需要 \(slots) 张，只选了 \(supply) 张（含主图）；补选图片或勾「用主图重复填满」才会排版"
    }

    /// 模板缺失时的固定点名（模板 id 是会话内 UUID，换设备/重开后可能找不到）。
    static let missingTemplateNote = "[collage_no_template] 拼图模板不存在，本次未排版"
}
