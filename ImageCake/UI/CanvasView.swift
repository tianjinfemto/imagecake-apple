import CoreGraphics
import SwiftUI

// 画布。三件事：等比适配、α 叠层、框选。
//
// 框选坐标存**归一化**（0..1，y 向下）：预览是 2048 档、导出是全量，
// 用像素存的话导出时整块会跑偏。归一化也让"换一张分辨率不同的图"不必换算。

struct CanvasView: View {
    let image: CGImage?
    let maskOverlay: CGImage?
    let showMask: Bool
    let selectionEnabled: Bool
    @Binding var selection: CGRect?

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fit(imageSize: imageSize, in: geo.size)
            ZStack {
                Tokens.bgCanvas
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                }
                if showMask, let maskOverlay {
                    Image(decorative: maskOverlay, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .opacity(0.45)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .allowsHitTesting(false)
                }
                if let rect = selectionRectInView(fitted) {
                    Rectangle()
                        .stroke(Tokens.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .background(Rectangle().fill(Tokens.accent.opacity(0.10)))
                        .frame(width: max(1, rect.width), height: max(1, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                }
                if image == nil {
                    Text("没有打开图片")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.textSecondary)
                }
                if selectionEnabled, image != nil {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    if dragStart == nil { dragStart = value.startLocation }
                                    dragCurrent = value.location
                                }
                                .onEnded { value in
                                    defer { dragStart = nil; dragCurrent = nil }
                                    let rect = Self.normalizedRect(from: value.startLocation,
                                                                   to: value.location,
                                                                   fitted: fitted)
                                    // 小于 1% 的拖拽当成误触，不清掉已有选区。
                                    if rect.width < 0.01 || rect.height < 0.01 {
                                        selection = nil
                                    } else {
                                        selection = rect
                                    }
                                }
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Tokens.bgCanvas)
    }

    private var imageSize: CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    /// 归一化选区 → 视图坐标矩形。
    private func selectionRectInView(_ fitted: CGRect) -> CGRect? {
        if let dragStart, let dragCurrent {
            return Self.rect(from: dragStart, to: dragCurrent)
        }
        guard let selection else { return nil }
        return CGRect(x: fitted.minX + selection.minX * fitted.width,
                      y: fitted.minY + selection.minY * fitted.height,
                      width: selection.width * fitted.width,
                      height: selection.height * fitted.height)
    }

    static func fit(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width,
                      height: size.height)
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func normalizedRect(from a: CGPoint, to b: CGPoint, fitted: CGRect) -> CGRect {
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max((point.x - fitted.minX) / fitted.width, 0), 1),
                    y: min(max((point.y - fitted.minY) / fitted.height, 0), 1))
        }
        let p0 = clamp(a)
        let p1 = clamp(b)
        return CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                      width: abs(p0.x - p1.x), height: abs(p0.y - p1.y))
    }
}
