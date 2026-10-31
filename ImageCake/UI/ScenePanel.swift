import SwiftUI
import UniformTypeIdentifiers

// 场景面板：换天空、虚拟打光、多帧堆栈（AI 慢门）。
//
// 为什么放在「风格」这一栏：这三件都是"改画面里的光与背景"，改完之后
// 人像/调色那些参数仍然照同一张图生效。而它们等的资产各不相同
// （天空区域 / 什么都不等 / 额外几张源图），所以每一组各写一行依赖。
//
// 天空颜色只给三组预设而不是开放取色器，理由不是省事：这两个色**必须成对**
// 才像天（天顶偏冷偏暗、地平线偏亮偏暖），单给两个拾色器的实际结果是一半
// 概率做出脏天。要做真取色器请连色相一起带（那已属于"设计"而不是"缺功能"）。

struct ScenePanel: View {
    @EnvironmentObject private var model: EditorModel

    @State private var skyPresetID = "day"
    @State private var showSkyPicker = false
    @State private var showFramePicker = false
    @State private var stackFrames: [URL] = []
    @State private var stackMode: StackMode = .average

    /// 三组天光预设（顶色 / 地平线色）。
    private struct SkyPreset: Identifiable, Equatable {
        var id: String
        var title: String
        var top: UInt32
        var horizon: UInt32
    }
    private static let presets: [SkyPreset] = [
        SkyPreset(id: "day", title: "晴日", top: 0x2E6FB7, horizon: 0xCFE3F2),
        SkyPreset(id: "dusk", title: "黄昏", top: 0x2B3A67, horizon: 0xE8A15C),
        SkyPreset(id: "overcast", title: "阴天", top: 0x8A93A0, horizon: 0xC9CFD6)
    ]

    var body: some View {
        VStack(spacing: 12) {
            skySection
            lightSection
            stackSection
        }
        .fileImporter(isPresented: $showSkyPicker,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.importSky(from: url) }
            }
        }
        .fileImporter(isPresented: $showFramePicker,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                urls.forEach { _ = $0.startAccessingSecurityScopedResource() }
                stackFrames = urls
            }
        }
    }

    // MARK: - 换天空

    private var skySection: some View {
        SectionCard(title: "换天空", subtitle: skySubtitle) {
            Toggle(isOn: skyEnabled) {
                Text("启用").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Picker("区域", selection: $skyPresetID) {
                ForEach(Self.presets) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: skyPresetID) { _, id in
                apply(presetID: id)
            }

            Picker("天的来源", selection: skyMode) {
                ForEach(SkyMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            SliderRow(title: "替换力度", range: 0 ... 100, value: double(\.sky.strength))
            SliderRow(title: "光照匹配", range: 0 ... 100, value: double(\.sky.lightMatch))

            HStack(spacing: 8) {
                Button {
                    Task { await model.detectSky() }
                } label: {
                    Label("检测天空", systemImage: "cloud.sun")
                }
                .buttonStyle(.bordered)
                .disabled(model.document == nil || model.busy != nil)
                Button("导入天图…") { showSkyPicker = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.hasImage)
                Button("清除区域") { model.clearSkyMask() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.document?.skyMask == nil || model.busy != nil)
            }

            Text("天空区域 = 从画面顶边做连通生长（蓝青或近无彩、够亮）。不连到顶边的同色区域（蓝裙、水洼、镜子）不会被换掉。导入天图不足时整段不跑并点名，不拿内置渐变冒充。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("边界：镜面反射、阴影一致、真实光源方向需要生成/深度权重，不在这一版；发丝级边缘同理（羽化近似）。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            notesRow(model.pipelineNotes.filter { $0.contains("[no_sky") })
        }
    }

    private var skySubtitle: String {
        guard model.document?.skyMask != nil else { return "需检测天空" }
        let name = model.params.sky.sourceName
        return model.params.sky.mode == .photo && !name.isEmpty ? "图：\(name)" : "渐变天"
    }

    // MARK: - 虚拟打光

    private var lightSection: some View {
        SectionCard(title: "虚拟打光", subtitle: "只加不减的方向光（梯度近似）") {
            SliderRow(title: "光方向", range: -180 ... 180,
                      format: { Self.directionLabel($0) },
                      value: double(\.light.direction))
            SliderRow(title: "光强", range: 0 ... 100, value: double(\.light.intensity))
            SliderRow(title: "软硬度", range: 1 ... 100,
                      format: { $0 < 34 ? "硬光" : ($0 < 67 ? "中" : "软光") },
                      value: double(\.light.softness))
            SliderRow(title: "光色", range: -100 ... 100,
                      format: { $0 == 0 ? "中性" : ($0 > 0 ? "暖" : "冷") },
                      value: double(\.light.warmth))
            SliderRow(title: "偏暗部", range: 0 ... 100,
                      format: { $0 > 66 ? "补光" : ($0 < 33 ? "主光" : "中间") },
                      value: double(\.light.spread))
            Text("加光量取「画面亮度沿这个方向的抬升」乘回画幅（所以预览档与全分辨率导出同一个力度）。只加不减：加一盏灯不会让其它地方变暗，局部平坦的背景逐比特不动，满力度最多加 0.25 亮度。「偏暗部」拉满是只抬暗部（补光），拉到 0 是沿光方向平铺（主光）。边界：没有深度与法线，转头角度、耳朵自遮挡、头发投影都重打不了。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func directionLabel(_ degrees: Double) -> String {
        let value = Int(degrees.rounded())
        switch value {
        case ..<(-135), 135...: return "\(value)° 左"
        case -135 ..< -45: return "\(value)° 上"
        case -45 ..< 45: return "\(value)° 右"
        default: return "\(value)° 下"
        }
    }

    // MARK: - 多帧堆栈

    private var stackSection: some View {
        SectionCard(title: "多帧堆栈（慢门）", subtitle: stackSubtitle) {
            Picker("堆法", selection: $stackMode) {
                ForEach(StackMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            HStack(spacing: 8) {
                Button {
                    showFramePicker = true
                } label: {
                    Label(stackFrames.isEmpty ? "选择其余帧…" : "更换（\(stackFrames.count) 张）",
                          systemImage: "stack")
                }
                .buttonStyle(.bordered)
                Button("堆栈并替换当前图") {
                    Task { await model.runLongExposure(with: stackFrames, mode: stackMode) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(stackFrames.isEmpty || model.busy != nil || !model.hasImage)
            }
            Text("当前编辑的这张图自动作为参考帧，所以只需再选 1 张以上同机位图。平均 = 真慢门（水/云摊平、噪点下降）；取亮 = 光轨与星轨；取暗 = 去掉路过的人与车。只做整数平移对齐：尺寸不一致会点名而不是静默重采样。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stackSubtitle: String {
        stackFrames.isEmpty ? "需 1 张以上同机位图" : "再加 \(stackFrames.count) 帧"
    }

    // MARK: - 辅助

    /// 把预设的两个色写进参数。只在选预设时写：面板不拿参数反推预设，
    /// 否则用户导入天图后的自定义颜色会被"下一个预设"悄悄盖掉。
    private func apply(presetID: String) {
        guard let preset = Self.presets.first(where: { $0.id == presetID }) else { return }
        model.updateParams { params in
            params.sky.topHex = preset.top
            params.sky.horizonHex = preset.horizon
        }
    }

    @ViewBuilder
    private func notesRow(_ notes: [String]) -> some View {
        ForEach(notes, id: \.self) { note in
            Text(note)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Tokens.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var skyEnabled: Binding<Bool> {
        Binding(get: { model.params.sky.enabled },
                set: { on in model.updateParams { $0.sky.enabled = on } })
    }

    private var skyMode: Binding<SkyMode> {
        Binding(get: { model.params.sky.mode },
                set: { value in model.updateParams { $0.sky.mode = value } })
    }

    private func double(_ keyPath: WritableKeyPath<EditParameters, Double>) -> Binding<Double> {
        Binding(get: { model.params[keyPath: keyPath] },
                set: { value in model.updateParams { $0[keyPath: keyPath] = value } })
    }
}
