import SwiftUI

// 调色面板。
//   线性域：曝光 / 色温 / 色调
//   显示域：对比 / 补光 / 高光柔化 / 饱和度 / 色相 / 四条曲线 / 空间滤波（降噪↔锐化）/ 三区色轮 / 八分区 HSL
// 色轮与 HSL 的算法一直在 ToneEngine 里跑、参数也早就在预设里，
// 缺的只是入口——所以 ColorGradingPanel 只负责把已有的算子接到滑杆上。
// 空间滤波要读邻域，不在 ToneEngine 的逐像素循环里，面板上仍然是两个滑杆。
// 背景与 AI 相关的入口都在 AI 面板，这里只管“颜色与细节”。
// 直方图放在本栏最前：它是调色结果的反馈，而不是一又一个工具。

struct TonePanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            HistogramView().environmentObject(model)

            SectionCard(title: "自动增强", subtitle: "量原图，不是 AI") {
                Button("曝光与白平衡自动") { model.applyAutoAdjust() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.hasImage)
                Text("中位数对 18% 灰定曝光，色温/色调由自家增益模型闭式解（不是试探，也不是网络）。量的始终是从原图，所以连按三次结果一样；建议值覆盖现有滑杆而不是叠加。已知边界：白参考取“近无彩且不暗”的像素，整幅都是暖色木墙时会把它当白参照把人追冷；参考像素不够会点名 [auto:wb_noref] 而不动白平衡，提亮越界会点名 [auto:hl_cap]。美学判断不在本栏，那需要权重。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SectionCard(title: "基础", subtitle: "线性 → 显示") {
                SliderRow(title: "曝光", range: -2 ... 2, step: 0.05,
                          format: { String(format: "%+.2f EV", $0) },
                          value: double(\.exposure), defaultValue: 0)
                SliderRow(title: "对比", range: -100 ... 100, value: double(\.contrast))
                SliderRow(title: "补光", range: 0 ... 100, value: double(\.fillLight))
                SliderRow(title: "高光柔化", range: 0 ... 100, value: double(\.highlightSoften))
                SliderRow(title: "饱和度", range: -100 ... 100, value: double(\.saturation))
                SliderRow(title: "色相", range: -180 ... 180, value: double(\.hue))
            }

            SectionCard(title: "白平衡", subtitle: "线性域") {
                SliderRow(title: "色温", range: -100 ... 100, value: double(\.temperature))
                SliderRow(title: "色调", range: -100 ... 100, value: double(\.tint))
                Text("正=暖 / 正=品红；中性时整段跳过，不空跑一遍矩阵。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
            }

            SectionCard(title: "曲线", subtitle: "RGB + 单通道") {
                CurveEditorView(curves: curves)
            }

            SectionCard(title: "细节", subtitle: "空间滤波") {
                SliderRow(title: "降噪", range: 0 ... 100, value: double(\.denoise))
                SliderRow(title: "锐化", range: 0 ... 100, value: double(\.sharpen))
                Text("降噪是保边平滑（双边滤波），锐化是 unsharp mask；两者都在调色之后执行，顺序固定为降噪 → 锐化。作用在预览图上，导出时同步重算。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ColorGradingPanel().environmentObject(model)

            SectionCard(title: "这一栏不做什么", subtitle: "分工") {
                Text("这一栏只管颜色与细节。滤镜/LUT、镜头校正与局部蒙版在「风格」，皮肤与形体在「人像」，批量在「批量」。旋转/裁剪会改画布尺寸，所以放在「工具」而不是这里：它改的是“坐标系”，不是“参数”。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func double(_ keyPath: WritableKeyPath<EditParameters, Double>) -> Binding<Double> {
        Binding(
            get: { model.params[keyPath: keyPath] },
            set: { value in model.updateParams { $0[keyPath: keyPath] = value } }
        )
    }

    private var curves: Binding<[CurveChannel]> {
        Binding(
            get: { model.params.curves },
            set: { value in model.updateParams { $0.curves = value } }
        )
    }
}
