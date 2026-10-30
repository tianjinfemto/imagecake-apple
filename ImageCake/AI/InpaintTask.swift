import Foundation

// 智能消除（LaMa）。
//
// 这张网络只吃 512×512（imagecake 实测），所以窗口是"以选区为中心的正方形"，
// 而不是把选区拉伸成方形——拉伸会让补出来的纹理方向不对，而映射回来之后
// 用户看到的是"这块石头长横了"。
//
// 大选区（>480px）走多窗 tiling：把选区分成若干 ≤480px 的块，每块各开
// 一个 512 窗口跑 LaMa，返回多个 InpaintPatch。与 SuperResTask 的分块
// 同理——互不重叠的内部块 + 各自的上下文窗口。
//
// 合成语义（与 imagecake 的 compose_inpaint_patch 同构）：
//   缓存 { rect, fill, base, alpha }，贴回时 out = cur + α·(fill − base)。
// 底图变了（用户接着拖曝光）时，修复被当成一个**相对量**带走，
// 于是旧补丁不会在遮罩外沿留一圈旧曝光的边。

enum InpaintTask {
    /// LaMa 的窗口边长。写死在任务里而不是参数里：这颗权重是定尺寸的，
    /// 参数化只会制造"传了 768 却静默按 512 跑"的第三种状态。
    static let windowSide = 512

    /// 单窗能装下的最大选区边长（窗口边长减去两倍留边）。
    static let maxTileSide = windowSide - 32  // 480

    static func run(display: RGBA8Buffer,
                    mask: MaskBuffer,
                    store: ModelStore,
                    ort: ORTEngine) async -> InpaintResult {
        let start = nowMs()
        guard let descriptor = store.descriptor(id: "inpaint_lama") else {
            return InpaintResult(patches: [], report: .failure(
                AIError.modelMissing("inpainting_lama_2025jan.onnx").errorDescription ?? "[no_model]", ms: nowMs() - start))
        }
        let bbox = MaskOps.boundingBox(mask)
        guard !bbox.isEmpty else {
            return InpaintResult(patches: [], report: .failure("[empty_mask] 没有选中任何像素", ms: nowMs() - start))
        }

        do {
            let path = try store.url(for: descriptor)
            let io = descriptor.ioSpec
            let netSize = PixelSize(width: io.fixedSize ?? windowSide, height: io.fixedSize ?? windowSide)

            let signature = try await ort.prepare(modelID: descriptor.id, path: path)
            let imageName = io.inputName.flatMap { signature.inputNames.contains($0) ? $0 : nil }
                ?? signature.inputNames.first ?? "image"
            let maskName = io.maskInputName.flatMap { signature.inputNames.contains($0) ? $0 : nil }
                ?? signature.inputNames.first { $0 != imageName }
            guard let maskName else {
                return InpaintResult(patches: [], report: .failure(
                    AIError.badShape("模型只有一个输入，mask 无处可放：\(signature.inputNames)").localizedDescription,
                    ms: nowMs() - start))
            }

            // 把选区分成 ≤480px 的块。小块选区只产生一个 tile（单窗路径）。
            let tiles = TileGrid.interiors(size: bbox.size, tile: maxTileSide)
            var patches: [InpaintPatch] = []

            for tile in tiles {
                // tile 坐标是相对 bbox 的，偏移到图像坐标。
                let tileRect = PixelRect(x: bbox.x + tile.x, y: bbox.y + tile.y,
                                         width: tile.width, height: tile.height)

                // 正方形窗口：以 tile 为中心，边长 = max(tile) + 两倍留边，夹到图内。
                let side = min(windowSide, max(tileRect.width, tileRect.height) + 2 * 64)
                let cx = tileRect.x + tileRect.width / 2
                let cy = tileRect.y + tileRect.height / 2
                let x = min(max(0, cx - side / 2), max(0, display.size.width - side))
                let y = min(max(0, cy - side / 2), max(0, display.size.height - side))
                let window = PixelRect(x: x, y: y, width: side, height: side)
                    .intersected(with: PixelRect(x: 0, y: 0, width: display.size.width, height: display.size.height))
                guard !window.isEmpty else { continue }

                let windowMask = mask.cropped(to: window)
                let dilated = MaskOps.dilated(windowMask, radius: 8)

                let imageTensor = try TensorIO.imageTensor(display.cropped(to: window),
                                                           target: netSize,
                                                           layout: io.resolvedLayout,
                                                           colorOrder: io.resolvedColorOrder,
                                                           valueRange: io.resolvedValueRange)
                let maskTensor = TensorIO.maskTensor(dilated, target: netSize, layout: io.resolvedLayout)

                let output = try await ort.run(modelID: descriptor.id,
                                               path: path,
                                               inputs: [imageName: imageTensor, maskName: maskTensor],
                                               preferredOutput: io.outputName)
                let netImage = try TensorIO.image(from: output, colorOrder: io.resolvedColorOrder)
                let fill = netImage.resized(to: window.size)
                let feather = MaskOps.feathered(dilated, radius: 12)
                let base = display.cropped(to: window)

                let patch = InpaintPatch(rect: window, reference: display.size,
                                         fill: fill, base: base, alpha: feather)
                if patch.isValid {
                    patches.append(patch)
                }
            }

            guard !patches.isEmpty else {
                return InpaintResult(patches: [], report: .failure("[no_patches] 所有窗口均无效", ms: nowMs() - start))
            }

            let note = patches.count > 1 ? "[tiled] \(patches.count) 窗" : ""
            return InpaintResult(patches: patches,
                                 report: AIReport(ok: true, note: note, elapsedMs: nowMs() - start))
        } catch {
            let message = (error as? AIError)?.errorDescription ?? error.localizedDescription
            return InpaintResult(patches: [], report: .failure(message, ms: nowMs() - start))
        }
    }

    /// 把补丁贴到任意一张同尺寸底图上（rel = fill − base）。
    /// rect 之外的像素一个字节都不碰。
    static func compose(bottom: RGBA8Buffer, patch: InpaintPatch) -> RGBA8Buffer {
        guard patch.isValid else { return bottom }
        let r = patch.rect
        guard r.maxX <= bottom.size.width, r.maxY <= bottom.size.height else { return bottom }
        var out = [UInt8](bottom.data)
        let fill = [UInt8](patch.fill.data)
        let base = [UInt8](patch.base.data)
        let alpha = [UInt8](patch.alpha.data)
        for y in 0 ..< r.height {
            for x in 0 ..< r.width {
                let i = y * r.width + x
                let a = Int(alpha[i])
                if a == 0 { continue }
                let dst = ((r.y + y) * bottom.size.width + (r.x + x)) * 4
                for c in 0 ..< 3 {
                    let cur = Int(out[dst + c])
                    let delta = Int(fill[i * 4 + c]) - Int(base[i * 4 + c])
                    out[dst + c] = UInt8(min(255, max(0, cur + delta * a / 255)))
                }
            }
        }
        return RGBA8Buffer(size: bottom.size, data: Data(out))
    }
}
