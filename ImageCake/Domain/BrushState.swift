import CoreGraphics
import Foundation

// 笔刷类编辑的状态。
//
// 与调色参数的根本差别：调色是**可逆的纯函数**（同一组参数任何时候重算都得到
// 同一个结果），笔刷是**直接改像素**。所以它进不了 EditParameters——预设要能
// 导出、滑杆要能复位，而一条笔迹既不"归零"也不"重算"，它是一段历史。
//
// 这里存的是**笔迹本身**而不是栅格化好的掩码，三个理由：
//   · 值类型，能直接进撤销栈（栅格化结果按分辨率算，2048 档一份是 4MB，
//     存进历史等于每步复制一张掩码）；
//   · 能序列化。笔迹不进 v37 预设格式（预设是给"参数"的），但要留给工程文件；
//   · 分辨率无关。导出走全分辨率重放时，归一化坐标 × 新画布就是正确位置，
//     半径按长边比例存同理——不需要任何换算表。
//
// 保护笔刷同样存笔迹：它和液化/图章共用 StrokeRasterizer 的语义，
// 栅格化留给渲染时按当前画布做一次。
struct BrushState: Equatable, Sendable {
    var liquify: [LiquifyStroke] = []
    var stamps: [CloneStamp] = []
    /// 保护笔刷。栅格化后 255 = 完全保护（液化不推、图章不盖）。
    var protection: [BrushStroke] = []
    /// 衣物祛褶的**涂抹区**。它不是"参数"而是历史（和液化同一条理由），
    /// 所以进 BrushState 而不是 GarmentParameters——预设同步抢不走它，
    /// 而这是对的：批里另一张衣服褶不在这个位置。
    var garments: [BrushStroke] = []

    var isEmpty: Bool { liquify.isEmpty && stamps.isEmpty && protection.isEmpty && garments.isEmpty }

    /// 涂过的衣物区（当前画布下的掩码）。没涂就是 nil，而不是全零掩码——
    /// 没选区时祛褶整段不跑，并点名 `[no_garment_region]`。
    func garmentMask(for size: PixelSize) -> MaskBuffer? {
        guard !garments.isEmpty else { return nil }
        return StrokeRasterizer.mask(strokes: garments, size: size)
    }

    /// 当前画布下的保护掩码。没涂保护笔刷时是 nil，而不是全零掩码——
    /// 让引擎走「完全没有这回事」那条分支，省掉整张图的逐像素乘法。
    func protectionMask(for size: PixelSize) -> MaskBuffer? {
        guard !protection.isEmpty else { return nil }
        return StrokeRasterizer.mask(strokes: protection, size: size)
    }
}
