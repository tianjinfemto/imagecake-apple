import CoreGraphics
import Foundation

// 皮肤掩码：哪些像素算"皮肤"。
//
// 像素蛋糕的磨皮/肤色统一/祛油光全都建立在"只作用于皮肤"这件事上。这里
// 用**色域判定 + 人像 α/人脸框约束**的确定性方案，不引入皮肤分割网络：
// 色域判定零权重、可离线断言、失败模式可解释（判错的是一块色，不是一个
// 黑盒），并且人像 α 与人脸框本来就已经在文档里了。
//
// 已知边界（写清楚，别当成 AI）：单靠色域会把木地板、沙色墙面、暖色衣物
// 判成皮肤。所以三层约束缺一不可：
//   1. YCbCr 肤色椭圆 + HSV 色相/饱和双门限（色域）；
//   2. 有人像 α 时按 α 相与（把背景里那面沙色墙切掉）；
//   3. 有 478 关键点时按人脸框把"脸"与"身"分开（身体力度不会糊到脸上）。
// 三条都不满足时（无 α、无关键点）掩码覆盖全图色域命中的像素，并在
// 调用侧点名 `[no_constraint]` —— 而不是静默地把沙发当脸磨。

enum SkinMask {
    /// 一张画布上的三层皮肤权重（0…255，画布尺寸）。
    struct Layers: Sendable {
        /// 全图皮肤（脸 + 身）。
        let all: MaskBuffer
        /// 脸部皮肤。关键点缺失时等于 all。
        let face: MaskBuffer
        /// 身体皮肤 = all ∧ ¬脸部外扩框。关键点缺失时为空（身体力度不生效）。
        let body: MaskBuffer
        /// 是否拿到了"脸/身"的约束依据。
        let hasFaceConstraint: Bool
    }

    // MARK: - 单像素判定（纯函数，可断言）

    /// 显示码（sRGB 0…1）下的肤色判定。
    ///
    /// 两道门限同时成立才算皮肤：
    ///   · YCbCr：Cb ∈ [77,130]、Cr ∈ [133,173]（经典肤色椭圆，偏暖偏亮的一半）；
    ///   · HSV：色相 ∈ [−8,52]°（含_wrap_的红侧）、饱和度 ∈ [0.06,0.65]、明度 ≥ 0.18。
    /// 饱和上限是关键：深色木头的 V 与色相都落在皮肤区里，只有 s=0.68 能把它挡住。
    static func isSkin(r: Double, g: Double, b: Double) -> Bool {
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let cb = 128 + 143.6 * (b - y)
        let cr = 128 + 182.2 * (r - y)
        guard cb >= 77, cb <= 130, cr >= 133, cr <= 173 else { return false }

        let maxV = Swift.max(r, Swift.max(g, b))
        let minV = Swift.min(r, Swift.min(g, b))
        let delta = maxV - minV
        guard maxV >= 0.18 else { return false }              // 太暗的不是皮肤
        let saturation = maxV <= 1e-6 ? 0 : delta / maxV
        guard saturation >= 0.06, saturation <= 0.65 else { return false }

        var hue: Double = 0
        if delta > 1e-6 {
            if maxV == r {
                hue = 60 * ((g - b) / delta)
            } else if maxV == g {
                hue = 60 * (2 + (b - r) / delta)
            } else {
                hue = 60 * (4 + (r - g) / delta)
            }
            if hue < 0 { hue += 360 }
        }
        // 红侧是环绕的：350–360 与 0–52 都算（泛红的皮肤与偏黄的皮肤同属一类）。
        return hue <= 52 || hue >= 348
    }

    // MARK: - 建掩码

    /// 在画布尺寸上生成皮肤分层。
    ///
    /// - Parameters:
    ///   - image: 已经过调色的画面（判定吃显示码，与整条显示域链一致）。
    ///   - personMask: 人像 α（可以是任意图幅，内部按画布重采样）。
    ///   - faceBoxes: 人脸框，**归一化**（0…1）。空 = 没有关键点可依据。
    static func build(_ image: DisplayImage,
                      personMask: MaskBuffer?,
                      faceBoxes: [CGRect]) -> Layers {
        let size = image.size
        let count = size.pixelCount
        guard count > 0 else {
            let empty = MaskBuffer.filled(size, value: 0)
            return Layers(all: empty, face: empty, body: empty, hasFaceConstraint: false)
        }

        // 1. 色域命中 → 二值。
        var skin = [UInt8](repeating: 0, count: count)
        image.pixels.withUnsafeBufferPointer { src in
            for i in 0 ..< count {
                let o = i * 4
                if isSkin(r: Double(src[o]), g: Double(src[o + 1]), b: Double(src[o + 2])) {
                    skin[i] = 255
                }
            }
        }

        // 2. 人像 α 相与：背景里的暖色墙不是皮肤。
        if let person = personMask?.resized(to: size), !person.isEmpty {
            let bytes = [UInt8](person.data)
            for i in 0 ..< count where skin[i] > 0 {
                skin[i] = Swift.min(skin[i], bytes[i])
            }
        }

        let feather = Swift.max(2, size.longEdge / 150)
        let all = MaskOps.feathered(MaskBuffer(size: size, data: Data(skin)), radius: feather)

        guard !faceBoxes.isEmpty else {
            // 没有关键点：脸/身分不开。宁可把全部皮肤交给"脸部"力度（保守，
            // 因为脸部力度通常更弱），身体那一层留空——而不是拿身体强度去糊脸。
            return Layers(all: all, face: all, body: MaskBuffer.filled(size, value: 0),
                          hasFaceConstraint: false)
        }

        var faceBytes = [UInt8](repeating: 0, count: count)
        var bodyBytes = [UInt8](repeating: 0, count: count)
        let allBytes = [UInt8](all.data)
        let rectangles = faceBoxes.map { PixelRect.fromNormalized($0, in: size).expanded(by: Swift.max(2, size.longEdge / 60)) }
        for y in 0 ..< size.height {
            let row = y * size.width
            for x in 0 ..< size.width {
                let index = row + x
                let value = allBytes[index]
                guard value > 0 else { continue }
                var inFace = false
                for rect in rectangles where rect.contains(x: x, y: y) {
                    inFace = true
                    break
                }
                if inFace { faceBytes[index] = value } else { bodyBytes[index] = value }
            }
        }
        return Layers(all: all,
                      face: MaskBuffer(size: size, data: Data(faceBytes)),
                      body: MaskBuffer(size: size, data: Data(bodyBytes)),
                      hasFaceConstraint: true)
    }

    /// 掩码 → 0…1 权重（算子里按像素乘）。空掩码返回全零而不是崩溃。
    static func weights(_ mask: MaskBuffer, size: PixelSize) -> [Float] {
        guard size.pixelCount > 0 else { return [] }
        let resized = mask.size == size ? mask : mask.resized(to: size)
        guard !resized.isEmpty else { return [Float](repeating: 0, count: size.pixelCount) }
        let bytes = [UInt8](resized.data)
        var out = [Float](repeating: 0, count: bytes.count)
        for i in 0 ..< bytes.count { out[i] = Float(bytes[i]) / 255 }
        return out
    }
}

private extension PixelRect {
    func contains(x: Int, y: Int) -> Bool {
        x >= self.x && x < maxX && y >= self.y && y < maxY
    }
}
