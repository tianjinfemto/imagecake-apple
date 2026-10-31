import CoreGraphics
import Foundation

// 位移场。液化笔刷与"美型预设"共用同一套底座：
// 先**累加场**，最后**只重采样一次**。
//
// 为什么坚持"先累加再一次采样"：每笔/每个预设各重采样一遍，图就被双线性
// 插值糊很多次——十个预设叠加后脸是糊的，而且糊得不可解释。累加之后一次
// 采样，插值损耗只发生一次。与 LiquifyEngine 的结论同一条。
//
// 约定（和 LiquifyEngine 完全一致，别处不许反过来定义）：
//   场里存的是**采样偏移**：目标像素 q 从 q + offset 取色。
//   所以"内容往 +d 方向移动"写成 offset −= d。
//   `addVerticalStretch` 是唯一的例外——它直接写采样偏移（拉伸的反函数
//   本来就是采样位置），签名与注释里都点明了这一点。
//
// 坐标一律归一化（0…1，y 向下），半径 x/y 分开给：图不是正方形，
// 一个半径没法同时是"多少个像素宽"和"多少个像素高"。

struct WarpField: Sendable {
    let size: PixelSize
    var offsetX: [Float]
    var offsetY: [Float]

    init(size: PixelSize) {
        self.size = size
        let count = max(0, size.pixelCount)
        offsetX = [Float](repeating: 0, count: count)
        offsetY = [Float](repeating: 0, count: count)
    }

    var isEmpty: Bool {
        offsetX.allSatisfy { $0 == 0 } && offsetY.allSatisfy { $0 == 0 }
    }

    /// 峰值位移上限（相对长边）。没有这道闸，极端参数叠加后采样坐标能跑出
    /// 半个图，画面直接撕开。0.12 在 2048 档约 246px，够任何合理的美型用量。
    static let maxDisplacementRatio = 0.12

    // MARK: - 累加

    /// 把椭圆作用域内的内容往 (dx, dy) 推。两个位移给的是**归一化长度**
    /// （dx 相对宽、dy 相对高），本函数乘回像素：场里记的是像素偏移，
    /// 而调用侧手里全是归一化坐标（关键点、脸宽、肩宽）。
    /// 衰减用 (1 − t²)²：中心平坦段更宽、边缘导数归零，接缝看不出来。
    mutating func addPush(center: CGPoint, radiusX: Double, radiusY: Double,
                          dx: Double, dy: Double, strength: Double) {
        guard size.pixelCount > 0, strength != 0 else { return }
        guard abs(dx) > 1e-6 || abs(dy) > 1e-6 else { return }
        let width = Double(size.width), height = Double(size.height)
        let cx = Double(center.x) * width, cy = Double(center.y) * height
        let rx = radiusX * width, ry = radiusY * height
        let dxPixels = dx * width, dyPixels = dy * height
        // 闸门看的是**像素半径**：半径参数是归一化长度，拿它去比 0.5 会
        // 把任何合理的作用域都挡掉（症状是“所有预设形变都没反应”）。
        guard rx > 0.5, ry > 0.5 else { return }
        let x0 = Swift.max(0, Int((cx - rx).rounded(.down)))
        let x1 = Swift.min(size.width - 1, Int((cx + rx).rounded(.up)))
        let y0 = Swift.max(0, Int((cy - ry).rounded(.down)))
        let y1 = Swift.min(size.height - 1, Int((cy + ry).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }

        for y in y0 ... y1 {
            let row = y * size.width
            let ny = (Double(y) + 0.5 - cy) / ry
            for x in x0 ... x1 {
                let nx = (Double(x) + 0.5 - cx) / rx
                let t2 = nx * nx + ny * ny
                guard t2 < 1 else { continue }
                let fall = (1 - t2) * (1 - t2)
                let w = fall * strength
                let index = row + x
                offsetX[index] -= Float(dxPixels * w)
                offsetY[index] -= Float(dyPixels * w)
            }
        }
    }

    /// 放大：椭圆内的内容沿"离圆心的方向"外推，amount>0 时看起来变大了。
    /// 中心处 (q − c) = 0，所以瞳孔不会被推到别处去；越靠边缘推得越多。
    mutating func addMagnify(center: CGPoint, radiusX: Double, radiusY: Double, amount: Double) {
        guard size.pixelCount > 0, amount != 0 else { return }
        let width = Double(size.width), height = Double(size.height)
        let cx = Double(center.x) * width, cy = Double(center.y) * height
        let rx = radiusX * width, ry = radiusY * height
        guard rx > 0.5, ry > 0.5 else { return }
        let x0 = Swift.max(0, Int((cx - rx).rounded(.down)))
        let x1 = Swift.min(size.width - 1, Int((cx + rx).rounded(.up)))
        let y0 = Swift.max(0, Int((cy - ry).rounded(.down)))
        let y1 = Swift.min(size.height - 1, Int((cy + ry).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }

        for y in y0 ... y1 {
            let row = y * size.width
            let ny = (Double(y) + 0.5 - cy) / ry
            for x in x0 ... x1 {
                let nx = (Double(x) + 0.5 - cx) / rx
                let t2 = nx * nx + ny * ny
                guard t2 < 1 else { continue }
                let fall = (1 - t2) * (1 - t2)
                let index = row + x
                offsetX[index] -= Float((Double(x) + 0.5 - cx) * amount * fall)
                offsetY[index] -= Float((Double(y) + 0.5 - cy) * amount * fall)
            }
        }
    }

    /// 纵向拉伸（增高/长腿用）。**直接写采样偏移**。
    ///
    /// scale > 1 = 把 [anchorY, anchorY+length] 这段源图摊到更长的输出区间，
    /// 于是这一段看起来被拉长了；锚线本身不动，锚线以上完全不动。
    /// 超出锚线 + length 之后偏移恒为最大（整体平移），不再增长——否则
    /// 画面底部会被无限拉伸。
    mutating func addVerticalStretch(anchorY: Double, length: Double, scale: Double) {
        guard size.pixelCount > 0, scale != 1, length > 1e-6 else { return }
        let height = Double(size.height)
        let anchor = anchorY * height
        let span = length * height
        let rate = 1 - 1 / scale           // 采样位置 = y − (y−anchor)·rate（带内）
        let y0 = Swift.max(0, Int(anchor.rounded(.down)))
        let y1 = Swift.min(size.height - 1, Int((anchor + span).rounded(.up)))
        guard y0 <= y1 else { return }
        let maxOffset = Swift.min(span, Swift.max(0, anchor + span)) * rate
        for y in y0 ... size.height - 1 {
            let row = y * size.width
            let dy = Double(y) + 0.5 - anchor
            let offset: Double
            if dy <= 0 {
                offset = 0
            } else if dy <= span {
                offset = dy * rate
            } else {
                offset = maxOffset
            }
            let value = Float(-offset)
            for x in 0 ..< size.width { offsetY[row + x] += value }
        }
    }

    /// 夹紧总位移，防止极端叠加把画面撕开。
    mutating func clampMagnitude() {
        let limit = Float(WarpField.maxDisplacementRatio * Double(size.longEdge))
        for i in 0 ..< offsetX.count {
            let x = offsetX[i], y = offsetY[i]
            let m = (x * x + y * y).squareRoot()
            guard m > limit, m > 0 else { continue }
            let k = limit / m
            offsetX[i] = x * k
            offsetY[i] = y * k
        }
    }

    // MARK: - 应用

    /// 按场重采样一次。protection 是保护笔刷掩码（255 = 完全不动）：
    /// 乘在**采样偏移**上，所以被保护的区域直接回到恒等采样，而不是
    /// "推完再贴回去"（那种做法边缘必然断层）。
    func resample(_ image: DisplayImage, protection: MaskBuffer? = nil) -> DisplayImage {
        let size = image.size
        guard size.pixelCount > 0, offsetX.count == size.pixelCount else { return image }
        let shiftX: [Float], shiftY: [Float]
        if let protection, !protection.isEmpty {
            let mask = protection.size == size ? protection : protection.resized(to: size)
            let bytes = [UInt8](mask.data)
            var px = [Float](repeating: 0, count: size.pixelCount)
            var py = [Float](repeating: 0, count: size.pixelCount)
            for i in 0 ..< size.pixelCount {
                let keep = Float(bytes[i]) / 255           // 255 = 保护 = 不推
                px[i] = offsetX[i] * (1 - keep)
                py[i] = offsetY[i] * (1 - keep)
            }
            shiftX = px
            shiftY = py
        } else {
            shiftX = offsetX
            shiftY = offsetY
        }

        let source = image.pixels
        var output = [Float](repeating: 0, count: source.count)
        source.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                shiftX.withUnsafeBufferPointer { dx in
                    shiftY.withUnsafeBufferPointer { dy in
                        for y in 0 ..< size.height {
                            for x in 0 ..< size.width {
                                let index = y * size.width + x
                                ImageSampling.bilinear(src: src, width: size.width, height: size.height,
                                                       x: Double(x) + Double(dx[index]),
                                                       y: Double(y) + Double(dy[index]),
                                                       into: dst, at: index * 4)
                            }
                        }
                    }
                }
            }
        }
        return DisplayImage(size: size, pixels: output)
    }
}
