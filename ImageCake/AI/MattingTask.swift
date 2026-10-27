import Foundation

// 人像分割（MODNet，缺件时回退 Vision）。
//
// 输出是**连续 α**，不是二值罩：发丝与衣缘的软边交给下游合成，
// 不从阈值里来。这也是"换底色"敢承诺去色边的前提。
//
// 预处理照上游 inference_onnx.py 的口径（imagecake 有实测）：
//   sRGB 显示码 → RGB → (x-127.5)/127.5 → 长边缩到 512（向下取 32 的倍数）→ NCHW。
// 把线性浮点直接 ×255 喂进去等于换一个分布推理，症状是"个别像素直接反向"。
//
// 后处理：α 先 ×255 **截断**取整、再缩回原尺寸。顺序换成"先缩放再取整"
// 会让边缘码值整体漂一档。

enum MattingTask {
    static func run(display: RGBA8Buffer, store: ModelStore, ort: ORTEngine) async -> MattingResult {
        let start = nowMs()
        var failureNote = ""

        if let descriptor = store.descriptor(id: "matting_modnet") {
            do {
                let path = try store.url(for: descriptor)
                let io = descriptor.ioSpec
                let signature = try await ort.prepare(modelID: descriptor.id, path: path)
                let target = netSize(for: display.size,
                                     longEdge: io.longEdge ?? 512,
                                     multipleOf: io.multipleOf ?? 32)
                let tensor = try TensorIO.imageTensor(display,
                                                      target: target,
                                                      layout: io.resolvedLayout,
                                                      colorOrder: io.resolvedColorOrder,
                                                      valueRange: io.resolvedValueRange)
                let inputName = io.inputName.flatMap { signature.inputNames.contains($0) ? $0 : nil }
                    ?? signature.inputNames.first ?? "input"
                let output = try await ort.run(modelID: descriptor.id,
                                               path: path,
                                               inputs: [inputName: tensor],
                                               preferredOutput: io.outputName)
                let alpha = try TensorIO.alpha(from: output)
                let mask = alpha.resized(to: display.size)
                return MattingResult(mask: mask, path: "modnet",
                                     report: AIReport(ok: true, note: "", elapsedMs: nowMs() - start))
            } catch {
                failureNote = (error as? AIError)?.errorDescription ?? error.localizedDescription
            }
        } else {
            failureNote = AIError.modelMissing("portrait_matting_modnet_photographic.onnx").errorDescription ?? "[no_model]"
        }

        // 兜底：Vision 的人像分割。模型缺件/前向失败时接手，并点名 path。
        if let mask = await VisionSupport.personMask(display) {
            return MattingResult(mask: mask.resized(to: display.size),
                                 path: "vision",
                                 report: AIReport(ok: true,
                                                  note: "\(failureNote) [fallback:vision]",
                                                  elapsedMs: nowMs() - start))
        }

        return MattingResult(mask: nil, path: "none",
                             report: .failure("\(failureNote) [no_person]", ms: nowMs() - start))
    }

    /// 网络输入尺寸：长边不超过 longEdge，且两边都是 multipleOf 的倍数。
    /// 小图不放大（放大只会让 451ms 变成 2s）；大图向下取整到倍数，
    /// 免得 ORT 在奇数边上报形状错。
    static func netSize(for size: PixelSize, longEdge: Int, multipleOf: Int) -> PixelSize {
        let multiple = max(1, multipleOf)
        let long = max(size.width, size.height)
        let scale = long > longEdge ? Double(longEdge) / Double(long) : 1
        func snap(_ value: Int) -> Int {
            max(multiple, (value / multiple) * multiple)
        }
        let w = snap(Int((Double(size.width) * scale).rounded()))
        let h = snap(Int((Double(size.height) * scale).rounded()))
        return PixelSize(width: w, height: h)
    }
}
