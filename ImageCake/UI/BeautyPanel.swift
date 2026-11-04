import SwiftUI

// 人像面板。像素蛋糕把"人像"做成独立一栏，是因为修图的活儿有一半在这里：
// 皮肤（磨皮/祛瑕/匀肤色/祛油光/美白）、五官与妆容（亮眼/牙齿/唇色/腮红/
// 黑眼圈/法令纹 + 妆容模板）、头发与手部、形体（脸型重塑与身体重塑）。各段的
// **依赖不同**，所以分开写清楚：
//   · 皮肤段：只需要一张照片（色域判皮肤，有 α/关键点会更好）；
//   · 区域段、妆容模板与脸型段：必须要 478 点关键点，没检测就整段不生效；
//   · 头发段：靠脸定位发区，同样等关键点；
//   · 手部段：等 Vision 手部姿态（零权重，但要按一次检测）；
//   · 衣物段：等用户在画面上涂的一块区；
//   · 身体段：必须要 17 点身形（而身形又要先抠图拿人像 α）。
// 缺什么就点名什么，而不是把滑杆调了却没反应让人以为是 bug。

struct BeautyPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            dependencySection
            skinSection
            regionSection
            // 妆容模板 / 头发 / 手部 / 衣物：同样改的是画面里的人，但各自等
            // 不同资产（脸、发区、手、涂抹区），所以单独一块而不是混进滑杆里。
            MakeupPanel().environmentObject(model)
            faceShapeSection
            faceStrengthSection
            bodyShapeSection
            oneClickSection
        }
    }

    // MARK: - 逐脸力度（合影）

    /// 区域美化与脸型那两组靠关键点，所以逐脸缩放只作用于它们。
    /// 下标就是"第几张脸（面积从大到小）"，面板上直说是序号而不假装认识人。
    private var faceStrengthSection: some View {
        SectionCard(title: "逐脸力度", subtitle: faceStrengthSubtitle) {
            if faceCount == 0 {
                Text("没检测关键点就逐不了脸。推一下上面任一滑杆不会自动帮你检测，因为那是一次额外的视觉推理。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
                    ForEach(0 ..< faceCount, id: \.self) { index in
                        faceChip("第\(index + 1)张", selected: model.faceSelection == index) {
                            model.faceSelection = index
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        model.facePickingMode.toggle()
                    } label: {
                        Label(model.facePickingMode ? "取消点脸" : "在画布上点脸",
                              systemImage: "hand.tap")
                    }
                    .buttonStyle(.bordered)
                    Button("按脸大小自动") { model.autoFaceScales() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.document?.faceGeometries.isEmpty ?? true)
                        .macHelp("脸占画面 4% 时力度的 100%（跟随全局），小脸按 sqrt(面积比) 降下来，夹在 50…150%。这是一条写死的政策，不是量出来的；没检测到关键点时整段不跑并点名 [no_landmarks]。")
                    Button("全部跟随全局") { model.resetFaceScales() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.document?.params.faceStrength.isNeutral ?? true)
                }

                if let index = model.faceSelection, index < faceCount {
                    SliderRow(title: "第\(index + 1)张脸的力度", range: 0 ... 200,
                              format: { percentFace($0) },
                              value: Binding(get: { model.faceScalePercent(for: index) },
                                             set: { model.setFaceScale($0, for: index) }))
                    Button("这张改回跟随全局") { model.followGlobalFace(index) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(model.faceScalePercent(for: index) == 100)
                } else {
                    Text("选上面一张脸（或点画布上的人）才能单独调它。")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textSecondary)
                }

                Text("100 = 跟随全局滑杆，0 = 这张脸不动，200 = 比全局更强一倍。作用范围只包含靠关键点的那两组（五官区域美化与脸型）；皮肤磨皮与美白不拆（拆了会在脸与脸之间出现质感不一致），身形项不属于任何一张脸。下标按脸大小排序，所以换图或重新检测后会对应到另一张脸——面板会自动取消选中。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var faceStrengthSubtitle: String {
        let set = model.document?.params.faceStrength.scales.filter { $0 != 100 }.count ?? 0
        if faceCount == 0 { return "需关键点" }
        return set == 0 ? "\(faceCount) 张脸均跟随全局" : "已单独调 \(set) 张"
    }

    private func percentFace(_ value: Double) -> String {
        if value == 100 { return "跟随全局" }
        if value == 0 { return "不动" }
        return "\(Int(value.rounded()))%"
    }

    /// 选脸的小按钮。`chip` 是 StylePanel 的私有辅助，不在这里依赖它（
    /// 把两个面板耦在一个私有视图上，改一个会碎另一个）。
    private func faceChip(_ title: String, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(selected ? Tokens.accent.opacity(0.18) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 依赖状态

    private var dependencySection: some View {
        SectionCard(title: "人像依赖", subtitle: "缺件点名") {
            VStack(alignment: .leading, spacing: 4) {
                Label("皮肤掩码：\(model.document?.hasPersonMask == true ? "已有人像 α（背景不会被连进来）" : "尚无人像 α（只按色域判皮肤）")",
                      systemImage: model.document?.hasPersonMask == true ? "checkmark.circle" : "circle")
                    .foregroundStyle(model.document?.hasPersonMask == true ? Tokens.ok : Tokens.textSecondary)
                Label("关键点：\(faceCount == 0 ? "未检测（区域美化与美型不生效）" : "已就绪 · \(faceCount) 张脸逐脸处理")",
                      systemImage: faceCount == 0 ? "circle" : "checkmark.circle")
                    .foregroundStyle(faceCount == 0 ? Tokens.textSecondary : Tokens.ok)
                Label("身形：\(model.document?.bodyAnchors == nil ? "未检测（身体重塑不生效）" : "已就绪")",
                      systemImage: model.document?.bodyAnchors == nil ? "circle" : "checkmark.circle")
                    .foregroundStyle(model.document?.bodyAnchors == nil ? Tokens.textSecondary : Tokens.ok)
            }
            .font(.system(size: 10))
            .fixedSize(horizontal: false, vertical: true)

            ForEach(model.pipelineNotes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("抠图") { Task { await model.runMatting() } }
                    .buttonStyle(.bordered)
                    .disabled(model.document == nil || model.busy != nil)
                Button("检测关键点") { Task { await model.runLandmarks() } }
                    .buttonStyle(.bordered)
                    .disabled(model.document == nil || model.busy != nil)
                Button("检测身形") { Task { await model.runBodyPose() } }
                    .buttonStyle(.bordered)
                    .disabled(model.document == nil || model.busy != nil)
            }
        }
    }

    // MARK: - 皮肤

    private var skinSection: some View {
        SectionCard(title: "皮肤", subtitle: "零权重·频率分离") {
            HStack {
                Text("磨皮模式")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                Picker("", selection: beauty(\.smoothMode)) {
                    Text("平整").tag(0)
                    Text("立体").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            SliderRow(title: "脸部磨皮", range: 0 ... 100, value: beauty(\.skinSmooth))
            SliderRow(title: "身体磨皮", range: 0 ... 100, value: beauty(\.bodySmooth))
            SliderRow(title: "祛瑕疵", range: 0 ... 100, value: beauty(\.blemish))
            SliderRow(title: "肤色统一", range: 0 ... 100, value: beauty(\.toneUnify))
            SliderRow(title: "祛红血丝", range: 0 ... 100, value: beauty(\.redness))
            SliderRow(title: "祛油光", range: 0 ... 100, value: beauty(\.deShine))
            SliderRow(title: "美白", range: 0 ... 100, value: beauty(\.whitening))
            Text("磨皮是频率分离：压掉中低频的不均匀光影，高频纹理按力度保留（满力度仍留约 45%），所以不会「磨到毛孔消失」。模式选「立体」时保留脸上明暗过渡，只压噪点。肤色/亮度四项只作用于皮肤掩码内，掩码外的像素逐比特不变。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 五官与妆容

    private var regionSection: some View {
        SectionCard(title: "五官与妆容", subtitle: "关键点定区·逐脸") {
            SliderRow(title: "亮眼", range: 0 ... 100, value: beauty(\.eyeBright))
            SliderRow(title: "牙齿美白", range: 0 ... 100, value: beauty(\.teethWhiten))
            SliderRow(title: "唇色", range: 0 ... 100, value: beauty(\.lipColor))
            SliderRow(title: "腮红", range: 0 ... 100, value: beauty(\.blush))
            SliderRow(title: "祛黑眼圈", range: 0 ... 100, value: beauty(\.darkCircle))
            SliderRow(title: "祛法令纹", range: 0 ... 100, value: beauty(\.nasolabial))
            SliderRow(title: "镜片祛反光", range: 0 ... 100, value: beauty(\.antiGlare))
            Text("七项都按 478 点栅格化区域（虹膜椭圆、唇内/唇环、两颊、下睑椭圆、鼻翼→嘴角带、眼圈外推的镜片区），合影里每张脸各做一遍。牙齿只处理「够亮且不太饱和」的像素，唇线内侧不会被刷白；亮眼不抬瞳孔核心。祛黑眼圈只抬亮不压暗；祛法令纹只填「比低频邻域暗得多的细线」，脸型自己的阴影（低频）不动。镜片祛反光只压「比邻域亮出来且低饱和」那一段，不编造反光底下的颜色，也不碰彩色镜片与瞳孔。主题妆容/换装需要服装与五官分割权重，不在这一版。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(faceCount == 0 ? 0.55 : 1)
    }

    // MARK: - 脸型重塑

    private var faceShapeSection: some View {
        SectionCard(title: "脸型重塑", subtitle: "关键点驱动液化") {
            SliderRow(title: "瘦颊", range: -100 ... 100, value: beauty(\.slimFace))
            SliderRow(title: "大眼", range: -100 ... 100, value: beauty(\.enlargeEyes))
            SliderRow(title: "缩鼻翼", range: -100 ... 100, value: beauty(\.noseSlim))
            SliderRow(title: "收下颌", range: -100 ... 100, value: beauty(\.jawSlim))
            SliderRow(title: "微笑唇", range: -100 ... 100, value: beauty(\.smileLift))
            SliderRow(title: "下巴", range: -100 ... 100, format: { $0 == 0 ? "原样" : String(Int($0.rounded())) },
                      value: beauty(\.chinAdjust))
            Text("方向由几何决定（朝脸中轴、沿虹膜半径），滑杆只管力度，满力度约 10% 相对位移——再往上就该用笔刷手动推。所有预设形变先于手动液化执行，保护笔刷对两者同样成立。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(faceCount == 0 ? 0.55 : 1)
    }

    // MARK: - 身体重塑

    private var bodyShapeSection: some View {
        SectionCard(title: "身体重塑", subtitle: "17 点驱动") {
            SliderRow(title: "细腰", range: -100 ... 100, value: beauty(\.waistSlim))
            SliderRow(title: "瘦腿", range: -100 ... 100, value: beauty(\.legsSlim))
            SliderRow(title: "增高/长腿", range: -100 ... 100, value: beauty(\.heighten))
            SliderRow(title: "天鹅颈", range: -100 ... 100, value: beauty(\.neckSlim))
            SliderRow(title: "直角肩", range: -100 ... 100, value: beauty(\.shoulderLift))
            Text("增高是真正的分段拉伸：以髋线为锚，髋—踝这一段按比例摊开，锚线以上逐比特不动。直角肩同时做两件事（肩上提 + 斜方肌下压），只提肩会反而更圆肩。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(model.document?.bodyAnchors == nil ? 0.55 : 1)
    }

    // MARK: - 一键

    private var oneClickSection: some View {
        SectionCard(title: "一键", subtitle: "保守默认值") {
            HStack(spacing: 8) {
                Button {
                    applyDefaults(natural: true)
                } label: {
                    Text("一键自然").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(model.document == nil)

                Button {
                    applyDefaults(natural: false)
                } label: {
                    Text("一键明显").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.document == nil)

                Button("全部归零") { model.resetBeauty() }
                    .buttonStyle(.bordered)
                    .disabled(model.document == nil)
            }
            Text("自然档 = 磨皮 40 / 瑕疵 25 / 匀肤色 25 / 祛油光 20 / 美白 15 / 亮眼 25 / 牙齿 20 / 黑眼圈 20 / 法令纹 20，形变全 0。这些是出厂值而不是「AI 分析结果」——真正按人脸特征自适应建议力度需要逐脸的评分，不在这版。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applyDefaults(natural: Bool) {
        let scale = natural ? 1.0 : 1.9
        model.updateParams { params in
            params.beauty.skinSmooth = min(100, 40 * scale)
            params.beauty.bodySmooth = natural ? 20 : 40
            params.beauty.smoothMode = natural ? 1 : 0
            params.beauty.blemish = min(100, 25 * scale)
            params.beauty.toneUnify = min(100, 25 * scale)
            params.beauty.redness = natural ? 15 : 30
            params.beauty.deShine = min(100, 20 * scale)
            params.beauty.whitening = min(100, 15 * scale)
            params.beauty.eyeBright = min(100, 25 * scale)
            params.beauty.teethWhiten = min(100, 20 * scale)
            params.beauty.lipColor = natural ? 15 : 35
            params.beauty.blush = natural ? 10 : 25
            params.beauty.darkCircle = natural ? 20 : 45
            params.beauty.nasolabial = natural ? 20 : 45
        }
    }

    /// 已派生的脸数（逐脸美化的前提）。面板上的所有闸门都读这一个数。
    private var faceCount: Int { model.document?.faceGeometries.count ?? 0 }

    private func beauty(_ keyPath: WritableKeyPath<BeautyParameters, Double>) -> Binding<Double> {
        Binding(
            get: { model.params.beauty[keyPath: keyPath] },
            set: { value in model.updateParams { $0.beauty[keyPath: keyPath] = value } }
        )
    }

    private func beauty(_ keyPath: WritableKeyPath<BeautyParameters, Int>) -> Binding<Int> {
        Binding(
            get: { model.params.beauty[keyPath: keyPath] },
            set: { value in model.updateParams { $0.beauty[keyPath: keyPath] = value } }
        )
    }
}
