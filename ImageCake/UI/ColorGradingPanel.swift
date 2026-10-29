import SwiftUI

// 颜色分级面板：三区色轮 + 八分区 HSL。
//
// 为什么现在才做：这两项的**参数、算子、预设序列化早就齐了**
// （EditParameters 的 wsh*/wmt*/whl* 与 hslHue/hslSat/hslLum，
// ToneEngine 里分别按亮度权重和色相带权重消费），唯独没有入口——
// 预设里带着它们进来，用户却看不见也改不了。这是当前唯一
// "完整实现却够不着"的功能，所以补的是 UI 而不是算法。
//
// 语义（读 ToneEngine 得出，别在这里重新发明）：
// · 色轮按**亮度**分区推整片颜色，三区的权重之和恒为 1（ColorMath.zoneWeights）；
// · HSL 按**色相带**染色，环距 45° 内线性衰减，重叠区按权重和归一；
// · 色轮的 sat 是 0...100（0 = 不染），不是 -100...100——所以色轮的点
//   在圆心代表"不推"，向外才有力度，这与 Lightroom 的色轮一致；
// · 色轮在 HSL 之前执行（管线顺序写在 ToneEngine 顶部，这里不重排）。

struct ColorGradingPanel: View {
    @EnvironmentObject private var model: EditorModel
    @State private var zone: WheelZone = .shadows
    @State private var band = 0

    var body: some View {
        VStack(spacing: 12) {
            SectionCard(title: "三区色轮", subtitle: "按亮度染色") {
                Picker("区", selection: $zone) {
                    ForEach(WheelZone.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(alignment: .top, spacing: 14) {
                    ColorWheelControl(hue: wheelHue, saturation: wheelSat)
                        .frame(width: 132, height: 132)
                    VStack(alignment: .leading, spacing: 10) {
                        SliderRow(title: "力度", range: 0 ... 100,
                                  format: { String(Int($0.rounded())) },
                                  value: wheelSat)
                        SliderRow(title: "亮度", range: -100 ... 100, value: wheelLum)
                        Text(zone.hint)
                            .font(.system(size: 10))
                            .foregroundStyle(Tokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SectionCard(title: "八分区 HSL", subtitle: "按色相染色") {
                ColorBandStrip(selected: $band)

                SliderRow(title: "色相", range: -30 ... 30,
                          format: { String(format: "%+.0f°", $0) },
                          value: bandValue(\.hslHue, band))
                SliderRow(title: "饱和", range: -100 ... 100,
                          value: bandValue(\.hslSat, band))
                SliderRow(title: "明度", range: -100 ... 100,
                          value: bandValue(\.hslLum, band))

                HStack {
                    Text("\(ColorGradingPanel.bandNames[band])带")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textSecondary)
                    Spacer()
                    Button("清空这一带") {
                        model.updateParams { p in
                            p.hslHue[band] = 0
                            p.hslSat[band] = 0
                            p.hslLum[band] = 0
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.accent)
                }

                Text("色相带中心与预设序一致：红0 / 橙30 / 黄60 / 绿120 / 青180 / 蓝240 / 紫285 / 品红320；相邻带环距 45° 内渐变过渡。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // —— 绑定 ——

    private var huePath: WritableKeyPath<EditParameters, Double> {
        switch zone {
        case .shadows: return \.wshHue
        case .mids: return \.wmtHue
        case .highlights: return \.whlHue
        }
    }

    private var satPath: WritableKeyPath<EditParameters, Double> {
        switch zone {
        case .shadows: return \.wshSat
        case .mids: return \.wmtSat
        case .highlights: return \.whlSat
        }
    }

    private var lumPath: WritableKeyPath<EditParameters, Double> {
        switch zone {
        case .shadows: return \.wshLum
        case .mids: return \.wmtLum
        case .highlights: return \.whlLum
        }
    }

    private var wheelHue: Binding<Double> { bind(huePath) }
    private var wheelSat: Binding<Double> { bind(satPath) }
    private var wheelLum: Binding<Double> { bind(lumPath) }

    private func bind(_ path: WritableKeyPath<EditParameters, Double>) -> Binding<Double> {
        Binding(
            get: { model.params[keyPath: path] },
            set: { value in model.updateParams { $0[keyPath: path] = value } }
        )
    }

    private func bandValue(_ path: WritableKeyPath<EditParameters, [Double]>, _ index: Int) -> Binding<Double> {
        Binding(
            get: {
                let values = model.params[keyPath: path]
                return index < values.count ? values[index] : 0
            },
            set: { value in
                // 数组长度由 clamp() 归一（EditParameters.normalizeArray），
                // 这里只负责写第 index 格，越界交给它兜。
                model.updateParams { $0[keyPath: path][index] = value }
            }
        )
    }

    static let bandNames = ["红", "橙", "黄", "绿", "青", "蓝", "紫", "品红"]
}

// MARK: - 三区枚举

enum WheelZone: Int, CaseIterable, Identifiable {
    case shadows, mids, highlights

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .shadows: return "阴影"
        case .mids: return "中间调"
        case .highlights: return "高光"
        }
    }

    var hint: String {
        switch self {
        case .shadows: return "重心落在暗部；亮度权重 = 1 - 2L。"
        case .mids: return "亮度中段；三区权重之和恒为 1，不会叠加成两倍。"
        case .highlights: return "重心落在亮部；亮度权重 = 2L - 1。"
        }
    }
}

// MARK: - 色轮控件

/// 圆形色相环：角度 = 色相方向，半径 = 力度。
///
/// 圆心代表「不推」——参数里 sat 是 0...100 而不是对称区间，
/// 所以没有「往反方向拉」这回事，反方向就是转过 180°。
/// 拉到圆心附近（< 4%）直接归零，避免手抖留一个 1 的残值。
struct ColorWheelControl: View {
    @Binding var hue: Double          // 模型里是 -180...180
    @Binding var saturation: Double   // 0...100

    private let ringSteps = 96
    private let dotSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = side / 2 - 4

            ZStack {
                Canvas { context, _ in
                    for step in 0 ..< ringSteps {
                        let start = Double(step) / Double(ringSteps) * 360
                        let end = Double(step + 1) / Double(ringSteps) * 360
                        var wedge = Path()
                        wedge.move(to: center)
                        // addArc 的 0° 在 3 点方向、顺时针，与下面的 atan2 一致。
                        wedge.addArc(center: center, radius: radius,
                                     startAngle: .degrees(start), endAngle: .degrees(end + 1),
                                     clockwise: false)
                        wedge.closeSubpath()
                        context.fill(wedge, with: .color(ringColor(start)))
                    }
                    // 中心留一块中性底，颜色推到 0 时看起来是「空」而不是「染了一点色」。
                    let core = CGRect(x: center.x - radius * 0.16, y: center.y - radius * 0.16,
                                      width: radius * 0.32, height: radius * 0.32)
                    context.fill(Path(ellipseIn: core), with: .color(Tokens.bgElevated))
                    context.stroke(Path(ellipseIn: core.insetBy(dx: -0.5, dy: -0.5)),
                                   with: .color(Tokens.border), lineWidth: 1)

                    let ring = CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2)
                    context.stroke(Path(ellipseIn: ring), with: .color(Tokens.border.opacity(0.8)), lineWidth: 1)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: dotSize, height: dotSize)
                    .overlay(Circle().stroke(Tokens.bgCanvas, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(dotPosition(center: center, radius: radius))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        apply(value.location, center: center, radius: radius)
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("色相与力度")
        .accessibilityValue("\(Int(hue.rounded()))°, \(Int(saturation.rounded()))")
    }

    private func dotPosition(center: CGPoint, radius: CGFloat) -> CGPoint {
        WheelGeometry.location(hue: hue, saturation: saturation, center: center, radius: radius)
    }

    private func apply(_ location: CGPoint, center: CGPoint, radius: CGFloat) {
        let next = WheelGeometry.adjust(at: location, center: center, radius: radius)
        // 死区内 hue 为 nil：只把力度归零，保留用户原来的方向。
        if let nextHue = next.hue { hue = nextHue }
        saturation = next.saturation
    }

    private func ringColor(_ degrees: Double) -> Color {
        let rgb = ColorMath.hsvToRGB(Float(degrees), 1, 1)
        return Color(.sRGB,
                     red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b),
                     opacity: 1)
    }
}

// MARK: - 色带选择条

/// 八个色带，等距排列（与 Lightroom 的 HSL 面板手感一致）。
/// 注意 bandCenters 本身不等距（0/30/60/120/180/240/285/320），
/// 视觉上按角度画会让红橙黄挤成一团，所以这里只取颜色、不取位置。
struct ColorBandStrip: View {
    @Binding var selected: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< ColorGradingPanel.bandNames.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(bandColor(index))
                    .frame(height: 26)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(selected == index ? Color.white : Color.clear, lineWidth: 2)
                    )
                    .overlay(
                        Text(ColorGradingPanel.bandNames[index])
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(selected == index ? 0.95 : 0.7))
                            .shadow(color: .black.opacity(0.5), radius: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
                    .onTapGesture { selected = index }
            }
        }
    }

    private func bandColor(_ index: Int) -> Color {
        let centers = ColorMath.bandCenters
        let degrees = index < centers.count ? centers[index] : Float(index) * 45
        let rgb = ColorMath.hsvToRGB(degrees, 1, 1)
        return Color(.sRGB,
                     red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b),
                     opacity: 1)
    }
}
