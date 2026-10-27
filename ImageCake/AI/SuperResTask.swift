import Foundation

// AI 超清（Real-ESRGAN general-x4v3）。
//
// 三个与链上其他阶段不同的地方，写在这里防写歪：
//
//   ① 它在**8bit 显示域**跑。Real-ESRGAN 在 sRGB 码上训练；喂线性值等于
//      换一个它没见过的域。代价是：开了超清就没有真 16bit 数据（16bit 容器
//      仍可装这份 8bit 结果，UI 会点名）。
//
//   ② 它是唯一**改输出尺寸**的阶段，所以只挂导出，不进预览。
//
//   ③ 分块用"互不重叠的块 + 每块加一圈上下文"，不是"重叠后按权重融合"：
//      后者要为整张 4 倍图维护一份浮点权重累加器——12MP 的 4 倍是 48MP，
//      16 字节/像素就是 768MB，iPad 上直接被杀。加一圈上下文之后每块只看
//      自己那一片，内存只有目标图本身（4 字节/像素）。

enum SuperResTask {
    /// 输出像素上限。48MP 的目标图是 192MB（RGBA8），再加 ORT 的张量，
    /// 60MP 是 8GB 设备上还安全的档；超了点名，不静默降采样冒充。
    static let maxOutputPixels = 60_000_000

    static func run(display: RGBA8Buffer,
                    scale: Int,
                    store: ModelStore,
                    ort: ORTEngine) async -> SuperResResult {
        let start = nowMs()
        guard [2, 4].contains(scale) else {
            return SuperResResult(image: nil, scale: scale, report: .failure(
                "[bad_scale] 只认 2 或 4，收到 \(scale)", ms: nowMs() - start), tiles: 0)
        }
        guard let descriptor = store.descriptor(id: "superres_esrgan") else {
            return SuperResResult(image: nil, scale: scale, report: .failure(
                AIError.modelMissing("superres_esrgan_x4v3.onnx").errorDescription ?? "[no_model]",
                ms: nowMs() - start), tiles: 0)
        }

        do {
            let path = try store.url(for: descriptor)
            let io = descriptor.ioSpec
            let native = io.nativeScale ?? 4
            let outSize = PixelSize(width: display.size.width * native, height: display.size.height * native)
            guard outSize.pixelCount <= maxOutputPixels else {
                return SuperResResult(image: nil, scale: scale, report: .failure(
                    "[too_large] \(outSize.width)×\(outSize.height) 超出本机内存档（上限 \(maxOutputPixels) 像素）",
                    ms: nowMs() - start), tiles: 0)
            }

            let signature = try await ort.prepare(modelID: descriptor.id, path: path)
            let inputName = io.inputName.flatMap { signature.inputNames.contains($0) ? $0 : nil }
                ?? signature.inputNames.first ?? "input"
            let interiors = TileGrid.interiors(size: display.size, tile: io.tile ?? 256)
            var dest = [UInt8](repeating: 255, count: outSize.pixelCount * 4)
            var done = 0

            for interior in interiors {
                let padded = TileGrid.padded(interior, overlap: io.overlap ?? 16, in: display.size)
                let crop = display.cropped(to: padded)
                let tensor = try TensorIO.imageTensor(crop,
                                                      layout: io.resolvedLayout,
                                                      colorOrder: io.resolvedColorOrder,
                                                      valueRange: io.resolvedValueRange)
                let output = try await ort.run(modelID: descriptor.id,
                                               path: path,
                                               inputs: [inputName: tensor],
                                               preferredOutput: io.outputName)
                var tile = try TensorIO.image(from: output, colorOrder: io.resolvedColorOrder)
                let expected = PixelSize(width: padded.width * native, height: padded.height * native)
                if tile.size != expected {
                    tile = tile.resized(to: expected)
                }

                // 只抄"内部块"那一片：上下左右各留的一圈上下文不落盘，
                // 于是块与块之间没有重叠写，也没有权重累加器。
                let offsetX = (interior.x - padded.x) * native
                let offsetY = (interior.y - padded.y) * native
                let copyW = min(interior.width * native, tile.size.width - offsetX)
                let copyH = min(interior.height * native, tile.size.height - offsetY)
                guard copyW > 0, copyH > 0 else { continue }
                let src = [UInt8](tile.data)
                for row in 0 ..< copyH {
                    let srcStart = ((offsetY + row) * tile.size.width + offsetX) * 4
                    let dstStart = ((interior.y * native + row) * outSize.width + interior.x * native) * 4
                    for i in 0 ..< (copyW * 4) {
                        dest[dstStart + i] = src[srcStart + i]
                    }
                }
                done += 1
            }

            var result = RGBA8Buffer(size: outSize, data: Data(dest))
            var note = ""
            if scale != native {
                // 2x = 先跑 4x 再面积平均降一半。比"拿 4x 模型硬跑 2x"更接近
                // 它在训练时见过的分布，也避免为 2x 再存一颗权重。
                let target = PixelSize(width: display.size.width * scale, height: display.size.height * scale)
                result = result.resized(to: target)
                note = "[from_4x]"
            }
            return SuperResResult(image: result,
                                  scale: scale,
                                  report: AIReport(ok: true, note: note, elapsedMs: nowMs() - start),
                                  tiles: done)
        } catch {
            let message = (error as? AIError)?.errorDescription ?? error.localizedDescription
            return SuperResResult(image: nil, scale: scale,
                                  report: .failure(message, ms: nowMs() - start), tiles: 0)
        }
    }
}
