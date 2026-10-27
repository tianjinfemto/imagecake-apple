import Foundation

// AI 层的公共契约。
//
// 这个文件里最重要的东西不是类型，而是**失败如何被指认**：
// imagecake 反复证明"模型没加载上"和"模型加载上了但没出结果"在成品上长得
// 一模一样。所以每个结果都带 note（ASCII 令牌），缺件不静默降级，也不拿
// 插值/磨皮冒充 AI。UI 把那句话原样显示给用户。

enum AIError: LocalizedError, Equatable {
    /// 权重不在盘上。文件名点名到**文件**，不点到"某个功能"。
    case modelMissing(String)
    case modelSizeMismatch(file: String, expected: Int, actual: Int)
    case modelDigestMismatch(file: String)
    /// 这份构建没有 ORT（SPM 没解析成功 / 平台不支持）。
    case backendUnavailable
    case badInput(String)
    case badShape(String)
    case inference(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let file):
            return "[no_model:\(file)]"
        case .modelSizeMismatch(let file, let expected, let actual):
            return "[size_mismatch:\(file)] 期望 \(expected) 字节，实际 \(actual)"
        case .modelDigestMismatch(let file):
            return "[sha256_mismatch:\(file)] 文件与清单不符，请删掉重下"
        case .backendUnavailable:
            return "[no_ort] 这份构建没有可用的 ONNX Runtime"
        case .badInput(let detail):
            return "[bad_input] \(detail)"
        case .badShape(let detail):
            return "[bad_shape] \(detail)"
        case .inference(let detail):
            return "[infer] \(detail)"
        }
    }

    /// 给 UI 的一句话（不重复令牌）。
    var userMessage: String {
        switch self {
        case .modelMissing(let file):
            return "缺少权重 \(file)，去「模型」页下载或导入"
        case .modelSizeMismatch(let file, _, _):
            return "权重 \(file) 不完整，删掉重下"
        case .modelDigestMismatch(let file):
            return "权重 \(file) 校验失败"
        case .backendUnavailable:
            return "ONNX Runtime 不可用"
        case .badInput(let detail), .badShape(let detail), .inference(let detail):
            return detail
        }
    }
}

/// 一次前向的输入/输出。Data 是 float32 的原始字节（little-endian，Apple 全系）。
struct TensorValue: Sendable {
    var shape: [Int]
    var data: Data

    var elementCount: Int { shape.reduce(1, *) }
}

struct ModelSignature: Sendable {
    var inputNames: [String]
    var outputNames: [String]
}

/// 模型状态：UI 与任务共用同一套判定，别处不许再写"文件在不在"。
enum ModelState: Equatable, Sendable {
    case missing
    case sizeMismatch(expected: Int, actual: Int)
    case unverified(URL)
    case ready(URL)
    case bundled(URL)

    var isUsable: Bool {
        switch self {
        case .ready, .bundled: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .missing: return "未下载"
        case .sizeMismatch: return "文件不完整"
        case .unverified: return "已就位（未校验）"
        case .ready: return "已就绪"
        case .bundled: return "随包"
        }
    }
}

/// 任务报告。success 与 note 是两个维度：note 非空不代表失败
/// （例如"已回退 Vision 抠图"），判断成败只看 ok。
struct AIReport: Sendable {
    var ok: Bool
    var note: String
    var elapsedMs: Double

    static func failure(_ message: String, ms: Double = 0) -> AIReport {
        AIReport(ok: false, note: message, elapsedMs: ms)
    }
}

struct MattingResult: Sendable {
    var mask: MaskBuffer?
    /// "modnet" / "vision" / "none"
    var path: String
    var report: AIReport
}

struct InpaintResult: Sendable {
    var patch: InpaintPatch?
    var report: AIReport
}

struct SuperResResult: Sendable {
    var image: RGBA8Buffer?
    var scale: Int
    var report: AIReport
    var tiles: Int
}

struct FaceRestoreResult: Sendable {
    var image: RGBA8Buffer?
    var faces: Int
    var report: AIReport
}

/// 一块可复用的修复成果（与 imagecake 的 InpaintPatch 同构）。
///
/// 为什么不缓存"合成好的整张图"：用户接着拖曝光时，旧补丁要能贴到新的
/// 明暗上。存"修复当时做了什么"（fill − base）而不是"做成什么"（fill），
/// 缓存才穿得过色参变化；直接贴旧图会在遮罩外沿留一圈旧曝光的边。
struct InpaintPatch: Sendable {
    var rect: PixelRect
    /// 这块补丁是在哪个尺寸的画布上算出来的。导出换分辨率时按它换算——
    /// 没有这个字段就只能拿"当前画布"猜，而猜错的表现是补丁整体偏移。
    var reference: PixelSize
    var fill: RGBA8Buffer   // 融合完的网络内容
    var base: RGBA8Buffer   // 推理时那一张底图在 rect 内的部分
    var alpha: MaskBuffer   // 羽化后的合成权重（遮罩外为 0）

    var isValid: Bool {
        !rect.isEmpty
            && fill.size == PixelSize(width: rect.width, height: rect.height)
            && base.size == fill.size
            && alpha.size == fill.size
    }

    /// 换到另一张画布尺寸（导出全分辨率时用）。
    /// 这是 v1 的**已知降级**：网络内容被缩放而不是重跑，导出报告里会写
    /// `[patch_scaled]`（与"导出让用户等几分钟重跑一次 LaMa"相比，
    /// v1 选前者，并在文档里说明）。
    func scaled(to canvas: PixelSize) -> InpaintPatch? {
        guard isValid, reference.width > 0, reference.height > 0, canvas.width > 0 else { return nil }
        if canvas == reference { return self }
        let sx = Double(canvas.width) / Double(reference.width)
        let sy = Double(canvas.height) / Double(reference.height)
        let target = PixelRect(x: Int((Double(rect.x) * sx).rounded()),
                               y: Int((Double(rect.y) * sy).rounded()),
                               width: max(1, Int((Double(rect.width) * sx).rounded())),
                               height: max(1, Int((Double(rect.height) * sy).rounded())))
            .intersected(with: PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        guard !target.isEmpty,
              let fillImage = DisplayImage(displayRGBA8: fill),
              let baseImage = DisplayImage(displayRGBA8: base) else { return nil }
        return InpaintPatch(rect: target,
                            reference: canvas,
                            fill: fillImage.resized(to: target.size).rgba8(),
                            base: baseImage.resized(to: target.size).rgba8(),
                            alpha: alpha.resized(to: target.size))
    }
}
