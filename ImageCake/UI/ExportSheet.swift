import SwiftUI
import UniformTypeIdentifiers

// 导出面板。
//
// 三件事刻意放在这里而不是自动：
//   · **全分辨率**：默认开（交付件就该是全量），但预览是 2048 档，
//     用户有权知道"这次要多等一会儿"；
//   · **保存去向**：iPadOS 上可以直接进相册（macOS 不提供——那边用 Files
//     更自然）；16bit PNG 存相册会被照片库转成 8bit，面板里点名；
//   · **导出报告**：AI 步骤失败/降级（`[patch_scaled]` / `[closed_eyes]` /
//     `[too_large]` / `[photos_denied]`）原样贴出来，不折成一句"导出完成"。

/// 导出后的去向。macOS 上只会有 `.files`，所以这个枚举不放在 #if 里——
/// 让两个平台都编译到，少一个只在一边生效的分支。
enum ExportDestination: String, CaseIterable, Identifiable {
    case files
    case photos
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "文件"
        case .photos: return "相册"
        case .both: return "两者"
        }
    }

    /// 是否要写相册。macOS 不提供入口（那边用 Files），所以那边只会是 .files。
    var writesPhotoLibrary: Bool { self != .files }
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .tiff, .jpeg, .heic, .json] }

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
    @State private var destination: ExportDestination = .files
    @State private var nameTemplate = ExportNaming.defaultTemplate

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
                    if format == .tiff16 {
                        Text("TIFF-16 用自家写入器（baseline 6.0、小端、单 strip、不压缩）：偏移与 tag 都在源码里可读；适合交给打印/后期的链路，文件会偏大。")
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

                Section("文件名") {
                    TextField("模板", text: $nameTemplate)
                        .font(.system(size: 11, design: .monospaced))

                    Text("预览：\(previewFilename)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Tokens.accent)
                        .textSelection(.enabled)

                    if !unknownTokens.isEmpty {
                        Text("不认识的占位符：\(unknownTokens.joined(separator: "、"))，导出时会原样保留。")
                            .font(.system(size: 10))
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("{stem} 原文件名、{date} 日期、{time} 时间、{index} 序号、{ext} 扩展名。模板不含 {ext} 时会自动补扩展名。")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                #if os(iOS)
                Section("保存到") {
                    Picker("保存到", selection: $destination) {
                        ForEach(ExportDestination.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    if destination.writesPhotoLibrary {
                        Text(photoNote)
                            .font(.system(size: 10))
                            .foregroundStyle(format == .png16 ? Tokens.danger : Tokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                #endif

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
        case .tiff16: return .tiff
        case .jpeg: return .jpeg
        case .heif: return .heic
        }
    }

    private var previewFilename: String {
        model.suggestedFilename(ext: format.fileExtension, template: nameTemplate)
    }

    private var unknownTokens: [String] {
        ExportNaming.unknownTokens(in: nameTemplate)
    }

    private var photoNote: String {
        if format == .png16 || format == .tiff16 {
            return "相册会按 8bit 转存，16bit 交付件请用「文件」或「两者」。"
        }
        return "写入后在「照片」里直接可见；「两者」会再弹一次文件保存，适合既归档又分享。"
    }

    private func runExport() {
        Task {
            guard let result = await model.exportData(format: format,
                                                      quality: quality,
                                                      maxEdge: maxEdge,
                                                      fullResolution: fullResolution,
                                                      nameTemplate: nameTemplate) else { return }

            #if os(iOS)
            if destination.writesPhotoLibrary {
                let saved = await model.saveToPhotos(result.data)
                if destination == .photos {
                    // 只存相册：成功就关窗；失败留在面板上，让「导出报告」把原因说清
                    // （拒绝授权是 `[photos_denied]`，不是一句“导出失败”）。
                    if saved { dismiss() }
                    return
                }
                _ = saved   // 两者：即使相册失败，文件仍要继续给
            }
            #endif

            payload = ExportFile(data: result.data)
            filename = result.filename
            showExporter = true
        }
    }
}
