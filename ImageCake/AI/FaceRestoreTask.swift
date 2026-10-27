import Foundation

// AI 面部重绘（GFPGAN v1.4）。
//
// 硬事实来自 imagecake 的 face_restore_probe（2026-10-19）：
//   · 定宽 512×512；输入 1/255；输出**未夹取**（实测 -0.44..1.24），
//     所以这里必须自己夹到 [0,1]；
//   · 单脸约 2.1 秒（CPU），所以只挂导出，不进预览；
//   · 闭眼不修：GFPGAN 只重绘、不修闭眼。眼裂开合比 < 0.10 的脸
//     原样交回并点名 [closed_eyes]——把闭眼"重绘"成睁眼是假实现。
//
// 权重许可：训练集 FFHQ 是 CC BY-NC-SA（非商用），所以它不随包，
// 清单里 commercialUse = restricted。UI 在下载按钮旁把这句话显示出来。

enum FaceRestoreTask {
    static let closedRatio = 0.10
    static let netSize = 512

    static func run(display: RGBA8Buffer,
                    strength: Int,
                    store: ModelStore,
                    ort: ORTEngine) async -> FaceRestoreResult {
        let start = nowMs()
        let amount = Swift.min(Swift.max(strength, 0), 100)
        guard amount > 0 else {
            return FaceRestoreResult(image: display, faces: 0,
                                     report: AIReport(ok: true, note: "", elapsedMs: 0))
        }
        guard let descriptor = store.descriptor(id: "face_restore_gfpgan") else {
            return FaceRestoreResult(image: nil, faces: 0, report: .failure(
                AIError.modelMissing("face_restore_gfpgan_v14.onnx").errorDescription ?? "[no_model]",
                ms: nowMs() - start))
        }

        let faces = await Task.detached(priority: .userInitiated) {
            VisionSupport.faces(in: display)
        }.value
        guard !faces.isEmpty else {
            return FaceRestoreResult(image: nil, faces: 0,
                                     report: .failure("[no_face] 这张图里没有检出人脸", ms: nowMs() - start))
        }

        do {
            let path = try store.url(for: descriptor)
            let io = descriptor.ioSpec
            let signature = try await ort.prepare(modelID: descriptor.id, path: path)
            let inputName = io.inputName.flatMap { signature.inputNames.contains($0) ? $0 : nil }
                ?? signature.inputNames.first ?? "input"

            var working = [UInt8](display.data)
            var done = 0
            var closed = 0

            for face in faces {
                // "不知道"（-1）不当作闭眼：关键点缺失时宁可重绘，也不静默跳过。
                if face.eyeOpenRatio >= 0, face.eyeOpenRatio < closedRatio {
                    closed += 1
                    continue
                }
                let box = squareBox(around: face.box, expand: 0.10, in: display.size)
                guard !box.isEmpty else { continue }

                let crop = display.cropped(to: box)
                let tensor = try TensorIO.imageTensor(crop,
                                                      target: PixelSize(width: netSize, height: netSize),
                                                      layout: io.resolvedLayout,
                                                      colorOrder: io.resolvedColorOrder,
                                                      valueRange: io.resolvedValueRange)
                let output = try await ort.run(modelID: descriptor.id,
                                               path: path,
                                               inputs: [inputName: tensor],
                                               preferredOutput: io.outputName)
                var patch = try TensorIO.image(from: output, colorOrder: io.resolvedColorOrder)
                if patch.size != box.size {
                    patch = patch.resized(to: box.size)
                }
                blend(into: &working,
                      canvas: display.size,
                      box: box,
                      patch: patch,
                      strength: Float(amount) / 100)
                done += 1
            }

            guard done > 0 else {
                return FaceRestoreResult(image: nil, faces: 0, report: .failure(
                    "[closed_eyes] \(closed) 张脸闭着眼，GFPGAN 修不了闭眼，已原样保留",
                    ms: nowMs() - start))
            }
            let note = closed > 0 ? "[closed_eyes:\(closed)]" : ""
            return FaceRestoreResult(image: RGBA8Buffer(size: display.size, data: Data(working)),
                                     faces: done,
                                     report: AIReport(ok: true, note: note, elapsedMs: nowMs() - start))
        } catch {
            let message = (error as? AIError)?.errorDescription ?? error.localizedDescription
            return FaceRestoreResult(image: nil, faces: 0, report: .failure(message, ms: nowMs() - start))
        }
    }

    /// 以脸框为中心取正方形（外扩 expand），夹到图内。
    /// 正方形是必需的：GFPGAN 只吃 512×512，非等比拉伸会把脸拉长。
    static func squareBox(around box: PixelRect, expand: Double, in size: PixelSize) -> PixelRect {
        let side = Int(Double(max(box.width, box.height)) * (1 + expand * 2))
        guard side > 0 else { return .zero }
        let cx = box.x + box.width / 2
        let cy = box.y + box.height / 2
        let x = min(max(0, cx - side / 2), max(0, size.width - side))
        let y = min(max(0, cy - side / 2), max(0, size.height - side))
        return PixelRect(x: x, y: y, width: side, height: side)
            .intersected(with: PixelRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    /// 椭圆羽化贴回：框外逐位不动，框内按 α × strength 混合。
    private static func blend(into working: inout [UInt8],
                              canvas: PixelSize,
                              box: PixelRect,
                              patch: RGBA8Buffer,
                              strength: Float) {
        let alpha = MaskOps.ellipseAlpha(size: box.size, feather: 0.30)
        let src = [UInt8](patch.data)
        for y in 0 ..< box.height {
            for x in 0 ..< box.width {
                let i = y * box.width + x
                let a = alpha[i] * strength
                if a <= 0 { continue }
                let dst = ((box.y + y) * canvas.width + (box.x + x)) * 4
                for c in 0 ..< 3 {
                    let current = Float(working[dst + c])
                    let target = Float(src[i * 4 + c])
                    working[dst + c] = UInt8(Swift.min(Swift.max(current + (target - current) * a, 0), 255))
                }
            }
        }
    }
}
