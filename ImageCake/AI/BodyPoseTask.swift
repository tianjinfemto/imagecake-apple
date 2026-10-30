import CoreGraphics
import Foundation

// 17 点身形关键点（RTMPose-m）。
//
// 输出是 17 个关节点（COCO 格式：鼻/眼/耳/肩/肘/腕/髋/膝/踝），
// 美体液化按这些点驱动局部形变。与 FaceLandmarksTask 同构：
// 检测框 → 裁切 → 推理 → 解码 → 映回原图坐标。
//
// v1 不做人体检测（需要 YOLO/RTMDet），只在已有人像 α 的区域上跑：
// 用 personMask 的外接框当检测框。没有 α 就不跑——点名 [no_mask]。

enum BodyPoseTask {
    /// COCO 17 点序。
    static let jointNames = ["nose", "left_eye", "right_eye", "left_ear", "right_ear",
                             "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
                             "left_wrist", "right_wrist", "left_hip", "right_hip",
                             "left_knee", "right_knee", "left_ankle", "right_ankle"]

    static func run(display: RGBA8Buffer, personMask: MaskBuffer?, store: ModelStore, ort: ORTEngine) async -> BodyPoseResult {
        let start = nowMs()
        guard let mask = personMask else {
            return BodyPoseResult(joints: [], report: .failure("[no_mask] 需先抠图获取人像 α", ms: nowMs() - start))
        }
        let bbox = MaskOps.boundingBox(mask)
        guard !bbox.isEmpty else {
            return BodyPoseResult(joints: [], report: .failure("[no_person] 人像掩码为空", ms: nowMs() - start))
        }

        guard let descriptor = store.descriptor(id: "body_pose_rtmpose") else {
            return BodyPoseResult(joints: [], report: .failure(AIError.modelMissing("body_pose_rtmpose_m.onnx").errorDescription ?? "[no_model]", ms: nowMs() - start))
        }

        do {
            let path = try store.url(for: descriptor)
            let io = descriptor.ioSpec
            let signature = try await ort.prepare(modelID: descriptor.id, path: path)
            let cropped = display.cropped(to: bbox)
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
            let joints = decodeJoints(output, in: bbox)
            return BodyPoseResult(joints: joints,
                                  report: AIReport(ok: true, note: "17 点", elapsedMs: nowMs() - start))
        } catch {
            return BodyPoseResult(joints: [], report: .failure((error as? AIError)?.errorDescription ?? error.localizedDescription, ms: nowMs() - start))
        }
    }

    private static func decodeJoints(_ output: TensorValue, in bbox: PixelRect) -> [BodyJoint] {
        let floats = output.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let count = output.shape.reduce(1, *)
        guard count >= 17 * 2 else { return [] }
        var joints: [BodyJoint] = []
        joints.reserveCapacity(17)
        for i in 0..<min(17, count / 2) {
            let nx = CGFloat(floats[i * 2])
            let ny = CGFloat(floats[i * 2 + 1])
            let px = bbox.x + Int(nx * CGFloat(bbox.width))
            let py = bbox.y + Int(ny * CGFloat(bbox.height))
            let name = i < jointNames.count ? jointNames[i] : "joint_\(i)"
            joints.append(BodyJoint(name: name, position: CGPoint(x: px, y: py)))
        }
        return joints
    }
}