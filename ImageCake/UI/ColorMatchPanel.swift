import SwiftUI
import UniformTypeIdentifiers

// 追色面板（样片对齐）。挂在「风格」栏里，与滤镜上下相邻。
//
// 为什么和滤镜放一起而不是放「调色」：这一组不是"把某个数值推到多少"，
// 而是"把这一张变成那一张的调性"。它跟滤镜同属"整张图的观感"，也因此
// 与滤镜同属批量同步的 `.style` 组（见 ParamSync）。
//
// 面板上必须直说的两件事：
//   · 对齐的是**均值与标准差**，不是直方图形状。样片是高反差硬光、客片是
//     平光时，追完只是均值反差像了，影调分布仍然不像（真解是直方图规定化，
//     断层风险高，本版不做）。
//   · 皮肤保护走**色域**判定，不是分割网络。所以暖色墙会被当成皮肤少追一点
//     色度——保守方向的错，比把人追绿安全。

struct ColorMatchPanel: View {
    @EnvironmentObject private var model: EditorModel

    @State private var showRefPicker = false

    var body: some View {
        SectionCard(title: "追色", subtitle: subtitle) {
            Toggle(isOn: bool(\.colorMatch.enabled)) {
                Text("启用").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 8) {
                Button {
                    showRefPicker = true
                } label: {
                    Label(refName.isEmpty ? "选样片…" : "换样片", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(model.document == nil || model.busy != nil)

                if !refName.isEmpty {
                    Button("清除") { model.clearColorReference() }
                        .buttonStyle(.bordered)
                        .disabled(model.busy != nil)
                }
            }

            SliderRow(title: "追多少", range: 0 ... 100,
                      format: { $0 == 100 ? "对齐" : String(Int($0.rounded())) },
                      value: double(\.colorMatch.strength))

            Toggle(isOn: bool(\.colorMatch.matchLuma)) {
                Text("连亮度一起追").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: bool(\.colorMatch.protectSkin)) {
                Text("保护皮肤色度").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            ForEach(missingNotes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("把这一张的亮度/红绿/蓝黄三个轴的均值与反差搬到样片上。只对齐一阶与二阶统计量：样片是高反差硬光而本张是平光时，追完像调性而不像影调。皮肤保护按色域判，暖色墙会被当成皮肤少追一点色度。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $showRefPicker,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.importColorReference(from: url) }
            }
        }
    }

    private var refName: String { model.params.colorMatch.sourceName }

    private var subtitle: String {
        if refName.isEmpty { return "需一张参考图" }
        return refName
    }

    /// 开了但没效果的原因，原样搬到底部。不写"请检查参考图"这种含糊话。
    private var missingNotes: [String] {
        guard !model.params.colorMatch.isNeutral else { return [] }
        return model.document?.pipelineWarnings.filter { $0.contains("colorref") } ?? []
    }

    private func bool(_ keyPath: WritableKeyPath<EditParameters, Bool>) -> Binding<Bool> {
        Binding(get: { model.params[keyPath: keyPath] },
                set: { value in model.updateParams { $0[keyPath: keyPath] = value } })
    }

    private func double(_ keyPath: WritableKeyPath<EditParameters, Double>) -> Binding<Double> {
        Binding(get: { model.params[keyPath: keyPath] },
                set: { value in model.updateParams { $0[keyPath: keyPath] = value } })
    }
}
