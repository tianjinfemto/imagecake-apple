import Foundation

// 模型清单的唯一真相（Resources/Models/models.json）。
//
// 为什么清单在资源里而不是写死在 Swift：同一份文件有两个消费者——App 决定
// "去哪找、怎么校验、怎么喂"，scripts/fetch_models.py 决定"去哪下"。写两处
// 的下场是"文件明明在，它说没有"（imagecake 在 asset_catalog 上踩过）。
//
// IO 规格里全部字段都是**提示**：真正的输入/输出名字以 ORT 会话枚举为准，
// 提示只用来在模型换了导出方式时少改一行代码。缺省值按 imagecake 实测口径填
// （NCHW、RGB、unit），不确定的地方显式留在 JSON 里而不是藏在代码里。

enum ModelTier: String, Codable, Sendable {
    case core
    case onDemand
}

enum TensorLayout: String, Codable, Sendable {
    case nchw
    case nhwc
}

enum ColorOrder: String, Codable, Sendable {
    case rgb
    case bgr
}

enum ValueRange: String, Codable, Sendable {
    /// [0,1]：网络自己在外面吃过 1/255（LaMa / ESRGAN / GFPGAN 实测口径）。
    case unit
    /// (x-127.5)/127.5：MODNet 的上游 inference_onnx.py 口径。
    case symmetric
    /// (x/255 - mean)/std，mean/std 由 io.mean/io.std 给。
    case meanStd = "mean_std"
}

struct ModelIO: Codable, Sendable {
    var inputName: String?
    var maskInputName: String?
    var outputName: String?
    var layout: TensorLayout?
    var colorOrder: ColorOrder?
    var valueRange: ValueRange?
    var mean: [Float]?
    var std: [Float]?
    /// 网络只吃固定边长（LaMa/GFPGAN 实测 512）。
    var fixedSize: Int?
    /// 动态尺寸时的长边上限（MODNet 512）。
    var longEdge: Int?
    /// 输入边长必须是这个数的倍数（MODNet 取 32；LaMa 取 8）。
    var multipleOf: Int?
    var tile: Int?
    var overlap: Int?
    var nativeScale: Int?
    var maskFill: String?

    var resolvedLayout: TensorLayout { layout ?? .nchw }
    var resolvedColorOrder: ColorOrder { colorOrder ?? .rgb }
    var resolvedValueRange: ValueRange { valueRange ?? .unit }
}

struct ModelSource: Codable, Sendable {
    var repo: String
    var path: String
}

struct ModelDescriptor: Codable, Identifiable, Sendable {
    var id: String
    var file: String
    var bytes: Int
    var sha256: String
    var license: String
    var commercialUse: String
    var tier: ModelTier
    var purpose: String
    var source: ModelSource
    var io: ModelIO?

    var ioSpec: ModelIO { io ?? ModelIO() }

    /// 下载地址。上游是 HuggingFace 的 resolve 端点；镜像同路径换域名即可。
    /// 不把 URL 写进 JSON：仓库路径才是真相，域名是可替换的传输细节。
    func downloadURL(mirror: Bool) -> URL? {
        let host = mirror ? "https://hf-mirror.com" : "https://huggingface.co"
        let escaped = source.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.path
        return URL(string: "\(host)/\(source.repo)/resolve/main/\(escaped)?download=true")
    }
}

struct ModelManifest: Codable, Sendable {
    var schema: Int
    var defaultTier: ModelTier
    var models: [ModelDescriptor]

    enum CodingKeys: String, CodingKey {
        case schema
        case defaultTier = "default_tier"
        case models
    }
}

enum ModelCatalog {
    /// 清单读不出就是装配错误（不是运行期可选资产）：返回空数组会把
    /// "清单坏了"伪装成"还没有模型"，而后者用户会去重下。
    static func load(from bundle: Bundle = .main) -> Result<ModelManifest, ModelCatalogError> {
        guard let url = bundle.url(forResource: "models", withExtension: "json") else {
            return .failure(.missingManifest)
        }
        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
            guard manifest.schema == 1 else { return .failure(.unsupportedSchema(manifest.schema)) }
            return .success(manifest)
        } catch {
            return .failure(.decode(error.localizedDescription))
        }
    }
}

enum ModelCatalogError: LocalizedError, Equatable {
    case missingManifest
    case unsupportedSchema(Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "[no_manifest] 资源里找不到 models.json"
        case .unsupportedSchema(let v):
            return "[schema:\(v)] 模型清单版本不认识（本程序只认 1）"
        case .decode(let message):
            return "[manifest_decode] \(message)"
        }
    }
}
