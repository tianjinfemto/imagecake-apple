import CoreGraphics
import Foundation

// 人脸属性分类：年龄 + 性别。
//
// 两颗独立网络（face_attr_age / face_attr_gender），同一张脸裁切喂进去。
// 用途是批量分组（按年龄/性别整理相册），不是修图本身——所以结果只给 UI
// 显示，不进渲染管线。
//
// 年龄输出是分箱 logits（FairFace 9 档：0-2/3-9/10-19/20-29/30-39/40-49/
// 50-59/60-69/70+），取 argmax 再映射到区间标签。
// 性别输出是 2 类 logits（male/female），取 argmax。

enum FaceAttrTask {
    static let ageBins = ["0-2", "3-9", "10-19", "20-29", "30-39", "40-49", "50-59", "60-69", "70+"]

    static func run(display: RGBA8Buffer, store: ModelStore, ort: ORTEngine) async -> FaceAttrResult {
        let start = nowMs()
        let faces = VisionSupport.faces(in: display)
        guard !faces.isEmpty else {
            return FaceAttrResult(attrs: [], report: .failure("[no_face] 没检测到人脸", ms: nowMs() - start))
        }

        var attrs: [FaceAttr] = []
        for face in faces {
            let age = await classify(display: display, faceBox: face.box,
                                     modelID: "face_attr_age", store: store, ort: ort)
            let gender = await classify(display: display, faceBox: face.box,
                                        modelID: "face_attr_gender", store: store, ort: ort)
            let ageLabel = age.flatMap { ageBins.indices.contains($0) ? ageBins[$0] : nil } ?? "?"
            let genderLabel = gender == 0 ? "男" : (gender == 1 ? "女" : "?")
            attrs.append(FaceAttr(faceBox: face.box, age: ageLabel, gender: genderLabel))
        }

        let note = attrs.isEmpty ? "未分类" : "\(attrs.count) 张脸"
        return FaceAttrResult(attrs: attrs, report: AIReport(ok: !attrs.isEmpty, note: note, elapsedMs: nowMs() - start))
    }

    private static func classify(display: RGBA8Buffer, faceBox: PixelRect,
                                 modelID: String, store: ModelStore, ort: ORTEngine) async -> Int? {
        guard let descriptor = store.descriptor(id: modelID) else { return nil }
        do {
            let path = try store.url(for: descriptor)
            let io = descriptor.ioSpec
            let signature = try await ort.prepare(modelID: descriptor.id, path: path)
            let cropped = display.cropped(to: faceBox)
            let target = MattingTask.netSize(for: cropped.size, longEdge: 224, multipleOf: 32)
            let tensor = try TensorIO.imageTensor(cropped,
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
            return argmax(output)
        } catch {
            return nil
        }
    }

    private static func argmax(_ tensor: TensorValue) -> Int? {
        let floats = tensor.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !floats.isEmpty else { return nil }
        var bestIdx = 0
        var bestVal: Float = -Float.greatestFiniteMagnitude
        for (i, v) in floats.enumerated() {
            if v > bestVal { bestVal = v; bestIdx = i }
        }
        return bestIdx
    }
}