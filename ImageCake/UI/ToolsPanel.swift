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
        }
    }
}
