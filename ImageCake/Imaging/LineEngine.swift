import CoreGraphics
import Foundation

// 身体细纹（颈纹 / 妊娠纹 / 疤痕）：涂一块皮肤，只把那里的细暗线填掉。
//
// 算子不新写：直接复用 `RegionEnhance.thinDarkLinePass`（法令纹那一条已经验证过
// 的"只填比低频邻域暗得多的细线、不碰低频阴影"）。这个文件存在的意义只有两点：
//
//   1. **选区不同**。法令纹的区域来自 478 点派生；这里的区域是用户涂出来的
//      （`BrushState.lines`）。身体其他部位没有可靠的关键点，而"涂一下"这个
//      交互本来就在笔刷底座里。
//   2. **不做自动检出**。哪些线是纹、哪些是身体自身的结构阴影（锁骨、孕肚
//      轮廓、腹部中线），在图里没有可分辨的信息；自动版把低频一起抹平的代价
//      是把人抹"扁"，比留几条纹严重得多。所以缺选区时整段不跑并点名
//      `[no_line_region]`，而不是拿皮肤色域当选区（那等于把整片皮肤抹平）。
enum LineEngine {
    /// 在涂过的区域内填细暗线。`weights` 是选区的 0…1 权重（由调用侧从掩码换算，
    /// 与衣物祛褶同一口径），区域外逐比特不动。
    static func apply(_ image: DisplayImage, weights: [Float], lines: BodyLineParameters) -> DisplayImage {
        let size = image.size
        guard !lines.isNeutral, size.pixelCount > 0, weights.count == size.pixelCount,
              image.pixels.count >= size.pixelCount * 4 else { return image }
        var pixels = image.pixels
        RegionEnhance.thinDarkLinePass(&pixels, size: size, weight: weights,
                                       amount: BeautyParameters.unit(lines.deLine))
        return DisplayImage(size: size, pixels: pixels)
    }
}
