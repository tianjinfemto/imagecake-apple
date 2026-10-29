import CoreGraphics
import SwiftUI

// 画布。四件事：等比适配、缩放/平移、α 叠层、框选。
//
// 框选坐标存**归一化**（0..1，y 向下）：预览是 2048 档、导出是全量，
// 用像素存的话导出时整块会跑偏。归一化也让"换一张分辨率不同的图"不必换算。
//
// 缩放/平移的数学全部在 CanvasViewport（纯值类型，有单测）：这个 View 只负责
// 把手势翻译成 viewport 变换。因为一旦有缩放，框选就多了一次坐标换算，
// 而那类错误在真机上只表现为"选框偏了一点"。
//
// 手势分工：
//   · 单指拖 → 框选（selectionEnabled 时）
//   · 双指捏 → 以捏合点为锚缩放；双指期间的位移当作平移
//   · 双击   → 复位到刚好铺满
// 单指/双指靠 MagnifyGesture 先置 isPinching 来区分——这是 SwiftUI 手势层
// 里唯一行的办法，也是本项目里唯一必须在真机上确认手感的地方。

struct CanvasView: View {
    let image: CGImage?
    let maskOverlay: CGImage?
    let showMask: Bool
    let selectionEnabled: Bool
    @Binding var selection: CGRect?

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    /// 捏合起点时的 zoom。手势给的是相对比例，不乘基准会一路累积漂移。
    @State private var pinchBase: CGFloat?
    @State private var isPinching = false
    /// 双指平移用的上一帧位置（DragGesture 给的是累计位移，不是增量）。
    @State private var lastPanLocation: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fit(imageSize: imageSize, in: geo.size)
            let viewport = CanvasViewport(container: geo.size, fitted: fitted, scale: zoom, offset: pan)

            ZStack {
                Tokens.bgCanvas

                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        // 放大到 150% 以上就关插值：修图时要看真实像素，不是被平滑过的猜测。
                        .interpolation(zoom > 1.5 ? .none : .high)
                        .frame(width: viewport.imageRect.width, height: viewport.imageRect.height)
                        .position(x: viewport.imageRect.midX, y: viewport.imageRect.midY)
                }
                if showMask, let maskOverlay {
                    Image(decorative: maskOverlay, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .opacity(0.45)
                        .frame(width: viewport.imageRect.width, height: viewport.imageRect.height)
                        .position(x: viewport.imageRect.midX, y: viewport.imageRect.midY)
                        .allowsHitTesting(false)
                }
                if let rect = selectionRectInView(viewport) {
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
                if zoom > CanvasViewport.minScale + 0.01 {
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Tokens.bgElevated.opacity(0.85), in: Capsule())
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(contextGesture(viewport))
            .simultaneousGesture(magnifyGesture(viewport))
            .onTapGesture(count: 2) { resetViewport() }
            .onChange(of: geo.size) { _, newSize in
                // 分屏/旋转后容器变了：按新容器重新夹一遍，否则记忆里的 offset 会越界。
                let next = Self.fit(imageSize: imageSize, in: newSize)
                applyViewport(CanvasViewport(container: newSize, fitted: next, scale: zoom, offset: pan))
            }
            .onChange(of: imageSize) { _, _ in resetViewport() }
        }
        .background(Tokens.bgCanvas)
    }

    // MARK: - 手势

    private func contextGesture(_ viewport: CanvasViewport) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if isPinching {
                    // 双指期间的拖动当平移：DragGesture 报的是主触点，够用。
                    if let last = lastPanLocation {
                        let delta = CGSize(width: value.location.x - last.x,
                                           height: value.location.y - last.y)
                        applyViewport(viewport.panned(by: delta))
                    }
                    lastPanLocation = value.location
                    return
                }
                guard selectionEnabled else { return }
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
                lastPanLocation = nil
                if isPinching { return }
                guard selectionEnabled else { return }
                defer { dragStart = nil; dragCurrent = nil }
                let rect = viewport.selectionRect(from: value.startLocation, to: value.location)
                // 小于 1% 的拖拽当成误触，不清掉已有选区。
                if rect.width < 0.01 || rect.height < 0.01 {
                    selection = nil
                } else {
                    selection = rect
                }
            }
    }

    private func magnifyGesture(_ viewport: CanvasViewport) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                isPinching = true
                if pinchBase == nil { pinchBase = zoom }
                let base = pinchBase ?? zoom
                // startAnchor 是 0...1 的单位点，换算成视图坐标当锚点。
                let anchor = CGPoint(x: value.startAnchor.x * viewport.container.width,
                                     y: value.startAnchor.y * viewport.container.height)
                let start = CanvasViewport(container: viewport.container,
                                           fitted: viewport.fitted,
                                           scale: base,
                                           offset: pan)
                applyViewport(start.zoomed(to: base * value.magnification, anchor: anchor))
            }
            .onEnded { _ in
                pinchBase = nil
                isPinching = false
                lastPanLocation = nil
            }
    }

    // MARK: - 状态

    private func applyViewport(_ next: CanvasViewport) {
        zoom = next.scale
        pan = next.offset
    }

    private func resetViewport() {
        zoom = CanvasViewport.minScale
        pan = .zero
    }

    private var imageSize: CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    private func selectionRectInView(_ viewport: CanvasViewport) -> CGRect? {
        if let dragStart, let dragCurrent {
            return Self.rect(from: dragStart, to: dragCurrent)
        }
        guard let selection else { return nil }
        return viewport.viewRect(selection)
    }

    // MARK: - 几何

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
}
