import Foundation

// 联机拍摄（tethering）的**决策层**。
//
// 为什么把"选哪台相机、文件叫什么、连拍怎么排队"从 AVFoundation 里拆出来：
// 相机是硬件，CI 上没有相机、真机上也不该为了测命名去按十次快门。拆出来后
// 这三件事是纯函数，能被完整断言；剩下的采集部分只是一层薄壳，失败必须
// 点名。这也正是这一整个项目的立场：**能被验证的部分不能靠人眼验收**。
//
// 平台事实（写清楚，不装作什么都能做）：
//   · macOS：外接相机/采集卡经 AVFoundation 以视频设备出现，这条路稳定；
//   · iPadOS：USB 相机（UVC）从 iPadOS 17 起有系统支持，但**需要 Apple 的
//     external-camera entitlement**。未签名的侧载包拿不到这个 entitlement，
//     于是列表为空 —— 这不是代码坏了，所以必须点名 `[no_camera]` 而不是
//     静默地"什么也没发生"（与本项目对缺件的一贯处理一致）；
//   · 真正的"相机原厂联机协议"（Canon EDSDK / Sony Imaging Edge 那一类）
//     是厂商 SDK，不在本项目范围，也不是 iPadOS 能装的东西 —— 见
//     docs/pixcake-parity.md 的 🟥 平台缺口。这里的联机是"相机作为系统输入
//     设备"这一条可行路径：插上就拍、片直接进编辑器。

/// 一台可选的采集设备。
struct TetheredDevice: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    /// "external" / "builtIn" / "continuity"——影响排序，不影响能不能拍。
    var kind: String
    /// 能否真的用来拍（iPad 上没 entitlement 时列表里的设备也可能不可用）。
    var isUsable: Bool

    var title: String { "\(name)（\(kindLabel)）" }

    var kindLabel: String {
        switch kind {
        case "external": return "外接"
        case "continuity": return "连续互通"
        default: return "内置"
        }
    }
}

/// 拍摄设置。都是"按一次快门要发生什么"的决策，不含任何 AVFoundation 类型。
struct TetherSettings: Equatable, Sendable {
    /// 期望的设备 id；不在列表里时回落到首选可用设备并点名。
    var preferredDeviceID: String? = nil
    /// 连拍张数。1 = 单拍。上限见 `TetherPlan.queueLimit`。
    var burstCount: Double = 1
    /// 每张之间的间隔（秒）。0 = 不等待（受相机自身限）。
    var intervalSeconds: Double = 0
    /// 拍完直接进编辑器（true）还是只入库（false）。
    var openInEditor: Bool = true
    /// 自动导入：拍完按素材库规则落盘（sidecar 命名与 `{stem}` 模板一致）。
    var autoImport: Bool = true

    static let validIntervals: ClosedRange<Double> = 0 ... 10
    static let validBurst: ClosedRange<Double> = 1 ... 60

    /// 用户**原本请求**的张数（不夹范围）。截断与夹回都要能点名，而 `burst`
    /// 已经夹到 1…60 —— 拿它去比上限永远“没超额”，那就是“静默少拍”。
    var requestedBurst: Int { Int(burstCount.rounded()) }

    var burst: Int { requestedBurst.clamped(to: Int(Self.validBurst.lowerBound) ... Int(Self.validBurst.upperBound)) }
    var interval: Double { intervalSeconds.clamped(to: Self.validIntervals) }
}

/// 一次联机作业的计划（纯函数）。
enum TetherPlan {
    /// 排队上限。超过它不排队，因为 iPad 后台会被挂起，"排到 200 张"
    /// 的实际结果是拍到第 30 张时静默停止——那比直接拒绝更糟。
    static let queueLimit = 60

    /// 选设备：用户指定的、可用的、按"外接 > 连续互通 > 内置"排序。
    /// 返回 (选中的设备, 是否用了回落)。列表里没有可用设备时返回 nil。
    static func pickDevice(from devices: [TetheredDevice], preferred: String?) -> (TetheredDevice, Bool)? {
        let usable = devices.filter(\.isUsable)
        guard !usable.isEmpty else { return nil }
        if let preferred, let hit = usable.first(where: { $0.id == preferred }) {
            return (hit, false)
        }
        return (ranked(usable)[0], preferred != nil)
    }

    /// 稳定排序：可用的排前面，同层里外接优先（联机拍摄的人本来就是拿外接相机），
    /// 再同层按 id 排保证两次结果一致（不稳定的排序会让"默认设备"每次不同）。
    ///
    /// 可用性必须参与排序：一台**没插电的外接相机**如果排在能用的内置机位之前，
    /// 列表就把用户引到一个按了也没反应的行上。
    static func ranked(_ devices: [TetheredDevice]) -> [TetheredDevice] {
        devices.enumerated().sorted { lhs, rhs in
            let score = rankScore(lhs.element) - rankScore(rhs.element)
            if score != 0 { return score < 0 }
            return lhs.element.id < rhs.element.id
        }.map(\.element)
    }

    private static func rankScore(_ device: TetheredDevice) -> Int {
        let kind: Int
        switch device.kind {
        case "external": kind = 0
        case "continuity": kind = 1
        default: kind = 2
        }
        return kind + (device.isUsable ? 0 : 10)
    }

    /// 连拍队列（含每张的等待时长）。`burst` 越界会被夹到上限，
    /// 并在 `notes` 里说明——不静默丢张。
    static func queue(settings: TetherSettings) -> (shots: [TetherShot], notes: [String]) {
        var notes: [String] = []
        // 拿**未夹范围**的请求值来比上限，否则 `burst` 自己已经夹到 60，
        // `accepted < requested` 永假 —— 请求 999 张会变成“默声拍 60 张”。
        let requested = settings.requestedBurst
        let accepted = max(1, min(requested, queueLimit))
        if accepted < requested {
            notes.append("[burst_capped] 连拍上限 \(queueLimit) 张（请求 \(requested) 张）：长队列在 iPad 上会被后台挂起中断")
        } else if requested < 1 {
            notes.append("[burst_clamped] 请求 \(requested) 张不是合法值，按单拍处理")
        }
        let interval = settings.interval
        let shots = (0 ..< accepted).map { index in
            TetherShot(sequence: index + 1, waitSeconds: index == 0 ? 0 : interval)
        }
        return (shots, notes)
    }

    /// 落盘文件名：`tether-<yyyymmdd-HHMMSS>-<序号>.<ext>`。
    /// 不用 `{stem}` 模板：联机拍的图**还没有原始文件名**，硬套模板会得到
    /// 一串以 `-tether.jpg` 结尾的无主文件名，比一个明确的自定前缀更难查。
    static func fileName(sequence: Int, stamp: String, ext: String) -> String {
        let padded = String(format: "%03d", max(0, sequence))
        return "tether-\(stamp)-\(padded).\(ext)"
    }

    /// 缺件时给人看的那句话。分平台写，因为原因不同。
    static func missingNote(devices: [TetheredDevice]) -> String {
        if devices.isEmpty {
            return "[no_camera] 系统没有列出可用的视频设备"
        }
        return "[no_camera_unusable] 检测到 \(devices.count) 台设备但都不可用"
            + "（iPad 侧 UVC 需要 external-camera entitlement，未签名包拿不到）"
    }
}

struct TetherShot: Equatable, Sendable {
    var sequence: Int
    var waitSeconds: Double
}
