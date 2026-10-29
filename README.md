# ImageCake for Apple（macOS + iPadOS）

参照 `D:\IdeaProjects\imagecake`（C++20 / Qt6 / OpenCV 的桌面修图引擎）重写的原生双端版本。
一份 SwiftUI 代码同时出 **macOS App** 与 **iPad App**，AI 走 **ONNX Runtime**（官方 SPM 包，
iOS 15+ / macOS 14+），权重按需下载、缺件点名。

> 立场沿用 imagecake：**全本地、离线可跑、缺件不静默、不拿别的算法冒充 AI**。
> 每个 AI 结果都带 `path` 与 `note`（`[no_model:xxx]` / `[fallback:vision]` / `[closed_eyes]` …），
> UI 原样显示。

---

## 一、这一版做了什么（v0.1）

| 模块 | 状态 | 说明 |
|---|---|---|
| 打开图片 | ✅ | JPEG/PNG/HEIC/TIFF/16bit + **RAW**（Core Image RAW 解码）；EXIF 方向在缩略图阶段转正 |
| 线性工作流 | ✅ | 场景线性 Float RGBA → 显示域 Float → sRGB 8bit；导出可 8bit/16bit |
| 调色 | ✅ | 曝光、色温/色调（线性域）；对比、饱和、色相、四条曲线（显示域，单调三次 Hermite）；三区色轮与八分区 HSL |
| 预设 | ✅ | 键名与 imagecake 预设 JSON 逐字对齐；缺键落出厂、未知键点名、比本程序新则拒收 |
| 人像抠图 | ✅ | MODNet（连续 α，发丝级软边）；缺权重/失败自动回退 **Vision 人像分割** 并点名 |
| 换底色 / 背景虚化 | ✅ | 用连续 α 合成；没有 α 时整段跳过并在底栏/导出报告点名 |
| 智能消除 | ✅ | 画布框选 → LaMa 512 窗口推理 → 羽化合成；补丁以「相对量」缓存，改曝光后仍然有效 |
| AI 面部重绘 | ✅ | GFPGAN 512×512，椭圆羽化贴回；闭眼（眼裂比 <0.10）不修并点名 `[closed_eyes]` |
| AI 超清 | ✅ | Real-ESRGAN x4v3，互不重叠分块 + 每块加一圈上下文；2x 由 4x 面积降采样得到 |
| 导出 | ✅ | PNG-8 / **PNG-16（自家写入器）** / JPEG / HEIF；全分辨率重载 + 32MP 保护；导出报告常驻；iPadOS 可直接存入相册 |
| 模型管理 | ✅ | 清单驱动的下载 / 导入 / SHA-256 校验 / 删除 / 释放会话；字节数与哈希直接展示 |
| 单元测试 | ✅ | 曲线单调性、色彩域、PNG-16 可被 ImageIO 读回、分块覆盖/不重叠、补丁合成、预设契约 |

**v1 明确不做**（与 imagecake 的差距，见 [docs/parity.md](docs/parity.md)）：
液化/美体/五官形变、保护笔刷、仿制图章、证件照与换装、拼图排版、批量与 CLI、
滤镜 `.cube`、XMP 导入、水印边框、ICC/lcms2、联机拍摄。

---

## 二、构建

要求：**macOS 14+**、**Xcode 16+**、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen` ≥ 2.42）。

```bash
# 1) 生成工程（仓库不提交 .xcodeproj）
bash scripts/bootstrap.sh

# 2) 打开、选 Team、运行
open ImageCake.xcodeproj
```

- 首次构建会联网解析 ONNX Runtime 的 SPM 二进制包（`onnxruntime-swift-package-manager`）。
  离线环境可把它换成本地 `binaryTarget`（见 [docs/ai-runtime.md](docs/ai-runtime.md)）。
- macOS 本地跑未签名版本时，`project.yml` 用 ad-hoc 签名（`CODE_SIGN_IDENTITY[sdk=macosx*] = "-"`，不需要 Team）；
  上架前改成自己的 Team。

### iPad 运行（v1 主目标）

| 项 | 现状 |
|---|---|
| 系统要求 | iPadOS 17+（`supportedDestinations: [iOS, macOS]`，`TARGETED_DEVICE_FAMILY = "1,2"`） |
| 模拟器 | 免签名，选 iPad Pro/Air 模拟器直接 Run |
| 真机 | 需在 Signing 里选 Team；免费账号 7 天有效 |
| 导入/导出 | Files 选择器（`fileImporter`/`fileExporter`）；预设默认落在「文件 → 我的 iPad → ImageCake/Presets」 |
| 相册 | ✅ 导出可选「相册」或「两者」（`.addOnly` 写入，不申请读取）；权限被拒会点名 `[photos_denied]` |
| 手势 | 单指拖框选（智能消除）；**v1 无双指缩放/平移**，画布固定等比适配 |
| 分屏 | 面板宽度跟窗口走（46%，最小 280pt）；窄分屏下画布仍保留 |
| 长任务 | 4x 超清/面部重绘是分钟级，**必须保持 App 在前台**（iPadOS 会挂起后台任务，未申请后台执行） |
| 内存档位 | 导出/超清上限按物理内存分档（4/6/8GB → 16/24/32MP 渲染、12/32/60MP 超清），超出点名拒绝 |
| 权重 | App 内「模型 → 下载」或从 Files 导入；GFPGAN 340MB，建议先只装 core 档 |

> 以上是**配置与设计上的结论**。构建侧已在 CI 的 iOS Simulator 目标上验证通过（2026-10-29），
> 但**还没有在任何 iPad 模拟器或真机上启动过 App**。首次运行请先做：
> 打开一张 JPEG → 拖一根滑杆（验证渲染）→ 点「抠图」（验证 Vision 兜底）→ 框选后「消除」（验证 ORT）。

### 权重

权重不进仓库、也不进 App 包（`*.onnx` 已在 `.gitignore`）。两条路任选：

```bash
# A. 脚本下载（core 档：超清 + 关键点 + YuNet，约 10MB）
python3 scripts/fetch_models.py --list          # 只报账
python3 scripts/fetch_models.py --tier core     # 落到 ImageCake/Resources/Models/（随包）
python3 scripts/fetch_models.py --tier all      # 全表约 660MB

# B. App 内：右上「模型」→ 下载（可走 hf-mirror.com）或「导入文件…」
#    下载/导入后做字节数 + SHA-256 双重校验，失败的文件会被删掉。
```

AI 任务与权重的关系：

| 能力 | 权重 | 缺件时 |
|---|---|---|
| 人像抠图 | `portrait_matting_modnet_photographic.onnx`（25.9MB） | **回退 Vision**，`path=vision` |
| 智能消除 | `inpainting_lama_2025jan.onnx`（92.6MB） | 报 `[no_model:…]`，不做假修复 |
| AI 超清 | `superres_esrgan_x4v3.onnx`（4.9MB，core 档） | 报 `[no_model:…]` |
| 面部重绘 | `face_restore_gfpgan_v14.onnx`（340MB，许可见下） | 报 `[no_model:…]` |
| 人脸检测/眼睛开合 | 无（Vision） | — |

> GFPGAN 权重 Apache-2.0，但训练集 FFHQ 是 **CC BY-NC-SA**（非商用）。清单里标 `commercialUse: restricted`，
> 模型面板显示「非商用」徽标。商用前请自行确认许可链。

---

## 三、结构

```
ImageCake/
├─ App/            ImageCakeApp.swift          双端入口（WindowGroup + 平台工具栏）
├─ Domain/         EditParameters.swift        参数/预设模型（键名对齐 imagecake）
│                  ImageDocument.swift         会话状态 + 渲染序（含换底色）
│                  PresetStore.swift           预设读写/版本闸门/未知键报告
│                  ExportPipeline.swift         全分辨率导出链
│                  ModelCatalog.swift           权重清单解码与 IO 规格
├─ Imaging/        ColorMath / CurveMath        sRGB、HSV、色轮、单调曲线
│                  Images.swift                 三层容器（线性/显示/8bit）+ 重采样
│                  ImageLoader.swift            ImageIO + RAW + 写盘
│                  ToneEngine.swift             调色链（线性 → 显示）
│                  PNG16Writer.swift            16bit PNG 容器（zlib stored 块）
├─ AI/             ORTEngine.swift              ORT 会话（actor，Core ML EP 可选）
│                  ModelStore.swift             定位/校验/下载/导入
│                  TensorIO.swift               图像 ↔ NCHW/NHWC 张量
│                  ImageOps.swift               遮罩外接框/膨胀/羽化、分块几何
│                  MattingTask / InpaintTask / SuperResTask / FaceRestoreTask
│                  VisionSupport.swift          Vision 人像分割兜底 + 人脸
├─ UI/             EditorModel.swift            状态机（所有重计算离开主线程）
│                  CanvasView / CurveEditor     画布框选、曲线编辑
│                  TonePanel / AIPanel / ModelsPanel / ExportSheet
└─ Resources/      Models/models.json           权重清单（唯一真相，脚本共用）
```

### 管线顺序（写在一处，别处不许重排）

```
线性域：曝光 → 色温/色调
显示域：对比 → 四条曲线（RGB 复合在前）→ 三区色轮 → 8 分区 HSL + 色相 + 饱和度
AI 资产：人像 α → 换底色/背景虚化；修复补丁（相对量）贴在显示域
导出：全分辨率重载 → 调色 → 补丁 → 换底色 → 面部重绘 → AI 超清(最后) → 尺寸档 → 编码
```

- **AI 预处理吃 sRGB 显示码**，不是线性浮点（模型在 sRGB 码上训练，喂线性等于换分布）。
- **16bit 交付件**不走 ImageIO：`PNG16Writer` 自己写 IHDR/IDAT/IEND，端序与 filter 可读。
- **超清必须最后一步**：修复/液化的坐标活在原图上，先放大再落笔会落到挪了位的图上。

---

## 四、验证到什么程度

| 手段 | 覆盖 |
|---|---|
| 单元测试（28 格） | 曲线单调/恒等/坏输入回退；中性调色只做 sRGB 编码；+1EV 线性翻倍；色相旋转；**三区色轮只碰自己的亮度区、八分区 HSL 的相邻带权重分摊**；RGBA8 往返；**PNG-16 经 ImageIO 读回**；分块覆盖恰好一次、加边不越界；外接框/膨胀/羽化；补丁合成只动遮罩内；补丁随画布缩放；预设往返/未知键/太新拒收/缺键落出厂；清单解码与下载 URL；MODNet 输入尺寸；GFPGAN 方框几何 |
| **真实编译**（2026-10-29） | GitHub Actions 的 macOS runner：`xcodebuild test` 在 macOS 上编过并跑完 **28 格断言全绿**；同一套代码的 iOS Simulator 目标也构建成功（Xcode 16.4 + XcodeGen） |
| 尚未做 | **未在 iPad 模拟器 / 真机上实际运行过**（CI 只做构建，不启动 App）。ORT 权重也没有在真机上跑过推导——CI 不下载 660MB 权重 |

> 首次真实编译暴露并修掉了 4 个问题，全是“没编译过就发现不了”的类型：
> 缺 AppIcon 资产集（actool 直接 BUILD FAILED）、`TEST_HOST` 在 macOS 上解析成测试包
> 自己、`Resampler` 对 `let` 常量就地修改、`withUnsafeMutableBufferPointer` 闭包内
> 重叠访问原数组。另有一条是 ORT 头文件两份之间 nullability 标注不一致，
> 详见 [docs/ai-runtime.md](docs/ai-runtime.md)。

### CI（没有 Mac 时的验证路径）

[.github/workflows/ci.yml](.github/workflows/ci.yml) 有两个 job：

| job | 做什么 | 能抓到什么 |
|---|---|---|
| `macos-test` | 选 Xcode 16 → 装 XcodeGen → 校验模型清单 → 生成工程 → `xcodebuild test` | 全部 28 格断言；App 宿主测试的签名/`TEST_HOST` 问题 |
| `ios-build` | 同一套生成流程 → 只构建 iOS Simulator | UIKit/AppKit 分支、iOS-only SwiftUI API、Info.plist 键 |

推上去后在 Actions 页面看 `macos-test` 的第一个红步：

- 失败在 **Generate project** → XcodeGen 版本或 `project.yml` 字段问题；
- 失败在 **Test on macOS** 的编译阶段 → 先看 `ORTEngine.swift` 的绑定签名（升级 ORT 后最常见）；
- 失败在 **Test on macOS** 的运行阶段 → 把 `macos-test-results` 里的 `.xcresult` 下载打开，断言名会直接指向几何/色彩/容器中的哪一条。

CI 已跑通（首次全绿：run [40809005087](https://github.com/tianjinfemto/imagecake-apple/actions/runs/40809005087)）。
两个 job 并行，一轮约 2 分钟；失败时先看是哪一个 step 变红，再按下表分流。

---

## 五、与 imagecake 的关系

- **理念继承**：单一真相（预设键名、模型清单、管线顺序）、缺件点名、不静默降级、几何与网络分离以便无权重断言。
- **技术不同**：imagecake 是 Qt Widgets + OpenCV + LibRaw；这里是 SwiftUI + Accelerate/手写算子 + Core Image（RAW）+ ORT。
- **未移植的对象模型**：笔迹（液化/保护/图章）、批量队列、导出模板、批量分组、联机拍摄、CLI。

完整的模块级对照见 [docs/parity.md](docs/parity.md)。

---

## 六、许可

- 本项目代码：与 imagecake 保持一致的 GPL 系许可（见 imagecake 仓库 LICENSE；发布前请按你的分发方式确认）。
- 各权重许可见 `ImageCake/Resources/Models/models.json` 的 `license` 字段；其中 GFPGAN 标 `restricted`
  （FFHQ 训练集非商用），FairFace 数据集 CC BY 4.0，ESRGAN BSD-3，LaMa/MODNet/RTMPose Apache-2.0。
