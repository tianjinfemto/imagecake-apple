import CoreGraphics
import SwiftUI

// 编辑器的状态机。
//
// 一条硬规矩：**所有重计算都不在主线程**。调色 12MP 一次几百毫秒、
// LaMa 一窗 7 秒、超清一分钟——放在主线程上，症状不是"慢"而是
// "界面卡住且没有任何反馈"，用户会以为崩了。
//
// 另一条：AI 报告（note/path）原样保留并显示。`[no_model:xxx]` 与
// `[fallback:vision]` 是给人看的，不要在 UI 层改写成"操作失败"。

@MainActor
final class EditorModel: ObservableObject {
    enum Busy: Equatable {
        case opening(String)
        case matting
        case inpainting
        case exporting(String)
        case savingToPhotos
        case model(String)

        var title: String {
            switch self {
            case .opening(let name): return "正在打开 \(name)"
            case .matting: return "正在抠图"
            case .inpainting: return "正在消除选区"
            case .exporting(let name): return "正在导出 \(name)"
            case .savingToPhotos: return "正在写入相册"
            case .model(let name): return "正在处理 \(name)"
            }
        }

        var detail: String {
            switch self {
            case .opening: return "RAW 与超大图会比 JPEG 慢很多"
            case .matting: return "MODNet 约 0.5 秒；缺权重时回退 Vision"
            case .inpainting: return "LaMa 单窗约 7 秒（CPU），Core ML 会更快"
            case .exporting: return "全分辨率重算 + 面部重绘/超清可能是分钟级；请保持 App 在前台（iPadOS 会挂起后台任务）"
            case .savingToPhotos: return "字节直接交给照片库，不重新编码；首次会弹一次授权框"
            case .model: return "下载后会做字节数与 SHA-256 双重校验"
            }
        }
    }

    @Published private(set) var document: ImageDocument?
    @Published private(set) var preview: CGImage?
    @Published private(set) var maskOverlay: CGImage?
    @Published private(set) var busy: Busy?
    @Published var status: String = "就绪"
    @Published var alert: String?
    @Published var showMask = false {
        didSet { scheduleRender() }
    }
    @Published var selectionMode = false
    /// 画布上的框选（归一化，y 向下）。
    @Published var selection: CGRect?
    @Published var selectionEnabled = true
    /// 最近一次 AI 任务的路径与 note（面板直接显示）。
    @Published private(set) var lastAIPath = ""
    @Published private(set) var lastAINote = ""
    @Published private(set) var exportNotes: [String] = []
    /// 调色参数的撤销栈。只覆盖参数：AI 资产（α / 补丁）有自己的回退入口，
    /// 把它们也存进历史会让内存按图数乘以几十 MB。
    @Published private(set) var history = ParameterHistory()
    /// 模型文件变化时自增，逼模型面板重新读盘。
    @Published private(set) var modelRevision = 0

    let store: ModelStore
    private let ort = ORTEngine.shared
    private var renderTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var lastOpenURL: URL?

    init() {
        self.store = ModelStore(manifest: ModelStore.loadManifest())
    }

    var hasImage: Bool { document != nil }

    var params: EditParameters { document?.params ?? EditParameters() }

    var canvasSize: PixelSize { document?.canvasSize ?? .zero }

    var installedBytesLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(store.installedBytes), countStyle: .file)
    }

    // MARK: - 打开

    func open(url: URL) async {
        lastOpenURL = url
        busy = .opening(url.lastPathComponent)
        defer { busy = nil }
        do {
            // 预览档：长边 2048。12MP 的 float RGBA 是 192MB，2048 档是 48MB；
            // 修图时看的是构图与颜色，导出再走全量。
            let loaded = try await ImageLoader.load(url: url, maxEdge: 2048)
            var doc = ImageDocument(loaded: loaded, url: url)
            doc.params = EditParameters()
            document = doc
            // 换图：旧图的历史全部作废，防抖任务也要提掉（否则它会把新图
            // 的参数当作一次修改记进去）。
            historyTask?.cancel()
            historyTask = nil
            history.reset(to: doc.params)
            selection = nil
            selectionMode = false
            showMask = false
            lastAIPath = ""
            lastAINote = ""
            exportNotes = []
            await renderNow()
            let size = loaded.originalSize
            status = "\(size.width)×\(size.height)\(loaded.isRAW ? " · RAW" : "") · 预览档 \(doc.canvasSize.width)×\(doc.canvasSize.height)"
            if !loaded.note.isEmpty { exportNotes = [loaded.note] }
        } catch {
            alert = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reloadLast() async {
        guard let url = lastOpenURL else { return }
        await open(url: url)
    }

    // MARK: - 参数

    func updateParams(_ body: (inout EditParameters) -> Void) {
        guard var doc = document else { return }
        body(&doc.params)
        doc.params.clamp()
        document = doc
        scheduleRender()
        scheduleHistoryCommit()
    }

    // MARK: - 撤销 / 重做

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// 滑杆拖一下会产生几十次 updateParams。如果每次都入栈，一次拖动就占满
    /// 整个历史；所以停手 600ms 后才记一步。
    private func scheduleHistoryCommit() {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, let doc = self.document else { return }
            self.history.commit(doc.params)
        }
    }

    /// 原子操作（复位、载入预设）立即入栈，并把可能存在的防抖任务撤掉，
    /// 否则它会在 600ms 后用一个旧值盖掉刚记的那一步。
    private func commitHistoryNow() {
        historyTask?.cancel()
        historyTask = nil
        guard let doc = document else { return }
        history.commit(doc.params)
    }

    func undo() {
        historyTask?.cancel()
        historyTask = nil
        guard var doc = document, let restored = history.undo() else { return }
        doc.params = restored
        document = doc
        scheduleRender()
        status = "已撤销"
    }

    func redo() {
        historyTask?.cancel()
        historyTask = nil
        guard var doc = document, let restored = history.redo() else { return }
        doc.params = restored
        document = doc
        scheduleRender()
        status = "已重做"
    }

    func resetParams() {
        guard var doc = document else { return }
        doc.params = EditParameters()
        document = doc
        commitHistoryNow()
        scheduleRender()
        status = "调色已复位（AI 资产保留）"
    }

    // MARK: - 渲染

    func scheduleRender() {
        renderTask?.cancel()
        guard let snapshot = document else { return }
        let showMask = showMask
        renderTask = Task { [weak self] in
            // 80ms 合并：滑杆连续拖动时只渲染最后一帧。
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                let display = snapshot.render()
                let image = display.cgImage()
                var overlay: CGImage?
                if showMask, let mask = snapshot.personMask {
                    overlay = mask.resized(to: snapshot.canvasSize).cgImage()
                }
                return (image, overlay)
            }.value
            guard !Task.isCancelled else { return }
            self?.preview = result.0
            self?.maskOverlay = result.1
        }
    }

    func renderNow() async {
        guard let snapshot = document else { return }
        let showMask = showMask
        let result = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
            let display = snapshot.render()
            let image = display.cgImage()
            var overlay: CGImage?
            if showMask, let mask = snapshot.personMask {
                overlay = mask.resized(to: snapshot.canvasSize).cgImage()
            }
            return (image, overlay)
        }.value
        preview = result.0
        maskOverlay = result.1
    }

    // MARK: - AI：抠图

    func runMatting() async {
        guard let doc = document else { return }
        busy = .matting
        defer { busy = nil }
        let bytes = await Task.detached(priority: .userInitiated) {
            doc.render(applyMask: false).rgba8()
        }.value
        let result = await MattingTask.run(display: bytes, store: store, ort: ort)
        lastAIPath = result.path
        lastAINote = result.report.note
        guard let mask = result.mask else {
            alert = result.report.note
            return
        }
        mutateDocument { doc in
            doc.personMask = mask
            doc.maskReference = bytes.size
            // 抠完就开换底色（默认白），用户能立刻看到这件事生效了。
            if !doc.params.bgEnabled {
                doc.params.bgEnabled = true
                doc.params.bgR = 255
                doc.params.bgG = 255
                doc.params.bgB = 255
            }
        }
        await renderNow()
        status = "抠图完成 · path=\(result.path) · \(Int(result.report.elapsedMs))ms"
    }

    func clearMask() {
        guard var doc = document else { return }
        doc.personMask = nil
        doc.params.bgEnabled = false
        document = doc
        maskOverlay = nil
        scheduleRender()
        status = "已清除人像 α 与换底色设置"
    }

    // MARK: - AI：消除

    func runInpaint() async {
        guard let doc = document, let rect = selection.map({ PixelRect.fromNormalized($0, in: doc.canvasSize) }),
              !rect.isEmpty else {
            alert = "先在画布上拖一个框，把要去掉的东西圈住"
            return
        }
        busy = .inpainting
        defer { busy = nil }
        let bytes = await Task.detached(priority: .userInitiated) {
            doc.render(applyMask: false).rgba8()
        }.value
        let mask = Self.rectangleMask(size: bytes.size, rect: rect)
        let result = await InpaintTask.run(display: bytes, mask: mask, store: store, ort: ort)
        lastAIPath = result.patch == nil ? "none" : "lama"
        lastAINote = result.report.note
        guard let patch = result.patch else {
            alert = result.report.note
            return
        }
        mutateDocument { $0.patches.append(patch) }
        selection = nil
        selectionMode = false
        await renderNow()
        status = "消除完成 · 窗口 \(patch.rect.width)×\(patch.rect.height) · \(Int(result.report.elapsedMs))ms"
    }

    func undoLastPatch() {
        guard var doc = document, !doc.patches.isEmpty else { return }
        doc.patches.removeLast()
        document = doc
        scheduleRender()
        status = "已撤销最近一次消除"
    }

    func clearPatches() {
        guard var doc = document, !doc.patches.isEmpty else { return }
        doc.patches.removeAll()
        document = doc
        scheduleRender()
        status = "已清除全部消除补丁"
    }

    // MARK: - 导出

    func exportData(format: ExportFormat,
                    quality: Double,
                    maxEdge: Int,
                    fullResolution: Bool,
                    nameTemplate: String = ExportNaming.defaultTemplate) async -> (data: Data, filename: String)? {
        guard let doc = document else { return nil }
        busy = .exporting(format.title)
        defer { busy = nil }
        let outcome = await ExportPipeline.render(doc, store: store, ort: ort, fullResolution: fullResolution)
        exportNotes = outcome.notes
        do {
            // 16bit PNG 的容器编码是百毫秒到秒级的纯计算：留在主线程上
            // 会让“导出完成”那一刻整个界面定住。
            let data = try await Task.detached(priority: .userInitiated) {
                try ExportPipeline.encode(outcome, format: format, quality: quality, maxEdge: maxEdge)
            }.value
            let name = suggestedFilename(ext: format.fileExtension, template: nameTemplate)
            status = "导出完成 · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
            return (data, name)
        } catch {
            alert = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    #if os(iOS)
    /// 把已编码好的字节存进系统相册。
    ///
    /// 失败原因追加进 `exportNotes` 而不是弹 alert：导出报告本来就是
    /// 「哪一步没做成」的专用出口，相册失败与 `[patch_scaled]` 同类。
    /// 返回值只表示是否成功，由导出面板决定是关窗还是停在报告上。
    func saveToPhotos(_ data: Data) async -> Bool {
        busy = .savingToPhotos
        defer { busy = nil }
        do {
            try await PhotoLibraryWriter.save(data)
            status = "已存入相册 · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
            return true
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            exportNotes.append(text)
            status = "存入相册失败"
            return false
        }
    }
    #endif

    func suggestedFilename(ext: String, template: String = ExportNaming.defaultTemplate) -> String {
        let stem = document?.sourceURL?.deletingPathExtension().lastPathComponent ?? "imagecake"
        return ExportNaming.filename(template: template, stem: stem, ext: ext)
    }

    // MARK: - 预设

    func applyPreset(_ params: EditParameters, report: PresetLoadReport?, sourceName: String) {
        guard var doc = document else { return }
        doc.params = params
        document = doc
        commitHistoryNow()
        scheduleRender()
        var message = "已载入预设 \(sourceName)"
        if let report, !report.warning.isEmpty {
            message += " · \(report.warning)"
        }
        if let report, !report.unknownKeys.isEmpty {
            lastAINote = report.warning
        }
        status = message
    }

    func savePresetToDefault() {
        guard let doc = document, let dir = PresetStore.defaultDirectory() else { return }
        let name = "preset-\(Self.stamp()).json"
        let url = dir.appendingPathComponent(name)
        do {
            try PresetStore.save(doc.params, to: url)
            status = "预设已保存：\(url.lastPathComponent)（\(dir.path)）"
        } catch {
            alert = error.localizedDescription
        }
    }

    func presetData() -> Data? {
        guard let doc = document else { return nil }
        var params = doc.params
        params.presetVersion = EditParameters.presetVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(params)
    }

    // MARK: - 模型管理

    func modelState(_ descriptor: ModelDescriptor) -> ModelState {
        store.state(for: descriptor)
    }

    func download(_ descriptor: ModelDescriptor, mirror: Bool) async {
        busy = .model(descriptor.file)
        defer { busy = nil }
        do {
            _ = try await store.download(descriptor, useMirror: mirror)
            modelRevision += 1
            status = "\(descriptor.file) 下载并校验通过"
        } catch {
            alert = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func importWeight(_ descriptor: ModelDescriptor, from url: URL) async {
        busy = .model(descriptor.file)
        defer { busy = nil }
        let store = self.store
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try store.importWeight(from: url, descriptor: descriptor)
            }.value
            modelRevision += 1
            status = "\(descriptor.file) 已导入并校验通过"
        } catch {
            alert = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func verify(_ descriptor: ModelDescriptor) async {
        busy = .model(descriptor.file)
        defer { busy = nil }
        let store = self.store
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.verify(descriptor)
            }.value
            modelRevision += 1
            status = "\(descriptor.file) SHA-256 校验通过"
        } catch {
            alert = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func remove(_ descriptor: ModelDescriptor) {
        do {
            try store.remove(descriptor)
            modelRevision += 1
            status = "已删除 \(descriptor.file)"
        } catch {
            alert = error.localizedDescription
        }
    }

    func unloadSessions() async {
        await ort.unload()
        status = "已释放 ORT 会话（下次推理会重新建图）"
    }

    // MARK: - 内部

    private func mutateDocument(_ body: (inout ImageDocument) -> Void) {
        guard var doc = document else { return }
        body(&doc)
        document = doc
    }

    private static func rectangleMask(size: PixelSize, rect: PixelRect) -> MaskBuffer {
        var bytes = [UInt8](repeating: 0, count: max(0, size.pixelCount))
        let r = rect.intersected(with: PixelRect(x: 0, y: 0, width: size.width, height: size.height))
        guard !r.isEmpty else { return MaskBuffer(size: size, data: Data(bytes)) }
        for y in r.y ..< r.maxY {
            let row = y * size.width
            for x in r.x ..< r.maxX {
                bytes[row + x] = 255
            }
        }
        return MaskBuffer(size: size, data: Data(bytes))
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
