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
        case landmarks
        case bodyPose
        case faceAttr
        case assembling
        case hands
        case sky
        case stacking
        case tethering

        var title: String {
            switch self {
            case .opening(let name): return "正在打开 \(name)"
            case .matting: return "正在抠图"
            case .inpainting: return "正在消除选区"
            case .exporting(let name): return "正在导出 \(name)"
            case .savingToPhotos: return "正在写入相册"
            case .model(let name): return "正在处理 \(name)"
            case .landmarks: return "正在检测关键点"
            case .bodyPose: return "正在检测身形"
            case .faceAttr: return "正在识别属性"
            case .assembling: return "正在拼图排版"
            case .hands: return "正在检测手部"
            case .sky: return "正在找天空"
            case .stacking: return "正在堆栈多帧"
            case .tethering: return "正在等相机回片"
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
            case .landmarks: return "478 点关键点，每张脸约 0.2 秒"
            case .bodyPose: return "RTMPose 17 点，需先抠图获取人像区域"
            case .faceAttr: return "年龄 + 性别分类，每张脸跑两颗网络"
            case .assembling: return "每张图源都走一遍全分辨率重渲染（不跑重绘/超清），4 格可能是十几秒"
            case .hands: return "Vision 手部姿态：零权重、双端自带，每张手约 0.1 秒"
            case .sky: return "从画面顶边做连通生长：不连到顶边的蓝色（裙子、水洼）不会被当成天"
            case .stacking: return "需要同一机位的 2 张以上连拍；先做整数平移对齐，再按模式堆叠"
            case .tethering: return "相机 10 秒不回片会报错而不是一直转圈"
            }
        }
    }

    @Published private(set) var document: ImageDocument?
    @Published private(set) var preview: CGImage?
    @Published private(set) var maskOverlay: CGImage?
    @Published private(set) var clippingOverlay: CGImage?
    /// 当前预览的直方图与溢出统计（调色面板的直方图卡片读这里）。
    @Published private(set) var histogram: Histogram = .empty
    @Published private(set) var busy: Busy?
    @Published var status: String = "就绪"
    @Published var alert: String?
    @Published var showMask = false {
        didSet { scheduleRender() }
    }
    /// 溢出高亮叠层（画布上的红/蓝斑）。只影响预览叠层，不改像素、不进导出。
    @Published var showClipping = false {
        didSet { scheduleRender() }
    }
    @Published var selectionMode = false
    /// 画布上的框选（归一化，y 向下）。
    @Published var selection: CGRect?
    @Published var selectionEnabled = true
    /// 当前笔刷工具。.none 时画布单指拖走框选；否则走笔刷落笔。
    @Published var brushTool: BrushTool = .none {
        didSet {
            // 换工具时清掉图章取样点与取样模式：不同工具的取样语义不同，
            // 留着旧锚点会让用户以为「换回来还能接着画」而画到错位置。
            if brushTool != .cloneStamp {
                cloneSource = nil
                clonePickingMode = false
            }
        }
    }
    /// 笔刷半径（归一化，相对长边）。与 BrushStroke.radius 同口径。
    @Published var brushRadius: Double = 0.04
    /// 笔刷强度 0...1，液化与图章共用。
    @Published var brushStrength: Double = 0.8
    /// 笔刷硬度 0...1，透传给栅格化。
    @Published var brushHardness: Double = 0.6
    /// 仿制图章的取样锚点（归一化）。nil = 尚未取样。
    @Published private(set) var cloneSource: CGPoint?
    /// 取样模式：开了之后下一次点画布设 cloneSource，设完自动关。
    @Published var clonePickingMode = false
    /// 最近一次 AI 任务的路径与 note（面板直接显示）。
    @Published private(set) var lastAIPath = ""
    @Published private(set) var lastAINote = ""
    /// 画笔蒙版刚采到的那一段选区（尚未绑定参数集）。
    @Published private(set) var pendingLocalStroke: BrushStroke?
    @Published private(set) var exportNotes: [String] = []
    @Published private(set) var faceLandmarksResult: FaceLandmarksResult?
    @Published private(set) var bodyPoseResult: BodyPoseResult?
    @Published private(set) var faceAttrResult: FaceAttrResult?
    /// 批量队列的上一次报告（面板直接显示）。
    @Published private(set) var batchReport: BatchReport?
    /// 编辑历史的撤销栈。一格是 `EditSnapshot`（调色参数 + 笔迹）：
    /// 「回到上一步」必须同时回到两边的状态，否则同一步操作先弹哪边
    /// 没人猜得到。AI 资产（α / 补丁）不进历史，它们有自己的回退入口。
    @Published private(set) var history = ParameterHistory<EditSnapshot>(initial: EditSnapshot())
    /// 模型文件变化时自增，逼模型面板重新读盘。
    @Published private(set) var modelRevision = 0

    // MARK: - 素材库（项目视图）

    /// 当前项目目录（nil = 没开项目）。会话级：沙箱不保留目录授权，
    /// 下次进来要重新选目录，但 sidecar 里的参数仍然接得上。
    @Published private(set) var libraryFolder: URL?
    @Published private(set) var libraryItems: [LibraryItem] = []
    @Published var libraryFilter: LibraryFilter = .all {
        didSet { objectWillChange.send() }
    }
    /// 最近一次 sidecar 读写结果（面板原样显示，不写"保存成功"这种废话）。
    @Published private(set) var libraryNote = ""

    // MARK: - 联机拍摄

    /// 系统列出的视频设备（含外接相机/采集卡）。
    @Published private(set) var tetherDevices: [TetheredDevice] = []
    @Published var tetherDeviceID: String? = nil
    @Published var tetherSettings = TetherSettings()
    /// 联机作业的报告与点名（面板与底栏共用，不弹完即烧）。
    @Published private(set) var tetherNote = ""
    @Published private(set) var tetherConnected = false
    /// 最近一张回片（面板上看得见的"拍到了"证据，也是进度反馈）。
    @Published private(set) var tetherLastShot: CGImage?
    private let capture = TetherCapture()

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

    /// “开了开关但缺资产”的清单（底栏与面板原样显示）。
    var pipelineNotes: [String] { document?.pipelineWarnings ?? [] }

    /// 当前可用的内置风格 + 已导入的 .cube。
    var availableFilters: [String] {
        FilterEngine.styles.map(\.id) + LUTLibrary.importedNames()
    }

    var installedBytesLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(store.installedBytes), countStyle: .file)
    }

    /// "当前素材"= 库里 URL 与文档源图一致的那一条。
    var currentItem: LibraryItem? {
        guard let source = document?.sourceURL else { return nil }
        return libraryItems.first { $0.url == source }
    }

    /// 按当前筛选条件列出的素材。
    var visibleLibraryItems: [LibraryItem] { ImageLibrary.filter(libraryItems, by: libraryFilter) }

    var libraryCounts: [LibraryStatus: Int] { ImageLibrary.counts(libraryItems) }

    /// 打开一个目录作为项目。只扫一层；sidecar 里的状态会接回来。
    func openLibrary(folder: URL) {
        let scoped = folder.startAccessingSecurityScopedResource()
        libraryFolder = folder
        let scanned = ImageLibrary.scan(folder: folder)
        // 状态从 sidecar 接：有文件就按文件里的（已出片 > 已修），没文件就是未修。
        libraryItems = scanned.map { item in
            var existing = item
            if let file = ProjectStore.load(from: item) {
                existing.status = file.status
            }
            return existing
        }
        let restored = libraryItems.filter { $0.status != .unedited }.count
        let collisions = libraryItems.filter { $0.sidecarName == nil }.count
        libraryNote = "\(libraryItems.count) 张素材，\(restored) 张已有工程数据"
            + (collisions > 0 ? " · [sidecar_conflict] \(collisions) 张图名重名，参数不入库" : "")
            + (scoped ? "" : " · [no_scope] 本次没有目录权限，sidecar 写不进去")
    }

    func closeLibrary() {
        libraryFolder = nil
        libraryItems = []
        libraryNote = ""
    }

    /// 把当前图的参数存进它旁边的 sidecar（续作的最小闭环）。
    @discardableResult
    func saveCurrentProgress(status: LibraryStatus? = nil) -> Bool {
        guard let doc = document else { return false }
        let item = currentItem ?? LibraryItem(url: doc.sourceURL ?? URL(fileURLWithPath: "/"))
        let derived = status ?? ImageLibrary.derive(document: doc)
        guard item.sidecarName != nil else {
            libraryNote = "[sidecar_conflict] \(item.fileName) 的图名与其兄弟文件重名，参数不入库"
            return false
        }
        if ProjectStore.save(params: doc.params, status: derived, to: item) != nil {
            if let index = libraryItems.firstIndex(where: { $0.url == item.url }) {
                libraryItems[index].status = derived
            }
            libraryNote = "已写入 \(ImageLibrary.sidecarName(for: item.url))（\(derived.title)）"
            return true
        }
        libraryNote = "[sidecar_failed] 写不进去：多半是没有目录权限或磁盘满"
        return false
    }

    /// 出片后把当前条目标成"已出片"（导出成功时自动调）。
    func markCurrentExported() {
        saveCurrentProgress(status: .exported)
    }

    /// 按派生状态刷新当前条目（改参数时调）：已出片不会被退回"已修"。
    private func syncCurrentItemStatus() {
        guard let doc = document, let index = libraryItems.firstIndex(where: { $0.url == doc.sourceURL }) else { return }
        let derived = ImageLibrary.derive(document: doc)
        if libraryItems[index].status == .exported, derived == .unedited { return }
        if libraryItems[index].status != derived {
            libraryItems[index].status = derived
        }
    }

    /// 跳到下一张未修的片子（批量修图时的一键"下一张"）。
    func openNextUnedited() {
        let queue = libraryItems.filter { $0.status == .unedited }
        guard !queue.isEmpty else {
            libraryNote = "库里已经没有未修的图了（共 \(libraryItems.count) 张）"
            return
        }
        Task { await open(url: queue[0].url) }
    }

    /// 刷新设备列表。授权被拒与真的没设备是两件事，分开点名。
    func refreshTetherDevices() async {
        busy = .tethering
        defer { busy = nil }
        guard await TetherCapture.requestAccess() else {
            tetherDevices = []
            tetherNote = TetherCapture.CaptureError.denied.errorDescription ?? "[no_camera]"
            return
        }
        let found = await Task.detached(priority: .userInitiated) { TetherCapture.discover() }.value
        tetherDevices = found
        if tetherDevices.isEmpty {
            tetherNote = TetherPlan.missingNote(devices: found)
        } else {
            let usable = tetherDevices.filter(\.isUsable).count
            tetherNote = "\(tetherDevices.count) 台设备，可用 \(usable) 台"
                + (usable == 0 ? " · \(TetherPlan.missingNote(devices: tetherDevices))" : "")
        }
        // 没选过设备就自动拿首选那台（排序是稳定的，不会每次换一个）。
        if tetherDeviceID == nil || tetherDevices.first(where: { $0.id == tetherDeviceID }) == nil {
            tetherDeviceID = TetherPlan.pickDevice(from: tetherDevices, preferred: tetherDeviceID)?.0.id
        }
    }

    /// 接上选中的设备（跑 session）。startRunning 是阻塞调用，所以丢后台。
    func connectTether() async {
        guard let id = tetherDeviceID, let device = tetherDevices.first(where: { $0.id == id }) else {
            tetherNote = "[no_camera] 先选一台设备"
            return
        }
        busy = .tethering
        defer { busy = nil }
        let capture = self.capture
        do {
            try await Task.detached(priority: .userInitiated) { try capture.configure(deviceID: id) }.value
            tetherConnected = true
            tetherNote = "已接上：\(device.title)"
        } catch {
            tetherConnected = false
            tetherNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func disconnectTether() {
        capture.stop()
        tetherConnected = false
        tetherNote = "已断开相机"
    }

    /// 拍一或 N 张（连拍走 `TetherPlan.queue`）。每张落盘后更新缩略图，
    /// 第一拍（且开了"拍完进编辑"）直接进编辑器。
    func shootTetherBurst(to directory: URL?) async {
        guard tetherConnected else { await connectTether(); guard tetherConnected else { return } }
        busy = .tethering
        defer { busy = nil }
        let settings = tetherSettings
        let plan = TetherPlan.queue(settings: settings)
        var notes = plan.notes
        var saved: [URL] = []
        var failures: [String] = []
        let capture = self.capture
        for shot in plan.shots {
            if shot.waitSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(shot.waitSeconds * 1_000_000_000))
            }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try capture.capture() }.value
                let stamp = Self.tetherStamp()
                if let directory {
                    let url = directory.appendingPathComponent(
                        TetherPlan.fileName(sequence: shot.sequence, stamp: stamp, ext: "jpg"))
                    do {
                        try data.write(to: url, options: .atomic)
                        saved.append(url)
                    } catch {
                        failures.append("写不进 \(url.lastPathComponent)")
                    }
                }
                // 回片缩略图：主线程不解图，512 档也是几毫秒的 ImageIO 工作。
                let shot = await Task.detached(priority: .userInitiated) {
                    ImageLoader.thumbnail(from: data, maxEdge: 512)
                }.value
                tetherLastShot = shot
                if settings.openInEditor, let url = saved.last {
                    await open(url: url)
                }
            } catch {
                failures.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                break      // 相机不回片时不要接着把剩下的 N 张都卡完
            }
        }
        if saved.isEmpty, failures.isEmpty { failures.append("没指定落盘目录，也没拍成任何一张") }
        tetherNote = "拍了 \(saved.count)/\(plan.shots.count) 张" + (failures.isEmpty ? "" : " · \(failures.prefix(2).joined(separator: "；"))")
        notes.forEach { tetherNote += " · \($0)" }
    }

    /// 时戳到秒。同一秒内的两张靠序号后缀区分（见 `TetherPlan.fileName`）。
    private static func tetherStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
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
            // 素材库里有这张图的 sidecar → 参数接回来。失败不影响打开：
            // 打不开图比参数没恢复严重。
            var restoredStatus: LibraryStatus = .unedited
            if let item = libraryItems.first(where: { $0.url == url }),
               let file = ProjectStore.load(from: item) {
                doc.params = file.params
                restoredStatus = file.status
            }
            document = doc
            // 换图：旧图的历史全部作废，防抖任务也要提掉（否则它会把新图
            // 的参数当作一次修改记进去）。
            historyTask?.cancel()
            historyTask = nil
            history.reset(to: EditSnapshot(doc))
            selection = nil
            selectionMode = false
            showMask = false
            showClipping = false
            clippingOverlay = nil
            histogram = .empty
            lastAIPath = ""
            lastAINote = ""
            exportNotes = []
            await renderNow()
            syncCurrentItemStatus()
            let size = loaded.originalSize
            status = "\(size.width)×\(size.height)\(loaded.isRAW ? " · RAW" : "") · 预览档 \(doc.canvasSize.width)×\(doc.canvasSize.height)"
                + (restoredStatus == .unedited ? "" : " · 已从 sidecar 接回参数（\(restoredStatus.title)）")
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
        syncCurrentItemStatus()
        scheduleRender()
        scheduleHistoryCommit()
    }

    // MARK: - 笔刷（液化 / 仿制图章 / 保护）
    //
    // 笔刷的入口在这里而不只在文档里，是为了让"一笔 = 一步历史"这件事
    // 有一个确定的地方发生。滑杆需要 600ms 防抖是因为拖一下产生几十次
    // 修改；一笔就是一笔，所以立即入栈，不防抖。
    // 坐标全部归一化：手指/Apple Pencil 的位置由 CanvasView 换算后交给这里。

    func addLiquifyStroke(_ stroke: LiquifyStroke) {
        mutateDocument { $0.brush.liquify.append(stroke) }
        commitHistoryNow()
        scheduleRender()
        status = "液化 \(document?.brush.liquify.count ?? 0) 笔"
    }

    func addCloneStamp(_ stamp: CloneStamp) {
        mutateDocument { $0.brush.stamps.append(stamp) }
        commitHistoryNow()
        scheduleRender()
        status = "图章 \(document?.brush.stamps.count ?? 0) 笔"
    }

    /// 涂一笔保护。半径落在 BrushStroke 自己的字段里，所以这里不再传。
    func addProtectionStroke(_ stroke: BrushStroke) {
        mutateDocument { $0.brush.protection.append(stroke) }
        commitHistoryNow()
        scheduleRender()
        status = "保护 \(document?.brush.protection.count ?? 0) 笔"
    }

    /// 清掉某一类笔迹。不是撤销：撤销只退一步，而"把液化全擦了但保留图章"
    /// 是独立意图，而且它能被断言（撤销栈那侧只保证入栈/出栈）。
    func clearBrush(_ kind: BrushKind) {
        guard var doc = document else { return }
        switch kind {
        case .liquify: doc.brush.liquify = []
        case .stamps: doc.brush.stamps = []
        case .protection: doc.brush.protection = []
        case .garments: doc.brush.garments = []
        case .all: doc.brush = BrushState()
        }
        document = doc
        commitHistoryNow()
        scheduleRender()
        status = "已清除\(kind.title)"
    }

    enum BrushKind: CaseIterable {
        case liquify, stamps, protection, garments, all
        var title: String {
            switch self {
            case .liquify: return "液化笔迹"
            case .stamps: return "图章笔迹"
            case .protection: return "保护笔刷"
            case .garments: return "衣物区"
            case .all: return "全部笔刷"
            }
        }
    }

    /// 画布上的当前工具。.none 时单指拖走框选（智能消除用），
    /// 其余几个走各自的笔刷落笔。
    enum BrushTool: CaseIterable {
        case none, liquify, cloneStamp, protection, localMask, garment
        var title: String {
            switch self {
            case .none: return "无"
            case .liquify: return "液化"
            case .cloneStamp: return "图章"
            case .protection: return "保护"
            case .localMask: return "选区"
            case .garment: return "衣物"
            }
        }
        var icon: String {
            switch self {
            case .none: return "hand.point.up.left"
            case .liquify: return "arrow.left.and.right"
            case .cloneStamp: return "stamp"
            case .protection: return "shield"
            case .localMask: return "circle.dashed"
            case .garment: return "tshirt"
            }
        }
    }

    // MARK: - 仿制图章取样

    /// 在画布上设取样锚点（归一化坐标）。由 CanvasView 在取样模式下调用。
    func setCloneSource(_ point: CGPoint) {
        cloneSource = point
        clonePickingMode = false
        status = "图章取样点已设：(\(String(format: "%.3f", point.x)), \(String(format: "%.3f", point.y)))"
    }

    func clearCloneSource() {
        cloneSource = nil
        clonePickingMode = false
    }

    // MARK: - 撤销 / 重做

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// 滑杆拖一下会产生几十次 updateParams。如果每次都入栈，一次拖动就占满
    /// 整个历史；所以停手 600ms 后才记一步。快照在防抖到期时取，记住的是
    /// 「停手那一刻的全部状态」——中间插入的笔刷（已立即入栈）会让两边
    /// 相等，空操作不入栈，不会多占一格。
    private func scheduleHistoryCommit() {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, let doc = self.document else { return }
            self.history.commit(EditSnapshot(doc))
        }
    }

    /// 原子操作（一笔笔刷、复位、载入预设）立即入栈，并把可能存在的防抖任务撤掉，
    /// 否则它会在 600ms 后用一个旧值盖掉刚记的那一步。
    private func commitHistoryNow() {
        historyTask?.cancel()
        historyTask = nil
        guard let doc = document else { return }
        history.commit(EditSnapshot(doc))
    }

    func undo() {
        historyTask?.cancel()
        historyTask = nil
        guard var doc = document, let restored = history.undo() else { return }
        doc.params = restored.params
        doc.brush = restored.brush
        document = doc
        scheduleRender()
        status = "已撤销"
    }

    func redo() {
        historyTask?.cancel()
        historyTask = nil
        guard var doc = document, let restored = history.redo() else { return }
        doc.params = restored.params
        doc.brush = restored.brush
        document = doc
        scheduleRender()
        status = "已重做"
    }

    func resetParams() {
        guard var doc = document else { return }
        doc.params = EditParameters()
        document = doc
        // 只复位调色：笔刷不跟着清。“擦了笔刷”与“回到中性参数”是两件事，
        // 前者在 clearBrush(.all)。栈里的一格是快照整体，所以先把栈顶的
        // params 换掉再入栈，不把「复位」与下一步笔刷并成一步。
        history.amendPresent { $0.params = EditParameters() }
        history.commit(EditSnapshot(doc))
        scheduleRender()
        status = "调色已复位（笔刷与 AI 资产保留）"
    }

    /// 只把人像那一组归零（调色与笔刷不动）。“重置调色”与“把人像效果关掉”
    /// 在修图里是两个动作，合并成一个的话总有一边会被误清。
    func resetBeauty() {
        guard var doc = document else { return }
        doc.params.beauty = BeautyParameters()
        document = doc
        commitHistoryNow()
        scheduleRender()
        status = "人像参数已归零（调色、笔刷与 AI 资产保留）"
    }

    // MARK: - 渲染

    /// 高光溢出警告的阈值：预览里 0.5% 的像素死了就值得说一句。
    /// 不拿 0 当阈值——一张有太阳的照片本来就该有几个 255。
    static let clippingWarnRatio = 0.005

    /// 当前该不该报"高光溢出"（底栏徽章与直方图卡片共用同一个判定）。
    var clippingWarning: String? {
        guard histogram.sampleCount > 0 else { return nil }
        let ratio = histogram.clippedHighlightRatio
        guard ratio >= EditorModel.clippingWarnRatio else { return nil }
        return String(format: "[clipping] 高光溢出 %.1f%%", ratio * 100)
    }

    func scheduleRender() {
        renderTask?.cancel()
        guard let snapshot = document else { return }
        let showMask = showMask
        let showClipping = showClipping
        renderTask = Task { [weak self] in
            // 80ms 合并：滑杆连续拖动时只渲染最后一帧。
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                PreviewRender.produce(snapshot, showMask: showMask, showClipping: showClipping)
            }.value
            guard !Task.isCancelled else { return }
            self?.preview = result.image
            self?.maskOverlay = result.mask
            self?.clippingOverlay = result.clipping
            self?.histogram = result.histogram
        }
    }

    func renderNow() async {
        guard let snapshot = document else { return }
        let showMask = showMask
        let showClipping = showClipping
        let result = await Task.detached(priority: .userInitiated) {
            PreviewRender.produce(snapshot, showMask: showMask, showClipping: showClipping)
        }.value
        preview = result.image
        maskOverlay = result.mask
        clippingOverlay = result.clipping
        histogram = result.histogram
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
        lastAIPath = result.patches.isEmpty ? "none" : "lama"
        lastAINote = result.report.note
        guard !result.patches.isEmpty else {
            alert = result.report.note
            return
        }
        mutateDocument { $0.patches.append(contentsOf: result.patches) }
        selection = nil
        selectionMode = false
        await renderNow()
        let firstRect = result.patches[0].rect
        status = "消除完成 · \(result.patches.count) 窗 · \(firstRect.width)×\(firstRect.height) · \(Int(result.report.elapsedMs))ms"
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

    // MARK: - AI：关键点 / 身形 / 属性

    func runLandmarks() async {
        guard let doc = document else { return }
        busy = .landmarks
        defer { busy = nil }
        let bytes = await Task.detached(priority: .userInitiated) {
            doc.render(applyMask: false).rgba8()
        }.value
        let result = await FaceLandmarksTask.run(display: bytes, store: store, ort: ort)
        faceLandmarksResult = result
        lastAINote = result.report.note
        syncFaceGeometry(from: result, canvas: bytes.size)
        if !result.report.ok { alert = result.report.note }
        status = result.report.ok ? "关键点：\(result.landmarks.count) 张脸 · \(Int(result.report.elapsedMs))ms" : result.report.note
    }

    /// 把"一堆点"汇成"每张脸上的语义量"，存到文档里供预览与导出共用。
    ///
    /// 逐张都派生，按面积从大到小排（合影里每张脸都会被磨皮/推形变）；
    /// 数量凑不齐 478 点的那张直接丢弃而不是拿错的索引去推脸——宁缺、错位
    /// 看不出来。一张也没有时置空，调用侧的 `[no_landmarks]` 才点得准。
    private func syncFaceGeometry(from result: FaceLandmarksResult, canvas: PixelSize) {
        guard canvas.width > 0, canvas.height > 0 else { return }
        func area(_ face: FaceLandmarks) -> Int { max(0, face.faceBox.width) * max(0, face.faceBox.height) }
        let derived: [FaceGeometry] = result.landmarks
            .filter { $0.points.count >= FaceGeometry.Index.requiredCount }
            .sorted { area($0) > area($1) }
            .compactMap { face in
                let normalized = face.points.map {
                    CGPoint(x: $0.x / CGFloat(canvas.width), y: $0.y / CGFloat(canvas.height))
                }
                return FaceGeometry.from(points: normalized)
            }
        mutateDocument { $0.faceGeometries = derived }
    }

    func runBodyPose() async {
        guard let doc = document else { return }
        busy = .bodyPose
        defer { busy = nil }
        let bytes = await Task.detached(priority: .userInitiated) {
            doc.render(applyMask: false).rgba8()
        }.value
        let result = await BodyPoseTask.run(display: bytes, personMask: doc.personMask, store: store, ort: ort)
        bodyPoseResult = result
        lastAINote = result.report.note
        if result.joints.count >= 17, bytes.size.width > 0, bytes.size.height > 0 {
            let normalized = result.joints.map {
                CGPoint(x: $0.position.x / CGFloat(bytes.size.width), y: $0.position.y / CGFloat(bytes.size.height))
            }
            mutateDocument { $0.bodyAnchors = BodyAnchors.from(joints: normalized) }
        } else {
            mutateDocument { $0.bodyAnchors = nil }
        }
        if !result.report.ok { alert = result.report.note }
        status = result.report.ok ? "身形：\(result.joints.count) 点 · \(Int(result.report.elapsedMs))ms" : result.report.note
    }

    func runFaceAttr() async {
        guard let doc = document else { return }
        busy = .faceAttr
        defer { busy = nil }
        let bytes = await Task.detached(priority: .userInitiated) {
            doc.render(applyMask: false).rgba8()
        }.value
        let result = await FaceAttrTask.run(display: bytes, store: store, ort: ort)
        faceAttrResult = result
        lastAINote = result.report.note
        if !result.report.ok { alert = result.report.note }
        status = result.report.ok ? "属性：\(result.attrs.count) 张脸 · \(Int(result.report.elapsedMs))ms" : result.report.note
    }

    // MARK: - 几何变换

    func rotate90(clockwise: Bool) {
        mutateDocument { doc in
            doc.geometry.rotation += clockwise ? 90 : -90
        }
        scheduleRender()
        status = "旋转 \(clockwise ? "右" : "左") 90°"
    }

    func flip(horizontal: Bool) {
        mutateDocument { doc in
            if horizontal { doc.geometry.flipHorizontal.toggle() }
            else { doc.geometry.flipVertical.toggle() }
        }
        scheduleRender()
        status = horizontal ? "水平翻转" : "垂直翻转"
    }

    func crop(to normalizedRect: CGRect) {
        mutateDocument { doc in
            doc.geometry.cropRect = normalizedRect
        }
        scheduleRender()
        status = "裁剪已设"
    }

    func resetGeometry() {
        mutateDocument { doc in
            doc.geometry = .identity
        }
        scheduleRender()
        status = "几何已复位"
    }

    // MARK: - 智能构图

    func suggestSmartCrop() async {
        guard let doc = document else { return }
        let bytes = await Task.detached(priority: .userInitiated) {
            doc.render(applyMask: false).rgba8()
        }.value
        let landmarks = faceLandmarksResult?.landmarks ?? []
        if landmarks.isEmpty {
            let result = await FaceLandmarksTask.run(display: bytes, store: store, ort: ort)
            faceLandmarksResult = result
            if let suggestion = SmartCropEngine.suggest(imageSize: bytes.size, landmarks: result.landmarks, personMask: doc.personMask) {
                crop(to: suggestion.cropRect)
                status = "智能构图：\(suggestion.reason)"
            } else {
                status = "无法建议构图：未检测到主体"
            }
        } else {
            if let suggestion = SmartCropEngine.suggest(imageSize: bytes.size, landmarks: landmarks, personMask: doc.personMask) {
                crop(to: suggestion.cropRect)
                status = "智能构图：\(suggestion.reason)"
            }
        }
    }

    // MARK: - 老照片修复

    func toggleOldPhoto() {
        mutateDocument { doc in
            doc.oldPhotoRestore.toggle()
        }
        scheduleRender()
        status = document?.oldPhotoRestore == true ? "老照片修复已开" : "老照片修复已关"
    }

    // MARK: - 修补工具

    func addPatchStroke(_ stroke: PatchStroke) {
        mutateDocument { $0.patchStrokes.append(stroke) }
        commitHistoryNow()
        scheduleRender()
        status = "修补 \(document?.patchStrokes.count ?? 0) 笔"
    }

    func clearPatchStrokes() {
        mutateDocument { $0.patchStrokes = [] }
        commitHistoryNow()
        scheduleRender()
        status = "已清除修补笔迹"
    }

    // MARK: - 滤镜 / LUT

    /// 选风格（内置 id 或导入的 .cube 名）。空串 = 关。
    ///
    /// `requires` 只登记**外部资产**：内置风格不登记（换设备也算得出来），
    /// 导入的表登记成 `lut:<名字>`，因为那份字节不在预设里。
    func setFilterStyle(_ style: String) {
        mutateDocument { doc in
            doc.params.filter.style = style
            var deps = doc.params.requires.filter { !$0.hasPrefix("lut:") }
            if !style.isEmpty, FilterEngine.style(id: style) == nil {
                deps.append("lut:\(style)")
            }
            doc.params.requires = deps
        }
        commitHistoryNow()
        scheduleRender()
        status = style.isEmpty ? "已清除滤镜" : "滤镜：\(style)"
    }

    func setFilterStrength(_ value: Double) {
        updateParams { $0.filter.strength = value }
    }

    /// 导入一份 .cube。坏表把令牌带进 alert（[bad_lut] 期望 N 项，读到 M 项…）。
    func importLUT(from url: URL) {
        busy = .model(url.lastPathComponent)
        defer { busy = nil }
        do {
            let installed = try LUTLibrary.install(from: url)
            setFilterStyle(installed.name)
            status = "已导入滤镜表 \(installed.name)（\(installed.lut.size)³）"
        } catch {
            alert = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - 证件照

    /// 按规格定构图（设裁剪框 + 推荐底色）。排版是下一步。
    ///
    /// 没检测到人脸时按画面中心构图并在状态里点名 `[no_face_box]`：
    /// 宁可得出一张构图不完美的证件照，也不假装知道头在哪。
    func applyIDPhoto(specID: String) {
        guard let doc = document, let spec = IDPhoto.spec(id: specID) else { return }
        var head: PixelRect? = nil
        if let bounds = doc.faceGeometry?.bounds, bounds.width > 0, bounds.height > 0 {
            let rect = PixelRect.fromNormalized(bounds, in: doc.canvasSize)
            // 关键点给的是脸（额头到下巴），证件照量的是**头**（发际顶到下巴），
            // 所以往上让开四分之一头高，不然额头会顶到上边。
            let hair = max(1, rect.height / 4)
            head = PixelRect(x: rect.x, y: max(0, rect.y - hair), width: rect.width, height: rect.height + hair)
        }
        let rect = IDPhoto.suggestedCrop(canvas: doc.canvasSize, spec: spec, headBox: head)
        mutateDocument { item in
            item.geometry.cropRect = rect
            if let bg = spec.background, item.personMask != nil {
                item.params.bgEnabled = true
                item.params.bgR = Double(bg.r); item.params.bgG = Double(bg.g); item.params.bgB = Double(bg.b)
            }
            item.idPhotoSheet = nil
        }
        commitHistoryNow()
        scheduleRender()
        status = head == nil
            ? "证件照 \(spec.title)：[no_face_box] 未检测到人脸，按画面中心构图"
            : "证件照 \(spec.title)：已按头部构图（\(spec.pixelSize.width)×\(spec.pixelSize.height)px @\(spec.dpi)dpi）"
    }

    /// 把当前图排到相纸上（导出时生效）。
    func composeIDPhotoSheet(specID: String, paperID: String) {
        guard let spec = IDPhoto.spec(id: specID), let paper = IDPhoto.paper(id: paperID) else { return }
        let sheet = IDPhoto.sheet(spec: spec, paper: paper)
        mutateDocument { $0.idPhotoSheet = sheet.count > 0 ? sheet : nil }
        scheduleRender()
        status = sheet.count > 0
            ? "已排版：\(paper.title) 上 \(sheet.count) 张 \(spec.title)"
            : "[id_photo_empty] \(paper.title) 排不下 \(spec.title)，需要换相纸或改边距"
    }

    func clearIDPhotoSheet() {
        mutateDocument { $0.idPhotoSheet = nil }
        status = "已取消证件照排版"
    }

    // MARK: - 拼图

    /// 套上拼图模板（只影响导出，预览仍是单张）。
    func setCollage(templateID: UUID, backgroundID: String, extraURLs: [URL], allowMainRepeat: Bool) {
        mutateDocument { doc in
            doc.collage = CollageComposition(templateID: templateID, backgroundID: backgroundID,
                                             extraURLs: extraURLs, allowMainRepeat: allowMainRepeat)
        }
        scheduleRender()
        let slots = CollageEngine.template(id: templateID)?.slots.count ?? 0
        status = collageWarning == nil
            ? "拼图：\(slots) 格已就绪（导出时排版）"
            : "拼图：\(collageWarning ?? "")"
    }

    func clearCollage() {
        mutateDocument { $0.collage = nil }
        scheduleRender()
        status = "已取消拼图排版"
    }

    /// 拼图当前的"拿不到结果"原因（nil = 就绪）。底栏与面板共用一份判定。
    var collageWarning: String? { document?.pipelineWarnings.first { $0.contains("[collage") } }

    /// 把主图（当前文档全链输出）与其余图源排到一张画布上直接写文件。
    ///
    /// 不走 `exportData`：那条路把排版结果当成"单张图"回给分享面板，名字
    /// 地不写模板。拼图是一次独立出片，报告与失败都要单独说清楚。
    func exportCollage(to directory: URL, format: ExportFormat, quality: Double) async {
        guard let doc = document else { return }
        guard doc.collage != nil else { alert = "先套一个模板"; return }
        busy = .assembling
        defer { busy = nil }
        let store = self.store
        let ort = self.ort
        let outcome = await ExportPipeline.render(doc, store: store, ort: ort, fullResolution: true)
        exportNotes = outcome.notes
        // 成功标记是 `[collage] …`，失败是 `[collage_short]` / `[collage_failed]` / `[collage_no_template]`：
        // 拿"包含 [collage]"当判据会把失败当成成功，所以比前缀。
        guard outcome.notes.contains(where: { $0.hasPrefix("[collage] ") }) else {
            let reason = outcome.notes.first(where: { $0.contains("[collage") }) ?? "排版未执行"
            alert = reason
            status = "拼图导出止步：\(reason)"
            return
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try ExportPipeline.encode(outcome, format: format, quality: quality, maxEdge: 0)
            }.value
            let name = suggestedFilename(ext: format.fileExtension, template: "{stem}-collage.{ext}")
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            status = "拼图已导出 · \(url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
        } catch {
            alert = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 涂一笔衣物区（祛褶只在这里生效）。与保护/选区同一类：只存笔迹。
    func addGarmentStroke(_ stroke: BrushStroke) {
        mutateDocument { $0.brush.garments.append(stroke) }
        commitHistoryNow()
        scheduleRender()
        status = "衣物区 \(document?.brush.garments.count ?? 0) 笔"
    }

    func clearGarmentStrokes() {
        mutateDocument { $0.brush.garments = [] }
        commitHistoryNow()
        scheduleRender()
        status = "已清除衣物区"
    }

    // MARK: - AI：手部 / 天空 / 多帧堆栈

    /// 检测手（Vision 手部姿态，零权重）。凸包存归一化坐标，
    /// 所以预览档算的点在全分辨率导出上直接能用。
    func runHandPose() async {
        guard let doc = document else { return }
        busy = .hands
        defer { busy = nil }
        let bytes = await Task.detached(priority: .userInitiated) {
            doc.render(applyMask: false).rgba8()
        }.value
        let hands = await Task.detached(priority: .userInitiated) {
            VisionSupport.hands(in: bytes)
        }.value
        let hulls = hands.map { $0.points }
        mutateDocument { $0.handHulls = hulls }
        status = hulls.isEmpty
            ? "[no_hand] 没检测到手（画面里可能没有手，或手指被遮）"
            : "手部：\(hulls.count) 只 · \(hulls.map(\.count).reduce(0, +)) 个关节点"
    }

    func clearHandHulls() {
        mutateDocument { $0.handHulls = [] }
        scheduleRender()
        status = "已清除手部区域"
    }

    /// 找天空（从顶边连通生长）。结果存为资产，与抠图同一性质。
    func detectSky() async {
        guard let doc = document else { return }
        busy = .sky
        defer { busy = nil }
        let display = await Task.detached(priority: .userInitiated) {
            doc.render(applyMask: false)
        }.value
        let weights = await Task.detached(priority: .userInitiated) {
            SkyMask.build(display, personMask: doc.personMask)
        }.value
        guard weights.count == display.size.pixelCount, weights.contains(where: { $0 > 0.5 }) else {
            mutateDocument { $0.skyMask = nil }
            status = "[no_sky_mask] 没找到与顶边相连的天空区（不连顶边的蓝色不会被当成天）"
            return
        }
        let bytes = Data(weights.map { UInt8((Swift.min(1.0, Double($0)) * 255).rounded()) })
        mutateDocument { $0.skyMask = MaskBuffer(size: display.size, data: bytes) }
        let share = Double(weights.filter { $0 > 0.5 }.count) / Double(max(1, display.size.pixelCount))
        // 把"为什么不是发丝级"直接写在结果里：天空区域一直走色域+连通生长的
        // 回退路径（分割权重不在清单里），不标就会被当成 AI 分割。
        status = String(format: "天空：占画面 %.0f%% · %d×%d · [fallback:sky-colour-locus]",
                        share * 100, display.size.width, display.size.height)
    }

    func clearSkyMask() {
        mutateDocument { $0.skyMask = nil }
        scheduleRender()
        status = "已清除天空区域"
    }

    /// 导入一张天。名字进参数、字节进文档（与 `.cube` 同一套处理）。
    func importSky(from url: URL) async {
        guard let doc = document else { return }
        busy = .sky
        defer { busy = nil }
        do {
            let name = try SkyLibrary.install(from: url)
            let photo = await SkyLibrary.load(name: name, canvas: doc.canvasSize)
            guard let photo else {
                alert = "[no_sky:\(name)] 存下了但读不出来（格式不支持或文件坏了）"
                return
            }
            mutateDocument { item in
                item.skyPhoto = photo
                item.params.sky.mode = .photo
                item.params.sky.sourceName = name
                var deps = item.params.requires.filter { !$0.hasPrefix("sky:") }
                deps.append("sky:\(name)")
                item.params.requires = deps
            }
            status = "已导入天空：\(name)"
        } catch {
            alert = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 多帧堆栈（AI 慢门）。取代之前的当前图：堆出来的就是一张新图，
    /// 后续所有调色/人像都要在它上面做，所以直接换 document 而不是另存一份。
    func runLongExposure(with urls: [URL], mode: StackMode) async {
        guard let doc = document else { return }
        busy = .stacking
        defer { busy = nil }
        // 主图 + 选中的其他帧。主图排在最前，所以第一帧就是参考帧。
        var sources: [URL] = []
        if let mine = doc.sourceURL { sources.append(mine) }
        sources += urls.filter { url in url != doc.sourceURL }
        guard sources.count >= 2 else {
            alert = "[frames_short] 堆栈需要同一机位的至少 2 张图（当前 \(sources.count) 张）"
            return
        }
        var frames: [DisplayImage] = []
        var skipped: [String] = []
        for url in sources {
            guard let loaded = try? await ImageLoader.load(url: url, maxEdge: 2048) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            frames.append(ToneEngine.render(loaded.linear, params: EditParameters()))
        }
        guard frames.count >= 2 else {
            alert = "[frames_short] 能读出来的图不足 2 张：\(skipped.prefix(3).joined(separator: ", "))"
            return
        }
        guard let result = LongExposureEngine.stack(frames, mode: mode) else {
            alert = "[stack_mismatch] 这些图尺寸不一致，堆栈只做平移对齐，不会静默重采样"
            return
        }
        guard let linear = LinearImage(display: result.image) else {
            alert = "[stack_failed] 堆栈结果转不回线性档"
            return
        }
        let stem = doc.sourceURL?.deletingPathExtension().lastPathComponent ?? "stack"
        mutateDocument { item in
            item.linear = linear
            item.maskReference = linear.size
            item.personMask = nil
            item.patches = []
            item.brush = BrushState()
            item.faceGeometries = []
            item.bodyAnchors = nil
            item.handHulls = []
            item.skyMask = nil
            item.skyPhoto = nil
        }
        exportNotes = [LongExposureEngine.report(result)] + (skipped.isEmpty ? [] : ["[stack_skipped] \(skipped.count) 张读不了")]
        await renderNow()
        status = "\(result.frames) 帧堆栈完成（\(mode.title)）· \(stem)"
    }

    // MARK: - 批量

    /// 把当前图的参数按组同步到多张图并导出（像素蛋糕式“一张调好→其余抄”）。
    /// 串行：iPad 内存只够一张一张来（见 BatchQueue 顶部注释）。
    func runBatch(urls: [URL], outputDirectory: URL, format: ExportFormat,
                  groups: SyncGroups, quality: Double, maxEdge: Int) async {
        guard !urls.isEmpty else { alert = "先选择要批量处理的图片"; return }
        guard groups != [] else { alert = "一个同步组也没选，这样导出等于原图"; return }
        busy = .exporting("批量 \(urls.count) 张")
        defer { busy = nil }
        let config = BatchConfig(params: params, format: format, quality: quality, maxEdge: maxEdge,
                                 outputDirectory: outputDirectory, groups: groups)
        let items = urls.map { BatchItem(url: $0) }
        let store = self.store
        let ort = self.ort
        let report = await BatchQueue.process(items: items, config: config, store: store, ort: ort) { done, total in
            self.status = "批量 \(done)/\(total) · \(groups.title)"
        }
        batchReport = report
        status = "批量完成：\(report.succeeded)/\(report.total) 成功" + (report.failed > 0 ? " · \(report.failed) 失败" : "")
    }

    // MARK: - 本地调节

    func addLocalAdjustment(_ adjustment: LocalAdjustment) {
        mutateDocument { $0.localAdjustments.append(adjustment) }
        commitHistoryNow()
        scheduleRender()
        status = "本地调节 \(document?.localAdjustments.count ?? 0) 个"
    }

    /// 收下画布上采到的画笔选区（等面板给它一组参数）。
    func setPendingLocalStroke(_ stroke: BrushStroke) {
        pendingLocalStroke = stroke
        status = "已采集画笔选区（\(stroke.points.count) 点）：到风格面板设参数后点「添加」"
    }

    func clearPendingLocalStroke() {
        pendingLocalStroke = nil
    }

    /// 把待用的画笔选区与面板上那一组参数绑成一个本地调节。
    /// 返回 false = 手里还没有画笔选区（面板据此提示先去画布涂一笔）。
    @discardableResult
    func commitPendingLocalStroke(exposure: Double, contrast: Double, saturation: Double,
                                  temperature: Double, tint: Double, sharpness: Double,
                                  feather: Double) -> Bool {
        guard let stroke = pendingLocalStroke else { return false }
        addLocalAdjustment(LocalAdjustment(mask: .stroke(stroke), exposure: exposure, contrast: contrast,
                                           saturation: saturation, temperature: temperature, tint: tint,
                                           sharpness: sharpness, feather: feather))
        pendingLocalStroke = nil
        return true
    }

    func clearLocalAdjustments() {
        mutateDocument { $0.localAdjustments = [] }
        commitHistoryNow()
        scheduleRender()
        status = "已清除本地调节"
    }

    // MARK: - 水印 / 边框 / 文字

    func addOverlay(_ element: OverlayElement) {
        mutateDocument { $0.overlays.append(element) }
        scheduleRender()
        status = "已添加装饰元素"
    }

    func removeOverlay(id: UUID) {
        mutateDocument { $0.overlays.removeAll { $0.id == id } }
        scheduleRender()
        status = "已移除装饰元素"
    }

    func clearOverlays() {
        mutateDocument { $0.overlays = [] }
        scheduleRender()
        status = "已清除所有装饰"
    }

    // MARK: - XMP 导入

    func importXMP(_ xmp: String) {
        guard var doc = document else { return }
        let (params, unknown) = XMPImporter.import_(xmp, into: doc.params)
        doc.params = params
        document = doc
        scheduleRender()
        scheduleHistoryCommit()
        status = unknown.isEmpty ? "XMP 已导入" : "XMP 已导入，\(unknown.count) 个未知键已跳过"
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
            // 出片是"这页干完了"的唯一可靠信号，所以在这里自动写 sidecar。
            // 导到相册与导到文件都走这里，不会漏一条。
            markCurrentExported()
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
        // 预设只换调色参数，不碰笔刷（与 resetParams 同理）。
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
        // 笔迹/资产类修改也得影响库里的"已修"状态：它们不走 updateParams。
        syncCurrentItemStatus()
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

// MARK: - 一次预览渲染的全部输出

/// 为什么不放在 `EditorModel` 里：它要在 `Task.detached` 的闭包中被调，
/// 而 `EditorModel` 是 `@MainActor` —— 成员静态函数默认主域隔离，
/// 拿 `Self.produce(...)` 就是"在后台线程叫一个主域函数"。
/// 单独一个顶层类型把这件事说明白：这一步本来就不需要主线程。
///
/// 预览与导出共用 `ImageDocument.render()`，这里只把"直方图 + 两个叠层"
/// 这两个派生量和它绑在同一次计算里——否则两处各写一套采样步长，
/// 症状是"直方图说没溢出、叠层说溢出了"。
struct PreviewRender: Sendable {
    var image: CGImage?
    var mask: CGImage?
    var clipping: CGImage?
    var histogram: Histogram

    static func produce(_ snapshot: ImageDocument, showMask: Bool, showClipping: Bool) -> PreviewRender {
        let display = snapshot.render()
        let histogram = HistogramBuilder.build(
            display, stride: HistogramBuilder.suggestedStride(pixelCount: display.size.pixelCount))
        var overlay: CGImage? = nil
        if showMask, let mask = snapshot.personMask {
            overlay = mask.resized(to: snapshot.canvasSize).cgImage()
        }
        var clipping: CGImage? = nil
        if showClipping {
            clipping = ClippingOverlay.mask(display).cgImage()
        }
        return PreviewRender(image: display.cgImage(), mask: overlay, clipping: clipping, histogram: histogram)
    }
}
