import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

// 风格面板。四块：滤镜（内置风格 + 导入 .cube）、镜头校正、本地调节、场景
// （换天空 / 虚拟打光 / 多帧堆栈）。
//
// 与「调色」面板的分工：调色面板是**逐通道数学**（曝光/曲线/HSL/色轮），
// 这里三块都是"整张图的观感"或"按区域二次调"。像素蛋糕把 70+ 滤镜放在
// 最显眼的一栏，是因为商业出片的一半工作量在"统一调性"而不是逐张细调——
// 所以滤镜支持强度混合（0 = 逐比特原图），一组图才能用同一个滤镜不同浓淡。

struct StylePanel: View {
    @EnvironmentObject private var model: EditorModel

    @State private var showLUTImport = false
    @State private var localShape = 0
    @State private var localExposure = 0.0
    @State private var localContrast = 0.0
    @State private var localSaturation = 0.0
    @State private var localTemperature = 0.0
    @State private var localTint = 0.0
    @State private var localSharpness = 0.0
    @State private var localFeather = 0.03

    var body: some View {
        VStack(spacing: 12) {
            filterSection
            lensSection
            localSection
            // 换天空 / 虚拟打光 / 多帧堆栈：同属"改画面里的光与背景"，
            // 而且都在这张图定下来之后才跑（顺序见 ImageDocument.render）。
            ScenePanel().environmentObject(model)
        }
        .fileImporter(isPresented: $showLUTImport,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importLUT(from: url)
            }
        }
    }

    // MARK: - 滤镜

    private var filterSection: some View {
        SectionCard(title: "滤镜", subtitle: "内置风格 + .cube") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)], spacing: 6) {
                chip(title: "无", selected: model.params.filter.style.isEmpty) {
                    model.setFilterStyle("")
                }
                ForEach(FilterEngine.styles, id: \.id) { style in
                    chip(title: style.title, selected: model.params.filter.style == style.id) {
                        model.setFilterStyle(style.id)
                    }
                }
                ForEach(model.availableFilters.filter { FilterEngine.style(id: $0) == nil }, id: \.self) { name in
                    chip(title: name, selected: model.params.filter.style == name) {
                        model.setFilterStyle(name)
                    }
                }
            }

            SliderRow(title: "强度", range: 0 ... 100,
                      format: { $0 == 100 ? "满" : String(Int($0.rounded())) },
                      value: Binding(get: { model.params.filter.strength },
                                     set: { model.setFilterStrength($0) }))

            Button {
                showLUTImport = true
            } label: {
                Label("导入 .cube 滤镜表…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("内置 8 种风格是代码里定义的逐点映射（采样成 17³ 的表），零依赖、可复现。导入的表落在「文件 → ImageCake/LUTs」，预设里只登记名字：换设备时找不到表会点名 [no_lut:名字] 并跳过滤镜，而不是给你一张没加滤镜的图。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(selected ? Tokens.accent.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Tokens.accent : Tokens.border, lineWidth: 1))
                .foregroundStyle(selected ? Tokens.accent : Tokens.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!model.hasImage)
    }

    // MARK: - 镜头

    private var lensSection: some View {
        SectionCard(title: "镜头与画质", subtitle: "校正 + 氛围层") {
            SliderRow(title: "畸变", range: -100 ... 100,
                      format: { $0 > 0 ? "桶形 \(Int($0))" : ($0 < 0 ? "枕形 \(Int(-$0))" : "关") },
                      value: lens(\.distortion))
            SliderRow(title: "色差", range: -100 ... 100,
                      format: { $0 == 0 ? "关" : String(Int($0.rounded())) },
                      value: lens(\.chromaticAberration))
            SliderRow(title: "暗角", range: 0 ... 100,
                      format: { $0 == 0 ? "关" : String(Int($0.rounded())) },
                      value: lens(\.vignette))
            SliderRow(title: "暗角过渡", range: 1 ... 10, step: 0.1,
                      format: { String(format: "%.1f", $0) },
                      value: lens(\.vignetteFalloff))
            SliderRow(title: "颗粒", range: 0 ... 100,
                      format: { $0 == 0 ? "关" : String(Int($0.rounded())) },
                      value: lens(\.grain))
            Text("畸变与色差改像素位置，跑在笔刷之前；暗角与颗粒是输出层，跑在最后一道。颗粒是确定性哈希（同坐标同值），所以两次导出逐比特一致。镜头**参数校正**（按机型库的 profil）不在这一版——那需要一份机型/镜头数据库。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 本地调节

    private var localSection: some View {
        SectionCard(title: "本地调节", subtitle: "\(model.document?.localAdjustments.count ?? 0) 个选区") {
            Picker("选区形状", selection: $localShape) {
                Text("径向").tag(0)
                Text("线性").tag(1)
                Text("画笔").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if localShape < 2 {
                if model.selection == nil {
                    Text("先在画布上框一块（AI 面板打开「在画布上框选」，或把笔刷工具设为「无」后直接拖）。径向用框的中心与半径，线性沿框的对角做坡道。")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("已框选：\(Int((model.selection?.width ?? 0) * Double(model.canvasSize.width)))×\(Int((model.selection?.height ?? 0) * Double(model.canvasSize.height))) px")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                }
            } else {
                Text(model.pendingLocalStroke == nil
                     ? "把笔刷工具设为「选区」，在画布上涂一笔，再回来点添加。"
                     : "已采集画笔选区（\(model.pendingLocalStroke?.points.count ?? 0) 点）")
                    .font(.system(size: 10))
                    .foregroundStyle(model.pendingLocalStroke == nil ? Tokens.textSecondary : Tokens.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SliderRow(title: "曝光", range: -2 ... 2, step: 0.05,
                      format: { String(format: "%+.2f EV", $0) }, value: $localExposure)
            SliderRow(title: "对比", range: -100 ... 100, value: $localContrast)
            SliderRow(title: "饱和度", range: -100 ... 100, value: $localSaturation)
            SliderRow(title: "色温", range: -100 ... 100, value: $localTemperature)
            SliderRow(title: "色调", range: -100 ... 100, value: $localTint)
            SliderRow(title: "锐化", range: 0 ... 100, value: $localSharpness)
            SliderRow(title: "羽化", range: 0 ... 0.2, step: 0.005,
                      format: { String(format: "%.3f", $0) }, value: $localFeather)

            HStack(spacing: 8) {
                Button {
                    addAdjustment()
                } label: {
                    Label("添加", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(!model.hasImage)

                Button("清除全部") { model.clearLocalAdjustments() }
                    .buttonStyle(.bordered)
                    .disabled(model.document?.localAdjustments.isEmpty ?? true)
            }
        }
    }

    private func addAdjustment() {
        let parameters = (exposure: localExposure, contrast: localContrast, saturation: localSaturation,
                          temperature: localTemperature, tint: localTint, sharpness: localSharpness,
                          feather: localFeather)
        if localShape == 2 {
            let ok = model.commitPendingLocalStroke(exposure: parameters.exposure,
                                                    contrast: parameters.contrast,
                                                    saturation: parameters.saturation,
                                                    temperature: parameters.temperature,
                                                    tint: parameters.tint,
                                                    sharpness: parameters.sharpness,
                                                    feather: parameters.feather)
            if !ok { model.alert = "先涂一笔画笔选区：把笔刷工具设为「选区」，在画布上拖一下。" }
            return
        }
        guard let selection = model.selection, let mask = shapeMask(from: selection) else {
            model.alert = "先在画布上框一块"
            return
        }
        model.addLocalAdjustment(LocalAdjustment(mask: mask,
                                                 exposure: parameters.exposure,
                                                 contrast: parameters.contrast,
                                                 saturation: parameters.saturation,
                                                 temperature: parameters.temperature,
                                                 tint: parameters.tint,
                                                 sharpness: parameters.sharpness,
                                                 feather: parameters.feather))
        model.selection = nil
        model.selectionMode = false
    }

    /// 把归一化框换算成径向/线性选区。半径按**像素**算再除以长边——
    /// 因为 LocalMask 的半径口径是"相对长边"，直接用框的归一化宽高会把
    /// 竖图的正圆选区拉成椭圆。
    private func shapeMask(from rect: CGRect) -> LocalMask? {
        let size = model.canvasSize
        guard size.longEdge > 0 else { return nil }
        let wide = rect.width * Double(size.width)
        let tall = rect.height * Double(size.height)
        guard wide > 1, tall > 1 else { return nil }
        if localShape == 0 {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = max(wide, tall) / 2 / Double(size.longEdge)
            return .radial(center: center, radius: radius)
        }
        let halfWidth = min(wide, tall) / 2 / Double(size.longEdge)
        return .linear(from: CGPoint(x: rect.minX, y: rect.minY),
                       to: CGPoint(x: rect.maxX, y: rect.maxY),
                       width: halfWidth)
    }

    private func lens(_ keyPath: WritableKeyPath<LensParameters, Double>) -> Binding<Double> {
        Binding(
            get: { model.params.lens[keyPath: keyPath] },
            set: { value in model.updateParams { $0.lens[keyPath: keyPath] = value } }
        )
    }
}
