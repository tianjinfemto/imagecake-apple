import SwiftUI

// 造型面板：妆容模板、头发、手部、衣物。
//
// 为什么这四件放在一起而不上「风格」：它们改的都是**画面里的人**，而且
// 都各自等一个资产（脸 / 发区 / 手 / 涂抹区）。面板上第一件事永远是告诉用户
// "这项在等什么"，否则会退回"推滑杆没反应 → 以为软件坏了"那种状态。
//
// 每一组都自带依赖行：缺件时把 `[no_landmarks]` / `[no_hand]` /
// `[no_garment_region]` 原样显示出来（与底栏同一份判定，来自
// `ImageDocument.pipelineWarnings`），不在这里另写一套条件。

struct MakeupPanel: View {
    @EnvironmentObject private var model: EditorModel

    @State private var hairColorID = "brown"

    /// 六个发色预设。不给开放拾色器的理由与换天空那两个色一样：发色必须
    /// 落在“真头发能有的颜色”里才不像假发，而自由取色一半概率取到荧光色。
    /// 需要真自由色的时候，目标色就是 `hair.colorHex`，面板换预设时直接写它。
    private struct HairTone: Identifiable, Equatable {
        var id: String
        var title: String
        var hex: UInt32
    }
    private static let hairTones: [HairTone] = [
        HairTone(id: "black", title: "黑", hex: 0x1A_17_15),
        HairTone(id: "brown", title: "深棕", hex: 0x6B_4A_34),
        HairTone(id: "linen", title: "亚麻", hex: 0xB8_92_63),
        HairTone(id: "copper", title: "铜红", hex: 0x9E_4B_2A),
        HairTone(id: "wine", title: "酒红", hex: 0x63_1F_30),
        HairTone(id: "ash", title: "蓝黑", hex: 0x2C_33_42)
    ]

    var body: some View {
        VStack(spacing: 12) {
            makeupSection
            hairSection
            handSection
            garmentSection
        }
    }

    // MARK: - 妆容模板

    private var makeupSection: some View {
        SectionCard(title: "妆容模板", subtitle: makeupSubtitle) {
            Picker("模板", selection: styleBinding) {
                Text("不用").tag("")
                ForEach(MakeupEngine.looks) { look in
                    Text(look.title).tag(look.id)
                }
            }
            SliderRow(title: "整体浓淡", range: 0 ... 100, value: double(\.makeup.strength))
            if !model.params.makeup.styleID.isEmpty {
                Text("五层按模板叠：眼影 → 眼线 → 填眉 → 唇 → 腮红。区域全部由 478 点派生，色度按满力度靠、亮度只靠一半——所以唇纹和眉骨阴影不会被关闭。真实妆容分割/发丝级眼窝要权重，不在这版。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            notesRow(model.pipelineNotes.filter { $0.contains("[no_landmarks]") || $0.contains("[no_makeup]") })
        }
        .opacity(faceCount == 0 ? 0.55 : 1)
    }

    private var makeupSubtitle: String {
        guard let look = MakeupEngine.look(id: model.params.makeup.styleID) else { return "关键点定区" }
        return "\(look.title) · 逐脸"
    }

    // MARK: - 头发

    private var hairSection: some View {
        SectionCard(title: "头发", subtitle: "色域几何定区") {
            SliderRow(title: "去毛躁", range: 0 ... 100, value: double(\.hair.smooth))
            SliderRow(title: "光泽", range: -100 ... 100,
                      format: { $0 == 0 ? "原样" : ($0 > 0 ? "加光泽" : "压亮丝") },
                      value: double(\.hair.shine))
            SliderRow(title: "发色饱和", range: 0 ... 100, value: double(\.hair.tint))
            SliderRow(title: "祛碎发", range: 0 ... 100, value: double(\.hair.tame))

            Text("换个发色").font(.system(size: 10)).foregroundStyle(Tokens.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                ForEach(Self.hairTones) { tone in
                    Button {
                        hairColorID = tone.id
                        model.updateParams { $0.hair.colorHex = tone.hex }
                    } label: {
                        Text(tone.title)
                            .font(.system(size: 10))
                            .padding(.vertical, 4).frame(maxWidth: .infinity)
                            .background(hairColorID == tone.id ? Tokens.accent.opacity(0.18)
                                                                : Color.clear)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            SliderRow(title: "换发色", range: 0 ... 100,
                      format: { $0 == 0 ? "不换" : String(Int($0.rounded())) },
                      value: double(\.hair.colorStrength))

            Text("发区 = 不在皮肤色域 ∧ 在头部框内 ∧ 额头以上或脸侧带状区。软阈值只削小振幅的碎边，超过阈值的真实发丝原样保留。换发色只推色度不动亮度（亮度一动就没体积了）；祛碎发只作用于发区边缘那一圈环带。边界：发丝级蒙版要分割权重；齐肩短发与衣领交界仍会误判。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            notesRow(model.pipelineNotes.filter { $0.contains("头发美化") })
        }
        .opacity(faceCount == 0 ? 0.55 : 1)
    }

    // MARK: - 手部

    private var handSection: some View {
        SectionCard(title: "手部", subtitle: handSubtitle) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.runHandPose() }
                } label: {
                    Label("检测手部", systemImage: "hand.raised")
                }
                .buttonStyle(.bordered)
                .disabled(model.document == nil || model.busy != nil)
                Button("清除") { model.clearHandHulls() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled((model.document?.handHulls.isEmpty ?? true) || model.busy != nil)
            }
            SliderRow(title: "磨皮", range: 0 ... 100, value: double(\.hand.smooth))
            SliderRow(title: "匀亮度", range: 0 ... 100, value: double(\.hand.evenTone))
            SliderRow(title: "祛红", range: 0 ... 100, value: double(\.hand.redness))
            Text("手的位置用 Vision 手部姿态（零权重、双端自带）取关节点再做凸包，再与皮肤色域相与——所以指甲与手里的物件不会被顺手磨平。凸包会把指缘一小圈背景圈进来，因此三层力度都偏温和。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            notesRow(model.pipelineNotes.filter { $0.contains("[no_hand]") })
        }
    }

    private var handSubtitle: String {
        let n = model.document?.handHulls.count ?? 0
        return n == 0 ? "需检测手部" : "已定位 \(n) 只手"
    }

    // MARK: - 衣物

    private var garmentSection: some View {
        SectionCard(title: "衣物祛褶", subtitle: garmentSubtitle) {
            SliderRow(title: "祛褶", range: 0 ... 100, value: double(\.garment.deWrinkle))
            HStack(spacing: 8) {
                Button {
                    model.brushTool = .garment
                } label: {
                    Label("去画布涂一块", systemImage: "tshirt")
                }
                .buttonStyle(.bordered)
                .disabled(!model.hasImage)
                Button("清除衣物区") { model.clearGarmentStrokes() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled((model.document?.brush.garments.isEmpty ?? true) || model.busy != nil)
            }
            Text("褶皱是光影问题：只把 base 层的低频推向更平的 deep，布纹（在 `source − base` 那一段）逐比特保留，所以拉满也不会变成塑料布。全自动祛褶需要服装分割来区分褶子与接缝/图案/腰带阴影，因此这一版明确要涂。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            notesRow(model.pipelineNotes.filter { $0.contains("[no_garment_region]") })
        }
    }

    private var garmentSubtitle: String {
        let strokes = model.document?.brush.garments.count ?? 0
        return strokes == 0 ? "未涂选区" : "已涂 \(strokes) 笔"
    }

    // MARK: - 辅助

    private var faceCount: Int { model.document?.faceGeometries.count ?? 0 }

    @ViewBuilder
    private func notesRow(_ notes: [String]) -> some View {
        ForEach(notes, id: \.self) { note in
            Text(note)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Tokens.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var styleBinding: Binding<String> {
        Binding(get: { model.params.makeup.styleID },
                set: { value in model.updateParams { $0.makeup.styleID = value } })
    }

    private func double(_ keyPath: WritableKeyPath<EditParameters, Double>) -> Binding<Double> {
        Binding(get: { model.params[keyPath: keyPath] },
                set: { value in model.updateParams { $0[keyPath: keyPath] = value } })
    }
}
