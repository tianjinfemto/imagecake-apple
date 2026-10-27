import Foundation

// 智能消除（LaMa）。
//
// 这张网络只吃 512×512（imagecake 实测），所以窗口是"以选区为中心的正方形"，
// 而不是把选区拉伸成方形——拉伸会让补出来的纹理方向不对，而映射回来之后
// 用户看到的是"这块石头长横了"。
//
// 合成语义（与 imagecake 的 compose_inpaint_patch 同构）：
//   缓存 { rect, fill, base, alpha }，贴回时 out = cur + α·(fill − base)。
// 底图变了（用户接着拖曝光）时，修复被当成一个**相对量**带走，
// 于是旧补丁不会在遮罩外沿留一圈旧曝光的边。

enum InpaintTask {
    /// LaMa 的窗口边长。写死在任务里而不是参数里：这颗权重是定尺寸的，
    /// 参数化只会制造"传了 768 却静默按 512 跑"的第三种状态。
    static let windowSide = 512

    static func run(display: RGBA8Buffer,
                    mask: MaskBuffer,
                    store: ModelStore,
                    ort: ORTEngine) async -> InpaintResult {
        let start = nowMs()
        guard let descriptor = store.descriptor(id: "inpaint_lama") else {
            return InpaintResult(patch: nil, report: .failure(
                AIError.modelMissing("inpainting_lama_2025jan.onnx").errorDescription ?? "[no_model]", ms: nowMs() - start))
        }
        let bbox = MaskOps.boundingBox(mask)
        guard !bbox.isEmpty else {
            return InpaintResult(patch: nil, report: .failure("[empty_mask] 没有选中任何像素", ms: nowMs() - start))
        }
        // 单窗就装不下的大选区**不做部分修复**：只修一半看起来像“模型没效果”，
        // 而用户下一次框选会更大。点名拒绝，让用户分两次。
        guard bbox.width <= windowSide - 32, bbox.height <= windowSide - 32 else {
            return InpaintResult(patch: nil, report: .failure(
                "[region_too_large] 选区 \(bbox.width)×\(bbox.height) 超出单窗 512×512；v1 不做多窗，请分次框选",
                ms: nowMs() - start))
        }

        do {
            let path = try store.url(for: descriptor)
            let io = descriptor.ioSpec

            // 正方形窗口：以 bbox 为中心，边长 = max(bbox) + 两倍留边，夹到图内。
            let side = min(windowSide, max(bbox.width, bbox.height) + 2 * 64)
            let cx = bbox.x + bbox.width / 2
            let cy = bbox.y + bbox.height / 2
            let x = min(max(0, cx - side / 2), max(0, display.size.width - side))
            let y = min(max(0, cy - side / 2), max(0, display.size.height - side))
            let window = PixelRect(x: x, y: y, width: side, height: side)
                .intersected(with: PixelRect(x: 0, y: 0, width: display.size.width, height: display.size.height))
            guard !window.isEmpty else {
                return InpaintResult(patch: nil, report: .failure("[empty_window]", ms: nowMs() - start))
            }

            let windowMask = mask.cropped(to: window)
            let dilated = MaskOps.dilated(windowMask, radius: 8)
            let netSize = PixelSize(width: io.fixedSize ?? windowSide, height: io.fixedSize ?? windowSide)

            let imageTensor = try TensorIO.imageTensor(display.cropped(to: window),
                                                       target: netSize,
                                                       layout: io.resolvedLayout,
                                                       colorOrder: io.resolvedColorOrder,
                                                       valueRange: io.resolvedValueRange)
            let maskTensor = TensorIO.maskTensor(dilated, target: netSize, layout: io.resolvedLayout)

            let signature = try await ort.prepare(modelID: descriptor.id, path: path)
            let imageName = io.inputName.flatMap { signature.inputNames.contains($0) ? $0 : nil }
                ?? signature.inputNames.first ?? "image"
            let maskName = io.maskInputName.flatMap { signature.inputNames.contains($0) ? $0 : nil }
                ?? signature.inputNames.first { $0 != imageName }
            guard let maskName else {
                // 4 通道拼接式导出（image+mask 合一）不在这颗的清单里。
                // 不猜通道，点名拒收。
                return InpaintResult(patch: nil, report: .failure(
                    AIError.badShape("模型只有一个输入，mask 无处可放：\(signature.inputNames)").localizedDescription,
                    ms: nowMs() - start))
            }

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
            guard patch.isValid else {
                return InpaintResult(patch: nil, report: .failure("[patch_invalid] 补丁尺寸对不上", ms: nowMs() - start))
            }
            return InpaintResult(patch: patch,
                                 report: AIReport(ok: true, note: "", elapsedMs: nowMs() - start))
        } catch {
            let message = (error as? AIError)?.errorDescription ?? error.localizedDescription
            return InpaintResult(patch: nil, report: .failure(message, ms: nowMs() - start))
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
