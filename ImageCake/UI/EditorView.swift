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
    @State private var showPresetImport = false
    @State private var showPresetExport = false
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
            CanvasView(image: model.preview,
                       maskOverlay: model.maskOverlay,
                       showMask: model.showMask,
                       selectionEnabled: model.selectionMode,
                       selection: $model.selection)
        } else {
            EmptyCanvasView { showOpen = true }
        }
    }

    // MARK: - 检查器

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("面板", selection: $tab) {
                Text("调色").tag(0)
                Text("AI").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            ScrollView {
                VStack(spacing: 12) {
                    if tab == 0 {
                        TonePanel().environmentObject(model)
                    } else {
                        AIPanel().environmentObject(model)
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
            if !model.lastAINote.isEmpty {
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
            if model.document?.isRAW == true {
                TokenBadge(text: "RAW")
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
                Button("复位调色") { model.resetParams() }
                    .disabled(!model.hasImage)
            } label: {
                Label("预设", systemImage: "slider.horizontal.3")
            }
            .disabled(!model.hasImage)

            Button {
                showModels = true
            } label: {
                Label("模型", systemImage: "cpu")
            }
        }
    }
}
