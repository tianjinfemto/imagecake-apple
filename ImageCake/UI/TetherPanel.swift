import SwiftUI
import UniformTypeIdentifiers

// 联机拍摄面板（工具栏「联机」按钮打开的 sheet）。
//
// 为什么是 sheet 而不是右侧检查器里的一张卡片：这台设备**决定输入**，
// 用户要在它和画布之间来回看（取景、按快门、看回片），检查器那 300pt
// 的一栏放不下"设备列表 + 参数 + 回片预览"三样东西。
//
// 面板只做四件事：列设备、接上、按快门（含连拍队列）、把回片送进编辑器。
// 决策（选哪台、叫什么名、拍几张怎么排队）全在 `TetherPlan` 里，是纯函数
// 且有断言；这里只留硬件调用与它的点名。
//
// 诚实的边界（面板上直接写出来，不藏在文档里）：
//   · macOS 上的 USB 相机/采集卡这条路稳定；
//   · iPad 上的 USB 相机需要 Apple 的 external-camera entitlement，
//     未签名侧载包拿不到 → 列表会是空的，这里会点名 `[no_camera]`；
//   · 相机原厂联机协议（EDSDK / Imaging Edge 那一类）不在本项目范围。

struct TetherPanel: View {
    @EnvironmentObject private var model: EditorModel
    var onClose: () -> Void = {}

    @State private var showDirectoryPicker = false
    @State private var outputDirectory: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Tokens.border)
            ScrollView {
                VStack(spacing: 12) {
                    deviceSection
                    settingsSection
                    shootSection
                }
                .padding(12)
            }
        }
        .background(Tokens.bgWindow)
        .frame(minWidth: 460, minHeight: 420)
        .task { await model.refreshTetherDevices() }
        .fileImporter(isPresented: $showDirectoryPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()
                outputDirectory = url
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("联机拍摄").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text("相机作为系统输入设备：插上就拍，回片直接进编辑器")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer()
            Button("关闭") { onClose() }
                .buttonStyle(.bordered)
        }
        .padding(12)
    }

    // MARK: - 设备

    private var deviceSection: some View {
        SectionCard(title: "设备", subtitle: "\(model.tetherDevices.count) 台"
            + (model.tetherConnected ? " · 已接上" : "")) {
            if model.tetherDevices.isEmpty {
                Text("系统没有列出可用的视频设备。检查：相机已开机并接入 USB；iPad 还需要 external-camera entitlement；macOS 需在系统设置里允许本 App 使用相机。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("相机", selection: $model.tetherDeviceID) {
                    ForEach(model.tetherDevices) { device in
                        Text(device.title + (device.isUsable ? "" : "（不可用）")).tag(Optional(device.id))
                    }
                }
                HStack(spacing: 8) {
                    Button("刷新列表") { Task { await model.refreshTetherDevices() } }
                        .buttonStyle(.bordered)
                    Button(model.tetherConnected ? "断开" : "接上") {
                        if model.tetherConnected {
                            model.disconnectTether()
                        } else {
                            Task { await model.connectTether() }
                        }
                    }
                    .buttonStyle(model.tetherConnected ? .bordered : .borderedProminent)
                    .tint(Tokens.accent)
                }
                .disabled(model.busy != nil)
            }
            if !model.tetherNote.isEmpty {
                Text(model.tetherNote)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(model.tetherNote.contains("[") ? Tokens.danger : Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 设置

    private var settingsSection: some View {
        SectionCard(title: "快门与落盘", subtitle: outputDirectory?.lastPathComponent ?? "未选目录") {
            SliderRow(title: "连拍张数", range: 1 ... 60, step: 1,
                      format: { "\(Int($0.rounded())) 张" },
                      value: $model.tetherSettings.burstCount)
            SliderRow(title: "间隔", range: 0 ... 10, step: 0.1,
                      format: { String(format: "%.1f s", $0) },
                      value: $model.tetherSettings.intervalSeconds)
            Toggle(isOn: $model.tetherSettings.openInEditor) {
                Text("拍完直接进编辑器").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Toggle(isOn: $model.tetherSettings.autoImport) {
                Text("同时落盘到下面这个目录").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                showDirectoryPicker = true
            } label: {
                Label(outputDirectory == nil ? "选择落盘目录…" : "更换目录：\(outputDirectory!.lastPathComponent)",
                      systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!model.tetherSettings.autoImport)

            Text("文件名固定 `tether-<时间戳>-<序号>.jpg`：联机拍的图还没有原始文件名，硬套 `{stem}` 模板会得到一串无主文件名。超过 60 张的队列会被截断并点名 —— 长队列在 iPad 上会被后台挂起，静默停止比直接拒绝更糟。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 拍摄

    private var shootSection: some View {
        SectionCard(title: "回片", subtitle: model.tetherLastShot == nil ? "还没拍过" : "已有预览") {
            HStack(spacing: 8) {
                Button {
                    Task { await model.shootTetherBurst(to: model.tetherSettings.autoImport ? outputDirectory : nil) }
                } label: {
                    Label("拍 \(model.tetherSettings.burst) 张", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(!model.tetherConnected || model.busy != nil)
            }
            if let shot = model.tetherLastShot {
                Image(decorative: shot, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.corner)
                        .stroke(Tokens.border, lineWidth: 1))
            }
            if !model.tetherConnected {
                Text("先接上相机再拍。列表为空时看上面「设备」那段的原因。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
