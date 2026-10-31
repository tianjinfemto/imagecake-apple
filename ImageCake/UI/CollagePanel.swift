import SwiftUI
import UniformTypeIdentifiers

// 拼图面板。`CollageEngine` 早就有算子和断言，缺的**只是入口**——
// 与 BatchQueue/LocalAdjustmentEngine 同一类缺陷：功能在仓里，用户拿不到。
//
// 三条设计约束：
//   · 主图永远是第一格，其余格由这里选的图源填。这样"在编辑的这张图"
//     不需要再选一遍，也不会出现"主图被排到第二格"的意外。
//   · 图不够格时不拿主图重复填坑（默认），因为症状是"4 格里 3 格是同一张"
//     而用户以为是软件出错。要么补选、要么显式勾「用主图重复填满」，
//     底栏与导出报告都会点名 `[collage_short]`。
//   · 排版只挂导出，不进预览：预览看的是单张效果，拼图是"一次出片"。

struct CollagePanel: View {
    @EnvironmentObject private var model: EditorModel

    @State private var templateID: UUID = CollageEngine.templates[0].id
    @State private var backgroundID = "white"
    @State private var allowMainRepeat = false
    @State private var showSourcePicker = false
    @State private var showDirectoryPicker = false
    @State private var outputDirectory: URL?
    @State private var format: ExportFormat = .jpeg
    @State private var quality = 0.92

    private var template: CollageTemplate {
        CollageEngine.template(id: templateID) ?? CollageEngine.templates[0]
    }

    var body: some View {
        SectionCard(title: "拼图排版", subtitle: "\(template.name) · \(template.slots.count) 格") {
            Picker("模板", selection: $templateID) {
                ForEach(CollageEngine.templates) { item in
                    Text(item.name).tag(item.id)
                }
            }
            Picker("底色", selection: $backgroundID) {
                Text("白").tag("white")
                Text("黑").tag("black")
                Text("灰").tag("gray")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                showSourcePicker = true
            } label: {
                Label("选择其余图源（需 \(max(0, template.slots.count - 1)) 张）", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if let composition = model.document?.collage, !composition.extraURLs.isEmpty {
                Text("已选 \(composition.extraURLs.count) 张：\(composition.extraURLs.prefix(4).map(\.lastPathComponent).joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $allowMainRepeat) {
                Text("格子不够时用主图重复填满").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                model.setCollage(templateID: templateID, backgroundID: backgroundID,
                                 extraURLs: model.document?.collage?.extraURLs ?? [],
                                 allowMainRepeat: allowMainRepeat)
            } label: {
                Label("套用模板", systemImage: "rectangle.3.group")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!model.hasImage)

            if let warning = model.collageWarning {
                Text(warning)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("排版并导出…") { showDirectoryPicker = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.accent)
                    .disabled(model.document?.collage == nil || model.busy != nil)
                Button("取消排版") { model.clearCollage() }
                    .buttonStyle(.bordered)
                    .disabled(model.document?.collage == nil)
            }
            if let directory = outputDirectory {
                Picker("格式", selection: $format) {
                    ForEach(ExportFormat.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Button("导出到 \(directory.lastPathComponent)") {
                    Task { await model.exportCollage(to: directory, format: format, quality: quality) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(model.busy != nil)
            }
        }
        .fileImporter(isPresented: $showSourcePicker,
                      allowedContentTypes: [.image, .rawImage],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            urls.forEach { _ = $0.startAccessingSecurityScopedResource() }
            model.setCollage(templateID: templateID, backgroundID: backgroundID,
                             extraURLs: urls, allowMainRepeat: allowMainRepeat)
        }
        .fileImporter(isPresented: $showDirectoryPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()
                outputDirectory = url
            }
        }
    }
}
