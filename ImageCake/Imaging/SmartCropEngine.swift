import CoreGraphics
import Foundation

// 智能构图：基于人脸关键点 + 主体重心，建议裁剪框。
//
// 不是 AI 生成式构图——是确定性规则：找到人脸与主体的包围盒，
// 按三分法留 margin，输出一个归一化裁剪框。用户可以一键应用。
//
// 依赖 FaceLandmarksTask 的结果（478 点）。没有关键点时退化到
// 人像 α 的外接框 + 居中。

enum SmartCropEngine {
    struct Suggestion: Equatable {
        var cropRect: CGRect
        var reason: String
    }

    /// 基于关键点建议裁剪框。
    static func suggest(imageSize: PixelSize, landmarks: [FaceLandmarks], personMask: MaskBuffer?) -> Suggestion? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        var points: [CGPoint] = []
        for face in landmarks {
            points.append(contentsOf: face.points)
            points.append(CGPoint(x: face.faceBox.midX, y: face.faceBox.midY))
        }

        if points.isEmpty, let mask = personMask {
            let bbox = MaskOps.boundingBox(mask)
            if !bbox.isEmpty {
                points.append(CGPoint(x: bbox.minX, y: bbox.minY))
                points.append(CGPoint(x: bbox.maxX, y: bbox.maxY))
            }
        }

        guard !points.isEmpty else { return nil }

        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }

        let subjectW = maxX - minX
        let subjectH = maxY - minY
        guard subjectW > 0, subjectH > 0 else { return nil }

        let marginX = subjectW * 0.3
        let marginY = subjectH * 0.3
        var cropX = minX - marginX
        var cropY = minY - marginY
        var cropW = subjectW + 2 * marginX
        var cropH = subjectH + 2 * marginY

        let imgW = CGFloat(imageSize.width)
        let imgH = CGFloat(imageSize.height)
        cropX = max(0, cropX)
        cropY = max(0, cropY)
        if cropX + cropW > imgW { cropW = imgW - cropX }
        if cropY + cropH > imgH { cropH = imgH - cropY }

        let normalized = CGRect(x: cropX / imgW, y: cropY / imgH,
                                width: cropW / imgW, height: cropH / imgH)
        let reason = landmarks.isEmpty ? "基于人像掩码" : "基于 \(landmarks.count) 张脸关键点"
        return Suggestion(cropRect: normalized, reason: reason)
    }
}