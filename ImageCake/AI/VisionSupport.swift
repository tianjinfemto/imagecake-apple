import CoreGraphics
import CoreVideo
import Foundation
import Vision

// Vision 的三件事：人像分割的兜底、人脸框与眼睛开合、手部姿态。
//
// 为什么先接 Vision 而不是"等 MODNet 下完再说"：
//   · Vision 的人像分割在 A12 以上是硬件加速的，模型零下载、离线、免许可；
//   · 它是**兜底路径**而不是替代：连续 α 的发丝边缘 MODNet 更好，
//     所以 MODNet 在场时优先用它，Vision 只在缺件/推理失败时接手，
//     并在报告里点名 path="vision"（"模型没加载上"与"模型分割得好"
//     必须能分开）。
//
// 人脸检测同理：v1 不接 YuNet，Vision 在双端都稳定；YuNet 留给
// "没有 Vision 的环境"这一档（清单里已登记）。
//
// 手部姿态是**另一回事**：它不是兜底而是唯一路径（清单里没有手部检测网络），
// 所以它的缺席不写成 `[fallback:…]`，而是写成 `[no_hand]`——没检测到就是
// 没检测到，不拿脸的位置猜手在哪。

struct DetectedFace: Sendable {
    var box: PixelRect
    /// 眼裂开合比（眼裂高/眼宽）。-1 = 关键点不可用（不能据此判闭眼）。
    var eyeOpenRatio: Double
}

struct DetectedHand: Sendable {
    /// 归一化关节点（y 向下：已从 Vision 的左下原点翻转）。
    var points: [CGPoint]
    var side: String
}

enum VisionSupport {
    // MARK: - 人像分割（兜底）

    static func personMask(_ buffer: RGBA8Buffer) async -> MaskBuffer? {
        guard let cgImage = buffer.cgImage() else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> MaskBuffer? in
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            guard let observation = request.results?.first else { return nil }
            let pixelBuffer = observation.pixelBuffer
            _ = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer), width > 0, height > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height)
            let src = base.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    bytes[y * width + x] = src[y * bytesPerRow + x]
                }
            }
            return MaskBuffer(size: PixelSize(width: width, height: height), data: Data(bytes))
        }.value
    }

    // MARK: - 人脸

    static func faces(in buffer: RGBA8Buffer) -> [DetectedFace] {
        guard let cgImage = buffer.cgImage() else { return [] }
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }
        let imageSize = CGSize(width: buffer.size.width, height: buffer.size.height)
        return observations.map { face in
            // Vision 的 boundingBox 原点在左下，转成"左上原点"的像素矩形。
            let bb = face.boundingBox
            let x = Int((bb.minX * imageSize.width).rounded())
            let y = Int(((1 - bb.maxY) * imageSize.height).rounded())
            let w = Int((bb.width * imageSize.width).rounded())
            let h = Int((bb.height * imageSize.height).rounded())
            let rect = PixelRect(x: x, y: y, width: w, height: h)
                .intersected(with: PixelRect(x: 0, y: 0, width: buffer.size.width, height: buffer.size.height))

            var ratio = -1.0
            if let landmarks = face.landmarks,
               let left = landmarks.leftEye,
               let right = landmarks.rightEye {
                let rl = eyeRatio(left.pointsInImage(imageSize: imageSize))
                let rr = eyeRatio(right.pointsInImage(imageSize: imageSize))
                if rl > 0 || rr > 0 {
                    ratio = [rl, rr].filter { $0 > 0 }.reduce(0, +) / Double(max(1, [rl, rr].filter { $0 > 0 }.count))
                }
            }
            return DetectedFace(box: rect, eyeOpenRatio: ratio)
        }
        .filter { !$0.box.isEmpty }
    }

    /// 手部姿态（零权重、双端自带）。拿置信度达标的关节点；不足 6 点的那只丢掉
    /// ——"看到三根手指"不足以定出一只手的地盘，猜出来的凸包会磨到袖子。
    static func hands(in buffer: RGBA8Buffer) -> [DetectedHand] {
        guard let cgImage = buffer.cgImage() else { return [] }
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }
        return observations.compactMap { hand in
            let points = (try? hand.recognizedPoints(.all)) ?? [:]
            let kept = points.values.filter { $0.confidence >= 0.5 }.map {
                // Vision 的原点在左下，本仓一律 y 向下。
                CGPoint(x: $0.location.x, y: 1 - $0.location.y)
            }
            guard kept.count >= 6 else { return nil }
            // 左右手标识只用于展示：拿不准就给 unknown，不猜。
            let side: String
            switch hand.chirality {
            case .left: side = "left"
            case .right: side = "right"
            default: side = "unknown"
            }
            return DetectedHand(points: kept, side: side)
        }
    }

    /// 眼裂高/宽。点组不全或退化时返回 -1（"不知道"不等于"闭着"）。
    private static func eyeRatio(_ points: [CGPoint]) -> Double {
        guard points.count >= 4 else { return -1 }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return -1 }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0.5 else { return -1 }
        return Double(height / width)
    }
}
