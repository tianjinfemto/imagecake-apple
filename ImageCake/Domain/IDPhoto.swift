import CoreGraphics
import Foundation

// 证件照：规格表、构图裁剪建议、打印排版。
//
// 为什么这一整块都不需要 AI：证件照的难点是**尺寸与合规**，不是生成内容。
//  mm → 像素、头部占比、相纸排版都是确定性算术，能精确断言，也正好是影楼
//  最需要"错一个像素就退片"的部分。换底色复用 α（AI 面板），头身定位复用
//  关键点（478 点/17 点），这里只做"按规格决定画布"。
//
// 两个刻意的选择：
//   · 一律按 300dpi 出像素。部分官方规格（身份证 358×441）隐含 350dpi，
//     这里不强凑那个像素数——凑上去会把 mm 尺寸改掉，而打印店看的是 mm。
//     差异写在这里，不假装不存在。
//   · 二寸按 35×49（最常见的冲印口径）。各地"二寸"并不统一，所以规格表
//     是数据而不是硬编码在算子里，需要时可增删。

struct IDPhotoSpec: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var widthMM: Double
    var heightMM: Double
    /// 头部（发际顶到下巴）占画面高度的推荐比例。
    var headRatio: Double
    /// 推荐底色（nil = 不限）。UI 用它一键设背景，真正的抠底仍走 α。
    var background: RGBA8?

    var dpi: Int { IDPhoto.dpi }
    var aspect: Double { heightMM > 0 ? widthMM / heightMM : 1 }

    /// 300dpi 下的目标像素尺寸（四舍五入，不做整数截断）。
    var pixelSize: PixelSize {
        PixelSize(width: IDPhoto.pixels(mm: widthMM, dpi: dpi),
                  height: IDPhoto.pixels(mm: heightMM, dpi: dpi))
    }
}

/// 相纸（排版载体）。
struct PaperSpec: Equatable, Sendable {
    var id: String
    var title: String
    var widthMM: Double
    var heightMM: Double

    var pixelSize: PixelSize {
        PixelSize(width: IDPhoto.pixels(mm: widthMM, dpi: IDPhoto.dpi),
                  height: IDPhoto.pixels(mm: heightMM, dpi: IDPhoto.dpi))
    }
}

/// 一次排版的结果：画布尺寸 + 每张照片占的像素矩形。
struct IDPhotoSheet: Equatable, Sendable {
    var paper: PaperSpec
    var canvas: PixelSize
    var slots: [PixelRect]
    var count: Int { slots.count }
}

enum IDPhoto {
    /// 全链统一的打印精度。
    static let dpi = 300

    static let specs: [IDPhotoSpec] = [
        IDPhotoSpec(id: "mini-one", title: "小一寸 22×32", widthMM: 22, heightMM: 32, headRatio: 0.62,
                    background: RGBA8(r: 255, g: 255, b: 255)),
        IDPhotoSpec(id: "one", title: "一寸 25×35", widthMM: 25, heightMM: 35, headRatio: 0.62,
                    background: RGBA8(r: 255, g: 255, b: 255)),
        IDPhotoSpec(id: "two", title: "二寸 35×49", widthMM: 35, heightMM: 49, headRatio: 0.62,
                    background: RGBA8(r: 255, g: 255, b: 255)),
        IDPhotoSpec(id: "mini-two", title: "小二寸 35×45", widthMM: 35, heightMM: 45, headRatio: 0.62,
                    background: RGBA8(r: 58, g: 110, b: 165)),
        IDPhotoSpec(id: "passport", title: "护照 33×48", widthMM: 33, heightMM: 48, headRatio: 0.60,
                    background: RGBA8(r: 255, g: 255, b: 255)),
        IDPhotoSpec(id: "id-card", title: "身份证 26×32", widthMM: 26, heightMM: 32, headRatio: 0.62,
                    background: RGBA8(r: 255, g: 255, b: 255)),
        IDPhotoSpec(id: "visa-us", title: "美签 51×51", widthMM: 51, heightMM: 51, headRatio: 0.58,
                    background: RGBA8(r: 255, g: 255, b: 255)),
        IDPhotoSpec(id: "schengen", title: "申根 35×45", widthMM: 35, heightMM: 45, headRatio: 0.62,
                    background: RGBA8(r: 255, g: 255, b: 255)),
    ]

    static let papers: [PaperSpec] = [
        PaperSpec(id: "5inch", title: "5 寸 89×127", widthMM: 89, heightMM: 127),
        PaperSpec(id: "6inch", title: "6 寸 102×152", widthMM: 102, heightMM: 152),
        PaperSpec(id: "a4", title: "A4 210×297", widthMM: 210, heightMM: 297),
    ]

    static func spec(id: String) -> IDPhotoSpec? { specs.first { $0.id == id } }
    static func paper(id: String) -> PaperSpec? { papers.first { $0.id == id } }

    /// mm → 像素（四舍五入）。
    static func pixels(mm: Double, dpi: Int = IDPhoto.dpi) -> Int {
        guard dpi > 0, mm > 0 else { return 0 }
        return Int((mm / 25.4 * Double(dpi)).rounded())
    }

    // MARK: - 构图

    /// 按规格给裁剪框（归一化，y 向下）。
    ///
    /// 有头部框时：**先把头放对**——头高 = 画面高 × headRatio，头顶留白
    /// 取画面高的 8%（证件照的通行口径），再横向居中；最后整框夹回画布内。
    /// 没有头部框时：按规格比例取画面中心的一块，并在调用侧点名
    /// `[no_face_box]`——不猜头在哪。
    static func suggestedCrop(canvas: PixelSize, spec: IDPhotoSpec, headBox: PixelRect?) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let canvasW = Double(canvas.width), canvasH = Double(canvas.height)

        guard let head = headBox, head.height > 0 else {
            // 中心构图：能装下的最大规格比例框。
            let scale = Swift.min(canvasW / spec.widthMM, canvasH / spec.heightMM)
            let w = spec.widthMM * scale, h = spec.heightMM * scale
            return CGRect(x: (canvasW - w) / 2 / canvasW, y: (canvasH - h) / 2 / canvasH,
                          width: w / canvasW, height: h / canvasH)
        }

        let headHeight = Double(head.height)
        let frameHeight = Swift.min(headHeight / Swift.max(spec.headRatio, 0.1), canvasH)
        let frameWidth = Swift.min(frameHeight * spec.aspect, canvasW)
        // 头顶留白 8%：框顶 = 头顶 − 0.08·画面高。
        var top = Double(head.y) - frameHeight * 0.08
        var left = Double(head.midX) - frameWidth / 2
        top = Swift.min(Swift.max(top, 0), Swift.max(0, canvasH - frameHeight))
        left = Swift.min(Swift.max(left, 0), Swift.max(0, canvasW - frameWidth))
        return CGRect(x: left / canvasW, y: top / canvasH,
                      width: frameWidth / canvasW, height: frameHeight / canvasH)
    }

    // MARK: - 排版

    /// 算一张相纸能排几张（含页边距与间距，都是 mm）。
    static func sheet(spec: IDPhotoSpec, paper: PaperSpec, marginMM: Double = 5, gapMM: Double = 2) -> IDPhotoSheet {
        let paperPx = paper.pixelSize
        let tile = spec.pixelSize
        guard paperPx.pixelCount > 0, tile.pixelCount > 0 else {
            return IDPhotoSheet(paper: paper, canvas: .zero, slots: [])
        }
        let margin = pixels(mm: marginMM), gap = pixels(mm: gapMM)
        let usableW = paperPx.width - margin * 2
        let usableH = paperPx.height - margin * 2
        guard usableW > tile.width, usableH > tile.height else {
            return IDPhotoSheet(paper: paper, canvas: paperPx, slots: [])
        }
        let cols = Swift.max(1, (usableW + gap) / (tile.width + gap))
        let rows = Swift.max(1, (usableH + gap) / (tile.height + gap))
        var slots: [PixelRect] = []
        for row in 0 ..< rows {
            for col in 0 ..< cols {
                let x = margin + col * (tile.width + gap)
                let y = margin + row * (tile.height + gap)
                let rect = PixelRect(x: x, y: y, width: tile.width, height: tile.height)
                // 越界的槽位直接不要：宁可少排一张，也不切掉半张脸。
                if rect.maxX <= paperPx.width, rect.maxY <= paperPx.height { slots.append(rect) }
            }
        }
        return IDPhotoSheet(paper: paper, canvas: paperPx, slots: slots)
    }

    /// 把一张证件照排到相纸上（同一张重复 count 次）。
    /// 输入会被缩放到槽位尺寸；比例不符时**按比例贴合再居中留白**，
    /// 而不是硬拉——硬拉的表现是"人脸被压扁"，退片成本比留白高。
    static func layout(_ photo: RGBA8Buffer, sheet: IDPhotoSheet, background: RGBA8 = RGBA8(r: 255, g: 255, b: 255)) -> RGBA8Buffer? {
        guard sheet.count > 0, sheet.canvas.pixelCount > 0, photo.size.pixelCount > 0 else { return nil }
        let canvas = sheet.canvas
        var bytes = [UInt8](repeating: 0, count: canvas.pixelCount * 4)
        for i in 0 ..< canvas.pixelCount {
            bytes[i * 4] = background.r
            bytes[i * 4 + 1] = background.g
            bytes[i * 4 + 2] = background.b
            bytes[i * 4 + 3] = 255
        }
        for slot in sheet.slots {
            draw(photo, into: &bytes, canvas: canvas, at: slot)
        }
        return RGBA8Buffer(size: canvas, data: Data(bytes))
    }

    /// 等比缩放 + 居中，把一张图放进槽位（整数搬运，不引入第二次插值）。
    private static func draw(_ photo: RGBA8Buffer, into dst: inout [UInt8], canvas: PixelSize, at slot: PixelRect) {
        let fitted = fittedSize(of: photo, in: slot.size)
        let resized = photo.resized(to: fitted)
        let offsetX = slot.x + (slot.width - fitted.width) / 2
        let offsetY = slot.y + (slot.height - fitted.height) / 2
        let src = [UInt8](resized.data)
        for y in 0 ..< fitted.height {
            let dstRow = (offsetY + y) * canvas.width + offsetX
            guard offsetY + y < canvas.height, dstRow >= 0 else { continue }
            for x in 0 ..< fitted.width {
                let dstIndex = (dstRow + x) * 4
                guard dstIndex + 3 < dst.count else { continue }
                let srcIndex = (y * fitted.width + x) * 4
                dst[dstIndex] = src[srcIndex]
                dst[dstIndex + 1] = src[srcIndex + 1]
                dst[dstIndex + 2] = src[srcIndex + 2]
                dst[dstIndex + 3] = src[srcIndex + 3]
            }
        }
    }

    static func fittedSize(of photo: RGBA8Buffer, in target: PixelSize) -> PixelSize {
        guard photo.size.width > 0, photo.size.height > 0, target.width > 0, target.height > 0 else { return target }
        let scale = Swift.min(Double(target.width) / Double(photo.size.width),
                              Double(target.height) / Double(photo.size.height))
        return PixelSize(width: Swift.max(1, Int((Double(photo.size.width) * scale).rounded())),
                         height: Swift.max(1, Int((Double(photo.size.height) * scale).rounded())))
    }
}
