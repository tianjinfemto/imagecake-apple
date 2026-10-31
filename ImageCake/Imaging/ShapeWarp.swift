import CoreGraphics
import Foundation

// 关键点驱动的"美型"预设形变（像素蛋糕的瘦脸/大眼/瘦腰/长腿那一层）。
//
// 与传统液化的关系：液化是"用户拿手指推"，这里是"按骨架推"。两者共用
// WarpField（一次累加、一次重采样），所以手感与画质表现是同一条口径——
// 不会出现"手动推过的地方清楚、预设推过的地方发糊"。
//
// 立场与仓里其余部分一致：
//   · 没有关键点就整段不跑，并点名 `[no_landmarks]` / `[no_pose]`。
//     绝不猜"脸大概在图中间"去推颧骨——那种猜测的表现是"把头发推走"。
//   · 每一项的**方向由几何决定**（朝躯干轴、朝脸中轴、沿虹膜半径），
//     滑杆只管力度。这样同一组参数换一张横图/竖图/侧身照不会反向。
//   · 强度上限被刻意压低（满力度也只有 ~10% 的相对位移），因为美型
//     最容易做成"蛇精脸"；要更激进应该手动液化，而不是把这里调宽。

// MARK: - 身形锚点

struct BodyAnchors: Equatable, Sendable {
    /// COCO 17 点（与 BodyPoseTask.jointNames 同序）。
    var head: CGPoint
    var ears: [CGPoint]
    var shoulders: [CGPoint]
    var hips: [CGPoint]
    var knees: [CGPoint]
    var ankles: [CGPoint]
    var shoulderWidth: Double
    var hipWidth: Double
    var shoulderCenter: CGPoint
    var hipCenter: CGPoint
    var neckCenter: CGPoint
    /// 腰线：肩中心到髋中心的 55% 处（解剖学上的最细处在髋上方一点）。
    var waistCenter: CGPoint

    static func from(joints: [CGPoint]) -> BodyAnchors? {
        guard joints.count >= 17 else { return nil }
        func mid(_ a: CGPoint, _ b: CGPoint, t: CGFloat = 0.5) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let shoulders = [joints[5], joints[6]]
        let hips = [joints[11], joints[12]]
        let shoulderWidth = Double(abs(shoulders[0].x - shoulders[1].x))
        let hipWidth = Double(abs(hips[0].x - hips[1].x))
        // 退化姿态（点全重合 / 肩宽为 0）不配拿来推身体。
        guard shoulderWidth > 1e-6, hipWidth > 1e-6 else { return nil }
        let shoulderCenter = mid(shoulders[0], shoulders[1])
        let hipCenter = mid(hips[0], hips[1])
        guard abs(Double(hipCenter.y - shoulderCenter.y)) > 1e-6 else { return nil }
        // 颈中心：两耳中点往肩中心靠 35%（两耳中点还在头侧，不是颈根）。
        let neckCenter = mid(mid(joints[3], joints[4]), shoulderCenter, t: 0.35)
        return BodyAnchors(
            head: joints[0],
            ears: [joints[3], joints[4]],
            shoulders: shoulders,
            hips: hips,
            knees: [joints[13], joints[14]],
            ankles: [joints[15], joints[16]],
            shoulderWidth: shoulderWidth,
            hipWidth: hipWidth,
            shoulderCenter: shoulderCenter,
            hipCenter: hipCenter,
            neckCenter: neckCenter,
            waistCenter: mid(shoulderCenter, hipCenter, t: 0.55)
        )
    }

    /// 躯干轴在给定 y（归一化）上的 x。细腰/瘦腿的"向内"就是朝这条线。
    func axisX(at y: CGFloat) -> CGFloat {
        let y0 = shoulderCenter.y, y1 = hipCenter.y
        guard y1 != y0 else { return shoulderCenter.x }
        let t = Swift.min(Swift.max((y - y0) / (y1 - y0), -0.5), 1.5)
        return shoulderCenter.x + (hipCenter.x - shoulderCenter.x) * t
    }
}

// MARK: - 预设形变

enum ShapeWarp {
    /// 需要人脸关键点的项是否至少开了一项。
    static func needsFace(_ beauty: BeautyParameters) -> Bool { !beauty.isFaceShapeNeutral }
    /// 需要身形关键点的项是否至少开了一项。
    static func needsBody(_ beauty: BeautyParameters) -> Bool { !beauty.isBodyShapeNeutral }

    /// 把开着的项累加成一张位移场。全关或没有对应锚点 → nil。
    ///
    /// 多人脸走的是同一个入口：每张脸的锚点都往同一张场上累加，所以
    /// 合影里"推了 A 的脸"不会把 B 的脸抹掉——两张脸的作用域几乎不相交
    /// （半径 ≈ 0.55 脸宽），相交处也是线性叠加，与手动液化同一条口径。
    static func build(size: PixelSize, faces: [FaceGeometry], body: BodyAnchors?,
                      beauty: BeautyParameters) -> WarpField? {
        guard size.pixelCount > 0, !(beauty.isShapeNeutral) else { return nil }
        var field = WarpField(size: size)
        var touched = false

        for face in faces {
            // 绝不能写成 `touched = touched || applyFaceEdits(...)`：`||` 会短路，
            // 第一张脸一旦生效，后面每张脸的函数调用都被跳过——症状正是
            // "合影里只磨最大那张脸"，而且只有断言能抓出来。
            let edited = applyFaceEdits(&field, size: size, face: face, beauty: beauty)
            touched = touched || edited
        }
        if let body {
            let edited = applyBodyEdits(&field, size: size, body: body, beauty: beauty)
            touched = touched || edited
        }
        guard touched else { return nil }
        field.clampMagnitude()
        return field
    }

    /// 单张脸的入口（断言与旧调用侧用）。
    static func build(size: PixelSize, face: FaceGeometry?, body: BodyAnchors?,
                      beauty: BeautyParameters) -> WarpField? {
        build(size: size, faces: face.map { [$0] } ?? [], body: body, beauty: beauty)
    }

    static func apply(_ image: DisplayImage, faces: [FaceGeometry], body: BodyAnchors?,
                      beauty: BeautyParameters, protection: MaskBuffer? = nil) -> DisplayImage {
        guard let field = build(size: image.size, faces: faces, body: body, beauty: beauty) else { return image }
        return field.resample(image, protection: protection)
    }

    static func apply(_ image: DisplayImage, face: FaceGeometry?, body: BodyAnchors?,
                      beauty: BeautyParameters, protection: MaskBuffer? = nil) -> DisplayImage {
        apply(image, faces: face.map { [$0] } ?? [], body: body, beauty: beauty, protection: protection)
    }

    // MARK: 单位换算

    /// 把"以画布宽为单位"的长度换成同一段物理长度在 y 方向上的归一化值。
    /// 图不是正方形：不换算的话，瘦脸的横向推力和下巴的纵向推力就不是同一个量纲。
    static func toY(_ lengthInWidthUnits: Double, size: PixelSize) -> Double {
        guard size.height > 0 else { return 0 }
        return lengthInWidthUnits * Double(size.width) / Double(size.height)
    }

    /// 半径对（x/y 归一化），保证作用域在屏幕上是圆的。
    static func round(_ radiusInWidthUnits: Double, size: PixelSize) -> (x: Double, y: Double) {
        (radiusInWidthUnits, toY(radiusInWidthUnits, size: size))
    }

    // MARK: - 五官

    static func applyFaceEdits(_ field: inout WarpField, size: PixelSize,
                                face: FaceGeometry, beauty: BeautyParameters) -> Bool {
        let width = face.faceWidth
        guard width > 1e-6 else { return false }
        var touched = false

        // 瘦颊：两颊朝脸中轴推。正 = 收，负 = 丰。
        let slim = BeautyParameters.unit(beauty.slimFace)
        if slim != 0 {
            let r = round(width * 0.55, size: size)
            for cheek in face.cheekCenters {
                let sign: Double = Double(cheek.x) > face.axisX ? -1 : 1
                field.addPush(center: cheek, radiusX: r.x, radiusY: r.y,
                              dx: sign * width * 0.10 * slim, dy: 0, strength: 1)
                touched = true
            }
        }

        // 收下颌：下颌轮廓上的每个点朝中轴推。点与点的作用域重叠，
        // 重叠处是**累加**（场本来就是线性的），所以轮廓的推力比单点更实。
        let jaw = BeautyParameters.unit(beauty.jawSlim)
        if jaw != 0, !face.jawPoints.isEmpty {
            let r = round(width * 0.30, size: size)
            for point in face.jawPoints {
                let sign: Double = Double(point.x) > face.axisX ? -1 : 1
                field.addPush(center: point, radiusX: r.x, radiusY: r.y,
                              dx: sign * width * 0.07 * jaw, dy: 0, strength: 1)
                touched = true
            }
        }

        // 缩鼻翼：两翼朝鼻梁轴推。半径给得小，避免连带把脸颊推走。
        let nose = BeautyParameters.unit(beauty.noseSlim)
        if nose != 0 {
            let r = round(width * 0.16, size: size)
            let axis = Double(face.noseBridge.x)
            for wing in face.noseWings {
                let sign: Double = Double(wing.x) > axis ? -1 : 1
                field.addPush(center: wing, radiusX: r.x, radiusY: r.y,
                              dx: sign * width * 0.06 * nose, dy: 0, strength: 1)
                touched = true
            }
        }

        // 大眼：以虹膜圆心向外放大。中心不动，所以瞳孔位置是稳的。
        let eyes = BeautyParameters.unit(beauty.enlargeEyes)
        if eyes != 0, face.irisRadius > 1e-6 {
            let r = round(face.irisRadius * 2.4, size: size)
            for center in face.irisCenters {
                field.addMagnify(center: center, radiusX: r.x, radiusY: r.y, amount: 0.10 * eyes)
                touched = true
            }
        }

        // 微笑唇：嘴角向上 + 轻微向外。向上为主，向外为辅——只向外会把嘴拉宽。
        let smile = BeautyParameters.unit(beauty.smileLift)
        if smile != 0, face.mouthCorners.count == 2 {
            let r = round(width * 0.22, size: size)
            for corner in face.mouthCorners {
                let sign: Double = Double(corner.x) > face.axisX ? 1 : -1
                field.addPush(center: corner, radiusX: r.x, radiusY: r.y,
                              dx: sign * width * 0.04 * smile,
                              dy: -toY(width * 0.06 * smile, size: size), strength: 1)
                touched = true
            }
        }

        // 下巴：正 = 加长（内容向下），负 = 缩短。
        let chin = BeautyParameters.unit(beauty.chinAdjust)
        if chin != 0 {
            let r = round(width * 0.26, size: size)
            field.addPush(center: face.chin, radiusX: r.x, radiusY: r.y,
                          dx: 0, dy: toY(width * 0.08 * chin, size: size), strength: 1)
            touched = true
        }
        return touched
    }

    // MARK: - 美体

    static func applyBodyEdits(_ field: inout WarpField, size: PixelSize,
                               body: BodyAnchors, beauty: BeautyParameters) -> Bool {
        var touched = false

        // 细腰：腰线两侧朝躯干轴推。锚点在髋宽 ×0.45 处，比腰的实际轮廓宽一点，
        // 这样推的是"腰外的肉"而不是把脊柱那一条也拖偏。
        let waist = BeautyParameters.unit(beauty.waistSlim)
        if waist != 0 {
            let axis = Double(body.axisX(at: body.waistCenter.y))
            let offset = body.hipWidth * 0.45
            let r = round(body.hipWidth * 0.5, size: size)
            for sign in [-1.0, 1.0] {
                let center = CGPoint(x: CGFloat(axis + Double(sign) * offset), y: body.waistCenter.y)
                field.addPush(center: center, radiusX: r.x, radiusY: r.y,
                              dx: -sign * body.hipWidth * 0.10 * waist, dy: 0, strength: 1)
            }
            touched = true
        }

        // 瘦腿：以"髋—膝"中点为锚，朝各腿自己的轴推。
        let legs = BeautyParameters.unit(beauty.legsSlim)
        if legs != 0 {
            let r = round(body.shoulderWidth * 0.20, size: size)
            for side in 0 ..< 2 {
                let hip = body.hips[side], knee = body.knees[side]
                let axis = Double(hip.x + knee.x) / 2
                // 锚点放在腿轴的外侧（左腿往左、右腿往右），推的方向再朝回轴。
                let outward: Double = side == 0 ? -1 : 1
                let center = CGPoint(x: axis + outward * body.shoulderWidth * 0.10,
                                     y: Double(hip.y + knee.y) / 2)
                let sign: Double = Double(center.x) > axis ? -1 : 1
                field.addPush(center: center, radiusX: r.x, radiusY: r.y,
                              dx: sign * body.shoulderWidth * 0.05 * legs, dy: 0, strength: 1)
            }
            touched = true
        }

        // 天鹅颈：耳—肩中点（颈侧）朝颈中心轴推。
        let neck = BeautyParameters.unit(beauty.neckSlim)
        if neck != 0 {
            let r = round(body.shoulderWidth * 0.22, size: size)
            let axis = Double(body.neckCenter.x)
            for side in 0 ..< 2 {
                let center = CGPoint(x: (body.ears[side].x + body.shoulders[side].x) / 2,
                                     y: (body.ears[side].y + body.shoulders[side].y) / 2)
                let sign: Double = Double(center.x) > axis ? -1 : 1
                field.addPush(center: center, radiusX: r.x, radiusY: r.y,
                              dx: sign * body.shoulderWidth * 0.06 * neck, dy: 0, strength: 1)
            }
            touched = true
        }

        // 直角肩：肩上提 + 斜方肌（颈—肩之间那条斜坡）下压。一上一下同时做
        // 才能得到"平肩"，只提肩会把斜坡一起抬上去，反而更圆肩。
        let shoulder = BeautyParameters.unit(beauty.shoulderLift)
        if shoulder != 0 {
            let rUp = round(body.shoulderWidth * 0.26, size: size)
            let rDown = round(body.shoulderWidth * 0.18, size: size)
            for side in 0 ..< 2 {
                let point = body.shoulders[side]
                field.addPush(center: point, radiusX: rUp.x, radiusY: rUp.y,
                              dx: 0, dy: -toY(body.shoulderWidth * 0.05 * shoulder, size: size), strength: 1)
                let trap = CGPoint(x: (body.neckCenter.x + point.x) / 2, y: (body.neckCenter.y + point.y) / 2)
                field.addPush(center: trap, radiusX: rDown.x, radiusY: rDown.y,
                              dx: 0, dy: toY(body.shoulderWidth * 0.03 * shoulder, size: size), strength: 1)
            }
            touched = true
        }

        // 增高/长腿：髋线为锚，髋—踝这一段纵向摊开。锚线以上（头与躯干）
        // 逐比特不动，这是这条算子最重要的性质。
        let heighten = BeautyParameters.unit(beauty.heighten)
        if heighten != 0 {
            let ankleY = Double((body.ankles[0].y + body.ankles[1].y) / 2)
            let span = ankleY - Double(body.hipCenter.y)
            guard span > 1e-4 else { return touched }
            field.addVerticalStretch(anchorY: Double(body.hipCenter.y),
                                     length: span,
                                     scale: 1 + 0.10 * heighten)
            touched = true
        }
        return touched
    }
}
