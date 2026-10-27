import CryptoKit
import Foundation

// 权重仓。
//
// 与 imagecake 的两条立场一致：
//   1. 权重不进 App 包（按需下载/导入），所以"缺件"是常态而不是异常；
//   2. 缺件必须点名到文件，并且**不拿别的算法冒充**。
//
// 解析顺序：随包 → Application Support/ImageCake/models → 内置测试目录。
// 随包排在最前，是为了让"这一版锁死某颗权重"成为可能；Application Support
// 在后，用户后补的文件不会盖掉随包版本（imagecake 的 asset_locator 末位）。

struct ModelStore: Sendable {
    let manifest: ModelManifest

    static let directoryName = "ImageCake"

    init(manifest: ModelManifest) {
        self.manifest = manifest
    }

    static func loadManifest(bundle: Bundle = .main) -> ModelManifest {
        switch ModelCatalog.load(from: bundle) {
        case .success(let manifest):
            return manifest
        case .failure:
            // 清单坏了也得让 App 起来：空清单 = 所有 AI 都点名缺件。
            return ModelManifest(schema: 1, defaultTier: .core, models: [])
        }
    }

    var manifestError: String? {
        if case .failure(let error) = ModelCatalog.load() { return error.localizedDescription }
        return nil
    }

    // MARK: - 路径

    /// 权重的可写目录。iOS 的 Application Support 默认不存在，必须创建。
    static func modelsDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func descriptor(id: String) -> ModelDescriptor? {
        manifest.models.first { $0.id == id }
    }

    func descriptor(file: String) -> ModelDescriptor? {
        manifest.models.first { $0.file == file }
    }

    func state(for descriptor: ModelDescriptor) -> ModelState {
        // 随包查找要拆成 name + ext 再试：url(forResource:withExtension: nil)
        // 对带扩展名的资源并不稳定（不同系统版本行为不一致）。
        let ns = descriptor.file as NSString
        let name = ns.deletingPathExtension
        let ext = ns.pathExtension
        if let bundled = Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: descriptor.file, withExtension: nil) {
            return .bundled(bundled)
        }
        guard let dir = try? Self.modelsDirectory() else { return .missing }
        let url = dir.appendingPathComponent(descriptor.file)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size != descriptor.bytes {
            return .sizeMismatch(expected: descriptor.bytes, actual: size)
        }
        return .unverified(url)
    }

    /// 取一个可用的权重路径；不可用时抛**点名到文件**的错误。
    /// 只查大小、不重算 sha（340MB 每次重算会让打开面板都卡住）；
    /// 完整校验走在下载/导入两处，另有 verify() 供"模型"页手动触发。
    func url(for descriptor: ModelDescriptor) throws -> URL {
        switch state(for: descriptor) {
        case .bundled(let url), .unverified(let url), .ready(let url):
            return url
        case .missing:
            throw AIError.modelMissing(descriptor.file)
        case .sizeMismatch(_, let actual):
            throw AIError.modelSizeMismatch(file: descriptor.file, expected: descriptor.bytes, actual: actual)
        }
    }

    // MARK: - 校验

    /// 流式 SHA-256。一次性把 340MB 读进内存会在旧设备上直接被杀。
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func verify(_ descriptor: ModelDescriptor) throws {
        let url = try url(for: descriptor)
        let digest = try Self.sha256(of: url)
        guard digest.caseInsensitiveCompare(descriptor.sha256) == .orderedSame else {
            throw AIError.modelDigestMismatch(file: descriptor.file)
        }
    }

    // MARK: - 导入与下载

    /// 用户从"文件"里选一颗权重：校验后放进模型目录。
    func importWeight(from source: URL, descriptor: ModelDescriptor) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let dir = try Self.modelsDirectory()
        let target = dir.appendingPathComponent(descriptor.file)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
        do {
            try verify(descriptor)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return target
    }

    /// 下载一颗权重。先落临时文件、校验通过才搬进模型目录——
    /// 半个文件比没有文件更坏：它会以"大小对不上"的错误形态出现，
    /// 而用户刚看过进度条走完。
    func download(_ descriptor: ModelDescriptor, useMirror: Bool = false) async throws -> URL {
        guard let remote = descriptor.downloadURL(mirror: useMirror) else {
            throw AIError.badInput("下载地址拼不出来：\(descriptor.source.repo)/\(descriptor.source.path)")
        }
        var request = URLRequest(url: remote)
        request.timeoutInterval = 600
        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw AIError.inference("HTTP \(http.statusCode)（\(remote.host ?? "")）")
        }
        let dir = try Self.modelsDirectory()
        let target = dir.appendingPathComponent(descriptor.file)
        defer { try? FileManager.default.removeItem(at: temp) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: temp.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size == descriptor.bytes else {
            throw AIError.modelSizeMismatch(file: descriptor.file, expected: descriptor.bytes, actual: size)
        }
        let digest = try Self.sha256(of: temp)
        guard digest.caseInsensitiveCompare(descriptor.sha256) == .orderedSame else {
            throw AIError.modelDigestMismatch(file: descriptor.file)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    func remove(_ descriptor: ModelDescriptor) throws {
        guard case .unverified(let url) = state(for: descriptor) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// 已就位的权重总字节数（"模型"页给一个可核对的数字）。
    var installedBytes: Int {
        manifest.models.reduce(0) { sum, descriptor in
            if case .missing = state(for: descriptor) { return sum }
            if case .sizeMismatch = state(for: descriptor) { return sum }
            return sum + descriptor.bytes
        }
    }
}
