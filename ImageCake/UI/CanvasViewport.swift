import CoreGraphics
import Foundation

// 画布视口：等比适配 → 缩放 → 平移。
//
// 为什么单独抽成值类型：框选坐标是**归一化**的（0..1，y 向下），画布一旦
// 能缩放平移，「视图坐标 ↔ 归一化坐标」就成了一次可错的换算；而这个换算
// 错了的表现是「框选位置偏了一点」，在真机上根本无法判断是眼睛的问题还是
// 代码的问题（越放大越明显，用户只会觉得"这个 App 选框不准"）。
// 抽出来之后，缩放锚点、边界夹紧、往返一致都能在 CI 里钉住。
//
// 全用 CGFloat：这里每一处都直接和视图几何接壤，混用 Double 只会让
// `CGFloat * Double` 这类不隐式转换的表达式散落在各处。
//
// 约定：
// · scale 相对等比适配后的尺寸，1 = 刚好铺满，上限 maxScale；
// · offset 是相对适配位置的平移（视图坐标，右/下为正）；
// · 图像永远居中于「适配矩形中心 + offset」。

struct CanvasViewport: Equatable {
    /// 容器（画布可见区域）尺寸。
    var container: CGSize
    /// 图像等比适配后的矩形，即 scale = 1、offset = 0 时的位置。
    var fitted: CGRect
    /// 相对适配的缩放倍数。
    private(set) var scale: CGFloat
    /// 相对适配位置的平移。
    private(set) var offset: CGSize

    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 8

    init(container: CGSize, fitted: CGRect, scale: CGFloat = 1, offset: CGSize = .zero) {
        self.container = container
        self.fitted = fitted
        self.scale = scale
        self.offset = offset
        clampInPlace()
    }

    /// 变换后的图像显示矩形。
    var imageRect: CGRect {
        let width = fitted.width * scale
        let height = fitted.height * scale
        return CGRect(x: fitted.midX + offset.width - width / 2,
                      y: fitted.midY + offset.height - height / 2,
                      width: width,
                      height: height)
    }

    var isFitted: Bool { scale <= Self.minScale + 1e-9 && offset == .zero }

    // MARK: - 坐标换算

    /// 视图坐标 → 图像归一化坐标。落在图像外返回 nil（调用方据此判断"点到画布外了"）。
    func normalized(_ point: CGPoint) -> CGPoint? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// 归一化矩形 → 视图矩形（遮罩、选区的描边要贴图走）。
    func viewRect(_ normalized: CGRect) -> CGRect {
        let rect = imageRect
        return CGRect(x: rect.minX + normalized.minX * rect.width,
                      y: rect.minY + normalized.minY * rect.height,
                      width: normalized.width * rect.width,
                      height: normalized.height * rect.height)
    }

    /// 框选：两个视图点 → 归一化矩形，夹到图像内（拖出画布也不产生越界选区）。
    func selectionRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max((point.x - rect.minX) / rect.width, 0), 1),
                    y: min(max((point.y - rect.minY) / rect.height, 0), 1))
        }
        let p0 = clamp(a)
        let p1 = clamp(b)
        return CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                      width: abs(p0.x - p1.x), height: abs(p0.y - p1.y))
    }

    // MARK: - 变换

    /// 以视图上的某个锚点缩放，保持锚点下的图像内容不动。
    ///
    /// 推导：锚点相对图像中心的偏移，在两套 scale 下对应同一个归一化位置，
    /// 于是  offset' = d - (d - offset) * k，其中 d = anchor - fitted.mid、k = scale'/scale。
    /// k = 1 时退化成"什么都不变"，这条也断言住了。
    func zoomed(to newScale: CGFloat, anchor: CGPoint) -> CanvasViewport {
        guard scale > 0, fitted.width > 0 else { return self }
        let target = min(max(newScale, Self.minScale), Self.maxScale)
        let k = target / scale
        let dx = anchor.x - fitted.midX
        let dy = anchor.y - fitted.midY
        var next = self
        next.scale = target
        next.offset = CGSize(width: dx - (dx - offset.width) * k,
                             height: dy - (dy - offset.height) * k)
        next.clampInPlace()
        return next
    }

    /// 平移。超出边界时夹住——图像比容器小的方向不允许平移，
    /// 大的方向最多把边缘拖到容器边上，不会拖出空白。
    func panned(by delta: CGSize) -> CanvasViewport {
        var next = self
        next.offset = CGSize(width: offset.width + delta.width,
                             height: offset.height + delta.height)
        next.clampInPlace()
        return next
    }

    /// 回到刚好铺满。
    func reset() -> CanvasViewport {
        CanvasViewport(container: container, fitted: fitted)
    }

    // MARK: - 边界

    private mutating func clampInPlace() {
        scale = min(max(scale, Self.minScale), Self.maxScale)
        guard fitted.width > 0, fitted.height > 0 else {
            offset = .zero
            return
        }
        // 只有「放大后比容器大」的那个方向才允许平移，其余方向锁在中心：
        // 竖图在横屏上放大时，横向仍不该能拖出空白。
        let width = fitted.width * scale
        let height = fitted.height * scale
        let limitX = max(0, (width - container.width) / 2)
        let limitY = max(0, (height - container.height) / 2)
        offset = CGSize(width: min(max(offset.width, -limitX), limitX),
                        height: min(max(offset.height, -limitY), limitY))
    }
}
