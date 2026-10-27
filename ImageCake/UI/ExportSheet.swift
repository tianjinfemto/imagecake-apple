import SwiftUI
import UniformTypeIdentifiers

// 导出面板。
//
// 两件事刻意放在这里而不是自动：
//   · **全分辨率**：默认开（交付件就该是全量），但预览是 2048 档，
//     用户有权知道"这次要多等一会儿"；
//   · **导出报告**：AI 步骤失败/降级（`[patch_scaled]` / `[closed_eyes]` /
//     `[too_large]`）原样贴出来，不折成一句"导出完成"。

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .jpeg, .heic, .json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ExportSheet: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .jpeg
    @State private var quality = 0.92
    @State private var maxEdge = 0
    @State private var fullResolution = true
    @State private var payload: ExportFile?
    @State private var filename = "imagecake.jpg"
    @State private var showExporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("格式") {
                    Picker("格式", selection: $format) {
                        ForEach(ExportFormat.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    if format == .png16 {
                        Text("PNG-16 用自家写入器（zlib stored 块，不压缩）：端序与 filter 都在源码里可读；文件会偏大。")
                            .font(.system(size: 10))
                            .foregroundStyle(Tokens.textSecondary)
                    }
                }

                if format == .jpeg || format == .heif {
                    Section("质量") {
                        SliderRow(title: "压缩质量", range: 0.5 ... 1.0, step: 0.01,
                                  format: { String(format: "%.0f%%", $0 * 100) },
                                  value: $quality, defaultValue: 0.92)
                    }
                }

                Section("尺寸") {
                    Toggle("全分辨率重载源文件", isOn: $fullResolution)
                        .toggleStyle(.switch)
                    Picker("长边上限", selection: $maxEdge) {
                        Text("不缩").tag(0)
                        Text("4096").tag(4096)
                        Text("2880").tag(2880)
                        Text("2048").tag(2048)
                        Text("1600").tag(1600)
                    }
                    Text("全分辨率会重新读一遍源文件并按 32MP 上限保护；预览档只有 2048 长边，不适合当交付件。")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textSecondary)
                }

                Section("这一步会做什么") {
                    if model.params.faceRestore > 0 {
                        Label("面部重绘 \(Int(model.params.faceRestore))（GFPGAN，单脸约 2 秒）", systemImage: "face.smiling")
                            .font(.system(size: 11))
                    }
                    if model.params.superRes != 0 {
                        Label("AI 超清 \(model.params.superRes)x（分块推理，分钟级）", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                    }
                    if model.params.bgEnabled && model.document?.hasPersonMask != true {
                        Label("换底色被跳过：还没有人像 α", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.danger)
                    }
                    if model.params.faceRestore == 0 && model.params.superRes == 0 {
                        Text("只跑调色与已有 AI 资产（α / 修复补丁），通常几秒内完成。")
                            .font(.system(size: 10))
                            .foregroundStyle(Tokens.textSecondary)
                    }
                }

                if !model.exportNotes.isEmpty {
                    Section("上一次导出报告") {
                        ForEach(model.exportNotes.indices, id: \.self) { index in
                            Text(model.exportNotes[index])
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Tokens.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("导出")
            .compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出") { runExport() }
                        .disabled(model.document == nil || model.busy != nil)
                }
            }
            .fileExporter(isPresented: $showExporter,
                          document: payload,
                          contentType: contentType,
                          defaultFilename: filename) { result in
                if case .failure(let error) = result {
                    model.alert = error.localizedDescription
                } else {
                    dismiss()
                }
            }
        }
        .frame(minWidth: 500, minHeight: 480)
    }

    private var contentType: UTType {
        switch format {
        case .png8, .png16: return .png
        case .jpeg: return .jpeg
        case .heif: return .heic
        }
    }

    private func runExport() {
        Task {
            guard let result = await model.exportData(format: format,
                                                      quality: quality,
                                                      maxEdge: maxEdge,
                                                      fullResolution: fullResolution) else { return }
            payload = ExportFile(data: result.data)
            filename = result.filename
            showExporter = true
        }
    }
}
