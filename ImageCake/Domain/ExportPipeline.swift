import Foundation

// 导出流水线。
//
// 顺序是承诺，不是实现细节：
//   全分辨率重载 → 调色 → 修复补丁 → 换底色 → 面部重绘 → AI 超清 → 尺寸档 → 编码
//
// 面部重绘与 AI 超清只在这里出现：两者都是秒级到分钟级，进预览会把
// 滑杆变成幻灯片（imagecake 的同一结论）。超清必须最后一步——
// 液化/修复的坐标都活在原图上，先放大再走会落到挪了位的图上。
//
// 失败不静默：任何一步失败都写进 notes（`[no_model]` / `[closed_eyes]` /
// `[too_large]` …），由 UI 原样显示；不会拿"原图"冒充"超清完成"。

struct ExportOutcome: Sendable {
    var display: DisplayImage
    var notes: [String]
}

enum ExportError: LocalizedError {
    /// PNG-16 是“不压缩 + 双份缓冲”的写法：24MP 的峰值约 600MB，
    /// 再往上就是被系统杀掉而不是报错。点名拒绝，不让它变成闪退。
    case png16TooLarge(pixels: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .png16TooLarge(let pixels, let limit):
            return "[png16_too_large] 这张图 \(pixels / 1_000_000)MP，超过 PNG-16 的 \(limit / 1_000_000)MP 上限；请改用 JPEG/PNG-8，或先压长边"
        }
    }
}

enum ExportPipeline {
    /// 全分辨率重载的上限，按物理内存分档。一张 50MP 的 float RGBA 是
    /// 800MB，链上还有补丁/超清/编码的峰值；4GB 的 iPad 在 16MP 就已经
    /// 靠边，8GB 的 Pro 才给到 32MP。
    static var maxRenderPixels: Int {
        let ram = ProcessInfo.processInfo.physicalMemory
        if ram >= 7_000_000_000 { return 32_000_000 }
        if ram >= 5_000_000_000 { return 24_000_000 }
        return 16_000_000
    }

    /// PNG-16 是“不压缩 + 双份缓冲”的写法，再叠上内存档。
    static var maxPNG16Pixels: Int {
        let ram = ProcessInfo.processInfo.physicalMemory
        if ram >= 7_000_000_000 { return 24_000_000 }
        if ram >= 5_000_000_000 { return 20_000_000 }
        return 12_000_000
    }

    static func render(_ document: ImageDocument,
                       store: ModelStore,
                       ort: ORTEngine,
                       fullResolution: Bool) async -> ExportOutcome {
        var notes: [String] = []
        var linear = document.linear

        if fullResolution, let url = document.sourceURL {
            do {
                let loaded = try await ImageLoader.load(url: url, maxEdge: 0)
                linear = loaded.linear
                if !loaded.note.isEmpty { notes.append("[reload] \(loaded.note)") }
            } catch {
                notes.append("[reload_failed] 全分辨率重载失败，已用预览档导出")
            }
        }
        if linear.size.pixelCount > maxRenderPixels {
            linear = linear.resized(maxEdge: 6000)
            notes.append("[export_downscaled] 导出上限 \(maxRenderPixels) 像素")
        }

        let working = ImageDocument(linear: linear,
                                    originalSize: document.originalSize,
                                    params: document.params,
                                    sourceURL: document.sourceURL,
                                    isRAW: document.isRAW,
                                    loadNote: document.loadNote,
                                    personMask: document.personMask,
                                    maskReference: document.maskReference,
                                    patches: document.patches)
        if working.patches.contains(where: { $0.reference != working.canvasSize }) {
            notes.append("[patch_scaled] 修复补丁按导出尺寸缩放（v1 未重跑网络）")
        }
        if working.params.bgEnabled && working.personMask == nil {
            notes.append("[no_mask] 未抠图，换底色被跳过")
        }

        var display = working.render()
        var bytes = display.rgba8()

        if working.params.faceRestore > 0 {
            let result = await FaceRestoreTask.run(display: bytes,
                                                   strength: Int(working.params.faceRestore),
                                                   store: store,
                                                   ort: ort)
            if let image = result.image {
                bytes = image
                if !result.report.note.isEmpty { notes.append(result.report.note) }
            } else {
                notes.append(result.report.note)
            }
        }

        if working.params.superRes != 0 {
            let result = await SuperResTask.run(display: bytes,
                                                scale: working.params.superRes,
                                                store: store,
                                                ort: ort)
            if let image = result.image {
                bytes = image
                if !result.report.note.isEmpty { notes.append(result.report.note) }
            } else {
                notes.append(result.report.note)
            }
        }

        if let rebuilt = DisplayImage(displayRGBA8: bytes) {
            display = rebuilt
        }
        return ExportOutcome(display: display, notes: notes)
    }

    static func encode(_ outcome: ExportOutcome,
                       format: ExportFormat,
                       quality: Double,
                       maxEdge: Int) throws -> Data {
        var display = outcome.display
        if maxEdge > 0, display.size.longEdge > maxEdge {
            let scale = Double(maxEdge) / Double(display.size.longEdge)
            let target = PixelSize(width: max(1, Int(Double(display.size.width) * scale)),
                                   height: max(1, Int(Double(display.size.height) * scale)))
            display = display.resized(to: target)
        }

        switch format {
        case .png16:
            guard display.size.pixelCount <= maxPNG16Pixels else {
                throw ExportError.png16TooLarge(pixels: display.size.pixelCount, limit: maxPNG16Pixels)
            }
            return try PNG16Writer.encode(display)
        case .png8, .jpeg, .heif:
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("imagecake-export-\(UUID().uuidString).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try ImageExporter.write(display, to: url, format: format, quality: quality)
            return try Data(contentsOf: url)
        }
    }
}
