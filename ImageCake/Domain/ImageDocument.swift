import CoreGraphics
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
// 渲染顺序（与 imagecake 的链同序，只保留可验证的阶段）：
//   几何转正 → [老照片] → 线性调色 → 显示域调色 → [本地调节] → [皮肤掩码]
//   → [滤镜/LUT] → [镜头畸变、色差] → 降噪 → 锐化 → [美肤] → [五官区域美化]
//   → [妆容模板] → [手部] → [头发] → [美型预设形变] → 手动液化 → 仿制图章
//   → [衣物祛褶] → 修补 → 修复补丁 → 换底色 → [换天空] → [虚拟打光]
//   → [暗角、颗粒]
//
// 几个位置的硬理由：
//   · 几何最先：它改画布尺寸，之后的归一化坐标（笔迹/遮罩/关键点）才都是
//     “用户当前看到的画面”上的坐标；
//   · 皮肤掩码在滤镜之前：风格会把色相整体推走，在推之前的色调上判肤色更稳；
//   · 畸变/色差在笔刷之前：它们也改像素位置，排在笔刷后面会把已落好的笔迹抬位；
//   · 暗角与颗粒最后：超清/重绘会拿粒度当细节放大，必须等一切像素级处理完了再加。
//
// 笔刷为什么夹在空间滤波之后、补丁之前：一条硬规则——**每个笔刷看到的
// 画面，必须就是用户落笔那一刻在画面上看到的画面**。预览与导出都按同一
// 次序重放，坐标才保证不漂（见 docs/parity.md §4）。推论是落笔顺序即渲染
// 顺序：先框选再液化，补丁会落在液化后的位置上——因为用户确实是对着
// 液化后的画面画的框。反过来（笔刷在调色之前）则不成立：调色后的像素
// 已经变了，图章从「看不到的颜色」取样。
//
// 已知代价（不是 bug）：几何变换不会重映射已有笔迹/AI 资产的坐标。
// 所以上面的次序里“几何最先”同时意味着：**先定构图再落笔**；
// 先画完再旋转，旧笔迹会落在转过之后的不同内容上。

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

    /// 全部人脸的语义量（归一化坐标），按脸的面积从大到小排。
    /// 由 478 点关键点逐张派生，存在文档里而不是只存在面板里：预览与
    /// 导出都要用它，而它们只拿得到 document。
    ///
    /// 为什么是数组而不是单张：像素蛋糕的"逐脸自适应"意味着合影里
    /// **每张脸都磨皮、每张脸都推形变**，只处理最大的那张脸的产品在
    /// 家庭照上会明显露馅（爸爸的脸没动）。形变与区域美化本来就是把
    /// 每张脸的锚点累加进同一个底座（位移场 / 权重图），多张脸只是多
    /// 累加几笔，不需要第二套算子。
    var faceGeometries: [FaceGeometry] = []

    /// 主脸（面积最大的那张）的语义量。证件照构图、智能构图这类
    /// "只有一个主体"的场景用它；区域美化/美型用整个 `faceGeometries`。
    var faceGeometry: FaceGeometry? { faceGeometries.first }

    /// 身形锚点（归一化坐标，17 点派生）。nil = 还没测过或没测到。
    var bodyAnchors: BodyAnchors? = nil

    /// 证件照排版。只挂导出（预览看的是单张构图，不是相纸）。
    var idPhotoSheet: IDPhotoSheet? = nil

    /// 拼图排版。同样只挂导出：预览看单张，拼图是"一次出片"而不是一个开关。
    var collage: CollageComposition? = nil

    /// 手部凸包（归一化坐标，每组一只手的关节点）。由"检测手部"写入；
    /// 空 = 没测过或没测到，此时手部美化整段不跑并点名 `[no_hand]`。
    var handHulls: [[CGPoint]] = []

    /// 天空区域（画布尺寸）。与 personMask 同一性质：跑一次得到的资产，
    /// 不跟着参数重算。nil = 还没检测，此时换天空不跑并点名 `[no_sky_mask]`。
    var skyMask: MaskBuffer? = nil

    /// 导入的那张天（已 cover-fit 到当前画布）。与 `.cube` 表同一待遇：
    /// 只存名字在参数里，字节由编辑器读盘后放这里，预览与导出共用。
    var skyPhoto: DisplayImage? = nil

    var canvasSize: PixelSize { linear.size }
    var hasPersonMask: Bool { personMask != nil }

    /// 全部人脸框（归一化），给皮肤掩码分脸/身用。没有关键点就是空。
    /// SkinMask 侧对多个框是"落在任一框内即算脸部"，所以合影里每张脸的
    /// 脸部力度都作用于自己的脸，而不是只糊最大的一张。
    var faceBoxes: [CGRect] {
        faceGeometries.compactMap { geo -> CGRect? in
            let bounds = geo.bounds
            return (bounds.width > 0 && bounds.height > 0) ? bounds : nil
        }
    }

    /// “开了开关但缺资产”的点名。预览底栏与导出报告共用这一份，
    /// 因为“调了滑杆什么也没变”必须先被说清楚，而不是被归为“工具坏了”。
    var pipelineWarnings: [String] {
        var notes: [String] = []
        let beauty = params.beauty
        // 造型与场景六组住在 `params` 里，不是 document 自己的字段：
        // 这里先命名一份局部别名，避开在下面六处重复写 `params.`。
        let makeup = params.makeup
        let hair = params.hair
        let hand = params.hand
        let garment = params.garment
        let sky = params.sky
        let light = params.light
        if !beauty.isRegionNeutral, faceGeometries.isEmpty {
            notes.append("[no_landmarks] 没检测人脸关键点：亮眼/牙齿/唇色/腮红/祛黑眼圈/法令纹未生效")
        }
        if !beauty.isFaceShapeNeutral, faceGeometries.isEmpty {
            notes.append("[no_landmarks] 没检测人脸关键点：瘦脸/大眼等美型未生效")
        }
        if !beauty.isBodyShapeNeutral, bodyAnchors == nil {
            notes.append("[no_pose] 没检测身形关键点：瘦腰/长腿等美体未生效")
        }
        if !params.filter.isNeutral, FilterEngine.resolve(name: params.filter.style) == nil {
            notes.append("[no_lut:\(params.filter.style)] 找不到这张滤镜表，已跳过滤镜")
        }
        if !beauty.isSkinNeutral, personMask == nil, faceGeometries.isEmpty {
            notes.append("[no_constraint] 没有 α 也没有关键点：皮肤只按色域判，暖色背景会被连进去")
        }
        // 造型与场景各组：缺的是哪个资产就说哪个，不拿"没反应"交差。
        if !makeup.isNeutral, faceGeometries.isEmpty {
            notes.append("[no_landmarks] 没检测人脸关键点：妆容模板未生效")
        } else if !makeup.isNeutral, MakeupEngine.look(id: makeup.styleID) == nil {
            notes.append("[no_makeup:\(makeup.styleID)] 找不到这个妆容模板")
        }
        if !hair.isNeutral, faceGeometries.isEmpty {
            notes.append("[no_landmarks] 没检测人脸关键点：头发美化未生效（发区靠脸定位）")
        }
        if !hand.isNeutral, handHulls.isEmpty {
            notes.append("[no_hand] 没检测到手：手部美化未生效（Vision 手部姿态，零权重）")
        }
        if !garment.isNeutral, brush.garments.isEmpty {
            notes.append("[no_garment_region] 没涂衣物区：祛褶要先在画面上涂一块（全自动需要服装分割权重）")
        }
        if !sky.isNeutral, skyMask == nil {
            notes.append("[no_sky_mask] 还没检测天空：换天空未生效")
        } else if !sky.isNeutral, sky.mode == .photo, skyPhoto == nil, !sky.sourceName.isEmpty {
            notes.append("[no_sky:\(sky.sourceName)] 找不到导入的那张天，已整段跳过而不是拿渐变冒充")
        }
        if !light.isNeutral {
            // 打光不需要资产，但它是"没结构可打"时静默不动的唯一一组，
            // 所以要给一条能说清的提示（全图抹平后没有梯度 = 一张灰纸）。
            notes.append("[relight] 虚拟打光是梯度近似：平坦无结构的区域不会有任何变化")
        }
        if params.bgEnabled, personMask == nil {
            notes.append("[no_mask] 未抠图，换底色被跳过")
        }
        if let collage {
            // 拼图只在导出时排版，但"图不够"这件事要提前说：底栏里看到
            // `[collage_short]` 比导出后才知道少一张图便宜得多。
            if CollageEngine.template(id: collage.templateID) == nil {
                notes.append(CollageComposition.missingTemplateNote)
            } else if let warning = collage.shortfallWarning(
                slots: CollageEngine.template(id: collage.templateID)!.slots.count) {
                notes.append(warning)
            }
        }
        return notes
    }

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
        // -1. 几何转正（旋转/翻转/裁剪）。最先做：它改画布尺寸，后面所有
        //     归一化坐标指的都是用户看到的这一帧。恒等时整段跳过（不插值、
        //     不重采样，中性图逐比特不变）。
        var workingLinear = GeometryEngine.apply(geometry, to: linear)

        // 0. 老照片修复：褪色恢复 + 划痕去除。在调色之前——它改的是输入
        //    本身的化学褪变，不是创意调色。先修后调，调色才不会把褪色
        //    当成"有意为之"再去抵消。
        if oldPhotoRestore {
            let display = ToneEngine.render(workingLinear, params: EditParameters())
            let restored = OldPhotoEngine.restore(display, scratchThreshold: oldPhotoScratchThreshold)
            workingLinear = LinearImage(display: restored.0) ?? workingLinear
        }

        var display = ToneEngine.render(workingLinear, params: params)

        // 本地调节：在全局调色之后、空间滤波之前。选区内再叠一层调色，
        // 选区外不动。复用笔迹底座做掩码，与保护笔刷同构。
        if !localAdjustments.isEmpty {
            display = LocalAdjustmentEngine.apply(display, adjustments: localAdjustments, linear: workingLinear)
        }

        // 皮肤掩码：在滤镜之前判。风格会把整个色相分布推走，皮肤椭圆
        // 门限在推之前的色调上才是调好的那一个。算一次就用到底（美肤与
        // 导出报告共用），所以它不是“顺便算算”，而是被开关闸住的必经步。
        let skinLayers: SkinMask.Layers?
        if params.beauty.isSkinNeutral {
            skinLayers = nil
        } else {
            skinLayers = SkinMask.build(display, personMask: personMask, faceBoxes: faceBoxes)
        }

        // 滤镜/LUT：逐点映射，在任何读邻域的算子之前做（它只改颜色不改结构）。
        if !params.filter.isNeutral, let lut = FilterEngine.resolve(name: params.filter.style) {
            display = FilterEngine.apply(display, lut: lut, strength: params.filter.strength)
        }

        // 镜头几何：畸变与色差。在笔刷之前——它们改像素位置。
        if !params.lens.isGeometryNeutral {
            display = LensEngine.applyGeometry(display, lens: params.lens)
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

        // 皮肤精修。在降噪之后：磨皮自己就是保边平滑，先把传感器噪声降噪
        // 一遍再磨，比拿噪声去调“纹理保留量”稳定得多。
        if let skinLayers {
            display = BeautyEngine.apply(display, skin: skinLayers, beauty: params.beauty)
        }

        // 五官区域美化（亮眼/牙齿/唇色/腮红/祛黑眼圈/法令纹）：逐张脸都做，
        // 一张关键点都给不出就整段跳过。
        if !params.beauty.isRegionNeutral {
            display = RegionEnhance.apply(display, geometries: faceGeometries, beauty: params.beauty)
        }

        // 妆容模板：跟区域美化同一层、同一依赖（关键点），所以紧跟其后。
        // 它在祛黑眼圈/法令纹之后：妆是"往上叠东西"，专项瑕疵是"去掉不该有的差"，
        // 顺序反了会把刚填平的瑕疵又盖一层颜色。
        if !params.makeup.isNeutral {
            display = MakeupEngine.apply(display, geometries: faceGeometries, makeup: params.makeup)
        }

        // 手部与头发：都是"靠另一个区域定位的人像修改"，排在美型形变之前——
        // 形变会搬运像素，先推脸再磨手会让两者用的区域不是同一块画面。
        if !params.hand.isNeutral, !handHulls.isEmpty {
            let weights = HandMask.build(size: display.size, hulls: handHulls, pixels: display.pixels)
            display = HandEngine.apply(display, weights: weights, hands: params.hand)
        }
        if !params.hair.isNeutral, let bounds = faceGeometry?.bounds {
            let weights = HairMask.build(display, faceBounds: bounds, personMask: personMask)
            display = HairEngine.apply(display, weights: weights, hair: params.hair)
        }

        // 形变类：美型预设 → 手动液化 → 仿制图章。
        // 预设排在手动之前：手动笔迹是用户“对着当前画面推”的结果，
        // 它必须是最后一位挪像素的人；保护掩码三者共用，只栅格化一次。
        if !params.beauty.isShapeNeutral || !brush.liquify.isEmpty || !brush.stamps.isEmpty {
            let protectionMask = brush.protectionMask(for: display.size)
            if !params.beauty.isShapeNeutral {
                display = ShapeWarp.apply(display, faces: faceGeometries, body: bodyAnchors,
                                          beauty: params.beauty, protection: protectionMask)
            }
            if !brush.liquify.isEmpty {
                display = LiquifyEngine.apply(display, strokes: brush.liquify, protection: protectionMask)
            }
            if !brush.stamps.isEmpty {
                display = CloneStampEngine.apply(display, stamps: brush.stamps, protection: protectionMask)
            }
        }

        // 衣物祛褶：跟在图章之后、修补之前。它和液化/图章一样是"对着当前画面
        // 涂一块"的历史操作，所以必须待在同一族里——放在修复补丁之后会让
        // 用户刚熨平的地方又被补丁贴回褶纹。
        if !params.garment.isNeutral, let garmentMask = brush.garmentMask(for: display.size) {
            display = GarmentEngine.apply(display, weights: SkinMask.weights(garmentMask, size: display.size),
                                          garment: params.garment)
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

        // 换天空：在换底色之后（两者都在背景层动手，但天空的掩码更局部）。
        // 没检测到天空、或没读到导入的那张天 → 整段不跑，不拿渐变冒充。
        if !params.sky.isNeutral, let skyMask = skyMask {
            let weights = SkinMask.weights(skyMask.resized(to: display.size), size: display.size)
            if params.sky.mode == .gradient || display.size == skyPhoto?.size {
                display = SkyEngine.apply(display, weights: weights, sky: params.sky, photo: skyPhoto)
            }
        }

        // 虚拟打光与暗角、颗粒一起属于输出层：打光要在画面里的东西都定下来之后
        // 再加（否则磨皮会把刚加的方向对比又抹平），而它必须在暗角之前——
        // 暗角是"四角变暗"，跟在新光后面会把刚建立的方向关系抹平。
        if !params.light.isNeutral {
            display = RelightEngine.apply(display, light: params.light)
        }

        // 暗角与颗粒：输出层，最后一道。
        if !params.lens.isOverlayNeutral {
            display = LensEngine.applyOverlay(display, lens: params.lens)
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
