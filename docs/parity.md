# 与 imagecake 的模块对照

状态标记：✅ 已实现并接线 ｜ ⛔ 平台限制或需额外模型权重

**总原则**：能力差距不是"漏了"，是**平台限制或模型缺失**。v1 把"端到端能跑通、失败能点名"的部分全做完。

## 1. 调色与几何

| imagecake 模块 | 本仓状态 | 差异说明 |
|---|---|---|
| 曝光/对比/色温/色调/饱和/色相 | ✅ | 同一套域划分：曝光与白平衡在线性域，其余在显示域 |
| 三区色轮（阴影/中间调/高光） | ✅ | 参数进预设、`ToneEngine` 按亮度权重消费、`ColorGradingPanel` 提供色轮入口；权重和恒为 1，一次只染一片 |
| 八分区 HSL | ✅ | 同上；色相带中心用标准色相角（红0/橙30/黄60/绿120/青180/蓝240/紫285/品红320），与 imagecake 的 CbCr 角序不同、参数序一致。注意环是闭合的：红带与品红带环距仅 40°，同一窗口内会分摊权重（见 `CurveAndToneTests`） |
| 四条曲线（RGB/红/绿/蓝） | ✅ | 单调三次 Hermite（Fritsch–Carlson），屏幕弧线与像素映射同一段插值 |
| 降噪 / 锐化 | ✅ | 双边滤波（保边平滑）+ unsharp mask，作用在调色之后、**液化/图章**与补丁之前（`SpatialFilters`）；4MP 预览约 0.3–0.8 秒，32MP 导出 3–8 秒 |
| 补光 / 高光柔化 | ✅ | 按亮度三区权重抬暗部 / 压高光（`ToneEngine`，在曲线之前）；只动亮度不染色，形式是 `v+k·(1−v)` 与 `v−k·v`，两端自然饱和不会死白/涂灰 |
| 本地调节（椭圆/笔迹） | ✅ | `LocalAdjustmentEngine`：选区支持**三形状**（`LocalMask`：画笔笔迹 / 径向渐变 / 线性渐变），选区内叠一层调色参数（曝光/对比/饱和/色温/色调/锐化），按羽化掩码混合；入口在「风格」面板（径向/线性用画布框选定位，画笔走新增的「选区」工具） |
| 旋转 / 裁剪 / 翻转 | ✅ | `GeometryEngine`：90° 倍数走整像素搬运（不插值），任意角度走双线性反向采样；裁剪复用各容器 `cropped(to:)`。**本轮修掉一个真缺陷**：`geometry` 之前从未被 `ImageDocument.render()` 消费（面板只显示值），现在在渲染链最前作用到线性图上；几何不重映射已有笔迹/AI 资产坐标，所以“先定构图再落笔”写在文档注释里 |
| 透视 / 自动水平 | ⛔ | 透视需额外的消失点检测；自动水平依赖 EXIF 方向（ImageLoader 已处理）+ 地平线检测 |
| 智能构图（auto crop） | ✅ | `SmartCropEngine`：基于人脸关键点（478 点）或人像 α 外接框，按三分法留 margin 建议裁剪框；`GeometryPanel` 一键应用 |

## 2. 人像与 AI

| imagecake 模块 | 本仓状态 | 差异说明 |
|---|---|---|
| 人像分割（MODNet 连续 α） | ✅ | 预处理/后处理口径照实测（sRGB 码、symmetric、长边 512 取 32 倍数、截断取整）；**新增 Vision 兜底** |
| 皮肤掩码（色域 + 约束） | ✅ | `SkinMask`：YCbCr 肤色椭圆 + HSV 双门限，再与人像 α 相与、按人脸框分脸/身。零权重、可断言；已知边界（暖色背景会被误判）写在注释里，没有 α 也没有关键点时点名 `[no_constraint]` |
| 中性灰磨皮 / 局部瑕疵 / 肤色统一 / 油光 / 美白 | ✅ | `BeautyEngine`：磨皮是频率分离（只平滑低频，高频纹理按力度保留）且分平整/立体两模式；局部瑕疵用与邻域低频之差定阈值；后四项在「亮度 + 红绿 + 蓝黄」对立色空间里只做色度收敛，**亮度守恒由构造保证**（有断言）。全部只在皮肤掩码内生效，掩码外逐比特不变 |
| 亮眼 / 牙齿美白 / 唇色 / 腮红 | ✅ | `FaceGeometry`（478 点 → 语义锚点；数量凑不齐直接返回 nil，不拿错索引去推脸）+ `RegionEnhance`（多边形/椭圆栅格 + 对立色修改）；瞳孔不抬、高饱和唇线不当牙齿。**逐张脸都做**（`faceGeometries` 数组，合影里不会只动最大那张） |
| 祛黑眼圈 / 祛法令纹 | ✅ | 同层的两个专项目：`FaceGeometry` 派生下睑椭圆与"鼻翼→嘴角"旋转椭圆带（`RegionRaster.disk(angle:)`），前者只抬亮不压暗、极暗像素不动；后者只填"比低频邻域暗得多的细线"，低频阴影逐比特不变。全部离线可断言（数值由 Python 镜像核对） |
| 妆容模板 | ✅ | `MakeupEngine`：5 个内置模板 = （唇环 · 上睑晕染带 · 眼线带 · 眉线带 · 腮红）×颜色×浓淡。带状区域由 `RegionRaster.band`（法向在**像素度量**里算，否则竖图上带子会斜）与 `upperArc`（上睑连续弧）从 478 点派生；上粉只按 `lumaKeep` 靠亮度，所以唇纹与眉骨阴影不会被关闭。眉毛索引表缺失时**整层不跑**而不是猜个位置 |
| 头发美化 | ✅ | `HairMask`（头部框 ∧ 非皮肤色域 ∧ 额头线以上/脸侧带，有人像 α 时再相与）+ `HairEngine`：去毛躁 = **软阈值**削小振幅拖动（真发丝逐根保留）、光泽 = 高光 roll-off / 按局部亮度差提亮、发色只推色度不动亮度 |
| 手部美化 | ✅ | `VisionSupport.hands`（`VNDetectHumanHandPoseRequest`，零权重、双端自带）→ `HandHull.polygon` 凸包（单调链，输入顺序无关）→ 与皮肤色域相与 → 磨皮（复用 `BeautyEngine.smoothPass`）+ 匀亮度 + 祛红。没检测到时整段不跑并点名 `[no_hand]` |
| 衣物祛褶 | ✅ | `GarmentEngine`：二频段（base = 长边 1.2% 模糊，deep = 再 5%），只把 base 的低频推向 deep，`source − base`（布纹/织纹/印花边缘）逐比特带回。选区存在 `BrushState.garments`（笔迹，不进预设）；未涂时点名 `[no_garment_region]`。换正装仍不做（需服装分割 + 生成式） |
| 换底色 / 去色边 | ✅ | 连续 α 合成；defringe 用邻域实心色替换边缘脏色（`EdgeDefringe`，合成前跑，α 不变）；无实心邻居时保守保留 |
| 背景虚化 | ✅ | 三次盒式模糊近似高斯；半径随长边缩放 |
| 换天空 | ✅ | `SkyMask`：从**画面顶边**4 邻域连通生长（判据 = 蓝青色相或近无彩 + 够亮 + 饱和不超上限），有人像 α 时 α 内不算天 → 不连顶边的同色区（蓝裙/水洼/镜子）不会被换掉；占比 >85% 判为"整面墙"，宁可不跑。合成：渐变天（顶→地平线 smoothstep）或导入天图（`SkyLibrary` + cover-fit）；`lightMatch` 只把非天区的色度往地平线色靠（亮度不变）。没检测到时 `[no_sky_mask]`，天图读不到时 `[no_sky:名字]`，不拿渐变冒充 |
| 虚拟打光（光影重塑） | ✅ | `RelightEngine`：facing = clamp01(⟨d, ∇S⟩ × 画幅)（S = 抹平后的亮度场），**只加不减**、局部平坦区逐比特不动、满力度上限 0.25 亮度；`spread` 连续地偏向暗部（补光↔主光），`warmth` 只给新加的光上色。斜率乘回画幅 → 与分辨率无关（断言：64 档与 256 档峰值得一样）。边界：梯度近似，无深度/法线 |
| 多帧堆栈（AI 慢门） | ✅ | `LongExposureEngine`：384 档亮度上 ±24 窗隔行 SAD 搜整数平移（尺寸不一致直接拒而不重采样），再按平均/取亮/取暗堆叠；同样图片堆一起逐比特相同，报告 `[stack] N 帧 · 位移 · 残差`。单帧图做不出光轨 → 不足 2 帧点名 `[frames_short]` |
| 智能消除（LaMa） | ✅ | 以选区为中心取 512 正方形窗口；大选区自动多窗 tiling（`TileGrid.interiors` 分块，每块各开窗口跑 LaMa，返回多个 `InpaintPatch`） |
| 修补工具 / 祛路人 | ✅ | `PatchEngine`：同图取样修复（固定偏移量搬纹理），与 LaMa 互补——LaMa 是语义修复（造内容），修补是物理搬运（零推理、毫秒级）；`PatchStroke` 存归一化源点+笔迹，进渲染管线与撤销栈 |
| 仿制图章 / 液化 / 保护笔刷 | ✅ | 三个工具从算子到渲染到**画布手势**全链路接通：`BrushState` 存笔迹 → `ImageDocument.render()` 重放 → `CanvasView` 单指拖落笔 → `BrushPanel` 工具选择/参数/取样/清除 |
| 面部重绘（GFPGAN） | ✅ | 512 定宽、1/255、输出自夹取、椭圆羽化、闭眼不改只点名 |
| AI 超清（ESRGAN x4v3） | ✅ | 互不重叠内部块 + 每块加一圈上下文；2x 由 4x 降采样 |
| 面部关键点 478 / 五官形变 | ✅ | `FaceLandmarksTask` 出点 → `FaceGeometry` 派生语义量（虹膜圆心与半径、唇内外环、下颌轮廓、颊部、**下睑椭圆、法令纹带**）→ `ShapeWarp` 驱动位移场（瘦脸/大眼/缩鼻翼/收下颌/微笑唇/下巴）+ `RegionEnhance` 驱动区域美化；结果存 `ImageDocument.faceGeometries`（归一化、**每张脸一项**），预览与导出共用 |
| 美体（RTMPose 17 点） | ✅ | `BodyPoseTask` 出关节点 → `BodyAnchors`（肩/髋/膝/踝 + 躯干轴 + 腰线）→ `ShapeWarp`：细腰/瘦腿/增高/天鹅颈/直角肩。增高用分段纵向拉伸，**锚线以上逐比特不动**（断言钉住） |
| 人脸年龄/性别分组 | ✅ | `FaceAttrTask`：两颗独立网络（FairFace age/gender），每张脸裁切喂入 → argmax → 区间标签；`AIPanel` 一键识别，结果按脸显示 |
| 老照片褪色/划痕 | ✅ | `OldPhotoEngine`：褪色恢复（灰世界白平衡反推偏色）+ 划痕去除（形态学开运算检测细线 + 邻域填充）；零权重、确定性，在调色之前执行；`LinearImage(display:)` 直接 Float 转线性，保留 16bit 精度；`AIPanel` 一键开关 |
| 衣物/证件照换装 | ⛔ | 需服装分割模型（不在 `models.json` 清单里）；模板合成与服装分割都不在 v1 |

## 3. 交付与工作流

| imagecake 模块 | 本仓状态 | 差异说明 |
|---|---|---|
| 预设（JSON，v37） | ✅ | 键名逐字对齐；缺键落出厂；未知键点名；比本程序新拒收；外部资产依赖只登记不加载 |
| 滤镜 / 风格（LUT） | ✅ | `LUTParser` + `CubeLUT`：.cube 读写（**红最快的枚举顺序**、三线性插值、1D 表逐通道）、DOMAIN 不是 0…1 就拒收并点名 `[bad_lut:domain]`；`FilterEngine` 8 个内置确定性风格（采样成 17³ 表）；强度=原像素与查表结果线性混合，0 时逐比特恒等；导入的 .cube 落在 `Documents/ImageCake/LUTs`，找不到时 `[no_lut:名字]` 并跳过该阶段 |
| 镜头校正 / 颗粒 | ✅ | `LensEngine`：畸变（径向映射 `radiusMap`）、色差（逐通道等量反向，三通道乘子之和恒为 3）、暗角（权重 1→1−k）、颗粒（splitmix 风格整数哈希，同坐标同值 → 两次导出可逐比特比对）。位置层在笔刷之前，输出层在最后 |
| 撤销 / 重做 | ✅ | 50 步，一格是 `EditSnapshot`（参数 + 笔迹），`ParameterHistory` 已改为泛型；滑杆拖动 600ms 防抖合并成一步，一笔笔刷立即算一步；!换图清空；amendPresent 只改写栈顶 |
| PNG-8 / JPEG / HEIF | ✅ | ImageIO |
| PNG-16 / TIFF-16 | ✅ | 两个自家容器写入器：PNG-16 用 zlib stored 块；TIFF-16 用 baseline 6.0。都用 ImageIO 读回验证 |
| 色彩空间（ICC / lcms2） | ✅ | `ICCProfile`：输出时嵌 sRGB ICC profile（`CGColorSpace(name: .sRGB)` → `iccData`）；输入 ICC 由 Core Graphics 在解码时转 sRGB |
| 水印 / 边框 / 文字贴纸 | ✅ | `OverlayEngine`：三种元素（水印图/纯色边框/文字），在导出最后一步合成（AI 之后、编码之前）；`OverlayPanel` 提供添加/删除/清除入口 |
| 证件照 | ✅ | `IDPhoto`：8 个规格（mm → 300dpi 像素）、按头部占比与头顶留白建议构图（无头部框时居中并点名 `[no_face_box]`）、5/6 寸与 A4 相纸排版（槽位不重叠、越界槽位丢弃）；排版在导出最后一步生效并写 `[id_photo] N 张` |
| 拼图排版 | ✅ | `CollageEngine`：4 种模板（1×2/2×1/2×2/1×3）+ **三种适配**（等比裁切填满 / 等比留白 / 拉伸），默认填满（把竖图拉成横格比留白更不可接受）。**本轮接上入口**：「工具」面板的拼图卡片 + 导出链把其余图源逐张全分辨率重渲染（不跑重绘/超清）；图不够时不拿主图默默填坑，写 `[collage_short]` / `[collage_failed]` / `[collage_no_template]` 并保留未排版输出 |
| 素材库 / 修图状态 | ✅ | `ImageLibrary` + `ProjectStore`：选目录扫素材（只扫一层、非图跳过、重名图点名 `[sidecar_conflict]`）、按未修/已修/已出片筛选、状态**从文档派生**而不是手点；参数逐张存在图旁边的 `<名字>.imagecake.json` sidecar，打开时自动接回；比本程序新的预设拒收 |
| 直方图 / 溢出诊断 | ✅ | `Histogram`：R/G/B + 亮度四组，**分箱与 `rgba8(dither:false)` 逐比特同口径**（否则"屏幕上没溢出、文件里死了"）；越界像素计入 `outOfRangeCount`，不静默夹走；`ClippingOverlay` 标红/蓝溢出，与预览同次渲染算出；入口在「调色」首栏与画布叠层 |
| 命名模板 / 尺寸档 | ✅ | 尺寸档（长边上限）+ 文件名模板 `{stem}/{date}/{time}/{index}/{ext}`（`ExportNaming`）；非法字符在生成阶段就清掉 |
| 批量队列 | ✅ | `BatchQueue`：串行处理多张图，每张完成后报告进度，失败不中断队列。**本轮接上入口**：「批量」面板 + `SyncGroups`/`ParamSync` 六组同步（调色/美肤/美型/风格/背景/交付端）——像素蛋糕式“一张调好→其余同步”，而手动液化与修复补丁不在 `EditParameters` 里，所以类型上就拿不走 |
| 联机拍摄 | ⚠️ | 部分：`TetherCapture`（AVFoundation 枚举/接入/`capturePhoto` 新式 completionHandler）+ `TetherPlan`（选设备优先级外接>连续互通>内置、连拍队列上限 60 张、文件名 `tether-<时间戳>-<序号>`）。可验证部分全在纯函数里并有断言；相机本体只能真机验。iPad 侧 UVC 需 external-camera entitlement（未签名包拿不到 → `[no_camera]`）；不是厂商联机协议 |
| CLI | ⛔ | iPadOS 无 CLI 等价路径；macOS 可通过 `xcodebuild` 跑测试但无独立 CLI |
| XMP 导入 | ✅ | `XMPImporter`：正则抽 crs: 属性，约 40 键映射到 `EditParameters`（曝光/色温/色调/对比/饱和/HSL/色轮等），未知键跳过并报告 |
| 用量统计 | ⛔ | 本项目没有点数语义，不需要 |

## 4. 工程与验证

| imagecake | 本仓 |
|---|---|
| 1000+ C++ 断言（Catch2 风格自研） | 320 格 XCTest（几何/色彩/色轮与 HSL/色轮坐标/画布视口/空间滤波/补光与高光/文件名模板/去色边/撤销栈与笔迹入栈/笔迹栅格化/液化/仿制图章/保护笔刷/文档级渲染管线与跨分辨率重放/笔刷手势采样/几何变换/老照片修复/修补工具/智能构图/XMP 导入/拼图/ICC/装饰叠加/本地调节与三形状蒙版/容器/预设契约/**皮肤掩码与六个美肤算子**/**关键点派生几何与区域美化**/**位移场与脸型美体预设**/**.cube 全链路 + 内置风格**/**镜头与颗粒确定性**/**证件照规格与排版**/**ParamSync 同步组**/**文档级几何生效与缺件点名**/**逐脸美化与两个专项目**/**直方图与溢出叠层**/**拼图适配与导出接线**/**素材库与 sidecar**/**妆容模板与眉/眼带派生**/**头发、手部、衣物三个新区域算子**/**天空连通生长与合成**/**只加不减且分辨率无关的方向光**/**多帧堆栈对齐与三种堆法**/**联机拍摄的决策层**） |
| 无头 CLI 回归 | 无（iPadOS 无 CLI） |
| 权重清单 + 双校验 | ✅ 同一份 `models.json`，脚本与 App 共用 |
| 缺件点名令牌 | ✅ `[no_model:file]` / `[fallback:vision]` / `[closed_eyes]` / `[too_large]` / `[patch_scaled]` / `[no_mask]` / `[no_face]` / `[no_person]` / `[no_landmarks]` / `[no_pose]` / `[no_constraint]` / `[no_lut:名字]` / `[clipping]` / `[out_of_range]` / `[collage_short]` / `[collage_failed]` / `[collage_no_template]` / `[sidecar_conflict]` / `[no_scope]` / `[no_hand]` / `[no_garment_region]` / `[no_makeup:名字]` / `[no_sky_mask]` / `[no_sky:名字]` / `[fallback:sky-colour-locus]` / `[frames_short]` / `[stack]` / `[no_camera]` / `[camera_timeout]` |
| 三端（Win/Linux/macOS） | 双端（macOS/iPadOS），SwiftUI 单代码库 |
