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
| 妆容模板 | ✅ | `MakeupEngine`：5 个内置模板 = 唇环 + 上睑晕染带 + 眼线带 + 眉线带 + 腮红的**区域×颜色×浓淡**组合（带状区域由 `RegionRaster.band`/`upperArc` 从 478 点派生）。亮度只按 `lumaKeep` 靠一部分，唇纹与眉骨阴影不会被关闭 |
| 头发 / 手部 / 衣物 | ✅ | 头发：头部框 ∧ 非皮肤色域 ∧ 额头线以上/脸侧带 → 软阈值去毛躁（真发丝逐根保留）+ 高光 roll-off + 发色。手部：**Vision 手部姿态（零权重）**取关节点 → 凸包 → 与皮肤色域相与 → 磨皮/匀亮度/祛红。衣物：二频段祛褶，布纹逐比特不动（选区要涂） |
| 渲染耗时诊断 | ✅ | `RenderPerf` 把渲染链拆成 27 个可命名阶段（几何/调色/追色/掩码/区域/妆容/发/形变/涂抹族/背景/天空/打光/输出层），预览侧再补直方图与两个叠层与 `toCGImage`；导出另加 5 段（含 `faceRestore`/`superRes` 两个 async AI 段）。工具栏「诊断」卡可开底栏常显，导出报告带 `[perf]` 行。**不变量：被中性闸门跳过的阶段不出现在列表里**，所以"改一个滑杆只重算受影响阶段"第一次能被断言 |
| 追色（样片对齐） | ✅ | `ColorTransfer`：在既有对立色空间 L/A/B 上做一阶/二阶统计量对齐（`(x−本图均值)·(参考std/本图std)+参考均值`）再按强度混合；参考图只取统计，不合成也不对齐所以不重采样。三条防炸各有断言：std 下限锁增益 1（纯色墙不会被追成斑块）、增益夹 0.55…1.8、恒等轴逐比特不动。皮肤保护按色域只减色度位移。缺参考图点名 `[no_colorref:名]`，开图时按名字自动回捞 |
| 逐脸力度（合影） | ✅ | `face_strength.scales`：下标 = 面积序的第几张脸，0…200%，100 = 跟随全局。位移场逐脸换一份 scaled 参数、区域美化逐脸缩放权重（等价：位移都是 `amount × weight` 的线性函数）。只作用于靠关键点的那两组；换图/重测后自动取消选中 |
| 镜片反光去除 | ✅ | 镜片区以**虹膜半径**为尺度外推；只压「比邻域低频亮出 0.06 且低饱和且够亮」那一段，只降不升且压不成洞，不编造反光底下的颜色 |
| 换发色 / 祛碎发 | ✅ | 换发色在发区内只推 A/B、亮度逐比特不动（单轴夹 0.22，6 个预设色不给自由拾色）；祛碎发用三角窗环带只动掩码边缘那一圈，发团内部与背景逐比特不变 |
| 颈纹 / 妊娠纹 | ✅ | 复用法令纹同一个 `thinDarkLinePass`（只填比低频邻域暗得多的细线），选区由用户涂；没涂点名 `[no_line_region]`。**不做自动检出**：区分纹与结构阴影的信息图里没有 |
| 换天空 | ✅ | `SkyMask` 从**画面顶边**做连通生长（不连顶边的蓝裙/水洼/镜子不会被换掉）+ 渐变天或导入天图（cover-fit）+ 可选光照匹配（只改色度不改亮度）。没检测/读不到天图就整段不跑并点名 |
| 虚拟打光 / 多帧慢门 | ✅ | 打光：`RelightEngine` 只加不减、局部平坦区逐比特不动、满力度上限 0.25、**斜率乘画幅 → 与分辨率无关**。慢门：`LongExposureEngine` 整数平移对齐 + 平均/取亮/取暗三堆法（单张图做不出光轨，不足 2 帧点名 `[frames_short]`） |
| 联机拍摄（部分） | ⚠️ | 工具栏「联机」：AVFoundation 枚举系统视频设备（macOS 上的 USB 相机/采集卡）→ 接上 → 拍 1~N 张 → 落盘 `tether-<时间戳>-<序号>` 并直接进编辑器。不是厂商联机协议；iPad 侧 UVC 需 entitlement（未签名包拿不到 → `[no_camera]`） |
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
| 重复帧去重 | ✅ | `FrameHash`：9×8 **盒平均**亮度网格的 dHash（64 位）+ 汉明距离 + 并查集分组。入口在素材库「扫重复帧」（每张只解 256px）。阈值 8 是实测的（机震 1~3px 距离 0、曝光微调 4；换构图 19、另一张片子 30），**明知会漏判高 ISO 噪点（11）、反差 +10%（12）、人动 30px（10）并把这些写进断言**：漏判只是多修一张，误判会让人只修代表张而丢片子。平场不参与分组（两张纯色图哈希完全相同），平场口径复用 `FrameTriage.flatLimit` 不另定一个。组内按文件名序给代表，意思是“这组修一张就够”，不是“这张最好看”——后者要美学权重 |
| XMP 导入 | ✅ | `XMPImporter` 把 Adobe 的 crs: 属性（约 40 键）映到 `EditParameters`。本轮**接上入口**：工具栏「预设」菜单的「读图旁边的 .xmp」（Lightroom 旁挂约定）与「从 .xmp 导入…」。四条失败路径各自点名：`[no_xmp_source]` / `[no_xmp_sidecar]` / `[xmp_unreadable]` / `[xmp_no_mapping]`（认出的键没改动任何参数时不能说“已导入”）。同时补上以前根本没接的高光半边（`SplitToningHighlight*` → `whl*`，三个 case 存在但无键返回它们） |

**与商业产品像素蛋糕的完整差距清单**（含已补与仍未补，分成入口/算法/权重/平台四类）：
[docs/pixcake-parity.md](docs/pixcake-parity.md)。入口缺口已清零（哑资产不再）——
本轮审计只掘到一处：`XMPImporter` 有引擎、有断言、`EditorModel.importXMP()` 也在，
但没有任何面板调它；**已接进工具栏「预设」菜单**（见上表）。
原本标为"需权重/平台限制"的六项（妆容、头发、手部、换天空、打光/慢门、联机）
都做了**诚实的确定性或系统 API 版本**，能力边界写在各自行与文档里。
真正仍不做的：换正装（生成式）、发丝级/膜级分割精度、镜面反射与阴影一致、
在线选片与云端协作（后者与"全本地、无服务"立场冲突）。
**逐脸不同力度已经做了**（`face_strength.scales`，见上表），不在不做之列。

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
│                  MakeupEngine.swift           妆容模板（唇环/上睑带/眼线带/眉线带 × 颜色）
│                  HairEngine.swift             发区几何 + 去毛躁/光泽/发色
│                  HandEngine.swift             手凸包 + 磨皮/匀亮度/祛红
│                  GarmentEngine.swift          衣物祛褶（二频段，保布纹）
│                  SkyEngine.swift              顶边连通长天区 + 渐变/天图合成 + 光照匹配
│                  RelightEngine.swift          只加不减的方向光（分辨率无关）
│                  LongExposureEngine.swift     多帧堆栈（平移对齐 + 平均/取亮/取暗）
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
│                  ToolsPanel（笔刷+几何+装饰+拼图）/ MakeupPanel / BatchPanel / LibraryPanel
│                  StylePanel（含 ScenePanel：换天空/打光/堆栈）/ TetherPanel（联机）
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
| 单元测试（**397** 格，工作树。口径：一格 = 一个 `func test…()`，全仓唯一计数处，`wiring_check.py` 会拿它与工作树对账，并且会报“锚不见了”（Markdown 的 `**` 曾把正则静默打死过，文档落后 12 格而检查器报 0 findings）；上一个已验 tip 是 `1b5b405` 的 387 格，本批形状档的 12 格已跑绿，新的 10 格归重复帧） | 曲线单调/恒等/坏输入回退；中性调色只做 sRGB 编码；+1EV 线性翻倍；色相旋转；**三区色轮只碰自己的亮度区、八分区 HSL 的相邻带权重分摊**；**色轮坐标几何**；**画布视口几何**；**降噪降方差且保边、锐化产生 overshoot 且不越界**；**补光只抬暗部、高光柔化只压高光**；**文件名模板**；**去色边**；**撤销栈**；**笔迹栅格化/液化/图章/保护笔刷**；**文档级渲染（笔刷接线 + 跳分辨率重放）**；RGBA8 往返；**PNG-16 与 TIFF-16 经 ImageIO 读回**；分块/外接框/羽化/补丁合成；预设往返/未知键/太新拒收/缺键落出厂；**皮肤色域与三层约束**；**磨皮降噪声方差但保纹理、掩码外逐比特不变**；**对立色往返恒等、匀肤色不改亮度、油光只压亮斑**；**478 点派生语义量**；**多边形/椭圆栅格**；**位移场单位换算与锚线守恒**；**增高时头与躯干逐比特不动**；**.cube 枚举顺序/三线性/1D 逐通道/坏表点名/序列化往返**；**内置风格确定性与抬黑**；**径向映射单调、颗粒可重复**；**证件照 mm→px/槽位不重叠/排版落点**；**ParamSync 只搬所选组**；**局部蒙版三形状**；**文档级：几何真生效、缺资产整段跳过并点名**；**逐脸美化：第二张脸真的动、只给一张脸时另一张逐比特不变**；**两个专项目：黑眼圈只抬不压、法令纹只填细暗线不碰低频阴影**；**直方图分箱与 8bit 编码同口径（含越界值）**；**旋转椭圆栅格逐字数值**；**拼图三种适配与满铺不露底色**；**sidecar 命名/重名冲突/坏文件与未来版本拒收**；**素材库状态派生与筛选**；**妆容模板（含眉带位置与“上粉不盖住唇纹”）**；**头发/手部/衣物三块的频段断言（软阈值保发丝、凸包与色域相与、二频段保布纹）**；**天空：不连顶边的同色区不换、整幅蓝判为墙、光照匹配不改动亮度**；**打光：只加不减、局部平坦区逐比特不动、两个分辨率力度一致**；**堆栈：同图恒等、找回平移、三种堆法**；**联机决策：选设备优先与回落点名、连拍上限、命名不撞名**；**并串逐比特对照（`PixelParallel.forcedBands`）与好片初筛、背景灰点检出**；**影调形状匹配：第二档把第一档补不了的差距钉成数（单峰→双峰 64 分箱距离 2.0000，只跑均值/反差仍是 2.0000，跑形状档 0.0600）、保序/连续/越界不外插/纯色跳过与强度 0 逐比特、`shape_match` 预设往返**；**重复帧：同一帧与机震 ≤ 8 位、换构图/另一张片子 > 8 位、平场不并（不靠平场门时它们会被距离 0 并到一起，所以这条在测门而不是测空集）、图太小无指纹要数进报告、分组确定性与并查集传递性（A~B=5、B~C=5、A~C=10 仍归一组）** |
| **首次真实编译**（2026-10-30） | GitHub Actions macOS runner：`xcodebuild test` 在 macOS 上跑完 **113 格全绿**；同一批断言在 **iPhone 16 Pro 模拟器**上也跑完 **113 格 / 0 failed / 0 skipped**（宿主 App 被真实拉起），Xcode 16.4 + XcodeGen |
| 镜像预验证（无本地工具链时的主力） | 本机没有 Swift 工具链（`swift`/`swiftc`/`xcodebuild` 均不存在），数值断言**先逐行镜像到 Python 跑出实际数值再回填**。本批靠它提前抓到天空饱和上限那条（镜像算出测试用的晴天天蓝 s=0.70 会被 0.55 拒掉），省下一轮只有 CI 能发现的红；但它**发现不了 UInt8 溢出 trap 与量纲混用**——那两类只有真编译器/真运行时会报，两边都要做 |
| **上一批（逐脸/专项/直方图/拼图/素材库）的编译与回归** | 已跑五轮 macOS + iOS 模拟器双端全量：从"测试目标编不过"（Float/Double 混算、不存在的 `^+` 中缀、`Bool |=`、缺 `Identifiable`）一路修到 **231 格中 229 格绿**；同时抓出两个"参数在、区域在、就是静默没反应"的真缺陷（关键点多边形未乘画布尺寸→唇色/牙齿永远拿到空遮罩；`touched || applyFaceEdits(...)` 短路→逐脸美化实际只做了第一张脸）。最后两处修正连同本批代码已在下面那轮一起跑绿 |
| **本批（妆容/头发/手部/衣物/天空/打光/慢门/联机）：已编译并全绿**（2026-11-01，`39d7f07`） | macOS + iPad 模拟器 + 未签名 ipa 三个 job 全绿，**331 格 / 0 failures**。这轮一共 8 次提交、每轮都是真编译/真跑测：编译错 5 类（数组括号错位、`pipelineWarnings` 里用裸参数名、`lockForConfiguration(nil)` 多传实参、guard 的 else 里再套 guard 会 fall-through、`.buttonStyle(cond ? .bordered : .borderedProminent)` 两个具体样式类型无法归一）。**真缺陷 5 个**：① `RegionRaster.subtract` 的 **UInt8 减法溢出 trap**（Signal 5，唇色一开就崩）；② 天空饱和上限 0.55 把真实蓝天判成"非天"；③ `SkyParameters.isNeutral` 漏了 `lightMatch`→"只借光不借天"整组被当关；④ 连拍队列拿已夹到 1…60 的值比上限→请求 999 张变成静默拍 60 张；⑤ AVFoundation 快门回调写成 `capture(...)` 只得警告不报错→接得上但永远等不到回片 |
| **P0 全批（追色 / 逐脸力度 / 镜片反光 / 换发色 / 祛碎发 / 颈纹）：已全绿**（2026-11-01，`fc95670`） | 三轮共新增 46 格断言，全部关系型/恒等型（追色：更接近参考、强度 0/30/100 单调、关亮度轴后每像素亮度不动但色度必须动、纯色追完仍纯色、增益两端夹住、报告点名被夹的轴；逐脸力度：**第 N 张设成 0 必须逐比特等于根本没有第 N 张脸**；镜片反光：只降不升且不压成洞、饱和色与暗像素不动；换发色保亮度；祛碎发只动环带；颈纹只填细暗线不碰宽暗斑）。本轮真正抓到的缺陷：镜片区原本拿眼圈外接框当尺度基准，眼环含下睑点时框撑到额头和嘴（改成锚虹膜半径）；测试夹具自己越界写数组把宿主跑崩（`Index out of range`，无可读失败信息）；两条断言拿平坦夹具期待像素必变、一条拿自己当基准 |
| **P1-① 第 1 步（可测指标）：已全绿** | `RenderPerfTests` 11 格：插桩**不许改变任何一个像素**（同一文档开/关计时逐比特等值）；中性文档下 12 个被闸门挡住的阶段必须不在列表里；开关组合下 13 个阶段必须在；阶段名唯一（否则 `milliseconds(for:)` 变成含糊求和）；顺序承诺（几何最先、打光→暗角在末段）；async 段能计时；导出报告带 `[perf]` 行 |
| 尚未做 | **未在真机上跑过**（模拟器不是 iPad：触摸压感、Apple Pencil、真 GPU 路径、系统权限弹窗都模拟不了；联机拍摄与手部检测**只能真机验**，CI 无相机、合成图喂不出 Vision 手部姿态）。ORT 权重也没有在真机上跑过推导——CI 不下载 660MB 权重 |

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
| `macos-test` | 选 Xcode 16 → 装 XcodeGen → 校验模型清单 → 生成工程 → `xcodebuild test` | 当前工作树的全部 **397** 格断言（上一个已验 tip `1b5b405` / run 41755637211 是 387 格 / 0 failures；本批 +10 格归重复帧去重）；App 宿主测试的签名/`TEST_HOST` 问题 |
| `ios-build` | 同一套生成流程 → 构建 iOS Simulator → 再把同一批断言在模拟器上跑一遍 | UIKit/AppKit 分支、iOS-only SwiftUI API、Info.plist 键，以及 **`#if os(iOS)` 里那些 macOS 一行都执行不到的代码**（`PhotoLibraryWriter` / 相册写回）和 App 在 iOS 运行时上能否被拉起 |
| `ios-unsigned-ipa` | Release 构建设备真机包 → 打成未签名 ipa | 只在推 main 或手动触发时跑；侧载人群用（见 [docs/device-check.md](docs/device-check.md) §1.5） |

> 设备名不写死：runner 镜像里的模拟器随 Xcode 版本变，写死 `iPhone 15` 这种名字
> 一旦不存在就会红成"Unable to find a device"，看起来像代码问题。`ios-build` 从
> `xcrun simctl list -j` 挑一台现成 iPhone，挑不到就直接失败并把可用设备打出来。

推上去后看第一个红步：

- 失败在 **Generate project** → XcodeGen 版本或 `project.yml` 字段问题；
- 失败在 **Test on macOS / Test on iOS Simulator** 的编译阶段 → 先看 `ORTEngine.swift` 的绑定签名（升级 ORT 后最常见）；
- 只在 **Test on iOS Simulator** 红、macOS 绿 → 问题在 `#if os(iOS)` 分支或 iOS 运行时（宿主 App 拉起、权限、主线程），不是算法；
- 失败在运行阶段 → 把 `macos-test-results` / `ios-test-results` 里的 `.xcresult` 下载打开，断言名会直接指向几何/色彩/容器中的哪一条。

CI 已跑通（首次全绿：run [40809005087](https://github.com/tianjinfemto/imagecake-apple/actions/runs/40809005087)；
本批妆容/场景六项首次全绿：run [41272846815](https://github.com/tianjinfemto/imagecake-apple/actions/runs/41272846815)，`39d7f07`，331 格 / 0 failures）。
已验的 tip（`1b5b405`，run 41755637211，四个 job 都绿）CI **387 格 / 0 failures**（macOS 与 iPad 模拟器都是，`Executed 387 tests` 取自日志）。1024² Release 一次全效果渲染：`b17962c`（run 41611231947）**min-of-7 1894.8ms**（跑内最慢/最快 1.09×），`e281889` 这一轮又是 **min 2117.4ms**（跑内 1.32×）—— 这两次之间热段生产代码没动（只改了 XMP 入口、测试与文档），所以这 11% 又是一次抽样而不是加速。第三个样本 `1b5b405`（run 41755637211）又是 **min 2562.5ms**（跑内 1.22×）—— 同一份热段代码三个数 1894.8 / 2117.4 / 2562.5，**跨 35%**。原语表里仍是 `skinApply 303.8ms`（0.29 µs/px）最贵，bbox 那条依据的同尺寸读数是 `raster 1.42ms vs 全幅 blurred 93.48ms（比值 66）`。**不要把任何一对读数写成倍数**：与 `81bf22c` 那回的 2425.0ms 差约 22%，而跨 run 抖动实测 34%（生产代码完全相同的两次跑量到 2425.0 与 1592.8ms），所以**任何倍数只能当数量级参考**，`f256e43` 基线得出的那个 1.7× 同样只算数量级 —— 要判 5~15% 这一档的优化，得靠自建/本机 runner 或真机「工具 → 诊断」的 `[RELEASE]` 读数，明细与测量口径见 `docs/pixcake-parity.md` §7。
实际落地的并行有三处：**模糊核**（缓冲复用 + 按行/按列分带）、**双边降噪/高斯锐化**，以及 `ab82107` 把剩下六个逐像素热段（衣物祛褶 / 上粉 / 区域与细线 / 头发 / 手 / 皮肤掩码）改成分带。把 `BeautyEngine` 三个 pass 也分带的那一步（`6e9b38b`）**已撤掉** —— 结果与串行逐比特相同，但整机 2367.6ms → 2411.7ms，落在共享 runner 的抖动里，量不出收益就不留在代码里。要说清一件事：撤那一步的同一批改动里，撑住上面六个引擎的并串对照用例也被一并删掉了，而它们仍接在 `PixelParallel` 上 —— 本轮把 `ParallelVsSerialParityTests` 的 10 个用例恢复回来（已在 `b17962c` 跑绿，372 格；`e281889` 是 375 格、`1b5b405` 是 387 格），否则仓里就是“文件头声称覆盖 = 已并行的内核，而六个已并行的内核无覆盖”这个自相矛盾。这六段到底快没快，得用新尺子（同一次跑内 7 次取 min + 拿未改动的段当内部对照）量了才能写数；量不出就同样按先例回退。
`macos-test` 与 `ios-build` 并行，加了模拟器测试后一轮约 5 分钟（冷启动模拟器占大头）；
失败时先看是哪一个 step 变红，再按上表分流。

本地没有 Mac 时，修红靠这四个脚本（都在 `scripts/`，纯 ASCII 以避开 PowerShell 5.1 的编码坑）：

| 脚本 | 用途 |
|---|---|
| `ci-status.ps1` | 列最近几次 run 的 sha / 状态 / 结论 |
| `ci-wait.ps1 <分钟>` | 轮询最新 run 直到结束，按 job 打印结论 |
| `ci-errors.ps1 [runId]` | **直接拉日志抽 `error:` 与失败用例**（日志 zip 里的目录名带 `·`，手拼路径很容易错，所以固化成脚本） |
| `ci-rerun.ps1 <runId>` | 只重跑失败的 job（`rerun-failed-jobs`），不重新推一个 commit 浪费 macOS 分钟 |

> `steps=0` 且 1–2 秒就判失败 → 不是代码，先查 `check-runs/{id}/annotations`。
> 本项目实际踩过：原文是 `The job was not started because recent account payments
> have failed or your spending limit needs to be increased`。
> 计费口径（已核 GitHub 官方文档）：仓库是 private 时，标准托管 runner 走套餐额度，
> macOS 按 **10×** 折算 —— Free 计划 2,000 分钟/月只等于 200 分钟 macOS 机时，
> 一轮全量回归约 10 分钟，所以每月只够约 20 轮；超出部分 $0.062/分钟。
> **同一批标准 runner 在 public 仓库是免费的** —— 这是本项目最直接的解法。

### 推 CI 之前先跑本地那一套（不花分钟）

额度两次把开发卡住之后，把“能本地判定的错”就地判掉成了必需：

```bash
python3 scripts/preflight.py            # 五项全跑，退出码 = 失败的检查数
python3 scripts/preflight.py lex cjk    # 只跑需要的
```

| 脚本 | 能拦住什么（都是真烧过 CI 轮次的形态） |
|---|---|
| `swift_lex_check.py` | 分隔符不配对与字符串/注释**未终止**（奇数个引号那类）。处理了 Swift 特有的嵌套块注释、`\(...)` 插值（代码回到字符串里）、`"""` 与 `#"..."#`。**能力边界**（本轮实测得出）：字面量里嵌一对引号、中间夹中文（`"...要求「低一点」..."` 写成了 `"...要求"低一点"..."`）在它眼里引号是配对的，所以**不报** —— 它抓的是未闭合，不是"字符串被提前结束后又开启"。那类错要靠编译器（类型/语法层），或把断言写成"字符串后紧跟 CJK 即报警"的启发式（待做）。**自带 `--self-test`**：10 个“合法但刁钻”的样本零误报，7 个已知错误形态全部抓住。 |
| `wiring_check.py` | 参数字段 ↔ `CodingKeys`/decode/encode/clamp/`knownKeys` 五处对齐；`isNeutral` 分组在 `render()` 里没消费者；`Imaging` 里有 `apply()` 但全仓无调用点（哑资产）；`requires` 前缀写了但同步规则不留；文档里写了代码已不再发出的令牌。后一条当场抓到一处真问题：文档里写着一个代码实际从不发出的令牌（正确的那个是 `[no_mask]`），已改。 |
| `cjk_check.py` | 编辑通道把单个汉字换成形近字（褶→裁/要、撒→鞰、颊→膣、锚→锦/锤、绝→绘/绍）与非 UTF-8 文件；`--expect <文件> <词...>` 用于改完立即回读断言。**统计式“稀用字”探测已删**：实测 142 个文件报 244 条，几乎全是正常中文（重启/面颊/创建），分不清噪声的检查不如没有。 |
| `preflight.py` | 上面三项 + `fetch_models.py --list` + PowerShell 解析（`syntax-check.ps1`）的一个入口。 |

> **这些检查不能证明什么（写在这里，不让“本地绿”被误读成“已验证”）**：它不
> 编译 —— 类型、协议一致性、参数标签、运行时 trap（比如那个 UInt8 减法）仍需要
> macOS runner；它不跑测试；它也支撑不了任何性能主张（计时必须是 Release）。
> 子进程输出用字节取回再兜底解码：这台机器上子工具按控制台代码页（GBK）输出
> 中文，`text=True` + UTF-8 会静默拿到空串，把“没输出”当成“通过”。

---

## 五、与 imagecake 的关系

- **理念继承**：单一真相（预设键名、模型清单、管线顺序）、缺件点名、不静默降级、几何与网络分离以便无权重断言。
- **技术不同**：imagecake 是 Qt Widgets + OpenCV + LibRaw；这里是 SwiftUI + 手写分带并行（`PixelParallel`，无 vImage/Accelerate/MPS）+ Core Image（RAW）+ ORT。
- **仍未移植的对象模型**：**工程文件**（持久化整组片子与逐张状态）与 **CLI**。逐张状态已经用图旁边的
  `<名字>.imagecake.json` sidecar 替代（不新建文件类型），但目录授权是会话级的，所以每次要重选目录。
- **本仓已有、旧仓没有的**：笔刷到画布手势的全链路、批量同步与队列、拼图排版、素材库、
  直方图与溢出叠层、证件照规格与相纸排版、逐脸美化与逐脸力度、妆容/头发/手部/衣物/天空/打光/堆栈、
  联机拍摄（AVFoundation 部分）、XMP 导入门面（**引擎与断言在，UI 入口未接**，见 device-check §6.2）。

完整的模块级对照见 [docs/parity.md](docs/parity.md)；与商业产品像素蛋糕的差距见
[docs/pixcake-parity.md](docs/pixcake-parity.md)。

---

## 六、许可

- 本项目代码：与 imagecake 保持一致的 GPL 系许可（见 imagecake 仓库 LICENSE；发布前请按你的分发方式确认）。
- 各权重许可见 `ImageCake/Resources/Models/models.json` 的 `license` 字段；其中 GFPGAN 标 `restricted`
  （FFHQ 训练集非商用），FairFace 数据集 CC BY 4.0，ESRGAN BSD-3，LaMa/MODNet/RTMPose Apache-2.0。
