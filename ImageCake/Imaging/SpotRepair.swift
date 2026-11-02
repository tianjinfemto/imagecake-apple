import CoreGraphics
import Foundation

/// 背景平坦区污点检出（P1-③ 的内核）。
///
/// 状态：**尚未接线**。它现在只有测试作为消费者，没有 UI 动作、也没进渲染链。
/// 接线方式已经定好（检出结果转成 `PatchStroke` 交给 `EditorModel.addPatchStroke`，
/// 走已有的 `patch` 阶段，天然可撤销、数量显示在状态栏），之所以留一步：面板里那张
/// 修补工具卡的确切代码我还没核实，盲改会做出"引擎有、参数有、UI 少一环"的静默
/// 半成品 —— 本仓为这类问题回退过不止一次。
///
/// 设计取向是**宁可漏检也不误检**：修错地方的代价（把人脸/衣服上的一块抹掉）远大于
/// 留一个背景污点，所以三条否决条件叠加，并且只找**暗**点（背景上更暗的孤立小斑，
/// 比如传感器灰点），不去找亮点 —— 亮点可能是灯、反光、天空，误判率完全不同。
enum SpotRepair {
    struct Finding: Equatable, Sendable {
        /// 归一化位置，直接当 `PatchStroke` 的目标点用。
        var at: CGPoint
        /// 归一化半径。
        var radius: Double
        /// 取样点（同一片平坦背景里偏开一点的位置），也是归一化。
        var source: CGPoint
    }

    /// 偏离局部均值多少算"暗点"（显示码亮度差）。
    static let darkLimit = 0.10
    /// 邻域方差低于它才算平坦背景（起伏大的地方如头发、树叶不该动）。
    static let flatLimit = 0.0016
    /// 单次最多提意多少个（保护面板与渲染，也逼着人去看而不是无脑接受）。
    static let maxFindings = 24

    static func detect(_ image: DisplayImage,
                       faceBounds: CGRect? = nil) -> (found: [Finding], tokens: [String]) {
        let size = image.size
        let count = size.pixelCount
        guard size.longEdge > 0, count >= 64, image.pixels.count >= count * 4 else {
            return ([], ["[too_small]"])
        }
        let px = image.pixels
        var luma = [Float](repeating: 0, count: count)
        var isSkin = [Bool](repeating: false, count: count)
        for i in 0 ..< count {
            let o = i * 4
            let r = px[o], g = px[o + 1], b = px[o + 2]
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            // 肤色像素一律不参与：脸、手、脖子都在同一档亮度里，只靠"暗"分不开。
            isSkin[i] = SkinMask.isSkin(r: Double(r), g: Double(g), b: Double(b))
        }
        let radius = Swift.max(2, size.longEdge / 60)
        let mean = BeautyEngine.blurredChannel(luma, size: size, radius: radius)
        // 局部方差用同一套模糊算 E[x²] − E[x]²，不必另写一遍窗口。
        var square = [Float](repeating: 0, count: count)
        for i in 0 ..< count { square[i] = luma[i] * luma[i] }
        let meanSquare = BeautyEngine.blurredChannel(square, size: size, radius: radius)
        let w = size.width
        let h = size.height

        var candidates: [(index: Int, depth: Double, spread: Double)] = []
        for y in 1 ..< h - 1 {
            for x in 1 ..< w - 1 {
                let i = y * w + x
                if isSkin[i] { continue }
                let m = Double(mean[i])
                let variance = Double(meanSquare[i] - m * m)
                guard variance >= 0, variance < flatLimit else { continue }
                let depth = m - Double(luma[i])
                guard depth > darkLimit else { continue }
                candidates.append((i, depth, variance))
            }
        }
        guard !candidates.isEmpty else { return ([], ["[spot-repair:none]"]) }

        // 脸框内一律跳过：合影里孩子占的画面不大，单靠肤色判据会漏（下面按归一化
        // 坐标判，向外放 0.02 是为了连上头发边缘一起不碰）。
        if let box = faceBounds, box.width > 0, box.height > 0 {
            candidates.removeAll { entry in
                let p = CGPoint(x: CGFloat(entry.index % w) / CGFloat(w),
                                y: CGFloat(entry.index / w) / CGFloat(h))
                return box.insetBy(dx: -0.02, dy: -0.02).contains(p)
            }
            guard !candidates.isEmpty else { return ([], ["[spot-repair:none]"]) }
        }
        candidates.sort { $0.depth > $1.depth }
        // 从最暗的开始取，取完把它周围一圈当已占用 —— 否则同一个污点会被切成
        // 好几个重叠笔迹，接受一次就等于在原地糊两遍。
        let spotRadius = Double(Swift.max(3, size.longEdge / 120)) / Double(size.longEdge)
        var taken = Set<Int>()
        var found: [Finding] = []
        for candidate in candidates {
            if found.count >= maxFindings { break }
            if taken.contains(candidate.index) { continue }
            let x = candidate.index % w
            let y = candidate.index / w
            // 8 格邻域内的候选一并占用。
            for dy in (-4)...4 {
                for dx in (-4)...4 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, ny >= 0, nx < w, ny < h { taken.insert(ny * w + nx) }
                }
            }
            let at = CGPoint(x: CGFloat(x) / CGFloat(w), y: CGFloat(y) / CGFloat(h))
            // 取样点向下偏 4 倍半径：背景平坦，偏一点仍是同一片颜色。
            let source = CGPoint(x: at.x, y: min(1, at.y + CGFloat(spotRadius * 4)))
            found.append(Finding(at: at, radius: spotRadius, source: source))
        }
        var tokens = ["[spot-repair:\(found.count)]"]
        if candidates.count > maxFindings { tokens.append("[spot-repair:capped]") }
        if faceBounds == nil { tokens.append("[no_face_box]") }
        return (found, tokens)
    }
}
