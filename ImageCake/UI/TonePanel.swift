import SwiftUI

// 调色面板。
//   线性域：曝光 / 色温 / 色调
//   显示域：对比 / 饱和度 / 色相 / 四条曲线 / 三区色轮 / 八分区 HSL
// 色轮与 HSL 的算法一直在 ToneEngine 里跑、参数也早就在预设里，
// 缺的只是入口——所以 ColorGradingPanel 只负责把已有的算子接到滑杆上。
// 背景与 AI 相关的入口都在 AI 面板，这里只管“颜色”。

struct TonePanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            SectionCard(title: "基础", subtitle: "线性 → 显示") {
                SliderRow(title: "曝光", range: -2 ... 2, step: 0.05,
                          format: { String(format: "%+.2f EV", $0) },
                          value: double(\.exposure), defaultValue: 0)
                SliderRow(title: "对比", range: -100 ... 100, value: double(\.contrast))
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

            ColorGradingPanel().environmentObject(model)

            SectionCard(title: "关于这版", subtitle: "v1 边界") {
                Text("本地滤镜表（.cube）、XMP 与批量不在 v1；旋转/裁剪会改画布尺寸，需与重采集同批。")
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
