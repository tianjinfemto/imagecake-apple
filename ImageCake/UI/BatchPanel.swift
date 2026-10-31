import SwiftUI
import UniformTypeIdentifiers

// 批量面板。像素蛋糕的立身之本不是"单张修得多好"，而是"一组图交得快"：
// 选一张当样本 → 按组把参数抄给其余 → 一次导出。这里把那条链路接通
// （BatchQueue 之前只有算子和断言，没有入口，等于没有这个功能）。
//
// 两个刻意的限制，都写在这里而不是藏在代码里：
//   · 串行处理。iPad 的内存只够一张一张来，并行会直接被系统杀掉；
//   · 只同步参数。手动液化、图章、保护笔迹、修复补丁**不在 EditParameters 里**，
//     所以它们抄不过去——这正是商业修图想要的安全边界（每张脸的手动修复
//     不该被套到别人脸上）。

struct BatchPanel: View {
    @EnvironmentObject private var model: EditorModel

    @State private var sources: [URL] = []
    @State private var outputDirectory: URL?
    @State private var showSourcePicker = false
    @State private var showDirectoryPicker = false
    @State private var format: ExportFormat = .jpeg
    @State private var groups: SyncGroups = .default
    @State private var quality = 0.92
    @State private var maxEdge = 0

    var body: some View {
        VStack(spacing: 12) {
            sourceSection
            groupSection
            outputSection
            runSection
        }
        .fileImporter(isPresented: $showSourcePicker,
                      allowedContentTypes: [.image, .rawImage],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                // 记住 security-scoped 访问权：文件选择器给的 URL 只在
                // 授权期间可读，批量是几十秒后的事，不 startAccessing 会读不到。
                urls.forEach { _ = $0.startAccessingSecurityScopedResource() }
                sources = urls
            }
        }
        .fileImporter(isPresented: $showDirectoryPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                // 目录能授权就授权；不能（本地沙箱内路径）也照常写入，
                // 所以两条分支得的是同一个 URL，只是带不带访问权。
                _ = url.startAccessingSecurityScopedResource()
                outputDirectory = url
            }
        }
    }

    // MARK: - 素材

    private var sourceSection: some View {
        SectionCard(title: "批量素材", subtitle: sources.isEmpty ? "未选择" : "\(sources.count) 张") {
            Button {
                showSourcePicker = true
            } label: {
                Label(sources.isEmpty ? "选择图片…" : "重新选择（\(sources.count) 张）", systemImage: "photo.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if !sources.isEmpty {
                Button("清空列表") { sources = [] }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text("只列前 8 张：\(sources.prefix(8).map(\.lastPathComponent).joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("样本是当前打开的这张图。批量时它**不在**队列里（避免把自己覆盖一遍）。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 同步组

    private var groupSection: some View {
        SectionCard(title: "同步哪些组", subtitle: groups.title) {
            groupToggle("调色（曝光/白平衡/曲线/HSL/色轮/降噪锐化）", .tone)
            groupToggle("美肤（磨皮/瑕疵/匀肤色/祛油光/美白）", .skin)
            groupToggle("美型与美体（预设形变）", .shape)
            groupToggle("滤镜与镜头（含 .cube 依赖登记）", .style)
            groupToggle("背景（换底色/虚化/去色边）", .background)
            groupToggle("交付端 AI（面部重绘/超清）", .delivery)
            HStack(spacing: 8) {
                Button("推荐") { groups = .default }.buttonStyle(.bordered).controlSize(.small)
                Button("全选") { groups = .all }.buttonStyle(.bordered).controlSize(.small)
                Button("清空") { groups = [] }.buttonStyle(.bordered).controlSize(.small)
            }
            Text("背景与交付端要谨慎：换底色依赖每张图自己的人像 α，而队列里的图**没有**跑过抠图——带着 bg_enabled 抄过去会得到 [no_mask] 点名而不是白底。面部重绘/超清是分钟级，60 张就是几十分钟。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func groupToggle(_ title: String, _ group: SyncGroups) -> some View {
        Toggle(isOn: Binding(get: { groups.contains(group) },
                             set: { on in
                                 if on { groups.insert(group) } else { groups.remove(group) }
                             })) {
            Text(title).font(.system(size: 11))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: - 输出

    private var outputSection: some View {
        SectionCard(title: "输出", subtitle: outputDirectory?.lastPathComponent ?? "未选目录") {
            Picker("格式", selection: $format) {
                ForEach(ExportFormat.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            SliderRow(title: "JPEG/HEIF 质量", range: 0.5 ... 1, step: 0.01,
                      format: { String(format: "%.2f", $0) }, value: $quality)
            Picker("长边上限", selection: $maxEdge) {
                Text("不缩").tag(0)
                Text("4096").tag(4096)
                Text("2880").tag(2880)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                showDirectoryPicker = true
            } label: {
                Label(outputDirectory == nil ? "选择输出目录…" : "更换输出目录", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 运行

    private var runSection: some View {
        SectionCard(title: "运行", subtitle: "串行·失败不中断") {
            Button {
                guard let directory = outputDirectory else {
                    model.alert = "先选输出目录"
                    return
                }
                let queue = sources.filter { $0.lastPathComponent != model.document?.sourceURL?.lastPathComponent }
                Task { await model.runBatch(urls: queue, outputDirectory: directory, format: format,
                                            groups: groups, quality: quality, maxEdge: maxEdge) }
            } label: {
                Label("开始批量（\(sources.count) 张）", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.accent)
            .disabled(sources.isEmpty || outputDirectory == nil || model.busy != nil)

            if let report = model.batchReport {
                VStack(alignment: .leading, spacing: 4) {
                    Text("报告：\(report.succeeded)/\(report.total) 成功，\(report.failed) 失败")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(report.failed == 0 ? Tokens.ok : Tokens.danger)
                    ForEach(report.notes.indices, id: \.self) { index in
                        Text(report.notes[index])
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Tokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
