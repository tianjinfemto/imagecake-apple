import Foundation

// 皮肤精修。像素蛋糕的"人像"模块里最值钱的一层就是这几个算子，
// 它们全都零权重、确定性、可离线断言——所以能测的必须全测。
//
// 三段，顺序固定（每一段的输入都是上一段的输出）：
//   1. 磨皮（频率分离）：把画面拆成「低频 = 光影与不均匀」和
//      「高频 = 纹理（毛孔/绒毛）」，只平滑低频再叠回高频。
//      这是"中性灰磨皮"的数学内核：修的是光影，不是把像素糊掉。
//      两种模式对应产品上的「平整 / 立体」：平整连明暗过渡一起抹，
//      立体只压中频噪点、保留脸上的立体光影。
//   2. 祛瑕疵：与邻域低频**差得离谱**的小面积像素（痘印、斑点、胡茬点）
//      用邻域低频填掉。阈值随力度收紧——力度 20 只抓明显的痘，100 连细小色差也抓。
//   3. 肤色/亮度四件套（统一、祛红、祛油光、美白）：一次「亮度 + 两路色度」
//      的对立色空间处理。色度往**局部均值**收敛，亮度按各自规则改，
//      所以不会把脸上的结构抹平（结构在亮度里）。
//
// 三段都由皮肤掩码定区：掩码为 0 的像素**逐比特不变**。这条是硬约束，
// 有断言钉着——否则"磨皮磨到头发上"这类问题只能靠肉眼在真机上发现。

enum BeautyEngine {
    // MARK: - 入口

    static func apply(_ image: DisplayImage, skin: SkinMask.Layers, beauty: BeautyParameters) -> DisplayImage {
        guard !beauty.isSkinNeutral, image.size.pixelCount > 0 else { return image }
        let size = image.size
        let face = SkinMask.weights(skin.face, size: size)
        let body = SkinMask.weights(skin.body, size: size)
        var pixels = image.pixels

        let base = ImageDocument.blurred(pixels, size: size, radius: Swift.max(2, size.longEdge / 220))

        if beauty.skinSmooth > 0 || beauty.bodySmooth > 0 {
            smoothPass(&pixels, base: base, size: size, face: face, body: body,
                       faceAmount: BeautyParameters.unit(beauty.skinSmooth),
                       bodyAmount: BeautyParameters.unit(beauty.bodySmooth),
                       volume: beauty.smoothMode == 1)
        }
        if beauty.blemish > 0 {
            blemishPass(&pixels, base: base, size: size, skin: maxLayer(face, body, size: size),
                        amount: BeautyParameters.unit(beauty.blemish))
        }
        if beauty.hasToneWork {
            tonePass(&pixels, size: size, face: face, body: body, beauty: beauty)
        }
        return DisplayImage(size: size, pixels: pixels)
    }

    // MARK: - 1. 磨皮（频率分离）

    /// 只改低频层，高频（纹理）原样叠回。边缘保护用低频亮度梯度：
    /// 眉眼唇的轮廓线处梯度大 → 权重迅速归零，不会被"磨过去"。
    static func smoothPass(_ pixels: inout [Float], base: [Float], size: PixelSize,
                           face: [Float], body: [Float],
                           faceAmount: Double, bodyAmount: Double, volume: Bool) {
        let count = size.pixelCount
        guard count > 0, face.count == count, body.count == count, base.count == pixels.count else { return }
        let deep = ImageDocument.blurred(base, size: size, radius: Swift.max(3, size.longEdge / 90))
        // 平整模式把低频彻底替换；立体模式只把它推向"更深一档"的低频 45%。
        let baseMix = volume ? 0.45 : 1.0
        // 纹理保留量：满力度仍留 45% 高频。"磨到毛孔消失"在这版里做不到。
        let detailKeep = 1 - 0.55 * Swift.max(faceAmount, bodyAmount)
        // 梯度阈值按显示码：0.06 ≈ 15 级灰阶差/像素。
        let edgeThreshold = 0.06

        // 二审：上一次也是分带，但判据用的是整机中位数（那台 runner 的抖动比这步
        // 预期的收益大），所以"分辨不出来"不等于"没用"。这次用 min-of-7 与同一次最快
        // 跑的分段毫秒数判定。算术前提没变：base/deep 已定型、gradient 只读、
        // 写只落在自己那三个通道，所以每个像素的算术序列与串行完全相同。
        PixelParallel.forEachPixel(&pixels, count) { buf, i in
            let amount = faceAmount * Double(face[i]) + bodyAmount * Double(body[i])
            guard amount > 0.001 else { return }
            let o = i * 4
            let protect = 1 - Swift.min(1, gradient(base, size: size, at: i) / edgeThreshold)
            let k = Swift.min(1, amount) * protect
            guard k > 0.001 else { return }
            for c in 0 ..< 3 {
                let source = Double(buf[o + c])
                let low = Double(base[o + c]) + (Double(deep[o + c]) - Double(base[o + c])) * baseMix
                let detail = source - Double(base[o + c])
                let target = low + detail * detailKeep
                buf[o + c] = Float(source + (target - source) * k)
            }
        }
    }

    /// 低频亮度梯度（相邻像素差的和）。用 base 而不是原图：纹理不该算边缘，
    /// 只有"形状"才算边缘——否则磨皮会自我设限，一片毛孔都推不开。
    static func gradient(_ base: [Float], size: PixelSize, at index: Int) -> Double {
        let x = index % size.width
        let y = index / size.width
        func luma(_ ix: Int, _ iy: Int) -> Double {
            let cx = Swift.min(Swift.max(ix, 0), size.width - 1)
            let cy = Swift.min(Swift.max(iy, 0), size.height - 1)
            let o = (cy * size.width + cx) * 4
            return Double(ColorMath.luma(base[o], base[o + 1], base[o + 2]))
        }
        let gx = abs(luma(x + 1, y) - luma(x - 1, y))
        let gy = abs(luma(x, y + 1) - luma(x, y - 1))
        return gx + gy
    }

    // MARK: - 2. 祛瑕疵

    /// 与邻域低频的差异超过阈值的像素判定为"孤点瑕疵"，用邻域低频填掉。
    /// 阈值随力度下降（0.16 → 0.05），所以小力度只动明显痘印。
    static func blemishPass(_ pixels: inout [Float], base: [Float], size: PixelSize,
                            skin: [Float], amount: Double) {
        let count = size.pixelCount
        guard count > 0, amount > 0, base.count == pixels.count, skin.count == count else { return }
        let threshold = 0.16 - 0.11 * amount
        PixelParallel.forEachPixel(&pixels, count) { buf, i in
            let weight = Double(skin[i]) * amount
            guard weight > 0.001 else { return }
            let o = i * 4
            var difference: Double = 0
            for c in 0 ..< 3 {
                difference += abs(Double(buf[o + c]) - Double(base[o + c]))
            }
            // 超出阈值多少，就填多少（软过渡，避免瑕疵边缘出现"补丁感"）。
            let fill = Swift.min(1, (difference - threshold * 3) / (threshold * 3))
            guard fill > 0 else { return }
            for c in 0 ..< 3 {
                let source = Double(buf[o + c])
                buf[o + c] = Float(source + (Double(base[o + c]) - source) * fill * weight)
            }
        }
    }

    // MARK: - 3. 肤色统一 / 祛红 / 祛油光 / 美白

    /// 在「亮度 L + 红绿色度 A + 蓝黄色度 B」的对立色空间里做。
    /// 色度往**局部均值**收敛，亮度单独改：这样"均匀肤色"不会顺带把
    /// 脸上的明暗结构抹平，而"美白"不会顺手把颜色洗淡。
    static func tonePass(_ pixels: inout [Float], size: PixelSize,
                         face: [Float], body: [Float], beauty: BeautyParameters) {
        let count = size.pixelCount
        guard count > 0, face.count == count, body.count == count else { return }
        var luma = [Float](repeating: 0, count: count)
        var chromaA = [Float](repeating: 0, count: count)
        var chromaB = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let o = i * 4
            let opp = BeautyEngine.opponent(r: Double(pixels[o]), g: Double(pixels[o + 1]), b: Double(pixels[o + 2]))
            luma[i] = Float(opp.l)
            chromaA[i] = Float(opp.a)
            chromaB[i] = Float(opp.b)
        }

        let radius = Swift.max(3, size.longEdge / 16)
        let meanA = blurredChannel(chromaA, size: size, radius: radius)
        let meanB = blurredChannel(chromaB, size: size, radius: radius)

        let unify = BeautyParameters.unit(beauty.toneUnify)
        let redness = BeautyParameters.unit(beauty.redness)
        let shine = BeautyParameters.unit(beauty.deShine)
        let whitening = BeautyParameters.unit(beauty.whitening)

        // 构造 luma/chroma 那一环仍然串行：它要同时写三个数组，分带就得三层指针
        // 嵌套。这一环是 tonePass 里真正贵的（每像素一次 fromOpponent），先只动它。
        PixelParallel.forEachPixel(&pixels, count) { buf, i in
                let weight = Swift.min(1, face[i] + body[i])
                guard weight > 0.001 else { return }
                let l = Double(luma[i])
                var lumaOut = l
                var a = Double(chromaA[i])
                var b = Double(chromaB[i])
                let ma = Double(meanA[i])
                let mb = Double(meanB[i])
    
                if unify > 0 {
                    // 两路色度都往局部均值收：只收红绿轴会把"匀肤色"做成"偏品红"，
                    // 黄一块白一块依旧在。
                    let k = unify * Double(weight) * 0.85
                    a += (ma - a) * k
                    b += (mb - b) * k
                }
                if redness > 0, a > ma {
                    // 只收回"比局部更红"的那一半差值；偏绿的像素一律不动，
                    // 否则整张脸会往青里跑（祛红做成偏绿是这类算子的经典翻车）。
                    let k = redness * Double(weight) * 0.8
                    a -= (a - ma) * k
                }
                if shine > 0 {
                    let localSat = (ma * ma + mb * mb).squareRoot()
                    let sat = (a * a + b * b).squareRoot()
                    let flat = Swift.max(0, (l - 0.68) / 0.24)
                    if flat > 0 {
                        // 油光 = 亮 + 色度比局部均值更淡。两个条件都成立才压。
                        let deficit = localSat > 1e-4 ? Swift.min(1, Swift.max(0, (localSat - sat) / localSat) * 2) : 1
                        let k = shine * Double(weight) * Swift.min(1, flat) * deficit
                        lumaOut -= (lumaOut - 0.62) * 0.55 * k
                        a += (ma - a) * Swift.min(1, k * 1.6)
                    }
                }
                if whitening > 0 {
                    // 趋向白：L ← L + k·(1−L)。满力度也只抬 40%，且越亮抬得越少。
                    let k = whitening * Double(weight) * 0.4
                    lumaOut += (1 - lumaOut) * k
                }
    
                let rgb = BeautyEngine.fromOpponent(l: lumaOut, a: a, b: b)
                let o = i * 4
                buf[o] = Float(Swift.min(Swift.max(rgb.r, 0), 1))
                buf[o + 1] = Float(Swift.min(Swift.max(rgb.g, 0), 1))
                buf[o + 2] = Float(Swift.min(Swift.max(rgb.b, 0), 1))
        }
    }

    // MARK: - 对立色空间（线性，往返恒等）

    /// L 用 Rec.709 权重；A = R−G（红绿轴）；B = B−(R+G)/2（蓝黄轴）。
    ///
    /// 权重要显式转 Double：`ColorMath.luma*` 是 Float，而本函数吃 Double，
    /// Float×Double 在 Swift 里不是合法运算（只能靠隐式字面量转换），
    /// 不写出来编译器会去做重载搜索，症状是"编译器无法在合理时间内推导"。
    static func opponent(r: Double, g: Double, b: Double) -> (l: Double, a: Double, b: Double) {
        let l = Double(ColorMath.lumaR) * r + Double(ColorMath.lumaG) * g + Double(ColorMath.lumaB) * b
        return (l, r - g, b - (r + g) / 2)
    }

    /// 反解：权重和为 1，所以 G = L − lR·A − lB·(B + A/2)…，闭式解，无迭代。
    static func fromOpponent(l: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let lumaB = Double(ColorMath.lumaB)
        let lumaR = Double(ColorMath.lumaR)
        let green = l - lumaB * b - (lumaR + lumaB * 0.5) * a
        return (green + a, green, green + a / 2 + b)
    }

    // MARK: - 小工具

    /// 单通道三次盒式模糊（近似高斯）。局部色度均值用它：
    /// 半径 = 长边/16 时，窗口比脸上的斑痘大一个量级，才能当"该区域的肤色"。
    ///
    /// 缓冲复用 + 按行/按列并行，与 `ImageDocument.blurred` 同一条改法：每个输出的
    /// 算术序列与串行版完全相同（递推不裁起点，只把行/列分给不同线程），所以逐比特不变。
    static func blurredChannel(_ values: [Float], size: PixelSize, radius: Int) -> [Float] {
        guard radius > 0, size.pixelCount > 0, values.count == size.pixelCount else { return values }
        let count = values.count
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let even = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let odd = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { scratch.deallocate(); even.deallocate(); odd.deallocate() }

        values.withUnsafeBufferPointer { src in
            boxBlur1(src: src.baseAddress!, size: size, radius: radius, tmp: scratch, out: even)
            boxBlur1(src: even, size: size, radius: radius, tmp: scratch, out: odd)
            boxBlur1(src: odd, size: size, radius: radius, tmp: scratch, out: even)
        }
        return [Float](UnsafeBufferPointer(start: even, count: count))
    }

    private static func boxBlur1(src: UnsafePointer<Float>, size: PixelSize, radius: Int,
                                 tmp: UnsafeMutablePointer<Float>,
                                 out: UnsafeMutablePointer<Float>) {
        let w = size.width
        let h = size.height
        let window = Float(radius * 2 + 1)
        let bands = Swift.min(Swift.max(1, ProcessInfo.processInfo.activeProcessorCount), 16)

        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let yStart = h * band / bands
            let yEnd = h * (band + 1) / bands
            for y in yStart ..< yEnd {
                var sum: Float = 0
                for x in -radius ... radius {
                    sum += src[y * w + Swift.min(Swift.max(x, 0), w - 1)]
                }
                for x in 0 ..< w {
                    tmp[y * w + x] = sum / window
                    sum -= src[y * w + Swift.min(Swift.max(x - radius, 0), w - 1)]
                    sum += src[y * w + Swift.min(Swift.max(x + radius + 1, 0), w - 1)]
                }
            }
        }
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let xStart = w * band / bands
            let xEnd = w * (band + 1) / bands
            for x in xStart ..< xEnd {
                var sum: Float = 0
                for y in -radius ... radius {
                    sum += tmp[Swift.min(Swift.max(y, 0), h - 1) * w + x]
                }
                for y in 0 ..< h {
                    out[y * w + x] = sum / window
                    sum -= tmp[Swift.min(Swift.max(y - radius, 0), h - 1) * w + x]
                    sum += tmp[Swift.min(Swift.max(y + radius + 1, 0), h - 1) * w + x]
                }
            }
        }
    }

    /// 两层的逐像素取大（脸 ∨ 身）。用于"只要沾皮肤就生效"的算子。
    static func maxLayer(_ a: [Float], _ b: [Float], size: PixelSize) -> [Float] {
        guard size.pixelCount > 0, a.count == size.pixelCount, b.count == size.pixelCount else {
            return [Float](repeating: 0, count: max(0, size.pixelCount))
        }
        return zip(a, b).map { Swift.max($0, $1) }
    }
}

extension BeautyParameters {
    /// 第 3 段（肤色四件套）是否需要跑。磨皮与祛瑕疵都不涉及均值色度场，
    /// 这四项全关时整段跳过（少两次全图通道模糊）。
    var hasToneWork: Bool {
        toneUnify > 0 || redness > 0 || deShine > 0 || whitening > 0
    }
}
