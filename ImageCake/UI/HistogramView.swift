import SwiftUI

// 直方图卡片。像素蛋糕这类商业软件把它常驻在画布边上，不是装饰：
// 拖曝光的人需要知道"高光已经死了"，而肉眼在缩略图上分不清 254 与 255。
//
// 这里读的是 `EditorModel.histogram`——它和预览同一次渲染算出来，所以
// "图上看到的"与"直方图说的"不可能两说。采样步长在模型侧统一给
// （`HistogramBuilder.suggestedStride`），卡片不参与决定。

struct HistogramView: View {
    @EnvironmentObject private var model: EditorModel

    @State private var channel: Channel = .rgb

    enum Channel: String, CaseIterable, Identifiable {
        case rgb, luma
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rgb: return "RGB"
            case .luma: return "亮度"
            }
        }
    }

    var body: some View {
        SectionCard(title: "直方图", subtitle: histogramSubtitle) {
            Picker("", selection: $channel) {
                ForEach(Channel.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            chart
                .frame(height: 76)
                .frame(maxWidth: .infinity)

            Toggle(isOn: $model.showClipping) {
                Text("溢出高亮（红=高光死 / 蓝=暗部死）").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let warning = model.clippingWarning {
                Text(warning)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let outOfRange = model.histogram.outOfRangeCount
            if outOfRange > 0 {
                Text("[out_of_range] \(outOfRange) 个像素超出可显示范围，编码时会被夹取")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.danger.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("分箱口径与导出的 8bit 编码逐比特一致，所以这张图预测的就是文件里的结果。统计按抽样步长进行（当前 \(model.histogram.sampleCount) 样本）。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var histogram: Histogram { model.histogram }

    private var histogramSubtitle: String {
        guard !histogram.isEmpty else { return "无图" }
        return String(format: "高光死 %.2f%% · 暗部死 %.2f%%",
                      histogram.clippedHighlightRatio * 100,
                      histogram.clippedShadowRatio * 100)
    }

    // MARK: - 绘图

    private var chart: some View {
        Canvas { context, size in
            guard !histogram.isEmpty else { return }
            let groups: [([Int], Color)]
            switch channel {
            case .luma:
                groups = [(histogram.luma, Tokens.textPrimary)]
            case .rgb:
                groups = [(histogram.red, Color(hex: 0xFF5A5A)),
                          (histogram.green, Color(hex: 0x4AD07A)),
                          (histogram.blue, Color(hex: 0x5AA0FF))]
            }
            // 三通道叠加时用 screen 混合，重叠处不会互相盖掉。
            let blend: GraphicsContext.BlendMode = groups.count > 1 ? .screen : .normal
            var ctx = context
            ctx.blendMode = blend
            for (values, color) in groups {
                let normalized = histogram.normalized(values)
                guard normalized.count > 1 else { continue }
                let barWidth = size.width / Double(normalized.count)
                var path = Path()
                for (index, value) in normalized.enumerated() {
                    let height = value * size.height
                    path.addRect(CGRect(x: Double(index) * barWidth,
                                        y: size.height - height,
                                        width: max(barWidth, 0.5),
                                        height: height))
                }
                ctx.fill(path, with: .color(color.opacity(0.85)))
            }
            // 左右边界线：贴边就说明有像素死在那里。
            var frame = Path()
            frame.addRect(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            ctx.stroke(frame, with: .color(Tokens.border), lineWidth: 0.5)
        }
    }
}
