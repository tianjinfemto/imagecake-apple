import CoreGraphics
import Foundation

// 人脸关键点的派生几何。
//
// 为什么要有这一层，而不是让每个算子直接去摸 478 个点：
//   · 五官形变、亮眼、牙齿美白、唇色、腮红要的都是"虹膜圆心 + 半径"
//     "唇内轮廓""颊部圆心"这种**语义量**。语义量算错一处，五个功能一起歪；
//   · 关键点网络的输出空间不稳定（有的给归一化、有的给裁切框内坐标），
//     把"点 → 语义量"收敛成一个纯函数，上层就只依赖语义量；
//   · 这一层是纯几何、零权重，能在没有模型权重的机器上被断言——
//     与仓里"几何与网络分离以便无权重断言"的立场一致。
//
// 坐标空间进出一致：喂归一化点得到归一化几何，喂像素点得到像素几何。
// 所有派生量都是同空间里的加权和/距离，所以不需要知道图有多大。
//
// 索引表照 MediaPipe FaceMesh（468 + 10 个虹膜点 = 478）。换关键点网络
// 必须重映射这张表——`from(points:)` 会先做数量校验，凑不齐 478 点直接返回
// nil，调用侧点名 `[no_landmarks]`，不会拿错的索引去推脸。

// MARK: - 专项区域（黑眼圈 / 法令纹）

/// 下睑椭圆（祛黑眼圈用）。坐标归一化、半径 x/y 分开（图不是正方形）。
struct UnderEyeRegion: Equatable, Sendable {
    var center: CGPoint
    var radiusX: Double
    var radiusY: Double
}

/// 法令纹带（沿鼻翼→嘴角一条略向外弧的旋转椭圆）。
/// `angle` 是长轴与水平线的夹角（弧度，y 向下系），屏幕上看就是那条斜纹的方向。
struct NasolabialRegion: Equatable, Sendable {
    var center: CGPoint
    var radiusX: Double
    var radiusY: Double
    var angle: Double
}

struct FaceGeometry: Equatable, Sendable {
    // MARK: 索引表（MediaPipe FaceMesh 478）

    enum Index {
        static let rightEyeRing = [33, 7, 160, 158, 157, 173, 133, 155, 154, 153, 145, 144]
        static let leftEyeRing = [362, 398, 384, 385, 386, 387, 263, 373, 380, 381, 382, 363]
        static let rightIris = [468, 469, 470, 471, 472]
        static let leftIris = [473, 474, 475, 476, 477]
        static let lipsOuterRing = [61, 185, 40, 39, 37, 0, 267, 269, 270, 409,
                                    291, 375, 321, 405, 314, 17, 84, 181, 91, 146]
        static let lipsInnerRing = [78, 191, 80, 81, 13, 312, 311, 310, 11, 8,
                                    251, 7, 197, 195, 5, 4, 148, 175, 171, 176]
        static let rightMouthCorner = 78
        static let leftMouthCorner = 308
        static let rightNoseWing = 129
        static let leftNoseWing = 358
        static let noseTip = 4
        static let noseBridge = 9
        static let chin = 152
        static let forehead = 10
        static let rightEyeOuter = 33
        static let leftEyeOuter = 263
        /// 脸部轮廓（face oval）。下颌点不是写死的下标，而是从这条轮廓里
        /// **按几何挑**：在嘴角连线以下的部分就是下颌。写死下标的话，换一套
        /// 轮廓点序就会挑到额头上。
        static let faceOval = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361,
                               288, 397, 365, 379, 378, 400, 377, 152, 148, 176, 149,
                               150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54,
                               103, 67, 109]
        static let requiredCount = 478
    }

    // MARK: 语义量

    /// 双眼虹膜圆心。
    var irisCenters: [CGPoint]
    /// 虹膜半径（与输入点同一坐标空间的长度单位）。
    var irisRadius: Double
    /// 眼睛轮廓多边形（两条，闭合）。
    var eyeRings: [[CGPoint]]
    var lipsOuter: [CGPoint]
    var lipsInner: [CGPoint]
    var mouthCorners: [CGPoint]
    var noseWings: [CGPoint]
    var noseTip: CGPoint
    var noseBridge: CGPoint
    var chin: CGPoint
    var forehead: CGPoint
    /// 轮廓里位于嘴角连线以下的部分（收下颌用）。
    var jawPoints: [CGPoint]
    /// 颊部圆心（瘦脸用）：鼻翼与同侧嘴角的中点，再向外让开半个眼距。
    var cheekCenters: [CGPoint]
    /// 颊部作用半径（≈ 半张脸宽）。
    var cheekRadius: Double
    /// 脸宽/脸高（同空间长度单位）与中心、中轴。
    var faceWidth: Double
    var faceHeight: Double
    var center: CGPoint
    /// 脸部中轴的 x（"向内推"的参考线）。
    var axisX: Double
    /// 外接框（同空间，像素版由调用侧换算）。
    var bounds: CGRect
    /// 下睑椭圆（两条，与 `eyeRings` 同序）——祛黑眼圈的作用区。
    var underEyes: [UnderEyeRegion]
    /// 法令纹带（两条，左右各一）——祛法令纹的作用区。
    var nasolabialBands: [NasolabialRegion]

    // MARK: 派生

    /// 从关键点派生。数量不足或关键索引越界 → nil（**不做**"用前 N 个凑"）。
    static func from(points: [CGPoint]) -> FaceGeometry? {
        guard points.count >= Index.requiredCount else { return nil }
        func p(_ index: Int) -> CGPoint? { index < points.count ? points[index] : nil }
        func ring(_ indices: [Int]) -> [CGPoint]? {
            var out: [CGPoint] = []
            out.reserveCapacity(indices.count)
            for i in indices {
                guard let point = p(i) else { return nil }
                out.append(point)
            }
            return out
        }
        guard let rightEye = ring(Index.rightEyeRing), let leftEye = ring(Index.leftEyeRing),
              let outer = ring(Index.lipsOuterRing), let inner = ring(Index.lipsInnerRing),
              let oval = ring(Index.faceOval),
              let rightIris = p(Index.rightIris[0]), let leftIris = p(Index.leftIris[0]),
              let rightCorner = p(Index.rightMouthCorner), let leftCorner = p(Index.leftMouthCorner),
              let rightWing = p(Index.rightNoseWing), let leftWing = p(Index.leftNoseWing),
              let noseTip = p(Index.noseTip), let noseBridge = p(Index.noseBridge),
              let chin = p(Index.chin), let forehead = p(Index.forehead),
              let rightOuter = p(Index.rightEyeOuter), let leftOuter = p(Index.leftEyeOuter)
        else { return nil }

        // 虹膜半径 = 虹膜圆心到虹膜环四点的平均距离。
        func irisMetrics(_ indices: [Int], center: CGPoint) -> Double {
            var sum = 0.0
            var n = 0
            for i in indices.dropFirst() {
                guard let q = p(i) else { continue }
                sum += hypot(Double(q.x) - Double(center.x), Double(q.y) - Double(center.y))
                n += 1
            }
            return n > 0 ? sum / Double(n) : 0
        }
        let radius = (irisMetrics(Index.rightIris, center: rightIris)
            + irisMetrics(Index.leftIris, center: leftIris)) / 2

        let bounds = boundingBox(of: oval)
        let eyeLineY = max(rightCorner.y, leftCorner.y)
        let jaw = oval.filter { Double($0.y) > Double(eyeLineY) }

        // 颊部：鼻翼—嘴角中点，向外让开 0.5 × 两眼外角距离。
        let eyeSpan = hypot(Double(leftOuter.x - rightOuter.x), Double(leftOuter.y - rightOuter.y))
        func mid(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + b) / 2 }
        func cheek(_ wing: CGPoint, _ corner: CGPoint, outward: Double) -> CGPoint {
            CGPoint(x: Double(mid(wing.x, corner.x)) + outward * eyeSpan * 0.32,
                    y: Double(mid(wing.y, corner.y)))
        }
        let cheeks = [cheek(rightWing, rightCorner, outward: -0.5), cheek(leftWing, leftCorner, outward: 0.5)]

        var faceWidth = Double(bounds.width)
        var faceHeight = Double(bounds.height)
        if faceWidth <= 0, eyeSpan > 0 { faceWidth = eyeSpan * 0.9 }
        if faceHeight <= 0, faceWidth > 0 { faceHeight = faceWidth * 1.35 }

        // 下睑椭圆（祛黑眼圈）：中心在虹膜正下方 0.9 个“半眼宽”处，
        // 横半轴 = 半眼宽 ×1.25、纵半轴 = 半眼宽 ×0.75。
        // 为什么以虹膜为锚而不是眼框下缘的原始点：眼袋浮肿时下缘轮廓点
        // 会掉得很低，拿它定中心会把颧骨的阴影当成黑眼圈。
        func underEye(_ iris: CGPoint, ring: [CGPoint]) -> UnderEyeRegion {
            let xs = ring.map { Double($0.x) }
            let halfWidth = (xs.max()! - xs.min()!) / 2
            let rX = halfWidth * 1.25
            let rY = halfWidth * 0.75
            return UnderEyeRegion(center: CGPoint(x: Double(iris.x), y: Double(iris.y) + halfWidth * 0.9),
                                  radiusX: rX, radiusY: rY)
        }
        let underEyes = [underEye(rightIris, ring: rightEye), underEye(leftIris, ring: leftEye)]

        // 法令纹带（鼻翼 → 嘴角）：长轴贴这条连线，中心稍微往颧骨一侧
        // 外弧（真实纹路不是直线）。两点重合或坐标退化时返回 nil，
        // 整张脸的两条带一起不收——不拿一个猜出来的角度去推脸。
        func band(_ wing: CGPoint, _ corner: CGPoint, outward: Double) -> NasolabialRegion? {
            let dx = Double(corner.x - wing.x), dy = Double(corner.y - wing.y)
            let length = hypot(dx, dy)
            guard length > 1e-6 else { return nil }
            let midX = (Double(wing.x) + Double(corner.x)) / 2
            let midY = (Double(wing.y) + Double(corner.y)) / 2
            // 法线（垂直于连线）取“向外”那一侧：right.wing.x < axis 时 outward 为负。
            let nx = dy / length, ny = -dx / length
            return NasolabialRegion(center: CGPoint(x: midX + nx * outward * length * 0.12,
                                                    y: midY + ny * outward * length * 0.12),
                                    radiusX: length * 0.58, radiusY: length * 0.13,
                                    angle: atan2(dy, dx))
        }
        var bands: [NasolabialRegion] = []
        if let rightBand = band(rightWing, rightCorner, outward: -1),
           let leftBand = band(leftWing, leftCorner, outward: 1) {
            bands = [rightBand, leftBand]
        }

        return FaceGeometry(
            irisCenters: [rightIris, leftIris],
            irisRadius: radius,
            eyeRings: [rightEye, leftEye],
            lipsOuter: outer,
            lipsInner: inner,
            mouthCorners: [rightCorner, leftCorner],
            noseWings: [rightWing, leftWing],
            noseTip: noseTip,
            noseBridge: noseBridge,
            chin: chin,
            forehead: forehead,
            jawPoints: jaw,
            cheekCenters: cheeks,
            cheekRadius: faceWidth * 0.34,
            faceWidth: faceWidth,
            faceHeight: faceHeight,
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            axisX: Double(bounds.midX),
            bounds: bounds,
            underEyes: underEyes,
            nasolabialBands: bands
        )
    }

    // MARK: 外接框
    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - 区域遮罩栅格化

/// 多边形 / 圆 → 掩码。RegionEnhance（亮眼、牙齿、唇色、腮红）共用。
enum RegionRaster {
    /// 偶奇规则填充多边形（扫描线），可选羽化。
    ///
    /// 为什么不用 Core Graphics 画：CGContext 的坐标翻转约定在两平台不同
    /// （iOS 的默认上下文是 y 向下还是向上取决于 startPage 时机），
    /// 而"唇内多边形到底盖住哪几行像素"必须是能离线断言的确定性几何。
    static func polygon(_ ring: [CGPoint], size: PixelSize, feather: Int = 0) -> MaskBuffer {
        guard ring.count >= 3, size.pixelCount > 0 else {
            return MaskBuffer.filled(size, value: 0)
        }
        var bytes = [UInt8](repeating: 0, count: size.pixelCount)
        let ys = ring.map { Double($0.y) }
        let top = Swift.max(0, Int(ys.min()!.rounded(.down)))
        let bottom = Swift.min(size.height - 1, Int(ys.max()!.rounded(.up)))
        guard top <= bottom else { return MaskBuffer.filled(size, value: 0) }

        for y in top ... bottom {
            let scanY = Double(y) + 0.5
            var crossings: [Double] = []
            for i in 0 ..< ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                let ay = Double(a.y), by = Double(b.y)
                guard (ay <= scanY && by > scanY) || (by <= scanY && ay > scanY) else { continue }
                let t = (scanY - ay) / (by - ay)
                crossings.append(Double(a.x) + t * (Double(b.x) - Double(a.x)))
            }
            crossings.sort()
            let row = y * size.width
            var pair = 0
            while pair + 1 < crossings.count {
                let x0 = Swift.max(0, Int(crossings[pair].rounded(.up)))
                let x1 = Swift.min(size.width - 1, Int(crossings[pair + 1].rounded(.down)))
                if x0 <= x1 {
                    for x in x0 ... x1 { bytes[row + x] = 255 }
                }
                pair += 2
            }
        }
        let mask = MaskBuffer(size: size, data: Data(bytes))
        return feather > 0 ? MaskOps.feathered(mask, radius: feather) : mask
    }

    /// 椭圆盘（浮点边界，中心 1、边缘 0），半径用像素且 **x/y 分开**。
    ///
    /// 为什么不写成"一个半径"：关键点如果来自归一化坐标，同一个数值在
    /// x 与 y 上对应的像素长度不同（图不是正方形）。用两个半径才不用
    /// 在调用侧各自乘一遍长边——那种写法迟早会有一处乘错。
    static func disk(center: CGPoint, radiusX: Double, radiusY: Double, size: PixelSize) -> MaskBuffer {
        disk(center: center, radiusX: radiusX, radiusY: radiusY, angle: 0, size: size)
    }

    /// 旋转椭圆盘（`angle` 弧度，y 向下系）。法令纹带需要旋转椭圆：
    /// 不转的话只能拿竖椭圆去盖一条斜纹，症状是纹路只淡了一半。
    static func disk(center: CGPoint, radiusX: Double, radiusY: Double,
                     angle: Double, size: PixelSize) -> MaskBuffer {
        guard radiusX > 0, radiusY > 0, size.pixelCount > 0 else { return MaskBuffer.filled(size, value: 0) }
        var bytes = [UInt8](repeating: 0, count: size.pixelCount)
        let cx = Double(center.x), cy = Double(center.y)
        let cosA = cos(angle), sinA = sin(angle)
        // 外包半径：旋转后椭圆在两个轴上的最大延伸。
        let extentX = (cosA * radiusX).magnitude + (sinA * radiusY).magnitude
        let extentY = (sinA * radiusX).magnitude + (cosA * radiusY).magnitude
        let x0 = Swift.max(0, Int((cx - extentX).rounded(.down)))
        let x1 = Swift.min(size.width - 1, Int((cx + extentX).rounded(.up)))
        let y0 = Swift.max(0, Int((cy - extentY).rounded(.down)))
        let y1 = Swift.min(size.height - 1, Int((cy + extentY).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return MaskBuffer.filled(size, value: 0) }
        for y in y0 ... y1 {
            let row = y * size.width
            for x in x0 ... x1 {
                // 旋回椭圆自身坐标系再判单位圆。
                let px = Double(x) + 0.5 - cx
                let py = Double(y) + 0.5 - cy
                let u = (px * cosA + py * sinA) / radiusX
                let v = (-px * sinA + py * cosA) / radiusY
                let d = (u * u + v * v).squareRoot()
                guard d < 1 else { continue }
                // smoothstep：中心平、边缘快落，避免圆盘出现一圈硬台阶。
                let t = 1 - d
                bytes[row + x] = UInt8((t * t * (3 - 2 * t) * 255).rounded())
            }
        }
        return MaskBuffer(size: size, data: Data(bytes))
    }

    /// 两个掩码相减（保留 a 中比 b 大的部分）。用于"唇环 − 唇内 = 牙齿之外"。
    static func subtract(_ a: MaskBuffer, _ b: MaskBuffer) -> MaskBuffer {
        guard a.size == b.size, !a.isEmpty, !b.isEmpty else { return a }
        let left = [UInt8](a.data), right = [UInt8](b.data)
        var out = [UInt8](repeating: 0, count: left.count)
        for i in 0 ..< left.count { out[i] = Swift.max(0, left[i] - right[i]) }
        return MaskBuffer(size: a.size, data: Data(out))
    }
}
