import Foundation

// 一张图在会话里的全部状态。
//
// 分工：
//   · tone 链是**纯参数**的（改滑杆就从 linear 重算一遍）；
//   · 笔刷（液化/图章/保护）是**历史**的（一笔就是一条记录，不可重算只可重放）；
//   · 人像 α 与修复补丁是**资产**（跑一次 AI 得到的，跨越参数变化复用）；
//   · 抠图/修复都存"参考尺寸"：预览是降采样的，导出是全分辨率的，
//     没有参考尺寸就只能靠当前画布猜，而猜错的表现是"遮罩整体错位"。
//
// 渲染顺序（与 imagecake 的链同序，只保留 v1 范围内可验证的阶段）：
//   线性调色 → 显示域调色 → 空间滤波 → 液化 → 仿制图章 → 修复补丁 → 换底色/背景虚化
//
// 笔刷为什么夹在空间滤波之后、补丁之前：一条硬规则——**每个笔刷看到的
// 画面，必须就是用户落笔那一刻在画面上看到的画面**。预览与导出都按同一
// 次序重放，坐标才保证不漂（见 docs/parity.md §4）。推论是落笔顺序即渲染
// 顺序：先框选再液化，补丁会落在液化后的位置上——因为用户确实是对着
// 液化后的画面画的框。反过来（笔刷在调色之前）则不成立：调色后的像素
// 已经变了，图章从「看不到的颜色」取样。

struct ImageDocument: Sendable {
    /// 工作分辨率的线性图（预览档）。导出时由 ExportPipeline 重新载入全量。
    var linear: LinearImage
    var originalSize: PixelSize
    var params: EditParameters
    var sourceURL: URL?
    var isRAW: Bool
    var loadNote: String

    /// 人像 α（maskReference 尺寸）。nil = 还没抠过。
    var personMask: MaskBuffer?
    var maskReference: PixelSize

    /// 修复补丁（按 ref 尺寸存）。
    var patches: [InpaintPatch]

    /// 笔刷类编辑（液化/图章/保护）。存笔迹不存栅格化结果，理由见 BrushState。
    var brush: BrushState

    /// 几何变换（旋转/翻转/裁剪）。不进预设：改画布尺寸，与调色参数不同生命周期。
    var geometry: GeometryTransform = .identity

    /// 水印/边框/文字贴纸。只挂导出，不进预览管线。
    var overlays: [OverlayElement] = []

    /// 本地调节（选区内调色）。复用笔迹底座做选区掩码。
    var localAdjustments: [LocalAdjustment] = []

    /// 修补笔迹（同图取样修复，与 LaMa 互补）。
    var patchStrokes: [PatchStroke] = []

    /// 老照片修复开关。
    var oldPhotoRestore: Bool = false
    var oldPhotoScratchThreshold: Double = 0.15

    var canvasSize: PixelSize { linear.size }
    var hasPersonMask: Bool { personMask != nil }

    init(loaded: LoadedImage, url: URL) {
        self.linear = loaded.linear
        self.originalSize = loaded.originalSize
        self.params = EditParameters()
        self.sourceURL = url
        self.isRAW = loaded.isRAW
        self.loadNote = loaded.note
        self.personMask = nil
        self.maskReference = loaded.linear.size
        self.patches = []
        self.brush = BrushState()
    }

    init(linear: LinearImage, originalSize: PixelSize, params: EditParameters,
         sourceURL: URL?, isRAW: Bool, loadNote: String,
         personMask: MaskBuffer?, maskReference: PixelSize, patches: [InpaintPatch],
         brush: BrushState = BrushState()) {
        self.linear = linear
        self.originalSize = originalSize
        self.params = params
        self.sourceURL = sourceURL
        self.isRAW = isRAW
        self.loadNote = loadNote
        self.personMask = personMask
        self.maskReference = maskReference
        self.patches = patches
        self.brush = brush
    }

    /// 预览/导出共用的一次渲染。返回显示码图（8bit 编码前）。
    func render(applyMask: Bool = true) -> DisplayImage {
        var workingLinear = linear

        // 0. 老照片修复：褪色恢复 + 划痕去除。在调色之前——它改的是输入
        //    本身的化学褪变，不是创意调色。先修后调，调色才不会把褪色
        //    当成"有意为之"再去抵消。
        if oldPhotoRestore {
            let display = ToneEngine.render(workingLinear, params: EditParameters())
            let restored = OldPhotoEngine.restore(display, scratchThreshold: oldPhotoScratchThreshold)
            workingLinear = LinearImage(rgba8: restored.0.rgba8()) ?? workingLinear
        }

        var display = ToneEngine.render(workingLinear, params: params)

        // 本地调节：在全局调色之后、空间滤波之前。选区内再叠一层调色，
        // 选区外不动。复用笔迹底座做掩码，与保护笔刷同构。
        if !localAdjustments.isEmpty {
            display = LocalAdjustmentEngine.apply(display, adjustments: localAdjustments, linear: workingLinear)
        }

        // 空间滤波：先降噪再锐化（反过来等于先把噪声锐化一遍）。
        // 放在补丁合成**之前**：补丁是 AI 的输出（本身干净而锐利），
        // 不该被再降噪一次或再锐化一次——那会让“修过的区域”和周围质感不一。
        // 背景替换更靠后，因为它是逐像素 α 合成，不是空间操作。
        if !params.isSpatialNeutral {
            if params.denoise > 0 {
                display = SpatialFilters.denoise(display, strength: params.denoise)
            }
            if params.sharpen > 0 {
                display = SpatialFilters.sharpen(display, strength: params.sharpen)
            }
        }

        // 笔刷：液化先于图章。液化改变像素位置，图章按位置从当前画面取样——
        // 反过来则图章搬进去的内容会被随后的位移场再次推走。
        if !brush.liquify.isEmpty || !brush.stamps.isEmpty {
            // 两个工具共用同一张保护掩码（保护笔刷对两者都成立，不该各涂一遍），
            // 所以只按当前画布栅格化一次。
            let protectionMask = brush.protectionMask(for: display.size)
            if !brush.liquify.isEmpty {
                display = LiquifyEngine.apply(display, strokes: brush.liquify, protection: protectionMask)
            }
            if !brush.stamps.isEmpty {
                display = CloneStampEngine.apply(display, stamps: brush.stamps, protection: protectionMask)
            }
        }

        // 修补笔迹（同图取样）：在图章之后、补丁之前。图章和修补都是
        // 从当前画面取样，但修补是固定偏移量，图章是动态锚点。
        if !patchStrokes.isEmpty {
            display = PatchEngine.apply(display, strokes: patchStrokes)
        }

        // 修复补丁：只在尺寸对得上时按相对量贴回去。
        if !patches.isEmpty {
            var bytes = display.rgba8()
            for patch in patches {
                let scaled: InpaintPatch?
                if patch.reference == canvasSize {
                    scaled = patch
                } else {
                    scaled = patch.scaled(to: canvasSize)
                }
                guard let scaled else { continue }
                bytes = InpaintTask.compose(bottom: bytes, patch: scaled)
            }
            if let rebuilt = DisplayImage(displayRGBA8: bytes) {
                display = rebuilt
            }
        }

        if applyMask, params.bgEnabled, let mask = personMask {
            display = Self.replaceBackground(display: display, mask: mask, params: params)
        }
        return display
    }

    /// 换底色 / 背景虚化。mask 255 = 人像保留。
    ///
    /// 没有抠图就整段 no-op：让"选了底色但画面没变"这件事在 UI 里被点名，
    /// 而不是在这里悄悄拿整张图当人像。
    static func replaceBackground(display: DisplayImage, mask: MaskBuffer, params: EditParameters) -> DisplayImage {
        let canvas = display.size
        let alpha = mask.resized(to: canvas)
        guard !alpha.isEmpty else { return display }

        // 边缘去色溢出必须在合成之前：合成本身是 straight alpha 混合，
        // 边缘那圈混了原背景的 RGB 会按 (1−α) 留下来。
        // 虚化路径同样需要——糊掉的背景也会把脏色混进边缘。
        let personImage = params.defringe > 0
            ? EdgeDefringe.apply(display, alpha: alpha, strength: params.defringe)
            : display

        let background: [Float]
        if params.bgBlur > 0 {
            let radius = max(1, Int(Double(params.bgBlur) / 100 * Double(canvas.longEdge) * 0.03))
            if radius > 8 {
                // 大半径先在 1/4 档上模糊再放大：4MP 上半径 60 的三次盒式模糊
                // 是十亿级运算，滑杆一动就是几秒；降档后代价降到 1/16，
                // 而背景本来就该是糊的。
                let small = PixelSize(width: max(1, canvas.width / 4), height: max(1, canvas.height / 4))
                let reduced = Resampler.resample(display.pixels, channels: 4, from: canvas, to: small, alphaAware: false)
                let blurredSmall = blurred(reduced, size: small, radius: max(1, radius / 4))
                background = Resampler.resample(blurredSmall, channels: 4, from: small, to: canvas, alphaAware: false)
            } else {
                background = blurred(display.pixels, size: canvas, radius: radius)
            }
        } else {
            let r = Float(params.bgR / 255), g = Float(params.bgG / 255), b = Float(params.bgB / 255)
            var color = [Float](repeating: 1, count: canvas.pixelCount * 4)
            var i = 0
            while i < canvas.pixelCount * 4 {
                color[i] = r; color[i + 1] = g; color[i + 2] = b
                i += 4
            }
            background = color
        }

        var out = [Float](repeating: 0, count: canvas.pixelCount * 4)
        let alphaBytes = [UInt8](alpha.data)
        personImage.pixels.withUnsafeBufferPointer { person in
            background.withUnsafeBufferPointer { bg in
                out.withUnsafeMutableBufferPointer { dst in
                    var i = 0
                    while i < canvas.pixelCount {
                        let a = Float(alphaBytes[i]) / 255
                        let o = i * 4
                        for c in 0 ..< 3 {
                            dst[o + c] = person[o + c] * a + bg[o + c] * (1 - a)
                        }
                        dst[o + 3] = person[o + 3] * a + bg[o + 3] * (1 - a)
                        i += 1
                    }
                }
            }
        }
        return DisplayImage(size: canvas, pixels: out)
    }

    /// 三次盒式模糊（近似高斯）。只在背景虚化上用，不需要频域精度。
    static func blurred(_ pixels: [Float], size: PixelSize, radius: Int) -> [Float] {
        guard radius > 0, size.pixelCount > 0 else { return pixels }
        var buffer = pixels
        for _ in 0 ..< 3 {
            buffer = boxBlurRGBA(buffer, size: size, radius: radius)
        }
        return buffer
    }

    private static func boxBlurRGBA(_ src: [Float], size: PixelSize, radius: Int) -> [Float] {
        let w = size.width
        let h = size.height
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        let window = Float(radius * 2 + 1)

        for y in 0 ..< h {
            for c in 0 ..< 4 {
                var sum: Float = 0
                for x in -radius ... radius {
                    sum += src[(y * w + min(max(x, 0), w - 1)) * 4 + c]
                }
                for x in 0 ..< w {
                    tmp[(y * w + x) * 4 + c] = sum / window
                    sum -= src[(y * w + min(max(x - radius, 0), w - 1)) * 4 + c]
                    sum += src[(y * w + min(max(x + radius + 1, 0), w - 1)) * 4 + c]
                }
            }
        }
        for x in 0 ..< w {
            for c in 0 ..< 4 {
                var sum: Float = 0
                for y in -radius ... radius {
                    sum += tmp[(min(max(y, 0), h - 1) * w + x) * 4 + c]
                }
                for y in 0 ..< h {
                    out[(y * w + x) * 4 + c] = sum / window
                    sum -= tmp[(min(max(y - radius, 0), h - 1) * w + x) * 4 + c]
                    sum += tmp[(min(max(y + radius + 1, 0), h - 1) * w + x) * 4 + c]
                }
            }
        }
        return out
    }
}
