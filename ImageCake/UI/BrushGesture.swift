import CoreGraphics
import Foundation

// 笔刷手势的纯值类型部分。
//
// 为什么要抽出来：CanvasView 的手势回调在主线程、带 SwiftUI 状态，
// 没法在 CI 里跑。而「一串触摸点 → 一条笔迹」的采样逻辑是会错的
// （点太密会让栅格化白跑一圈、点太稀会让笔迹断），且错了在真机上
// 只表现为「笔刷手感怪怪的」。抽成纯函数就能钉住。

enum StrokeSampler {
    /// 按最小间距过滤一串归一化点，首尾始终保留。
    ///
    /// DragGesture 的 onChanged 每帧都回调，一秒几十个点；全塞进 BrushStroke
    /// 会让 StrokeRasterizer 沿线插值时在相邻几乎重合的点上反复画圆——
    /// 既慢又让重叠区的掩码提前饱和。按半径的一半间距过滤后，相邻两点
    /// 之间恰好由 StrokeRasterizer 内部插值补上（它用 radius*0.5 做步长），
    /// 不会出现断层。
    static func resample(_ points: [CGPoint], minSpacing: Double) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        guard points.count > 1 else { return points }
        let spacing = max(minSpacing, 0)
        var result: [CGPoint] = [points[0]]
        var last = points[0]
        for point in points.dropFirst() {
            let dx = point.x - last.x
            let dy = point.y - last.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance >= spacing {
                result.append(point)
                last = point
            }
        }
        // 首尾必须保留：拖动终点是用户抬手的位置，丢掉会让笔迹短一截。
        if let tail = points.last, result.last != tail {
            result.append(tail)
        }
        return result
    }
}