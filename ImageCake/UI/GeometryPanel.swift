import SwiftUI

// 几何面板：旋转 / 翻转 / 裁剪 / 智能构图 / 证件照。
//
// 几何变换存 ImageDocument.geometry 而非 EditParameters：
// 旋转/裁剪改画布尺寸，不是调色参数，不进预设。
//
// 几何在渲染链的**最前**，而且不会重映射已有笔迹/AI 资产的坐标，
// 所以面板上把「先定构图再落笔」写在旋转卡片里：先画完再旋转，
// 旧笔迹会落在转过之后的不同内容上。

struct GeometryPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            rotationSection
            flipSection
            cropSection
            smartCropSection
            IDPhotoSection().environmentObject(model)
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
            Text("几何跑在渲染链最前且不会重映射已有笔迹/抠图遮罩：先定构图（旋转/裁剪）再抠图与落笔。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

// MARK: - 证件照

/// 规格是数据不是滑杆：mm 尺寸与头部占比一旦写错就是「退片」，
/// 所以规格表集中在 IDPhoto.specs（带断言），面板只负责选型与应用。
private struct IDPhotoSection: View {
    @EnvironmentObject private var model: EditorModel
    @State private var specID = "one"
    @State private var paperID = "6inch"

    var body: some View {
        SectionCard(title: "证件照", subtitle: "规格/构图/排版") {
            Picker("规格", selection: $specID) {
                ForEach(IDPhoto.specs) { spec in
                    Text(spec.title).tag(spec.id)
                }
            }
            Button {
                model.applyIDPhoto(specID: specID)
            } label: {
                Label("按规格定构图", systemImage: "person.crop.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.accent)
            .disabled(!model.hasImage)

            Picker("相纸", selection: $paperID) {
                ForEach(IDPhoto.papers, id: \.id) { paper in
                    Text(paper.title).tag(paper.id)
                }
            }
            HStack(spacing: 8) {
                Button("排版到相纸") { model.composeIDPhotoSheet(specID: specID, paperID: paperID) }
                    .buttonStyle(.bordered)
                    .disabled(!model.hasImage)
                Button("取消排版") { model.clearIDPhotoSheet() }
                    .buttonStyle(.bordered)
                    .disabled(model.document?.idPhotoSheet == nil)
            }
            if let sheet = model.document?.idPhotoSheet {
                Text("已排版：\(sheet.paper.title) · \(sheet.count) 张 · \(sheet.canvas.width)×\(sheet.canvas.height)px")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.ok)
            }
            Text("构图按头部定位（需先检测关键点，没检测就按画面中心并点名 [no_face_box]）；底色只在已抠图时自动切到规格推荐色。排版在导出的最后一步生效，尺寸固定为相纸的 \(IDPhoto.dpi)dpi 像素。")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}