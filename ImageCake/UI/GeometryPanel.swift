import SwiftUI

// 几何面板：旋转 / 翻转 / 裁剪 / 智能构图。
//
// 几何变换存 ImageDocument.geometry 而非 EditParameters：
// 旋转/裁剪改画布尺寸，不是调色参数，不进预设。

struct GeometryPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            rotationSection
            flipSection
            cropSection
            smartCropSection
        }
    }

    private var rotationSection: some View {
        SectionCard(title: "旋转") {
            HStack(spacing: 8) {
                Button { model.rotate90(clockwise: false) } label: {
                    Label("左转 90°", systemImage: "rotate.left")
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button { model.rotate90(clockwise: true) } label: {
                    Label("右转 90°", systemImage: "rotate.right")
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
            if let angle = model.document?.geometry.rotation, angle != 0 {
                Text("当前旋转：\(Int(angle))°")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
    }

    private var flipSection: some View {
        SectionCard(title: "翻转") {
            HStack(spacing: 8) {
                Button { model.flip(horizontal: true) } label: {
                    Label("水平翻转", systemImage: "arrow.left.and.right")
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button { model.flip(horizontal: false) } label: {
                    Label("垂直翻转", systemImage: "arrow.up.and.down")
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var cropSection: some View {
        SectionCard(title: "裁剪") {
            if let crop = model.document?.geometry.cropRect {
                Text("裁剪框：(\(String(format: "%.2f", crop.minX)), \(String(format: "%.2f", crop.minY))) \(String(format: "%.2f", crop.width))×\(String(format: "%.2f", crop.height))")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                Button("清除裁剪") { model.resetGeometry() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Tokens.danger)
            } else {
                Text("在画布上框选区域后点「应用裁剪」")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                if let selection = model.selection {
                    Button("应用选区裁剪") { model.crop(to: selection) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var smartCropSection: some View {
        SectionCard(title: "智能构图", subtitle: "基于人脸关键点") {
            Button {
                Task { await model.suggestSmartCrop() }
            } label: {
                Label("建议裁剪框", systemImage: "crop")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("检测人脸与主体位置，按三分法留 margin 建议裁剪框。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
        }
    }
}