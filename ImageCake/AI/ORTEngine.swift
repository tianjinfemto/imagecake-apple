import Foundation

#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

// ONNX Runtime 的薄封装。
//
// 为什么用官方 Objective-C 绑定而不是自写 C++ 桥：绑定包（onnxruntime-swift-
// package-manager）自带 iOS/macOS 的二进制与头文件，SPM 一句依赖就能双端
// 编译；自写 ObjC++ 需要额外维护桥接头与静态库搜索路径，收益只有"少一个
// 依赖"，不值。
//
// 会话放在 actor 里：ORT 的 session 不是线程安全的（同 imagecake 那把
// 引擎级锁的立场），而预览与导出会并发要同一颗权重。actor 的粒度是
// "一次前向"，导出等一个窗口，换的是不会两张 92MB 模型互踩。
//
// 没有 ORT 时整个类型退化成"只会报 [no_ort]"的桩：编译能过、UI 能开、
// 面板把话说清楚。不让"依赖没装"变成"工程打不开"。

actor ORTEngine {
    static let shared = ORTEngine()

    /// 编译期是否有绑定。UI 用它决定“ONNX Runtime 不可用”要不要出现在面板上。
    nonisolated static var isSupported: Bool {
        #if canImport(OnnxRuntimeBindings)
        return true
        #else
        return false
        #endif
    }

    #if canImport(OnnxRuntimeBindings)
    private var sessions: [String: ORTSessionBox] = [:]
    private var signatureCache: [String: ModelSignature] = [:]

    var isAvailable: Bool { true }
    #else
    var isAvailable: Bool { false }
    #endif

    /// 载入（或复用）一颗权重的会话。Core ML EP 在 iOS 上给 ANE/GPU，
    /// macOS 上给 GPU；拿不到就安静回退 CPU——这是性能档，不是正确性档。
    func prepare(modelID: String, path: URL, preferCoreML: Bool = true) throws -> ModelSignature {
        #if canImport(OnnxRuntimeBindings)
        if let signature = signatureCache[modelID] { return signature }
        let box = try sessionBox(modelID: modelID, path: path, preferCoreML: preferCoreML)
        let inputs = try box.session.inputNames().sorted()
        let outputs = try box.session.outputNames().sorted()
        let signature = ModelSignature(inputNames: inputs, outputNames: outputs)
        signatureCache[modelID] = signature
        return signature
        #else
        throw AIError.backendUnavailable
        #endif
    }

    /// 一次前向。inputs 的键用清单里的提示名；找不到就用会话的第一个输入
    /// （顺序由 ORT 给定，稳定）。输出同理。
    func run(modelID: String, path: URL, inputs: [String: TensorValue],
             preferredOutput: String? = nil) throws -> TensorValue {
        #if canImport(OnnxRuntimeBindings)
        let signature = try prepare(modelID: modelID, path: path)
        let box = try sessionBox(modelID: modelID, path: path, preferCoreML: true)

        var orInputs: [String: ORTValue] = [:]
        for (name, tensor) in inputs {
            let data = NSMutableData(data: tensor.data)
            let shape = tensor.shape.map { NSNumber(value: $0) }
            orInputs[name] = try ORTValue(tensorData: data, elementType: .float, shape: shape)
        }
        guard !orInputs.isEmpty else { throw AIError.badInput("没有给任何输入张量") }

        let outputName = preferredOutput.flatMap { signature.outputNames.contains($0) ? $0 : nil }
            ?? signature.outputNames.first
        guard let outputName else { throw AIError.badShape("这颗模型没有输出") }

        let outputs = try box.session.run(withInputs: orInputs,
                                          outputNames: Set([outputName]),
                                          runOptions: nil)
        guard let value = outputs[outputName] else {
            throw AIError.inference("前向返回里没有 \(outputName)")
        }
        let data = try value.tensorData() as Data
        // 形状不在 ORTValue 上：官方头文件里只有 typeInfoWithError: →
        // ORTValueTypeInfo.tensorTypeAndShapeInfo.shape。写 value.tensorShape()
        // 是编译期直接失败（曾经就是这么写的）。
        guard let typeInfo = try value.typeInfo(),
              let tensorInfo = typeInfo.tensorTypeAndShapeInfo else {
            throw AIError.badShape("输出不是张量：\(outputName)")
        }
        let shape = tensorInfo.shape.map { $0.intValue }
        return TensorValue(shape: shape, data: data)
        #else
        throw AIError.backendUnavailable
        #endif
    }

    /// 丢掉某颗（或全部）会话。切换执行后端、或"模型"页手动释放内存时用。
    func unload(modelID: String? = nil) {
        #if canImport(OnnxRuntimeBindings)
        if let modelID {
            sessions[modelID] = nil
            signatureCache[modelID] = nil
        } else {
            sessions.removeAll()
            signatureCache.removeAll()
        }
        #endif
    }

    #if canImport(OnnxRuntimeBindings)
    private final class ORTSessionBox {
        let env: ORTEnv
        let session: ORTSession

        init(env: ORTEnv, session: ORTSession) {
            self.env = env
            self.session = session
        }
    }

    private func sessionBox(modelID: String, path: URL, preferCoreML: Bool) throws -> ORTSessionBox {
        if let box = sessions[modelID] { return box }
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        if preferCoreML {
            // 失败不是错误：部分模型（动态 shape / 不支持的算子）Core ML EP
            // 会拒绝建图，此时留在 CPU 上仍然正确，只是慢。
            let coreML = ORTCoreMLExecutionProviderOptions()
            try? options.appendCoreMLExecutionProvider(with: coreML)
        }
        let session = try ORTSession(env: env, modelPath: path.path, sessionOptions: options)
        let box = ORTSessionBox(env: env, session: session)
        sessions[modelID] = box
        return box
    }
    #endif
}
