import SwiftUI
import UniformTypeIdentifiers

// 主界面。左边画布、右边检查器；底栏是"事实栏"（尺寸/预览档/AI 路径）。
//
// 为什么把 note 常驻底栏而不是弹窗：修图是连续动作，弹窗会打断；
// 而 `[no_model]` 这类事实必须一直在视野里，直到它被解决。

struct EditorView: View {
    @EnvironmentObject private var model: EditorModel

    @State private var tab = 0
    @State private var showOpen = false
    @State private var showModels = false
    @State private var showExport = false
    @State private var showLibrary = false
    @State private var showTether = false
    @State private var showPresetImport = false
    @State private var showPresetExport = false
    @State private var showXMPImport = false
    @State private var presetPayload: ExportFile?
    @State private var presetFilename = "preset.json"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 面板宽度跟窗口走：iPad 分屏（窄）时 344pt 会把画布挤没，
                // 但完全收起又会让"AI 面板在哪"变成一个要记的事。
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        canvasArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider().overlay(Tokens.border)
                        inspector
                            .frame(width: min(Tokens.panelWidth, max(280, geo.size.width * 0.46)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                statusBar
            }
            .background(Tokens.bgWindow)
            .navigationTitle("ImageCake")
            .compactNavigationTitle()
            .toolbar { toolbarContent }
        }
        .fileImporter(isPresented: $showOpen,
                      allowedContentTypes: [.image, .rawImage],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.open(url: url) }
            }
        }
        .fileImporter(isPresented: $showPresetImport,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                let loaded = try PresetStore.load(from: url)
                model.applyPreset(loaded.params, report: loaded.report, sourceName: url.lastPathComponent)
            } catch {
                model.alert = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showXMPImport,
                      allowedContentTypes: [UTType(filenameExtension: "xmp") ?? .xml],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importXMP(from: url)
            }
        }
        .fileExporter(isPresented: $showPresetExport,
                      document: presetPayload,
                      contentType: .json,
                      defaultFilename: presetFilename) { result in
            if case .failure(let error) = result {
                model.alert = error.localizedDescription
            }
        }
        .sheet(isPresented: $showModels) {
            ModelsPanel().environmentObject(model)
        }
        .sheet(isPresented: $showExport) {
            ExportSheet().environmentObject(model)
        }
        .sheet(isPresented: $showLibrary) {
            // 素材库要宽度，所以是 sheet 而不是检查器里的第七个标签页。
            LibraryPanel { showLibrary = false }.environmentObject(model)
        }
        .sheet(isPresented: $showTether) {
            // 联机同理：设备列表 + 快门参数 + 回片预览，一栏 300pt 装不下。
            TetherPanel { showTether = false }.environmentObject(model)
        }
        .overlay {
            if let busy = model.busy {
                BusyOverlay(title: busy.title, detail: busy.detail)
            }
        }
        .alert("提示", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        )) {
            Button("好") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
                .font(.system(size: 12))
        }
        .onOpenURL { url in
            Task { await model.open(url: url) }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 画布

    @ViewBuilder
    private var canvasArea: some View {
        if model.hasImage {
            CanvasView()
        } else {
            EmptyCanvasView { showOpen = true }
        }
    }

    // MARK: - 检查器

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("面板", selection: $tab) {
                Text("调色").tag(0)
                Text("人像").tag(1)
                Text("AI").tag(2)
                Text("风格").tag(3)
                Text("工具").tag(4)
                Text("批量").tag(5)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            ScrollView {
                VStack(spacing: 12) {
                    switch tab {
                    case 0: TonePanel().environmentObject(model)
                    case 1: BeautyPanel().environmentObject(model)
                    case 2: AIPanel().environmentObject(model)
                    case 3: StylePanel().environmentObject(model)
                    case 4: ToolsPanel().environmentObject(model)
                    default: BatchPanel().environmentObject(model)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.visible)
        }
        .background(Tokens.bgPanel)
        .overlay(alignment: .leading) {
            Rectangle().fill(Tokens.border).frame(width: 1)
        }
    }

    // MARK: - 底栏

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(model.status)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)
            // 缺件点名排在“上一次 AI 结果”之前：滑杆推了却没反应时，
            // 用户需要先看到“因为缺关键点”，而不是一个旧的耗时数字。
            if !model.pipelineNotes.isEmpty {
                Text(model.pipelineNotes[0])
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.danger)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .macHelp(model.pipelineNotes.joined(separator: "\n"))
            } else if !model.lastAINote.isEmpty {
                Text(model.lastAINote)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.hasImage {
                TokenBadge(text: "\(model.canvasSize.width)×\(model.canvasSize.height)")
            }
            // 溢出警告排在缺件徽章之前："高光死了"是本次修图的结果问题，
            // 而"缺权重"是环境事实，前者对当下这张图更紧要。
            if let warning = model.clippingWarning {
                Text(warning)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.danger)
                    .lineLimit(1)
            }
            // 耗时行默认不显示，但要随手可开（工具栏“渲染耗时”）：性能优化
            // 得能在真机上当场看到“耗在哪一段”，而不是只能回来看日志。
            if model.showRenderPerf && !model.renderPerfSummary.isEmpty {
                Text(model.renderPerfSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .macHelp("各阶段之和；不含阶段之间的调度空隙")
            }
            if model.document?.isRAW == true {
                TokenBadge(text: "RAW")
            }
            if !model.pipelineNotes.isEmpty {
                TokenBadge(text: "缺件 \(model.pipelineNotes.count)", tone: .bad)
            }
            TokenBadge(text: ORTEngine.isSupported ? "ORT" : "ORT 缺失",
                       tone: ORTEngine.isSupported ? .good : .bad)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Tokens.bgPanel)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.border).frame(height: 1)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.undo()
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!model.canUndo)

            Button {
                model.redo()
            } label: {
                Label("重做", systemImage: "arrow.uturn.forward")
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.canRedo)

            Button {
                showOpen = true
            } label: {
                Label("打开", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)

            Button {
                showExport = true
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!model.hasImage)

            Menu {
                Button("载入预设…") { showPresetImport = true }
                Button("导出当前预设…") {
                    if let data = model.presetData() {
                        presetPayload = ExportFile(data: data)
                        presetFilename = "preset-\(Int(Date().timeIntervalSince1970)).json"
                        showPresetExport = true
                    }
                }
                Button("保存到 App 目录") { model.savePresetToDefault() }
                Divider()
                // XMP 就是 Adobe 那边的“一组参数”，与载入预设同一条语义。
                // 两条路径都只能当场点名：旁边没文件、读不了、认不出键，
                // 都得在状态栏/弹窗看到令牌，不能只靠一句“已导入”。
                Button("读图旁边的 .xmp") { model.importXMPSidecar() }
                Button("从 .xmp 导入…") { showXMPImport = true }
                Divider()
                Button("复位调色") { model.resetParams() }
                    .disabled(!model.hasImage)
            } label: {
                Label("预设", systemImage: "slider.horizontal.3")
            }
            .disabled(!model.hasImage)

            Button {
                showLibrary = true
            } label: {
                Label("图库", systemImage: "square.grid.2x2")
            }

            Button {
                showTether = true
            } label: {
                Label("联机", systemImage: "camera")
            }

            Button {
                showModels = true
            } label: {
                Label("模型", systemImage: "cpu")
            }
        }
    }
}
