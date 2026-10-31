import Foundation

// 素材库（像素蛋糕的"项目/相册"那一层的最小可用版）。
//
// 为什么需要这一层：批量链路之前只到"选文件 → 跑队列"，而商业修图的真实
// 工作是"一组片子要管"——哪张调过、哪张没动、哪张已经出片，这些状态在
// 关掉窗口后就丢了，下一次进来只能重头认。这里补的是**状态与续作**，
// 不是云端项目（云端/协作/在线选片属于平台缺口，见 docs/pixcake-parity.md §4）。
//
// 三条立场：
//   · 工程不新建文件类型。素材就在用户选的那个目录里，每张图旁边落一份
//     `<名字>.imagecake.json` 的 sidecar 存参数（与 Lightroom 的 .xmp 同一个
//     思路）；这样"换设备/重开 App"不需要找回我们的私有工程。
//   · 目录里的 URL 授权是会话级的（沙箱不会让我们下次自动进来），所以
//     每次都要重新选目录 —— 但 sidecar 里的**参数**仍然接得上。
//   · 状态是从文档派生的，不是用户手点的：`derive` 只认"有没有真的动过这张图"。
//     手点状态的症状是"标了已修但参数全 0"。

enum LibraryStatus: String, Equatable, Sendable, CaseIterable, Codable {
    case unedited
    case edited
    case exported

    var title: String {
        switch self {
        case .unedited: return "未修"
        case .edited: return "已修"
        case .exported: return "已出片"
        }
    }

    var icon: String {
        switch self {
        case .unedited: return "circle"
        case .edited: return "checkmark.circle"
        case .exported: return "square.and.arrow.down"
        }
    }
}

struct LibraryItem: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var url: URL
    var status: LibraryStatus = .unedited
    /// sidecar 文件名。同一目录里两张同名不同扩展的图会撞名，
    /// 撞上的那张在这里点名，而不是悄悄共用一份参数。
    var sidecarName: String?

    var fileName: String { url.lastPathComponent }
    var sidecarURL: URL? {
        guard let sidecarName else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(sidecarName)
    }
}

/// 筛选条件。全部/未修/已修/已出片 四档，对应商业出片的"这批还剩几张"。
enum LibraryFilter: String, Equatable, Sendable, CaseIterable, Codable {
    case all, unedited, edited, exported

    var title: String {
        switch self {
        case .all: return "全部"
        case .unedited: return "未修"
        case .edited: return "已修"
        case .exported: return "已出片"
        }
    }

    func matches(_ status: LibraryStatus) -> Bool {
        switch self {
        case .all: return true
        case .unedited: return status == .unedited
        case .edited: return status == .edited
        case .exported: return status == .exported
        }
    }
}

enum ImageLibrary {
    /// 认作素材的扩展名。与 `ImageLoader.rawExtensions` 的交集由扫描时决定，
    /// 这里只保证"能列出的一律是本项目打得开的"。
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp", "gif"
    ]

    /// sidecar 的名字规则：`<图名>.imagecake.json`。纯函数，可断言。
    static func sidecarName(for url: URL) -> String {
        "\(url.deletingPathExtension().lastPathComponent).imagecake.json"
    }

    /// 扫目录（只扫一层）。返回按文件名排序的条目；非图片与子目录跳过。
    /// 撞 sidecar 名的条目会带 `sidecarName = nil`（调用侧显示为"参数不入库"）。
    static func scan(folder: URL) -> [LibraryItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        let images = entries
            .filter { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return values?.isRegularFile == true
                    && imageExtensions.contains(url.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var seen: Set<String> = []
        return images.map { url in
            let name = sidecarName(for: url)
            let collision = seen.contains(name)
            seen.insert(name)
            return LibraryItem(url: url, sidecarName: collision ? nil : name)
        }
    }

    /// 从文档派生状态。判据是"这张图真的被动过"：参数非中性、有笔迹、
    /// 有抠图/补丁/本地调节/修补/老照片/排版任一项。
    static func derive(document: ImageDocument?) -> LibraryStatus {
        guard let document else { return .unedited }
        let touched = !document.params.isNeutral
            || !document.brush.isEmpty
            || !document.localAdjustments.isEmpty
            || !document.patchStrokes.isEmpty
            || !document.patches.isEmpty
            || document.personMask != nil
            || document.oldPhotoRestore
            || document.idPhotoSheet != nil
            || document.collage != nil
        return touched ? .edited : .unedited
    }

    static func filter(_ items: [LibraryItem], by filter: LibraryFilter) -> [LibraryItem] {
        items.filter { filter.matches($0.status) }
    }

    /// 各状态的计数（面板上的一行进度）。
    static func counts(_ items: [LibraryItem]) -> [LibraryStatus: Int] {
        var out: [LibraryStatus: Int] = [:]
        for item in items { out[item.status, default: 0] += 1 }
        return out
    }
}

// MARK: - sidecar 读写

enum ProjectStore {
    /// sidecar 里存的东西：参数 + 状态 + 来源。
    /// `exportedAt` 只用于"已出片"的判定与展示，不参与参数恢复。
    struct ProgressFile: Codable {
        var presetVersion: Int = EditParameters.presetVersion
        var params: EditParameters = EditParameters()
        var status: LibraryStatus = .unedited
        var sourceName: String = ""
        var exportedAt: Date?
    }

    /// 把当前文档的参数写进素材目录里的 sidecar。
    /// 返回 nil = 这条素材没有可用的 sidecar 名（重名冲突）。
    @discardableResult
    static func save(params: EditParameters, status: LibraryStatus, to item: LibraryItem) -> String? {
        guard let url = item.sidecarURL else { return nil }
        var file = ProgressFile(params: params, status: status, sourceName: item.fileName)
        file.exportedAt = status == .exported ? Date() : nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url.lastPathComponent
        } catch {
            return nil
        }
    }

    /// 读回参数。文件坏/版本更新都**不抛**：返回 nil 并让调用侧显示"参数没接上"，
    /// 而不是打开图失败——素材打不开比参数没恢复严重得多。
    static func load(from item: LibraryItem) -> ProgressFile? {
        guard let url = item.sidecarURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(ProgressFile.self, from: data) else { return nil }
        // 比本程序新的预设：拒收（与 PresetStore 同一立场），不猜字段。
        guard file.presetVersion <= EditParameters.presetVersion else { return nil }
        var params = file.params
        params.clamp()
        return ProgressFile(presetVersion: EditParameters.presetVersion, params: params,
                            status: file.status, sourceName: file.sourceName, exportedAt: file.exportedAt)
    }
}
