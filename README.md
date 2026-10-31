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
| 调色 | ✅ | 曝光、色温/色调（线性域）；对比、补光/高光柔化、饱和、色相、四条曲线（显示域，单调三次 Hermite）；三区色轮与八分区 HSL；降噪/锐化（空间滤波） |
| 预设 | ✅ | 键名与 imagecake 预设 JSON 逐字对齐；缺键落出厂、未知键点名、比本程序新则拒收 |
| 撤销 / 重做 | ✅ | 50 步，一格是 `EditSnapshot`（调色参数 **+ 笔迹**）；工具栏按钮 + `⌘Z` / `⇧⌘Z`；滑杆拖动合并成一步，一笔笔刷算一步 |
| 笔刷工具（液化 / 仿制图章 / 保护笔刷） | ✅ | 算子、渲染管线、撤销栈、**画布手势与面板入口**全链路接通：`BrushPanel` 选工具/调参数，`CanvasView` 单指拖落笔（液化 from→to、保护/图章采样笔迹），图章先取样再绘制；一笔 = 一步历史 |
| 人像抠图 | ✅ | MODNet（连续 α，发丝级软边）；缺权重/失败自动回退 **Vision 人像分割** 并点名 |
| 换底色 / 背景虚化 | ✅ | 用连续 α 合成；边缘去色溢出（defringe）用邻域实心色替换脏边；没有 α 时整段跳过并在底栏/导出报告点名 |
| 智能消除 | ✅ | 画布框选 → LaMa 512 窗口推理 → 羽化合成；补丁以「相对量」缓存，改曝光后仍然有效 |
| AI 面部重绘 | ✅ | GFPGAN 512×512，椭圆羽化贴回；闭眼（眼裂比 <0.10）不修并点名 `[closed_eyes]` |
| AI 超清 | ✅ | Real-ESRGAN x4v3，互不重叠分块 + 每块加一圈上下文；2x 由 4x 面积降采样得到 |
| 导出 | ✅ | PNG-8 / **PNG-16（自家写入器）** / **TIFF-16（自家写入器）** / JPEG / HEIF；全分辨率重载 + 32MP 保护；文件名模板（`{stem}/{date}/{time}/{index}/{ext}`）；导出报告常驻；iPadOS 可直接存入相册 |
| 模型管理 | ✅ | 清单驱动的下载 / 导入 / SHA-256 校验 / 删除 / 释放会话；字节数与哈希直接展示 |
| 单元测试 | ✅ | 曲线单调性、色彩域、PNG-16 可被 ImageIO 读回、分块覆盖/不重叠、补丁合成、预设契约、**文档级渲染管线（笔刷接线 + 跨分辨率重放）** |

| 人像精修（皮肤） | ✅ | `SkinMask`（色域 ∧ 人像 α ∧ 人脸框三层约束）+ `BeautyEngine`：**中性灰磨皮（频率分离，平整/立体两模式）**、疤痕类瑕疵清理、肤色统一、红血丝收敛、油光压制、美白；脸/身各独立力度。掩码外逐比特不变 |
| 五官区域美化 | ✅ | `FaceGeometry`（MediaPipe 478 点 → 语义锚点）+ `RegionEnhance`：亮眼（不抬瞳孔）、牙齿美白（去黄 + 饱和门控）、唇色（唇环）、腮红，**外加两个专项目：祛黑眼圈（只抬不压）、祛法令纹（只填细暗线、不动低频阴影）**。没关键点就整段跳过并点名 `[no_landmarks]` |
| 逐脸美化（合影） | ✅ | `ImageDocument.faceGeometries` 是**数组**：预设形变逐脸累加进同一张位移场、区域美化逐脸取大合并掩码、皮肤按 N 个脸框分脸/身——不再"一家四口只磨小孩的脸" |
| 五官/身体预设形变 | ✅ | `WarpField`（与手动液化同一套“先累加场、只重采样一次”底座）+ `ShapeWarp`：瘦脸/大眼/缩鼻翼/收下颌/微笑唇/下巴；细腰/瘦腿/增高（以臀部水平线为锚的分段拉伸）/天鹅颈/直角肩 |
| 滤镜与风格 | ✅ | `LUTParser`/`CubeLUT`（.cube 读写 + 三线性插值 + 1D 逐通道）+ 8 个内置确定性风格 + 强度混合；`.cube` 导入落在 `Documents/ImageCake/LUTs`，找不到时点名 `[no_lut:名字]` |
| 镜头与画质层 | ✅ | `LensEngine`：畸变（径向映射）、色差（逐通道等量反向）、暗角、颗粒（同坐标同值的确定性哈希，两次导出可逐比特比对） |
| 局部蒙版 | ✅ | `LocalMask` 三形状：画笔 / 径向渐变 / 线性渐变（前两个用画布框选定位，画笔走新增的「选区」工具） |
| 证件照 | ✅ | `IDPhoto`：8 个规格（小一寸→美签）、mm→px、按头部占比建议构图、5/6 寸与 A4 相纸排版（导出最后一步生效） |
| 拼图排版 | ✅ | `CollageEngine` 接上入口：「工具」面板 4 模板 / 3 底色 / 填满或留白两种适配；导出时其余图源逐张全分辨率重渲染，图不够写 `[collage_short]` 且不默默重复主图 |
| 素材库（项目视图） | ✅ | 工具栏「图库」：选目录 → 缩略图网格 → 未修/已修/已出片筛选 → 点开即编；参数逐张存在图旁边的 `<名字>.imagecake.json`，下次进来自动接回 |
| 直方图与溢出警告 | ✅ | `Histogram`（R/G/B + 亮度，分箱与 8bit 编码逐比特同口径）+ 画布溢出高亮叠层（红=高光死/蓝=暗部死）+ 底栏 `[clipping]` 警告 |
| 批量与参数同步 | ✅ | `SyncGroups` + `ParamSync`（六组：调色/美肤/美型/风格/背景/交付端）+ 「批量」面板接上 `BatchQueue`。手动液化与修复补丁不在参数里，所以**类型上就拿不走** |
| 几何 | ✅ | 本轮修掉一个真缺陷：`geometry` 之前**从未被 `render()` 消费**（面板只是把值显示出来）。现在旋转/翻转/裁剪在渲染链最前作用到线性图，并有逐比特断言 |

**与商业产品像素蛋糕的完整差距清单**（含已补与仍未补，分成入口/算法/权重/平台四类）：
[docs/pixcake-parity.md](docs/pixcake-parity.md)。本轮已清零"入口缺口"（哑资产不再）。
仍未做的主要是：主题妆容模板、换装/衣物祛褶、换天空、AI 打光/慢门、逐脸不同力度、
联机拍摄、云端协作与在线选片（这三项与"全本地、无服务"的立场冲突，**明确不做**）。

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
| 手势 | 单指拖框选（智能消除）；**双指捏合缩放（1–8×，以捏合点为锚）+ 双指拖平移**；双击复位 |
| 分屏 | 面板宽度跟窗口走（46%，最小 280pt）；窄分屏下画布仍保留 |
| 长任务 | 4x 超清/面部重绘是分钟级，**必须保持 App 在前台**（iPadOS 会挂起后台任务，未申请后台执行） |
| 内存档位 | 导出/超清上限按物理内存分档（4/6/8GB → 16/24/32MP 渲染、12/32/60MP 超清），超出点名拒绝 |
| 权重 | App 内「模型 → 下载」或从 Files 导入；GFPGAN 340MB，建议先只装 core 档 |

> 以上是**配置与设计上的结论**。构建侧已在 CI 的 iOS Simulator 目标上验证通过（2026-10-29），
> 从本轮起宿主 App 会在 iPhone 模拟器里被真正拉起并跑完 121 格（见 §四 CI）——
> 但这仍然不是 iPad：分屏尺寸、Apple Pencil、相册权限弹窗、手感都模拟不了。
> 真机调测按 [docs/device-check.md](docs/device-check.md) 走：那里按「冒烟 → 新功能 → 回归」分层，
> 每条都写了预期与失败时该看哪一层，并标出了两处“看着像 bug 其实是设计”的地方。

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
│                  BeautyParameters.swift      人像/滤镜/镜头三组参数（本仓扩展键）
│                  ImageDocument.swift         会话状态 + 渲染序（含皮肤、美型、证件照）
│                  PresetStore.swift           预设读写/版本闸门/未知键报告
│                  ParamSync.swift             批量同步的六个参数组（哪些能同步）
│                  BatchQueue.swift            串行批量队列（已接「批量」面板）
│                  IDPhoto.swift               证件照规格/构图/相纸排版
│                  ExportPipeline.swift         全分辨率导出链
│                  ModelCatalog.swift           权重清单解码与 IO 规格
├─ Imaging/        ColorMath / CurveMath        sRGB、HSV、色轮、单调曲线
│                  Images.swift                 三层容器（线性/显示/8bit）+ 重采样
│                  ImageLoader.swift            ImageIO + RAW + 写盘
│                  ToneEngine.swift             调色链（线性 → 显示）
│                  SkinMask.swift               皮肤三层掩码（色域 ∧ α ∧ 人脸框）
│                  BeautyEngine.swift           磨皮/瑕疵清理/匀肤色/油光/美白（频率分离 + 对立色）
│                  FaceGeometry.swift           478 点 → 语义锚点 + 多边形/椭圆栅格
│                  RegionEnhance.swift          亮眼/牙齿/唇色/腮红 + 祛黑眼圈/祛法令纹（逐脸）
│                  Histogram.swift              直方图与溢出叠层（分箱=8bit 编码口径）
│                  WarpField.swift              位移场底座（液化与预设形变共用）
│                  ShapeWarp.swift              脸型/身体预设形变 + BodyAnchors
│                  CubeLUT.swift                .cube 解析/三线性/内置风格/LUT 目录
│                  CollageEngine.swift          拼图模板/三种适配/多图源排版
│                  LensEngine.swift             畸变/色差/暗角/颗粒
│                  StrokeRasterizer.swift       笔迹栅格化（液化/图章/保护笔刷共同底座）
│                  ImageSampling.swift          双线性采样（液化与图章共用）
│                  LiquifyEngine / CloneStampEngine  笔刷算子，都接受 protection 掩码
│                  PNG16Writer.swift            16bit PNG 容器（zlib stored 块）
├─ AI/             ORTEngine.swift              ORT 会话（actor，Core ML EP 可选）
│                  ModelStore.swift             定位/校验/下载/导入
│                  TensorIO.swift               图像 ↔ NCHW/NHWC 张量
│                  ImageOps.swift               遮罩外接框/膨胀/羽化、分块几何
│                  MattingTask / InpaintTask / SuperResTask / FaceRestoreTask
│                  FaceLandmarksTask / BodyPoseTask / FaceAttrTask  关键点与属性（驱动美型）
│                  VisionSupport.swift          Vision 人像分割回退 + 人脸
├─ UI/             EditorModel.swift            状态机（所有重计算离开主线程）
│                  CanvasView / CurveEditor     画布框选、曲线编辑、溢出高亮叠层
│                  TonePanel（含 HistogramView）/ BeautyPanel / AIPanel / StylePanel
│                  ToolsPanel（笔刷+几何+装饰+拼图）/ BatchPanel / LibraryPanel
│                  ModelsPanel / ExportSheet
└─ Resources/      Models/models.json           权重清单（唯一真相，脚本共用）
```

### 管线顺序（写在一处，别处不许重排）

```
几何（旋转/翻转/裁剪，最先：它改画布）→ [老照片] → 线性域：曝光 → 色温/色调
显示域：对比 → 补光/高光柔化 → 四条曲线（RGB 复合在前）→ 三区色轮 → 8 分区 HSL + 色相 + 饱和度
人像：皮肤掩码（在滤镜之前判色）→ 滤镜/LUT → 镜头畸变与色差 → 降噪 → 锐化
　　　→ 美肤（磨皮/瑕疵/匀肤色/红血丝/油光/美白）→ 区域美化（眼/牙/唇/腮 + 黑眼圈/法令纹，逐脸）
　　　→ 美型预设形变 → 手动液化 → 仿制图章 → 修补 → 修复补丁 → 换底色 → 暗角与颗粒
导出：全分辨率重载 → 同上整条链 → 面部重绘 → AI 超清 → 证件照排版 → 拼图排版 → 装饰叠加 → 尺寸档 → 编码
```

新增项的位置不是随手插的，每条都有理由（写在 `ImageDocument.render` 的注释里）：
皮肤掩码在滤镜**之前**判，因为风格会把整个色相分布推走；畸变/色差在笔刷**之前**，
因为它们也改像素位置；暗角与颗粒在**最后**，因为超清与重绘会把颗粒当细节放大。

- **AI 预处理吃 sRGB 显示码**，不是线性浮点（模型在 sRGB 码上训练，喂线性等于换分布）。
- **16bit 交付件**不走 ImageIO：`PNG16Writer` 自己写 IHDR/IDAT/IEND，端序与 filter 可读。
- **超清必须最后一步**：修复/液化的坐标活在原图上，先放大再落笔会落到挪了位的图上。

---

## 四、验证到什么程度

| 手段 | 覆盖 |
|---|---|
| 单元测试（244 格） | 曲线单调/恒等/坏输入回退；中性调色只做 sRGB 编码；+1EV 线性翻倍；色相旋转；**三区色轮只碰自己的亮度区、八分区 HSL 的相邻带权重分摊**；**色轮坐标几何**；**画布视口几何**；**降噪降方差且保边、锐化产生 overshoot 且不越界**；**补光只抬暗部、高光柔化只压高光**；**文件名模板**；**去色边**；**撤销栈**；**笔迹栅格化/液化/图章/保护笔刷**；**文档级渲染（笔刷接线 + 跳分辨率重放）**；RGBA8 往返；**PNG-16 与 TIFF-16 经 ImageIO 读回**；分块/外接框/羽化/补丁合成；预设往返/未知键/太新拒收/缺键落出厂；**皮肤色域与三层约束**；**磨皮降噪声方差但保纹理、掩码外逐比特不变**；**对立色往返恒等、匀肤色不改亮度、油光只压亮斑**；**478 点派生语义量**；**多边形/椭圆栅格**；**位移场单位换算与锚线守恒**；**增高时头与躯干逐比特不动**；**.cube 枚举顺序/三线性/1D 逐通道/坏表点名/序列化往返**；**内置风格确定性与抬黑**；**径向映射单调、颗粒可重复**；**证件照 mm→px/槽位不重叠/排版落点**；**ParamSync 只搬所选组**；**局部蒙版三形状**；**文档级：几何真生效、缺资产整段跳过并点名**；**逐脸美化：第二张脸真的动、只给一张脸时另一张逐比特不变**；**两个专项目：黑眼圈只抬不压、法令纹只填细暗线不碰低频阴影**；**直方图分箱与 8bit 编码同口径（含越界值）**；**旋转椭圆栅格逐字数值**；**拼图三种适配与满铺不露底色**；**sidecar 命名/重名冲突/坏文件与未来版本拒收**；**素材库状态派生与筛选** |
| **真实编译**（2026-10-30） | GitHub Actions macOS runner：`xcodebuild test` 在 macOS 上跑完 **113 格全绿**；同一批断言在 **iPhone 16 Pro 模拟器**上也跑完 **113 格 / 0 failed / 0 skipped**（宿主 App 被真实拉起），Xcode 16.4 + XcodeGen |
| **这两轮的编译与回归** | 已跑五轮 macOS + iOS 模拟器双端全量：从"测试目标编不过"（Float/Double 混算、不存在的 `^+` 中缀、`Bool |=`、缺 `Identifiable`）一路修到 **231 格中 229 格绿**（仓内共 244 个测试函数，macOS 那一轮汇总执行 231 格）；同时抓出两个"参数在、区域在、就是静默没反应"的真缺陷（关键点多边形未乘画布尺寸→唇色/牙齿永远是空掩码；`touched || applyFaceEdits(...)` 短路→逐脸美化实际只做了第一张脸）。最后两处修正 **尚未被 CI 验到**：之后的 run 在分配 runner 前就失败（零步骤），check-run 注释是账户额度/付款问题（macOS 分钟 5× 计入，本轮跑得太密），恢复后 `scripts/ci-rerun.ps1 <runId>` 或重推即可 |
| 尚未做 | **未在真机上跑过**（模拟器不是 iPad：触摸压感、Apple Pencil、真 GPU 路径、系统权限弹窗都模拟不了）。ORT 权重也没有在真机上跑过推导——CI 不下载 660MB 权重 |

> 真实编译累计暴露并修掉了 5 个问题，全是“没编译过就发现不了”的类型：
> 缺 AppIcon 资产集（actool 直接 BUILD FAILED）、`TEST_HOST` 在 macOS 上解析成测试包
> 自己、`Resampler` 对 `let` 常量就地修改、`withUnsafeMutableBufferPointer` 闭包内
> 重叠访问原数组，以及泛型化 `ParameterHistory` 后的 `static let`（Swift 不允许
> 泛型类型有存储型静态成员，只能把常量搬到类型外面）。另有一条是 ORT 头文件
> 两份之间 nullability 标注不一致，
> 详见 [docs/ai-runtime.md](docs/ai-runtime.md)。

### CI（没有 Mac 时的验证路径）

[.github/workflows/ci.yml](.github/workflows/ci.yml) 有三个 job：

| job | 做什么 | 能抓到什么 |
|---|---|---|
| `macos-test` | 选 Xcode 16 → 装 XcodeGen → 校验模型清单 → 生成工程 → `xcodebuild test` | 全部 244 格断言；App 宿主测试的签名/`TEST_HOST` 问题 |
| `ios-build` | 同一套生成流程 → 构建 iOS Simulator → 再把 244 格在模拟器上跑一遍 | UIKit/AppKit 分支、iOS-only SwiftUI API、Info.plist 键，以及 **`#if os(iOS)` 里那些 macOS 一行都执行不到的代码**（`PhotoLibraryWriter` / 相册写回）和 App 在 iOS 运行时上能否被拉起 |
| `ios-unsigned-ipa` | Release 构建设备真机包 → 打成未签名 ipa | 只在推 main 或手动触发时跑；侧载人群用（见 [docs/device-check.md](docs/device-check.md) §1.5） |

> 设备名不写死：runner 镜像里的模拟器随 Xcode 版本变，写死 `iPhone 15` 这种名字
> 一旦不存在就会红成"Unable to find a device"，看起来像代码问题。`ios-build` 从
> `xcrun simctl list -j` 挑一台现成 iPhone，挑不到就直接失败并把可用设备打出来。

推上去后看第一个红步：

- 失败在 **Generate project** → XcodeGen 版本或 `project.yml` 字段问题；
- 失败在 **Test on macOS / Test on iOS Simulator** 的编译阶段 → 先看 `ORTEngine.swift` 的绑定签名（升级 ORT 后最常见）；
- 只在 **Test on iOS Simulator** 红、macOS 绿 → 问题在 `#if os(iOS)` 分支或 iOS 运行时（宿主 App 拉起、权限、主线程），不是算法；
- 失败在运行阶段 → 把 `macos-test-results` / `ios-test-results` 里的 `.xcresult` 下载打开，断言名会直接指向几何/色彩/容器中的哪一条。

CI 已跑通（首次全绿：run [40809005087](https://github.com/tianjinfemto/imagecake-apple/actions/runs/40809005087)）。
`macos-test` 与 `ios-build` 并行，加了模拟器测试后一轮约 5 分钟（冷启动模拟器占大头）；
失败时先看是哪一个 step 变红，再按上表分流。

---

## 五、与 imagecake 的关系

- **理念继承**：单一真相（预设键名、模型清单、管线顺序）、缺件点名、不静默降级、几何与网络分离以便无权重断言。
- **技术不同**：imagecake 是 Qt Widgets + OpenCV + LibRaw；这里是 SwiftUI + Accelerate/手写算子 + Core Image（RAW）+ ORT。
- **未移植的对象模型**：工程文件（持久化整组片子与逐张状态）、CLI、联机拍摄。
  笔迹与批量队列已经接通（笔迹到画布手势，批量到「批量」面板）；
  `CollageEngine`（拼图）仍只有算子没有入口，列在 [docs/pixcake-parity.md](docs/pixcake-parity.md)。

完整的模块级对照见 [docs/parity.md](docs/parity.md)；与商业产品像素蛋糕的差距见
[docs/pixcake-parity.md](docs/pixcake-parity.md)。

---

## 六、许可

- 本项目代码：与 imagecake 保持一致的 GPL 系许可（见 imagecake 仓库 LICENSE；发布前请按你的分发方式确认）。
- 各权重许可见 `ImageCake/Resources/Models/models.json` 的 `license` 字段；其中 GFPGAN 标 `restricted`
  （FFHQ 训练集非商用），FairFace 数据集 CC BY 4.0，ESRGAN BSD-3，LaMa/MODNet/RTMPose Apache-2.0。
