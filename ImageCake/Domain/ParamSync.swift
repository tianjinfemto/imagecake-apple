import Foundation

// 参数同步组。像素蛋糕"批量出片"的真正杠杆不是"多张图跑同一组参数"，
// 而是"一张调好 → 其余按组抄过去"：调色可以全抄，手动液化和局部补丁
// 绝对不能抄（那是逐张的脸型与逐张的路人）。所以"哪些能同步"必须显式建模，
// 而不是靠人记得"这次别抄液化"。
//
// 默认值刻意**不含**手动笔迹与修复补丁：它们本来也不在 EditParameters 里
// （见 BrushState 的注释），所以这里想抄也抄不走——把这条约束写进类型，
// 比写进文档可靠。

struct SyncGroups: OptionSet, Sendable {
    let rawValue: Int

    static let tone = SyncGroups(rawValue: 1 << 0)
    static let skin = SyncGroups(rawValue: 1 << 1)
    static let shape = SyncGroups(rawValue: 1 << 2)
    static let style = SyncGroups(rawValue: 1 << 3)
    static let background = SyncGroups(rawValue: 1 << 4)
    static let delivery = SyncGroups(rawValue: 1 << 5)

    /// 出厂推荐：调色 + 人像 + 美型 + 风格 + 背景。不含交付端（面部重绘/超清
    /// 是逐张耗时项，批量时用户要自己决定要不要开）。
    static let `default`: SyncGroups = [.tone, .skin, .shape, .style, .background]
    static let all: SyncGroups = [.tone, .skin, .shape, .style, .background, .delivery]

    init(rawValue: Int) { self.rawValue = rawValue }

    var title: String {
        var parts: [String] = []
        if contains(.tone) { parts.append("调色") }
        if contains(.skin) { parts.append("美肤") }
        if contains(.shape) { parts.append("美型") }
        if contains(.style) { parts.append("滤镜镜头") }
        if contains(.background) { parts.append("背景") }
        if contains(.delivery) { parts.append("交付端AI") }
        return parts.isEmpty ? "无" : parts.joined(separator: " / ")
    }
}

enum ParamSync {
    /// 按组把 source 的相应字段搬到 target 上，其余保持 target 原值。
    /// 读起来像"赋值一堆字段"，但每一组都要成对处理：漏一个键的症状是
    /// "同步过去少一半效果"，这种半套状态比整段不动难查得多。
    static func merge(source: EditParameters, into target: EditParameters,
                      groups: SyncGroups) -> EditParameters {
        var out = target
        if groups.contains(.tone) {
            out.exposure = source.exposure
            out.temperature = source.temperature
            out.tint = source.tint
            out.contrast = source.contrast
            out.saturation = source.saturation
            out.hue = source.hue
            out.fillLight = source.fillLight
            out.highlightSoften = source.highlightSoften
            out.denoise = source.denoise
            out.sharpen = source.sharpen
            out.wshHue = source.wshHue; out.wshSat = source.wshSat; out.wshLum = source.wshLum
            out.wmtHue = source.wmtHue; out.wmtSat = source.wmtSat; out.wmtLum = source.wmtLum
            out.whlHue = source.whlHue; out.whlSat = source.whlSat; out.whlLum = source.whlLum
            out.hslHue = source.hslHue
            out.hslSat = source.hslSat
            out.hslLum = source.hslLum
            out.curves = source.curves
        }
        if groups.contains(.skin) {
            var beauty = out.beauty
            beauty.skinSmooth = source.beauty.skinSmooth
            beauty.bodySmooth = source.beauty.bodySmooth
            beauty.smoothMode = source.beauty.smoothMode
            beauty.blemish = source.beauty.blemish
            beauty.toneUnify = source.beauty.toneUnify
            beauty.redness = source.beauty.redness
            beauty.deShine = source.beauty.deShine
            beauty.whitening = source.beauty.whitening
            beauty.eyeBright = source.beauty.eyeBright
            beauty.teethWhiten = source.beauty.teethWhiten
            beauty.lipColor = source.beauty.lipColor
            beauty.blush = source.beauty.blush
            beauty.darkCircle = source.beauty.darkCircle
            beauty.nasolabial = source.beauty.nasolabial
            out.beauty = beauty
        }
        if groups.contains(.shape) {
            var beauty = out.beauty
            beauty.slimFace = source.beauty.slimFace
            beauty.enlargeEyes = source.beauty.enlargeEyes
            beauty.noseSlim = source.beauty.noseSlim
            beauty.jawSlim = source.beauty.jawSlim
            beauty.smileLift = source.beauty.smileLift
            beauty.chinAdjust = source.beauty.chinAdjust
            beauty.waistSlim = source.beauty.waistSlim
            beauty.legsSlim = source.beauty.legsSlim
            beauty.heighten = source.beauty.heighten
            beauty.neckSlim = source.beauty.neckSlim
            beauty.shoulderLift = source.beauty.shoulderLift
            out.beauty = beauty
        }
        if groups.contains(.style) {
            out.filter = source.filter
            out.lens = source.lens
            // requires 登记的是外部资产（.cube 表），跟着滤镜走。
            out.requires = source.requires.filter { $0.hasPrefix("lut:") }
        }
        if groups.contains(.background) {
            out.bgEnabled = source.bgEnabled
            out.bgR = source.bgR; out.bgG = source.bgG; out.bgB = source.bgB
            out.bgBlur = source.bgBlur
            out.defringe = source.defringe
        }
        if groups.contains(.delivery) {
            out.faceRestore = source.faceRestore
            out.superRes = source.superRes
        }
        out.clamp()
        return out
    }
}
