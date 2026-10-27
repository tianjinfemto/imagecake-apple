import SwiftUI
import UniformTypeIdentifiers

// 模型管理。这个面板的存在意义只有一个：把"缺什么、在哪、怎么补"说清楚。
//
// 每一行都显示**清单里的字节数与 sha256 前 12 位**，与下载脚本读的是同一份
// models.json——两处不一致时用户能当场看出来，而不是等某次推理失败才猜。

struct ModelsPanel: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var importing: ModelDescriptor?
    @State private var showImporter = false
    @State private var useMirror = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(ORTEngine.isSupported ? Tokens.ok : Tokens.danger)
                            .frame(width: 8, height: 8)
                        Text(ORTEngine.isSupported ? "ONNX Runtime 已链接" : "ONNX Runtime 不可用（这份构建没有绑定）")
                            .font(.system(size: 12))
                        Spacer()
                        TokenBadge(text: "已装 \(model.installedBytesLabel)")
                    }
                    HStack {
                        Toggle("下载走镜像（hf-mirror.com）", isOn: $useMirror)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Spacer()
                        Button("释放会话") {
                            Task { await model.unloadSessions() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("权重不进 App 包。下载/导入后做字节数与 SHA-256 双重校验；校验失败的文件会被删掉，不会以“不完整”的形态留在盘上。")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("运行时")
                }

                Section {
                    ForEach(model.store.manifest.models) { descriptor in
                        row(descriptor)
                    }
                } header: {
                    Text("权重（\(model.store.manifest.models.count) 颗）")
                } footer: {
                    Text("随包 / 按需的分档由 models.json 决定；“未接线”表示 v1 还没有对应任务的入口，权重可以先备着。")
                        .font(.system(size: 10))
                }
            }
            .navigationTitle("AI 模型")
            .compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                guard let descriptor = importing else { return }
                if case .success(let urls) = result, let url = urls.first {
                    Task { await model.importWeight(descriptor, from: url) }
                }
                importing = nil
            }
        }
        .frame(minWidth: 600, minHeight: 520)
    }

    @ViewBuilder
    private func row(_ descriptor: ModelDescriptor) -> some View {
        let state = model.modelState(descriptor)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(descriptor.purpose)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                TokenBadge(text: state.label,
                           tone: state.isUsable ? .good : (isProblem(state) ? .bad : .neutral))
            }
            Text(descriptor.file)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                TokenBadge(text: String(format: "%.1f MB", Double(descriptor.bytes) / 1_048_576))
                TokenBadge(text: descriptor.license)
                TokenBadge(text: descriptor.tier == .core ? "core" : "按需")
                if descriptor.commercialUse == "restricted" {
                    TokenBadge(text: "非商用", tone: .bad)
                }
            }
            HStack(spacing: 6) {
                if state.isUsable {
                    Button("校验") {
                        Task { await model.verify(descriptor) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("删除") { model.remove(descriptor) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Tokens.danger)
                } else {
                    Button("下载") {
                        Task { await model.download(descriptor, mirror: useMirror) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Tokens.accent)
                    Button("导入文件…") {
                        importing = descriptor
                        showImporter = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                Text("sha256 \(descriptor.sha256.prefix(12))…")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .disabled(model.busy != nil)
    }

    private func isProblem(_ state: ModelState) -> Bool {
        switch state {
        case .sizeMismatch: return true
        default: return false
        }
    }
}
