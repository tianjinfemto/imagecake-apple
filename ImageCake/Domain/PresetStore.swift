import Foundation

// 预设读写。键名与 imagecake 逐字对齐（snake_case），因此两边的文件可以
// 互相读：缺键落出厂（对方的语义），不认识的键**点名丢进报告**（我们的语义）。
//
// 两条硬约束（与 imagecake 的 PresetIO::migrate 同源）：
//   1. 版本比本程序新 → 拒收。旧程序读新文件只能猜，猜错的预设会安静地
//      输出一批"看着没问题但参数不对"的片子。
//   2. 读失败时**一个字段都不改**。半套状态（参数变了、笔迹没了）比报错难查。

struct PresetLoadReport: Sendable {
    var version: Int
    /// 文件里有、本程序没有落点的键（排序稳定）。
    var unknownKeys: [String]
    /// 人读的一句话（空 = 无需提示）。
    var warning: String
}

enum PresetError: LocalizedError {
    case tooNew(Int)
    case notJSON(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooNew(let version):
            return "[preset_too_new] 预设版本 \(version) 比本程序（\(EditParameters.presetVersion)）新"
        case .notJSON(let detail):
            return "[preset_not_json] \(detail)"
        case .unreadable(let detail):
            return "[preset_unreadable] \(detail)"
        }
    }
}

enum PresetStore {
    static func load(from url: URL) throws -> (params: EditParameters, report: PresetLoadReport) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetError.unreadable(error.localizedDescription)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw PresetError.notJSON("顶层不是 JSON 对象")
        }
        let version = (root["preset_version"] as? NSNumber)?.intValue ?? 1
        guard version <= EditParameters.presetVersion else {
            throw PresetError.tooNew(version)
        }
        let params: EditParameters
        do {
            params = try JSONDecoder().decode(EditParameters.self, from: data)
        } catch {
            throw PresetError.notJSON(error.localizedDescription)
        }
        let unknown = root.keys
            .filter { !EditParameters.knownKeys.contains($0) }
            .sorted()
        var warning = ""
        if !unknown.isEmpty {
            warning = "已忽略 \(unknown.count) 个本程序没有落点的键：\(unknown.joined(separator: ", "))"
        }
        if !params.requires.isEmpty {
            // v1 不加载 lut/追色/天空表：点名告诉用户"这份预设带外部资产"，
            // 而不是让滤镜悄悄消失。
            let assets = params.requires.joined(separator: ", ")
            warning += (warning.isEmpty ? "" : "；") + "这份预设依赖外部资产：\(assets)（v1 未加载）"
        }
        return (params, PresetLoadReport(version: version, unknownKeys: unknown, warning: warning))
    }

    static func save(_ params: EditParameters, to url: URL) throws {
        var copy = params
        copy.presetVersion = EditParameters.presetVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
    }

    /// 预设默认目录：文稿目录下的 ImageCake/Presets。iOS 上可从"文件"App 看到。
    static func defaultDirectory() -> URL? {
        guard let base = try? FileManager.default.url(for: .documentDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        let dir = base.appendingPathComponent("ImageCake", isDirectory: true)
            .appendingPathComponent("Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func savedPresets() -> [URL] {
        guard let dir = defaultDirectory() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
