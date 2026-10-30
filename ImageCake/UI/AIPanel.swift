import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// AI 面板。四块：人像 α、背景、智能消除、导出端 AI。
//
// 每一块都把"这一步靠什么跑的"写出来（path / note），因为缺权重时的
// 回退路径与模型路径在成品上可能一模一样——用户有权知道刚才那 0.5 秒
// 跑的是 MODNet 还是 Vision。

struct AIPanel: View {
    @EnvironmentObject private var model: EditorModel

    private struct Swatch: Identifiable {
        let name: String
        let color: Color
        var id: String { name }
    }

    private let swatches: [Swatch] = [
        Swatch(name: "证件白", color: Color(hex: 0xFFFFFF)),
        Swatch(name: "证件蓝", color: Color(hex: 0x3A6EA5)),
        Swatch(name: "证件红", color: Color(hex: 0xD94F4F)),
        Swatch(name: "深灰", color: Color(hex: 0x2B2B2B)),
        Swatch(name: "米色", color: Color(hex: 0xE8E2D0)),
    ]

    var body: some View {
        VStack(spacing: 12) {
            personSection
            backgroundSection
            inpaintSection
            landmarksSection
            poseSection
            attrSection
            oldPhotoSection
            exportAISection
        }
    }

    // MARK: - 人像

    private var personSection: some View {
        SectionCard(title: "人像抠图", subtitle: model.document?.hasPersonMask == true ? "已有人像 α" : "未抠图") {
            HStack(spacing: 8) {
                Button {
                    Task { await model.runMatting() }
                } label: {
                    Label("抠图", systemImage: "person.crop.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(model.document == nil || model.busy != nil)

                Button("清除") { model.clearMask() }
                    .buttonStyle(.bordered)
                    .disabled(model.document?.hasPersonMask != true)
            }

            if model.document?.hasPersonMask == true {
                Toggle("显示 α 叠层", isOn: $model.showMask)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if !model.lastAIPath.isEmpty {
                HStack(spacing: 6) {
                    TokenBadge(text: "path=\(model.lastAIPath)", tone: .good)
                    if !model.lastAINote.isEmpty {
                        Text(model.lastAINote)
                            .font(.system(size: 10))
                            .foregroundStyle(Tokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("MODNet 出连续 α（发丝级软边）；缺权重或前向失败时回退 Vision 分割，并在上面点名。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 背景

    private var backgroundSection: some View {
        SectionCard(title: "背景", subtitle: "换底色 / 虚化") {
            Toggle("启用背景处理", isOn: Binding(
                get: { model.params.bgEnabled },
                set: { value in model.updateParams { $0.bgEnabled = value } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 8) {
                ForEach(swatches) { item in
                    Circle()
                        .fill(item.color)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Tokens.border, lineWidth: 1))
                        .onTapGesture { setColor(item.color) }
                        .macHelp(item.name)
                }
                ColorPicker("", selection: backgroundColor, supportsOpacity: false)
                    .labelsHidden()
            }
            .opacity(model.params.bgEnabled ? 1 : 0.5)
            .allowsHitTesting(model.params.bgEnabled)

            SliderRow(title: "背景虚化", range: 0 ... 100,
                      value: Binding(
                        get: { model.params.bgBlur },
                        set: { value in model.updateParams { $0.bgBlur = value } }
                      ))
                .opacity(model.params.bgEnabled ? 1 : 0.5)
                .allowsHitTesting(model.params.bgEnabled)

            SliderRow(title: "边缘去色溢出", range: 0 ... 100,
                      value: Binding(
                        get: { model.params.defringe },
                        set: { value in model.updateParams { $0.defringe = value } }
                      ))
                .opacity(model.params.bgEnabled ? 1 : 0.5)
                .allowsHitTesting(model.params.bgEnabled)

            Text("抠图边缘的半透明像素混着原背景色（白底发白、绿幕发绿）。这一项用邻域里的实心颜色替换它们，α 不变；0 = 关，找不到实心邻居的像素原样保留。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(model.params.bgEnabled ? 1 : 0.5)

            if model.params.bgEnabled && model.document?.hasPersonMask != true {
                Text("[no_mask] 还没有人像 α：先抠图，否则这一整段会被跳过（导出报告里也会点名）。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 消除

    private var inpaintSection: some View {
        SectionCard(title: "智能消除", subtitle: "LaMa 局部修复") {
            Toggle("在画布上框选", isOn: $model.selectionMode)
                .toggleStyle(.switch)
                .controlSize(.small)

            if let selection = model.selection {
                let size = model.canvasSize
                Text("选区 \(Int(selection.width * Double(size.width)))×\(Int(selection.height * Double(size.height))) px")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
            } else {
                Text("打开框选后，在图上拖一个框，把要去掉的东西圈住。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await model.runInpaint() }
                } label: {
                    Label("消除选区", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(model.document == nil || model.selection == nil || model.busy != nil)

                Menu("补丁") {
                    Button("撤销最近一次") { model.undoLastPatch() }
                    Button("清除全部") { model.clearPatches() }
                }
                .buttonStyle(.bordered)
                .disabled(model.document?.patches.isEmpty ?? true)
            }

            Text("修复以「相对量」缓存：改曝光后补丁仍然有效，不会在遮罩外沿留一圈旧亮边。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 关键点

    private var landmarksSection: some View {
        SectionCard(title: "人脸关键点", subtitle: model.faceLandmarksResult?.landmarks.count == 0 ? nil : "\(model.faceLandmarksResult?.landmarks.count ?? 0) 张脸") {
            Button {
                Task { await model.runLandmarks() }
            } label: {
                Label("检测 478 点关键点", systemImage: "face.dashed")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.document == nil)
            if let result = model.faceLandmarksResult, !result.report.note.isEmpty {
                Text(result.report.note)
                    .font(.system(size: 10))
                    .foregroundStyle(result.report.ok ? Tokens.textSecondary : Tokens.danger)
            }
        }
    }

    // MARK: - 身形

    private var poseSection: some View {
        SectionCard(title: "身形检测", subtitle: model.bodyPoseResult?.joints.isEmpty == false ? "\(model.bodyPoseResult?.joints.count ?? 0) 点" : nil) {
            Button {
                Task { await model.runBodyPose() }
            } label: {
                Label("检测 17 点身形", systemImage: "figure.dance")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.document == nil)
            if let result = model.bodyPoseResult, !result.report.note.isEmpty {
                Text(result.report.note)
                    .font(.system(size: 10))
                    .foregroundStyle(result.report.ok ? Tokens.textSecondary : Tokens.danger)
            }
            Text("需先抠图获取人像区域。美体液化按关节点驱动。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
        }
    }

    // MARK: - 年龄 / 性别

    private var attrSection: some View {
        SectionCard(title: "年龄 / 性别", subtitle: model.faceAttrResult?.attrs.isEmpty == false ? "\(model.faceAttrResult?.attrs.count ?? 0) 张脸" : nil) {
            Button {
                Task { await model.runFaceAttr() }
            } label: {
                Label("识别属性", systemImage: "person.text.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.document == nil)
            if let result = model.faceAttrResult, !result.attrs.isEmpty {
                ForEach(Array(result.attrs.enumerated()), id: \.offset) { _, attr in
                    Text("脸 \(attr.faceBox.midX.formatted()) : \(attr.age) 岁 · \(attr.gender)")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textSecondary)
                }
            }
        }
    }

    // MARK: - 老照片修复

    private var oldPhotoSection: some View {
        SectionCard(title: "老照片修复", subtitle: model.document?.oldPhotoRestore == true ? "已开" : "已关") {
            Button {
                model.toggleOldPhoto()
            } label: {
                Label(model.document?.oldPhotoRestore == true ? "关闭修复" : "开启修复",
                      systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(model.document?.oldPhotoRestore == true ? Tokens.accent : nil)
            Text("褪色恢复（灰世界白平衡）+ 划痕去除（形态学开运算）。零权重、确定性。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
        }
    }

    // MARK: - 导出端 AI

    private var exportAISection: some View {
        SectionCard(title: "导出端 AI", subtitle: "只挂导出，不进预览") {
            SliderRow(title: "面部重绘", range: 0 ... 100,
                      format: { $0 == 0 ? "关" : String(Int($0.rounded())) },
                      value: Binding(
                        get: { model.params.faceRestore },
                        set: { value in model.updateParams { $0.faceRestore = value } }
                      ))
            Text("GFPGAN 512×512，单脸约 2 秒；闭眼不修（会点名 [closed_eyes]）。权重许可受限，不随包。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("AI 超清")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { model.params.superRes },
                    set: { value in model.updateParams { $0.superRes = value } }
                )) {
                    Text("关").tag(0)
                    Text("2x").tag(2)
                    Text("4x").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            Text("ESRGAN x4v3 分块跑；4x 的 12MP 需要几分钟。输出上限按设备内存给（4GB 约 12MP、6GB 约 32MP、8GB 60MP），超出会点名拒绝。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 颜色绑定

    private var backgroundColor: Binding<Color> {
        Binding(
            get: {
                Color(.sRGB,
                      red: model.params.bgR / 255,
                      green: model.params.bgG / 255,
                      blue: model.params.bgB / 255,
                      opacity: 1)
            },
            set: { color in
                #if os(iOS)
                let ui = UIColor(color)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                _ = ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                model.updateParams {
                    $0.bgR = Double(r) * 255
                    $0.bgG = Double(g) * 255
                    $0.bgB = Double(b) * 255
                }
                #else
                let ns = NSColor(color)
                let converted = ns.usingColorSpace(.sRGB) ?? ns
                model.updateParams {
                    $0.bgR = Double(converted.redComponent) * 255
                    $0.bgG = Double(converted.greenComponent) * 255
                    $0.bgB = Double(converted.blueComponent) * 255
                }
                #endif
            }
        )
    }

    private func setColor(_ color: Color) {
        backgroundColor.wrappedValue = color
    }
}
