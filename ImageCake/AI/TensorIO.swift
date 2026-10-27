import Foundation

// 图像 ↔ 张量。所有 AI 任务的"喂法"都从这里出，模型之间只有参数差异，
// 没有第二套实现。
//
// 三件在 imagecake 上有实测数字的事，这里逐条保留：
//   1. **域**：喂给网络的是 sRGB 显示码（0..255 → 变换），不是线性浮点。
//      MODNet/GFPGAN/ESRAM 都在 sRGB 码上训练，喂线性等于换一个分布。
//   2. **布局**：NCHW 与 NHWC 只差一个循环顺序，但错布局不报错、只给脏结果。
//      所以布局是从清单里读的显式参数，不是代码里的默认假设。
//   3. **值域**：unit（/255）与 symmetric（(x-127.5)/127.5）是两种口径，
//      混用的代价在 MODNet 上是 |Δα|≈1（个别像素直接反向）。

enum TensorIO {
    // MARK: - 输入

    /// RGBA8(显示码) → NCHW/NHWC float 张量。
    static func imageTensor(_ buffer: RGBA8Buffer,
                            target: PixelSize? = nil,
                            layout: TensorLayout,
                            colorOrder: ColorOrder,
                            valueRange: ValueRange,
                            mean: [Float]? = nil,
                            std: [Float]? = nil) throws -> TensorValue {
        guard buffer.size.pixelCount > 0 else { throw AIError.badInput("空图") }
        let size = target ?? buffer.size
        let resizedBytes: Data
        if size == buffer.size {
            resizedBytes = buffer.data
        } else {
            guard let display = DisplayImage(displayRGBA8: buffer) else { throw AIError.badInput("空图") }
            resizedBytes = display.resized(to: size).rgba8().data
        }

        let w = size.width
        let h = size.height
        let count = w * h
        var out = [Float](repeating: 0, count: count * 3)
        let c0: Int, c1: Int, c2: Int
        switch colorOrder {
        case .rgb: c0 = 0; c1 = 1; c2 = 2
        case .bgr: c0 = 2; c1 = 1; c2 = 0
        }
        let hasAffine = valueRange == .meanStd && (mean?.count ?? 0) >= 3 && (std?.count ?? 0) >= 3
        let order = [c0, c1, c2]
        resizedBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            out.withUnsafeMutableBufferPointer { dst in
                switch layout {
                case .nchw:
                    let plane = count
                    var i = 0
                    while i < count {
                        for c in 0 ..< 3 {
                            let value = transform(src[i * 4 + order[c]], range: valueRange,
                                                  mean: hasAffine ? mean![c] : 0,
                                                  std: hasAffine ? std![c] : 1)
                            dst[c * plane + i] = value
                        }
                        i += 1
                    }
                case .nhwc:
                    var i = 0
                    while i < count {
                        for c in 0 ..< 3 {
                            dst[i * 3 + c] = transform(src[i * 4 + order[c]], range: valueRange,
                                                       mean: hasAffine ? mean![c] : 0,
                                                       std: hasAffine ? std![c] : 1)
                        }
                        i += 1
                    }
                }
            }
        }

        let shape: [Int]
        switch layout {
        case .nchw: shape = [1, 3, h, w]
        case .nhwc: shape = [1, h, w, 3]
        }
        return TensorValue(shape: shape, data: out.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// 单通道遮罩 → [1,1,H,W]（或 NHWC 的 [1,H,W,1]）。>128 记为 1。
    static func maskTensor(_ mask: MaskBuffer, target: PixelSize? = nil, layout: TensorLayout) -> TensorValue {
        let size = target ?? mask.size
        let resized = size == mask.size ? mask : mask.resized(to: size)
        let count = size.width * size.height
        var out = [Float](repeating: 0, count: count)
        resized.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            for i in 0 ..< count {
                out[i] = src[i] > 128 ? 1 : 0
            }
        }
        let shape: [Int] = layout == .nchw ? [1, 1, size.height, size.width] : [1, size.height, size.width, 1]
        return TensorValue(shape: shape, data: out.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    @inline(__always)
    private static func transform(_ byte: UInt8, range: ValueRange, mean: Float, std: Float) -> Float {
        let v = Float(byte)
        switch range {
        case .unit:
            return v / 255
        case .symmetric:
            return (v - 127.5) / 127.5
        case .meanStd:
            return (v / 255 - mean) / max(std, 1e-6)
        }
    }

    // MARK: - 输出

    /// 网络输出的 RGB 图 → RGBA8。容忍 NCHW/NHWC、[0,1] 与 [0,255]、
    /// 单图/批量（取第 0 张）。形状对不上时点名，不做"猜一个"。
    static func image(from tensor: TensorValue, colorOrder: ColorOrder) throws -> RGBA8Buffer {
        let (shape, offset, planeStride, pixelStride) = try imageLayout(tensor.shape)
        let h = shape.height
        let w = shape.width
        let values = floatArray(tensor)
        // 值域探测：真实模型偶尔在末尾带 sigmoid/不夹取的输出（GFPGAN 实测
        // -0.44..1.24），所以按数量级判断，而不是假定 [0,1]。
        let peak = values.max() ?? 0
        let scale: Float = peak > 2 ? 1 : 255

        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let c0: Int, c1: Int, c2: Int
        switch colorOrder {
        case .rgb: c0 = 0; c1 = 1; c2 = 2
        case .bgr: c0 = 2; c1 = 1; c2 = 0
        }
        let order = [c0, c1, c2]
        for y in 0 ..< h {
            for x in 0 ..< w {
                let p = offset + y * planeStride + x * pixelStride
                let o = (y * w + x) * 4
                bytes[o] = quantize(values[p + order[0]], scale: scale)
                bytes[o + 1] = quantize(values[p + order[1]], scale: scale)
                bytes[o + 2] = quantize(values[p + order[2]], scale: scale)
                bytes[o + 3] = 255
            }
        }
        return RGBA8Buffer(size: PixelSize(width: w, height: h), data: Data(bytes))
    }

    /// 网络输出的单通道 α → 遮罩。
    ///
    /// 取整用**截断**（×255 后直接切 UInt8），与 imagecake 对齐 numpy 的
    /// `.astype('uint8')`：四舍五入会让边缘码值系统性偏亮一档。
    static func alpha(from tensor: TensorValue) throws -> MaskBuffer {
        let dims = tensor.shape.filter { $0 > 1 }
        // 常见形状：[1,1,H,W]、[1,H,W]、[H,W]；H/W 取最后两维。
        guard tensor.shape.count >= 2 else {
            throw AIError.badShape("α 张量形状不认识：\(tensor.shape)")
        }
        let h = tensor.shape[tensor.shape.count - 2]
        let w = tensor.shape[tensor.shape.count - 1]
        guard h > 0, w > 0, dims.count >= 2 else {
            throw AIError.badShape("α 张量形状不认识：\(tensor.shape)")
        }
        let values = floatArray(tensor)
        guard values.count >= w * h else {
            throw AIError.badShape("α 元素数 \(values.count) 少于 \(w)×\(h)")
        }
        let peak = values.max() ?? 0
        let scale: Float = peak > 2 ? 1 : 255
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0 ..< (w * h) {
            let v = Swift.min(Swift.max(values[i], 0), 1)
            bytes[i] = UInt8(v * scale)
        }
        return MaskBuffer(size: PixelSize(width: w, height: h), data: Data(bytes))
    }

    // MARK: - 形状解析

    private struct ImageShape {
        var height: Int
        var width: Int
    }

    private static func imageLayout(_ shape: [Int]) throws -> (ImageShape, offset: Int, planeStride: Int, pixelStride: Int) {
        // NCHW
        if shape.count == 4, shape[1] == 3 {
            let h = shape[2], w = shape[3]
            guard h > 0, w > 0 else { throw AIError.badShape("空输出：\(shape)") }
            return (ImageShape(height: h, width: w), 0, h * w, 1)
        }
        // NHWC
        if shape.count == 4, shape[3] == 3 {
            let h = shape[1], w = shape[2]
            guard h > 0, w > 0 else { throw AIError.badShape("空输出：\(shape)") }
            return (ImageShape(height: h, width: w), 0, w * 3, 3)
        }
        // [3,H,W]
        if shape.count == 3, shape[0] == 3 {
            let h = shape[1], w = shape[2]
            guard h > 0, w > 0 else { throw AIError.badShape("空输出：\(shape)") }
            return (ImageShape(height: h, width: w), 0, h * w, 1)
        }
        // [H,W,3]
        if shape.count == 3, shape[2] == 3 {
            let h = shape[0], w = shape[1]
            guard h > 0, w > 0 else { throw AIError.badShape("空输出：\(shape)") }
            return (ImageShape(height: h, width: w), 0, w * 3, 3)
        }
        throw AIError.badShape("输出形状不认识：\(shape)")
    }

    static func floatArray(_ tensor: TensorValue) -> [Float] {
        guard tensor.data.count >= 4 else { return [] }
        return tensor.data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    @inline(__always)
    private static func quantize(_ value: Float, scale: Float) -> UInt8 {
        let v = Swift.min(Swift.max(value, 0), 1)
        return UInt8(v * scale)
    }
}
