import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// 装饰面板：水印 / 边框 / 文字贴纸。
//
// 装饰元素只挂导出，不进预览——预览看修图效果，不看水印。
// 面板里可以预览元素本身（边框颜色、文字内容），但合成效果
// 要导出才能看到。

struct OverlayPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            borderSection
            textSection
            listSection
        }
    }

    @State private var borderColor = Color.white
    @State private var borderWidth: Double = 0.02
    @State private var textContent = ""
    @State private var textSize: Double = 0.04
    @State private var textColor = Color.white
    @State private var textPosition: OverlayElement.OverlayPosition = .bottomRight

    private var borderSection: some View {
        SectionCard(title: "边框") {
            ColorPicker("颜色", selection: $borderColor)
            SliderRow(title: "宽度", range: 0.001...0.1, step: 0.001,
                      format: { String(format: "%.3f", $0) },
                      value: $borderWidth)
            Button {
                let rgba = colorToRGBA8(borderColor)
                let element = OverlayElement(id: UUID(),
                                             kind: .border(color: rgba, widthRatio: borderWidth))
                model.addOverlay(element)
            } label: {
                Label("添加边框", systemImage: "square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var textSection: some View {
        SectionCard(title: "文字") {
            TextField("文字内容", text: $textContent)
                .textFieldStyle(.roundedBorder)
            SliderRow(title: "字号", range: 0.01...0.1, step: 0.001,
                      format: { String(format: "%.3f", $0) },
                      value: $textSize)
            ColorPicker("颜色", selection: $textColor)
            Picker("位置", selection: $textPosition) {
                ForEach(OverlayElement.OverlayPosition.allCases, id: \.self) { pos in
                    Text(pos.rawValue).tag(pos)
                }
            }
            .pickerStyle(.segmented)
            Button {
                let rgba = colorToRGBA8(textColor)
                let element = OverlayElement(id: UUID(),
                                             kind: .text(textContent, fontName: "Helvetica",
                                                        sizeRatio: textSize, color: rgba,
                                                        position: textPosition))
                model.addOverlay(element)
            } label: {
                Label("添加文字", systemImage: "textformat")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(textContent.isEmpty)
        }
    }

    private var listSection: some View {
        SectionCard(title: "已添加", subtitle: "\(model.document?.overlays.count ?? 0) 个") {
            if let overlays = model.document?.overlays, !overlays.isEmpty {
                ForEach(overlays) { element in
                    HStack {
                        Image(systemName: overlayIcon(element))
                            .foregroundStyle(Tokens.textSecondary)
                        Text(overlayLabel(element))
                            .font(.system(size: 11))
                        Spacer()
                        Button {
                            model.removeOverlay(id: element.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.danger)
                    }
                }
                Button("清除全部") { model.clearOverlays() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Tokens.danger)
            } else {
                Text("尚未添加装饰元素")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
    }

    private func overlayIcon(_ element: OverlayElement) -> String {
        switch element.kind {
        case .border: return "square"
        case .text: return "textformat"
        case .watermark: return "drop"
        }
    }

    private func overlayLabel(_ element: OverlayElement) -> String {
        switch element.kind {
        case .border: return "边框"
        case .text(let s, _, _, _, _): return "文字：\(s)"
        case .watermark: return "水印"
        }
    }
}

private func colorToRGBA8(_ color: Color) -> RGBA8 {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    #if canImport(UIKit)
    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    #elseif canImport(AppKit)
    (NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black).getRed(&r, green: &g, blue: &b, alpha: &a)
    #endif
    return RGBA8(r: UInt8(r * 255), g: UInt8(g * 255), b: UInt8(b * 255), a: UInt8(a * 255))
}