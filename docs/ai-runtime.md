# AI 运行时：ONNX Runtime on Apple

## 1. 依赖

`project.yml`：

```yaml
packages:
  onnxruntime:
    url: https://github.com/microsoft/onnxruntime-swift-package-manager
    from: "1.16.0"
```

- 该包声明 `platforms: [.iOS(.v15), .macOS(.v14)]`，产品名 `onnxruntime`（静态库 + Objective-C 绑定），
  Swift 里 `import OnnxRuntimeBindings`。
- `from: "1.16.0"` 会解析到该仓库可用的最新 tag。首次解析要联网（下载 pod 归档 zip）。
- **离线环境**：把包 clone 到本地，在 `project.yml` 改成
  `packages: onnxruntime: { path: Vendor/onnxruntime-swift-package-manager }`，
  并把 `Package.swift` 里的 `binaryTarget` 指向本地 `pod-archive-onnxruntime-c-*.zip`。

### 这份代码用到的 ORT API（版本敏感处）

| 调用 | 说明 |
|---|---|
| `ORTEnv(loggingLevel:)` | 环境 |
| `ORTSessionOptions()` + `appendCoreMLExecutionProvider(with:)` | Core ML EP，失败即静默回 CPU（性能档，不是正确性档） |
| `ORTSession(env:modelPath:sessionOptions:)` | 会话 |
| `session.inputNames()` / `outputNames()` | 只用名字，不猜形状 |
| `ORTValue(tensorData:elementType:shape:)` | 输入张量（float32，little-endian） |
| `session.run(withInputs:outputNames:runOptions:)` | 前向 |
| `value.tensorData()` | 输出字节（float32） |
| `value.typeInfo()?.tensorTypeAndShapeInfo?.shape` | 输出形状。**`ORTValue` 没有 `tensorShape()`**，写成那样是编译期失败（2026-10-27 已按官方 `ort_value.h` 修正） |

> 若升级 ORT 后这些签名有变，改动只集中在 `ImageCake/AI/ORTEngine.swift` 一个文件；
> 其余任务代码只依赖 `TensorValue`（shape + Data）。

## 2. 模型 IO 规格

清单 `ImageCake/Resources/Models/models.json` 的 `io` 字段是**提示**，不是硬编码：
真正的输入名以 ORT 会话枚举为准（`io.inputName` 命中才用，否则取第一个）。

| 模型 | 布局 | 色彩序 | 值域 | 尺寸 | 后处理 |
|---|---|---|---|---|---|
| MODNet | NCHW | RGB | symmetric `(x-127.5)/127.5` | 长边 ≤512，两边取 32 倍数 | α ×255 **截断**取整 → 缩回原尺寸 |
| LaMa | NCHW | RGB | unit `/255` | 固定 512×512；mask 为 `[1,1,512,512]` {0,1} | 夹到 [0,1] → ×255 → 羽化合成 |
| ESRGAN x4v3 | NCHW | RGB | unit | 动态；tile 256 + 每边 16 上下文 | 输出尺寸 = 输入 ×4；2x 由 4x 降采样 |
| GFPGAN v1.4 | NCHW | BGR | unit | 固定 512 | 输出未夹取，**必须自夹到 [0,1]** |

三条与 imagecake 实测对齐的硬事实：

1. **域**：喂 sRGB 显示码，不喂线性浮点（模型在 sRGB 码上训练）。
2. **布局**：NCHW/NHWC 错布局不报错、只给脏结果——所以布局是清单里的显式参数。
3. **值域**：`unit` 与 `symmetric` 混用在 MODNet 上可让个别像素 α 反向（imagecake 量到 |Δα|≈1）。

## 3. 兜底与降级（全部点名）

| 情况 | 行为 | UI/报告 |
|---|---|---|
| MODNet 缺件 / 前向失败 | Vision 人像分割接手 | `path=vision`，note 带原始原因 + `[fallback:vision]` |
| Vision 也失败 | 不出罩 | `[no_person]`，面板提示重试 |
| LaMa 缺件 | 不修复 | `[no_model:inpainting_lama_2025jan.onnx]` |
| LaMa 选区超出单窗（>480px） | 不做部分修复 | `[region_too_large]`，请分次框选 |
| LaMa 只有一个输入（image+mask 拼 4 通道） | 拒收，不猜通道 | `[no_mask_input]` 语义的 badShape 文案 |
| 超清缺件 / 输出 >60MP | 不输出 | `[no_model:…]` / `[too_large]` |
| GFPGAN 缺件 | 不重绘 | `[no_model:…]` |
| 全部脸闭眼 | 不重绘 | `[closed_eyes]`，原图交回 |
| 一张图里部分脸闭眼 | 其余照做 | `[closed_eyes:N]` |
| 导出时补丁参考分辨率不同 | 缩放补丁 | `[patch_scaled]`（v1 不重跑网络） |
| 换底色但没有 α | 跳过该段 | `[no_mask]` |

## 4. 内存闸门

| 位置 | 上限 | 原因 |
|---|---|---|
| 预览档 | 长边 2048 | 12MP 的 float RGBA 是 192MB；2048 档约 48MB |
| 导出渲染 | 16 / 24 / 32MP | 按物理内存分档（4 / 6 / 8GB）；50MP 的 float RGBA 约 800MB |
| PNG-16 导出 | 12 / 20 / 24MP | 不压缩 + 双份缓冲，再大就是被系统杀掉而不是报错 |
| 超清输出 | 12 / 32 / 60MP | 同样按内存分档；4GB 的 iPad 在 4x 上最容易 OOM |
| LaMa 窗口 | 512×512 | 权重定尺寸；大选区 v1 不做多窗 |
| Core ML EP | 尽力启用 | 动态 shape/不支持算子时自动回 CPU |

## 5. 加一颗新模型

只改 JSON，不改代码（前提是任务的预处理/后处理已有）：

```json
{
  "id": "my_model",
  "file": "my_model.onnx",
  "bytes": 123,
  "sha256": "…",
  "license": "Apache-2.0",
  "commercialUse": "allowed",
  "tier": "onDemand",
  "purpose": "一句话用途",
  "source": { "repo": "org/repo", "path": "onnx/model.onnx" },
  "io": { "layout": "nchw", "colorOrder": "rgb", "valueRange": "unit",
          "fixedSize": 512, "tile": 256, "overlap": 16, "nativeScale": 4 }
}
```

下载脚本与 App 会同时读到它；模型面板出现新行，`--list` 也会多一行。
若要新任务（例如 RTMPose 解码），新增一个 `XxxTask.run(display:store:ort:)`，
把报告字段按 `AIReport` 的形状交回即可。

## 6. 首次构建最可能卡住的两处

1. **XcodeGen 版本**：`supportedDestinations`（单 target 双端）需要 ≥ 2.42。
   `xcodegen version` 低于这个数时，改成两个 target（iOS/macOS）共享 `sources`。
2. **SwiftUI 平台差异**：iOS-only 的修饰符（`navigationBarTitleDisplayMode`、`help`）已经
   收进 `View` 扩展里的空操作包装；如果仍报错，按报错行换回 `#if` 包完整表达式。

ORT 绑定这一层已经按官方头文件逐条核准过：`init(tensorData:elementType:shape:)`、
`run(withInputs:outputNames:runOptions:)`、`appendCoreMLExecutionProvider(with:)`、
`typeInfo()?.tensorTypeAndShapeInfo?.shape`。升级 ORT 后若再有变化，只改 `ORTEngine.swift`。
