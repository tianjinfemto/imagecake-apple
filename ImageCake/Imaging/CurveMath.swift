import Foundation

// 曲线采样：单调三次 Hermite（Fritsch–Carlson）。
//
// 为什么不用 Catmull-Rom：用户把中间调往上拖时，Catmull-Rom 会在相邻段
// 过冲出"回勾"，落在像素上就是一圈不该有的亮边。单调插值保证"控制点往上，
// 曲线不会先往下"——这是曲线编辑器敢画弧线的前提。
//
// 屏幕上的形状与烘进像素的映射是同一段插值：UI 画弧线也走 curveLUT，
// 不允许第二份实现（imagecake 的 sample_curve 是同一条立场）。

enum CurveMath {
    /// 把控制点采样成 size 项的查找表。输入非法时交恒等表。
    static func lut(_ channel: CurveChannel, size: Int = 1024) -> [Float] {
        guard size >= 2 else { return Array(repeating: 0, count: max(0, size)) }
        guard channel.isValid else {
            return (0 ..< size).map { Float($0) / Float(size - 1) }
        }
        let xs = channel.x
        let ys = channel.y.map { $0.clamped(to: 0 ... 1) }
        let n = xs.count

        // 段斜率
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0 ..< (n - 1) {
            delta[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])
        }

        // 切线：端点取单侧斜率，内点取两侧平均后按单调性夹取
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1 ..< (n - 1) {
            if delta[i - 1] * delta[i] <= 0 {
                m[i] = 0
            } else {
                m[i] = (delta[i - 1] + delta[i]) / 2
            }
        }
        for i in 0 ..< (n - 1) {
            if delta[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / delta[i]
            let b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * delta[i]
                m[i + 1] = t * b * delta[i]
            }
        }

        return (0 ..< size).map { i -> Float in
            let t = Double(i) / Double(size - 1)
            let seg = segmentIndex(xs, t)
            let x0 = xs[seg], x1 = xs[seg + 1]
            let h = x1 - x0
            let u = (t - x0) / h
            let u2 = u * u
            let u3 = u2 * u
            // Hermite 基函数
            let h00 = 2 * u3 - 3 * u2 + 1
            let h10 = u3 - 2 * u2 + u
            let h01 = -2 * u3 + 3 * u2
            let h11 = u3 - u2
            let value = h00 * ys[seg] + h10 * h * m[seg] + h01 * ys[seg + 1] + h11 * h * m[seg + 1]
            return Float(value.clamped(to: 0 ... 1))
        }
    }

    /// 在 x 控制点里找 t 所在段的下标（x 严格递增，t ∈ [0,1]）。
    private static func segmentIndex(_ xs: [Double], _ t: Double) -> Int {
        if t <= xs[0] { return 0 }
        if t >= xs[xs.count - 1] { return xs.count - 2 }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] <= t { lo = mid } else { hi = mid }
        }
        return lo
    }

    @inline(__always)
    static func sample(_ lut: [Float], _ t: Float) -> Float {
        let clamped = min(max(t, 0), 1)
        let pos = clamped * Float(lut.count - 1)
        let i = Int(pos)
        let f = pos - Float(i)
        if i >= lut.count - 1 { return lut[lut.count - 1] }
        return lut[i] + (lut[i + 1] - lut[i]) * f
    }
}
