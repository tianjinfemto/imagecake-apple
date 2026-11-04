import SwiftUI
import UniformTypeIdentifiers

// 追色面板（样片对齐）。挂在「风格」栏里，与滤镜上下相邻。
//
// 为什么和滤镜放一起而不是放「调色」：这一组不是"把某个数值推到多少"，
// 而是"把这一张变成那一张的调性"。它跟滤镜同属"整张图的观感"，也因此
// 与滤镜同属批量同步的 `.style` 组（见 ParamSync）。
//
// 面板上必须直说的两件事：
//   · 第一档对齐的是**均值与标准差**；影调形状（双峰样片对单峰客片）靠下面
//     那个“影调形状也追”开关（分位数传递，`ShapeTransfer`），它默认关：
//     等价于拉一条重 S 曲线，样片反差极大时会在渐变里留硬边。
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

            // 第二档。放在“连亮度一起追”下面是因为它只动亮度轴：上面那个关了，
            // 这里开了也不会生效（报告里点名 [shape:luma_off]，不静默）。
            Toggle(isOn: bool(\.colorMatch.shapeMatch)) {
                Text("影调形状也追（第二档）").font(.system(size: 11))
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

            Text("把这一张的亮度/红绿/蓝黄三个轴的均值与反差搬到样片上。只对齐一阶与二阶统计量时，样片是高反差硬光而本张是平光会出现“像调性而不像影调”。\n\n开了“影调形状也追”后，亮度轴改走分位数传递（整条影调曲线搬到样片的形状上），实测单峰→双峰的 64 分箱距离从 2.00 降到 0.06（不开时仍是 2.00）。代价是它等价于拉一条重 S 曲线，样片反差极大时渐变里会出现硬边，所以默认关；纯色/黑场这类几乎没分布的图会自动跳过并点名。皮肤保护只减色度位移，不动亮度。")
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
