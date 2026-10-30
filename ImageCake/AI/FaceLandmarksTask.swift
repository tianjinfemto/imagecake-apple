import CoreGraphics
import Foundation

// 478 点人脸关键点。
//
// 接线方式照 MattingTask：descriptor → url → prepare → imageTensor → run。
// 输出是 [CGPoint]（归一化 0...1），UI 与五官形变液化都按归一化消费。
//
// 为什么不自己做人脸检测：VisionSupport.faces 已经用 VNDetectFaceLandmarksRequest
// 做了检测，这里复用它的框，在框内跑 478 点网络。Vision 的关键点只有几十个，
// 478 点给的是眼角/嘴角/鼻翼等细粒度位置——五官形变液化需要这些。

enum FaceLandmarksTask {
    static func run(display: RGBA8Buffer, store: ModelStore, ort: ORTEngine) async -> FaceLandmarksResult {
        let start = nowMs()
        let faces = VisionSupport.faces(in: display)
        guard !faces.isEmpty else {
            return FaceLandmarksResult(landmarks: [], report: .failure("[no_face] 没检测到人脸", ms: nowMs() - start))
        }

        guard let descriptor = store.descriptor(id: "face_landmarks_478") else {
            return FaceLandmarksResult(landmarks: [], report: .failure(AIError.modelMissing("face_landmarks_478.onnx").errorDescription ?? "[no_model]", ms: nowMs() - start))
        }

        var allLandmarks: [FaceLandmarks] = []
        for face in faces {
            do {
                let path = try store.url(for: descriptor)
                let io = descriptor.ioSpec
                let signature = try await ort.prepare(modelID: descriptor.id, path: path)
                let faceRect = face.box
                guard !faceRect.isEmpty else { continue }
                let cropped = display.cropped(to: faceRect)
                let target = MattingTask.netSize(for: cropped.size, longEdge: 256, multipleOf: 32)
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
                let points = decodeLandmarks(output, in: faceRect)
                allLandmarks.append(FaceLandmarks(faceBox: faceRect, points: points, eyeOpenRatio: face.eyeOpenRatio))
            } catch {
                return FaceLandmarksResult(landmarks: allLandmarks,
                                           report: .failure((error as? AIError)?.errorDescription ?? error.localizedDescription, ms: nowMs() - start))
            }
        }

        return FaceLandmarksResult(landmarks: allLandmarks,
                                   report: AIReport(ok: true, note: "\(allLandmarks.count) 张脸", elapsedMs: nowMs() - start))
    }

    /// 把网络输出解码成归一化坐标点。
    /// 输出形状通常是 [1, N, 2] 或 [1, 2*N]，N=478。
    private static func decodeLandmarks(_ output: TensorValue, in faceRect: PixelRect) -> [CGPoint] {
        let floats = output.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let count = output.shape.reduce(1, *)
        guard count >= 2 else { return [] }
        let pointCount: Int
        let stride: Int
        if output.shape.count == 3 {
            pointCount = output.shape[1]
            stride = output.shape[2]
        } else if output.shape.count == 2 {
            pointCount = output.shape[1] / 2
            stride = 2
        } else {
            pointCount = count / 2
            stride = 2
        }
        guard pointCount > 0, stride >= 2 else { return [] }
        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)
        for i in 0..<pointCount {
            let nx = CGFloat(floats[i * stride])
            let ny = CGFloat(floats[i * stride + 1])
            let px = faceRect.x + Int(nx * CGFloat(faceRect.width))
            let py = faceRect.y + Int(ny * CGFloat(faceRect.height))
            points.append(CGPoint(x: px, y: py))
        }
        return points
    }
}