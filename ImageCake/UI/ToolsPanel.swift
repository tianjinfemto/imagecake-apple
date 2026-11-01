import SwiftUI

// 工具面板。把笔刷、几何、装饰、拼图四张卡片收进一栏。
//
// 为什么合并：检查器只有一栏宽（iPad 分屏下会更窄），六七个顶级标签页
// 在 300pt 宽里放不下第二段 segmented picker。分栏的边界按**依赖**走而不是
// 按功能名走：调色（颜色与细节）、人像（皮肤与形体）、AI（跑网络的事）、
// 风格（滤镜/镜头/局部蒙版）、工具（改变画布与加东西上去的操作）、批量。
// 拼图放在工具而不单独开一栏：它和证件照排版一样是"改变输出形态"的操作，
// 而它以前一直只是有算子没入口的哑资产（见 docs/pixcake-parity.md §5）。
// 被合并的面板自身没有状态，合起来不改变任何行为。

struct ToolsPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            BrushPanel().environmentObject(model)
            GeometryPanel().environmentObject(model)
            OverlayPanel().environmentObject(model)
            CollagePanel().environmentObject(model)
            diagnosticsCard
        }
    }

    // MARK: - 诊断

    /// 渲染耗时开关 + 重测一次。为什么单独占一张卡而不是丢进某个面板的角落：
    /// P1 的性能工作靠的是"改之前与改之后的同一张数字"，它得随时能拉出来看，
    /// 并且能在同一张图上重跑一次拿对照（换图会换分辨率，数字就没有可比性）。
    private var diagnosticsCard: some View {
        SectionCard(title: "诊断", subtitle: model.showRenderPerf ? "耗时常显中" : "未显示") {
            Toggle(isOn: $model.showRenderPerf) {
                Text("底栏显示渲染耗时").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                Task { await model.renderNow() }
            } label: {
                Label("重测一次", systemImage: "stopwatch")
            }
            .buttonStyle(.bordered)
            .disabled(!model.hasImage)

            Text(model.renderPerfSummary.isEmpty
                 ? "还没有渲染记录：打开开关后随便改一个滑杆就有了。"
                 : model.renderPerfSummary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("阶段之和不含阶段之间的调度空隙；导出报告里也有一行 [perf]，那里多带重绘/超清等 AI 阶段（导出耗时的头寸通常在那里）。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
