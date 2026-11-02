import Foundation

// 导出流水线。
//
// 顺序是承诺，不是实现细节（与 ImageDocument.render 同序）：
//   全分辨率重载 → 几何转正 → 调色 → 皮肤色域分层 → 滤镜 → 镜头几何 → 空间滤波
//   → 美肤 → 区域美化 → 妆容/手部/头发 → 美型预设 → 液化 → 仿制图章 → 衣物祛褶
//   → 修补 → 修复补丁 → 换底色 → 换天空 → 虚拟打光 → 暗角与颗粒
//   → 面部重绘 → AI 超清 → 证件照排版 → 拼图排版 → 装饰叠加 → 编码
//
// 预览与导出走同一个 `ImageDocument.render()`，所以笔刷不需要在这里出现：
// 它们存的是归一化坐标 + 长边比例的半径，在全分辨率画布上重放就是正确位置。
// 这也是笔刷不进补丁那类 `[..._scaled]` 备注的原因——补丁要缩放是因为它
// 存的是像素矩形，而笔迹从来不存像素。
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
    /// 不压缩 16bit 格式（PNG-16 / TIFF-16）都是“不压缩 + 双份缓冲”的写法：
    /// 24MP 的峰值约 600MB，再往上就是被系统杀掉而不是报错。
    /// 点名拒绝，不让它变成闪退。
    case uncompressedTooLarge(kind: String, pixels: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .uncompressedTooLarge(let kind, let pixels, let limit):
            let token = kind.replacingOccurrences(of: "-", with: "").lowercased()
            return "[\(token)_too_large] 这张图 \(pixels / 1_000_000)MP，超过 \(kind) 的 \(limit / 1_000_000)MP 上限；请改用 JPEG/PNG-8，或先压长边"
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

    /// 不压缩 16bit 格式的像素上限，按物理内存分档。PNG-16 与 TIFF-16 共用：
    /// 两者都是「不压缩 + 双份缓冲」，内存峰值同一个量级。
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

        var working = ImageDocument(linear: linear,
                                    originalSize: document.originalSize,
                                    params: document.params,
                                    sourceURL: document.sourceURL,
                                    isRAW: document.isRAW,
                                    loadNote: document.loadNote,
                                    personMask: document.personMask,
                                    maskReference: document.maskReference,
                                    patches: document.patches,
                                    brush: document.brush)
        working.geometry = document.geometry
        working.overlays = document.overlays
        working.localAdjustments = document.localAdjustments
        working.patchStrokes = document.patchStrokes
        working.oldPhotoRestore = document.oldPhotoRestore
        working.oldPhotoScratchThreshold = document.oldPhotoScratchThreshold
        // 关键点派生的语义量是**归一化**的，所以在全分辨率画布上直接能用；
        // 不带过去的话症状是“预览有磨皮瘦脸、导出件没有”。逐张脸都带，
        // 否则“预览里合影每张都磨了、导出只磨了最大那张”。
        working.faceGeometries = document.faceGeometries
        working.bodyAnchors = document.bodyAnchors
        // 手、天空区域、导入的那张天、追色的样片都是同一类资产：不带过去就是
        // "预览里手磨了、天换了、调性对上了，导出件里三者都没了"。
        working.handHulls = document.handHulls
        working.skyMask = document.skyMask
        working.skyPhoto = document.skyPhoto
        working.colorReference = document.colorReference
        working.idPhotoSheet = document.idPhotoSheet
        working.collage = document.collage
        if working.patches.contains(where: { $0.reference != working.canvasSize }) {
            notes.append("[patch_scaled] 修复补丁按导出尺寸缩放（v1 未重跑网络）")
        }
        // “开了开关但缺资产”与预览底栏同一份名单（含 [no_mask]），
        // 不两处各写一套判定。
        notes.append(contentsOf: working.pipelineWarnings)

        // 导出自己开一个计时器：它与预览同一口径、但不共用实例（一个实例只属于
        // 一次渲染），这样全分辨率重放到底耗在哪一段会直接写进导出报告。
        let perf = RenderPerf()
        var display = working.render(perf: perf)
        var bytes = display.rgba8()

        if working.params.faceRestore > 0 {
            let result = try? await perf.stageAsync("faceRestore") {
                await FaceRestoreTask.run(display: bytes,
                                          strength: Int(working.params.faceRestore),
                                          store: store,
                                          ort: ort)
            }
            if let result {
                if let image = result.image {
                    bytes = image
                    if !result.report.note.isEmpty { notes.append(result.report.note) }
                } else {
                    notes.append(result.report.note)
                }
            }
        }

        if working.params.superRes != 0 {
            let result = try? await perf.stageAsync("superRes") {
                await SuperResTask.run(display: bytes,
                                       scale: working.params.superRes,
                                       store: store,
                                       ort: ort)
            }
            if let result {
                if let image = result.image {
                    bytes = image
                    if !result.report.note.isEmpty { notes.append(result.report.note) }
                } else {
                    notes.append(result.report.note)
                }
            }
        }

        // 证件照排版：把单张照片排到相纸上（同一张重复 N 次）。
        // 排在 AI 之后：重绘/超清要对着单张大图做，排完再跑等于浪费算力。
        if let sheet = working.idPhotoSheet {
            let laid = perf.stage("idPhoto") { IDPhoto.layout(bytes, sheet: sheet) }
            if let laid {
                bytes = laid
                notes.append("[id_photo] \(sheet.paper.title) 排 \(sheet.count) 张 · \(sheet.canvas.width)×\(sheet.canvas.height)")
            } else {
                notes.append("[id_photo_empty] \(sheet.paper.title) 相纸排不下这个规格（排版须 ≥ 1 张），导出未排版")
            }
        }

        // 拼图排版：多张图按模板排到一张画布上（CollageEngine 一直只有算子
        // 没有入口，这里把它接进导出）。排在证件照之后、装饰之前：
        // 水印要盖的是整张拼图，不是每个格子里的图。
        //
        // 其余槽位各自走一遍完整导出链（全分辨率 + 按同步组抄参数），
        // 但**强制关掉交付端 AI**：4 格就是 4 次重绘/超清，批量场景是分钟级
        // 叠加，而且逐格重绘在拼图上看不出区别。
        if let composition = working.collage {
            let stage = await perf.stageAsync("collage") {
                await Self.composeCollage(main: bytes, canvas: display.size,
                                          composition: composition, document: working,
                                          store: store, ort: ort)
            }
            switch stage {
            case .composed(let laid, let note):
                bytes = laid
                notes.append(note)
            case .failed(let note):
                notes.append(note)
            }
        }

        // 水印/边框/文字贴纸：导出最后一步（AI 之后、编码之前）。
        // 不进预览管线——预览看修图效果，不看装饰。

        if !working.overlays.isEmpty {
            bytes = perf.stage("overlays") { OverlayEngine.apply(bytes, elements: working.overlays) }
        }

        if let rebuilt = DisplayImage(displayRGBA8: bytes) {
            display = rebuilt
        }
        // 导出报告里的耗时行：与预览同一口径、同一个类型，只是多带几个 AI 阶段。
        // 它不靠肉眼验收：没有这一行，“导出特别慢”永远只能凭感觉说。
        notes.append("[perf] " + perf.summary())
        // 好片初筛（确定性三轴：清晰度 / 截幅 / 曝光）。它进报告而不是进弹窗：
        // 导出口径上看到数，才不会把它误当"自动删片"的授权。面板入口本轮没做,
        // 所以这里只声明已有消费者是报告，不假称 UI 有入口。
        notes.append("[triage] " + FrameTriage.review(display).summary())
        return ExportOutcome(display: display, notes: notes)
    }

    // MARK: - 拼图

    enum CollageStage: Sendable {
        case composed(RGBA8Buffer, note: String)
        case failed(String)
    }

    /// 把主图与其余图源排到模板上。图不够 / 模板不存在 / 解码失败 →
    /// 一律不排版并点名，而不是拿纯色或重复图假装排好了。
    private static func composeCollage(main: RGBA8Buffer, canvas: PixelSize,
                                       composition: CollageComposition, document: ImageDocument,
                                       store: ModelStore, ort: ORTEngine) async -> CollageStage {
        guard let base = CollageEngine.template(id: composition.templateID) else {
            return .failed(CollageComposition.missingTemplateNote)
        }
        // 底色是这次导出的选择，不是模板自带的（模板是会话内常量）。
        var template = base
        template.background = CollageEngine.background(id: composition.backgroundID)
        let slots = template.slots.count
        if let warning = composition.shortfallWarning(slots: slots) {
            return .failed(warning)
        }

        // 输出画布：默认长边跟主图；指定了 longEdge 就按它缩。
        var canvasSize = canvas
        if composition.longEdge > 0, canvas.longEdge > composition.longEdge {
            let scale = Double(composition.longEdge) / Double(canvas.longEdge)
            canvasSize = PixelSize(width: max(1, Int(Double(canvas.width) * scale)),
                                   height: max(1, Int(Double(canvas.height) * scale)))
        }
        let config = BatchConfig(params: document.params, format: .jpeg,
                                 outputDirectory: FileManager.default.temporaryDirectory,
                                 groups: [.tone, .skin, .shape, .style, .background])

        var images: [RGBA8Buffer] = [main]
        var failed: [String] = []
        for url in composition.extraURLs.prefix(max(0, slots - 1)) {
            let name = url.lastPathComponent
            do {
                let loaded = try await ImageLoader.load(url: url, maxEdge: 0)
                var doc = ImageDocument(loaded: loaded, url: url)
                doc.params = config.effectiveParams
                let outcome = await ExportPipeline.render(doc, store: store, ort: ort, fullResolution: true)
                var bytes = outcome.display.rgba8()
                if !doc.overlays.isEmpty {
                    bytes = OverlayEngine.apply(bytes, elements: doc.overlays)
                }
                images.append(bytes)
            } catch {
                failed.append(name)
            }
        }
        guard failed.isEmpty else {
            return .failed("[collage_failed] \(failed.count) 张拼图源图读不了：\(failed.prefix(3).joined(separator: ", "))，本次未排版")
        }
        guard let laid = CollageEngine.compose(images: images, template: template, canvasSize: canvasSize) else {
            return .failed("[collage_failed] 排版失败（格子或图尺寸退化），本次未排版")
        }
        return .composed(laid,
                         note: "[collage] \(template.name) · \(canvasSize.width)×\(canvasSize.height) · \(images.count) 张")
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
            try ensureUncompressedFits(display, kind: "PNG-16")
            return try PNG16Writer.encode(display)
        case .tiff16:
            try ensureUncompressedFits(display, kind: "TIFF-16")
            return try TIFF16Writer.encode(display)
        case .png8, .jpeg, .heif:
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("imagecake-export-\(UUID().uuidString).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try ImageExporter.write(display, to: url, format: format, quality: quality)
            return try Data(contentsOf: url)
        }
    }

    private static func ensureUncompressedFits(_ display: DisplayImage, kind: String) throws {
        guard display.size.pixelCount <= maxPNG16Pixels else {
            throw ExportError.uncompressedTooLarge(kind: kind,
                                                   pixels: display.size.pixelCount,
                                                   limit: maxPNG16Pixels)
        }
    }
}
