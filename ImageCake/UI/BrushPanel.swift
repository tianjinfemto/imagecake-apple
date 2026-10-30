import SwiftUI

// 笔刷面板。三件事：选工具、调笔刷参数、清笔迹。
//
// 工具与参数存在 EditorModel 而不在这里：画布手势要读它们，面板只是
// 一个写入口。仿制图章的取样锚点也存 model——画布上拖一下设，面板里
// 显示状态并给一个清除按钮。

struct BrushPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            toolSection
            parameterSection
            cloneSection
            clearSection
        }
    }

    // MARK: - 工具

    private var toolSection: some View {
        SectionCard(title: "笔刷工具", subtitle: subtitle) {
            HStack(spacing: 6) {
                ForEach(EditorModel.BrushTool.allCases, id: \.self) { tool in
                    Button {
                        model.brushTool = tool
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tool.icon)
                                .font(.system(size: 16))
                            Text(tool.title)
                                .font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            model.brushTool == tool
                                ? Tokens.accent.opacity(0.18)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(model.brushTool == tool ? Tokens.accent : Tokens.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(toolHint)
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 参数

    private var parameterSection: some View {
        SectionCard(title: "笔刷参数") {
            SliderRow(title: "半径", range: 0.005 ... 0.2, step: 0.001,
                      format: { String(format: "%.3f", $0) },
                      value: $model.brushRadius)
            SliderRow(title: "强度", range: 0 ... 1, step: 0.05,
                      format: { String(format: "%.0f%%", $0 * 100) },
                      value: $model.brushStrength)
            SliderRow(title: "硬度", range: 0 ... 1, step: 0.05,
                      format: { String(format: "%.0f%%", $0 * 100) },
                      value: $model.brushHardness)
            Text("半径相对长边：0.04 在 2048 长边上约 80px 直径。硬度 1 = 硬边，0 = 从中心衰减到边缘。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 仿制图章取样

    private var cloneSection: some View {
        SectionCard(title: "仿制图章取样", subtitle: model.cloneSource == nil ? "未设置" : "已设置") {
            if let source = model.cloneSource {
                HStack(spacing: 6) {
                    TokenBadge(text: String(format: "(%.3f, %.3f)", source.x, source.y), tone: .good)
                    Spacer()
                    Button("清除取样点") { model.clearCloneSource() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else if model.brushTool == .cloneStamp {
                Button {
                    model.clonePickingMode = true
                } label: {
                    Label("在画布上点一下取样", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Tokens.accent)

                Text("取样模式：开了之后，下一次点画布设定取样锚点，设完自动回到绘制。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("选了仿制图章后，先在画布上设取样锚点，再拖动绘制。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 清除

    private var clearSection: some View {
        SectionCard(title: "笔迹", subtitle: brushCounts) {
            HStack(spacing: 8) {
                ForEach(EditorModel.BrushKind.allCases.filter { $0 != .all }, id: \.self) { kind in
                    Button(kind.title) { model.clearBrush(kind) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .disabled(brushCount(kind) == 0)
                }
            }
            Button("清除全部笔刷") { model.clearBrush(.all) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Tokens.danger)
                .disabled(model.document?.brush.isEmpty ?? true)
        }
    }

    // MARK: - 辅助

    private var subtitle: String {
        model.brushTool == .none ? "未选工具" : model.brushTool.title
    }

    private var toolHint: String {
        switch model.brushTool {
        case .none:
            return "选一个工具后，在画布上单指拖动落笔。双指捏合仍可缩放。"
        case .liquify:
            return "液化：在画布上拖动，把笔刷半径内的像素往拖动方向推。一笔 = 一步历史。"
        case .cloneStamp:
            return "仿制图章：先设取样锚点，再拖动绘制——锚点处的内容会被搬到笔迹处。"
        case .protection:
            return "保护笔刷：涂过的区域不被液化推动、也不被图章覆盖。先涂保护，再涂液化/图章。"
        }
    }

    private var brushCounts: String {
        let brush = model.document?.brush
        let l = brush?.liquify.count ?? 0
        let s = brush?.stamps.count ?? 0
        let p = brush?.protection.count ?? 0
        return "液\(l) · 章\(s) · 护\(p)"
    }

    private func brushCount(_ kind: EditorModel.BrushKind) -> Int {
        guard let brush = model.document?.brush else { return 0 }
        switch kind {
        case .liquify: return brush.liquify.count
        case .stamps: return brush.stamps.count
        case .protection: return brush.protection.count
        case .all: return brush.liquify.count + brush.stamps.count + brush.protection.count
        }
    }
}