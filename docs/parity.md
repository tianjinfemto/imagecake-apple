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
| 本地调节（椭圆/笔迹） | ✅ | `LocalAdjustmentEngine`：选区掩码复用笔迹底座（`BrushStroke`），选区内叠一层调色参数（曝光/对比/饱和/色温/色调/锐化），按羽化掩码混合；`LocalAdjustmentPanel` 提供入口 |
| 旋转 / 裁剪 / 翻转 | ✅ | `GeometryEngine`：90° 倍数走整像素搬运（不插值），任意角度走双线性反向采样；裁剪复用各容器 `cropped(to:)`；`GeometryPanel` 提供左转/右转/水平翻转/垂直翻转/裁剪入口 |
| 透视 / 自动水平 | ⛔ | 透视需额外的消失点检测；自动水平依赖 EXIF 方向（ImageLoader 已处理）+ 地平线检测 |
| 智能构图（auto crop） | ✅ | `SmartCropEngine`：基于人脸关键点（478 点）或人像 α 外接框，按三分法留 margin 建议裁剪框；`GeometryPanel` 一键应用 |

## 2. 人像与 AI

| imagecake 模块 | 本仓状态 | 差异说明 |
|---|---|---|
| 人像分割（MODNet 连续 α） | ✅ | 预处理/后处理口径照实测（sRGB 码、symmetric、长边 512 取 32 倍数、截断取整）；**新增 Vision 兜底** |
| 换底色 / 去色边 | ✅ | 连续 α 合成；defringe 用邻域实心色替换边缘脏色（`EdgeDefringe`，合成前跑，α 不变）；无实心邻居时保守保留 |
| 背景虚化 | ✅ | 三次盒式模糊近似高斯；半径随长边缩放 |
| 智能消除（LaMa） | ✅ | 以选区为中心取 512 正方形窗口；大选区不做多窗 tiling（v1 已知降级） |
| 修补工具 / 祛路人 | ✅ | `PatchEngine`：同图取样修复（固定偏移量搬纹理），与 LaMa 互补——LaMa 是语义修复（造内容），修补是物理搬运（零推理、毫秒级）；`PatchStroke` 存归一化源点+笔迹，进渲染管线与撤销栈 |
| 仿制图章 / 液化 / 保护笔刷 | ✅ | 三个工具从算子到渲染到**画布手势**全链路接通：`BrushState` 存笔迹 → `ImageDocument.render()` 重放 → `CanvasView` 单指拖落笔 → `BrushPanel` 工具选择/参数/取样/清除 |
| 面部重绘（GFPGAN） | ✅ | 512 定宽、1/255、输出自夹取、椭圆羽化、闭眼不改只点名 |
| AI 超清（ESRGAN x4v3） | ✅ | 互不重叠内部块 + 每块加一圈上下文；2x 由 4x 降采样 |
| 面部关键点 478 / 五官形变 | ✅ | `FaceLandmarksTask`：Vision 检测人脸框 → 478 点网络推理 → 归一化坐标输出；`AIPanel` 一键检测，结果存 `EditorModel2.faceLandmarksResult` 供五官形变液化消费 |
| 美体（RTMPose 17 点） | ✅ | `BodyPoseTask`：需先抠图获取人像 α → 外接框内跑 RTMPose-m → 17 关节点（COCO 格式）；`AIPanel` 一键检测 |
| 人脸年龄/性别分组 | ✅ | `FaceAttrTask`：两颗独立网络（FairFace age/gender），每张脸裁切喂入 → argmax → 区间标签；`AIPanel` 一键识别，结果按脸显示 |
| 老照片褪色/划痕 | ✅ | `OldPhotoEngine`：褪色恢复（灰世界白平衡反推偏色）+ 划痕去除（形态学开运算检测细线 + 邻域填充）；零权重、确定性，在调色之前执行；`AIPanel` 一键开关 |
| 衣物/证件照换装 | ⛔ | 需服装分割模型（不在 `models.json` 清单里）；模板合成与服装分割都不在 v1 |

## 3. 交付与工作流

| imagecake 模块 | 本仓状态 | 差异说明 |
|---|---|---|
| 预设（JSON，v37） | ✅ | 键名逐字对齐；缺键落出厂；未知键点名；比本程序新拒收；外部资产依赖只登记不加载 |
| 撤销 / 重做 | ✅ | 50 步，一格是 `EditSnapshot`（参数 + 笔迹），`ParameterHistory` 已改为泛型；滑杆拖动 600ms 防抖合并成一步，一笔笔刷立即算一步；!换图清空；amendPresent 只改写栈顶 |
| PNG-8 / JPEG / HEIF | ✅ | ImageIO |
| PNG-16 / TIFF-16 | ✅ | 两个自家容器写入器：PNG-16 用 zlib stored 块；TIFF-16 用 baseline 6.0。都用 ImageIO 读回验证 |
| 色彩空间（ICC / lcms2） | ✅ | `ICCProfile`：输出时嵌 sRGB ICC profile（`CGColorSpace(name: .sRGB)` → `iccData`）；输入 ICC 由 Core Graphics 在解码时转 sRGB |
| 水印 / 边框 / 文字贴纸 | ✅ | `OverlayEngine`：三种元素（水印图/纯色边框/文字），在导出最后一步合成（AI 之后、编码之前）；`OverlayPanel` 提供添加/删除/清除入口 |
| 拼图排版 | ✅ | `CollageEngine`：4 种模板（1×2/2×1/2×2/1×3），按槽位归一化矩形排版，背景色可配 |
| 命名模板 / 尺寸档 | ✅ | 尺寸档（长边上限）+ 文件名模板 `{stem}/{date}/{time}/{index}/{ext}`（`ExportNaming`）；非法字符在生成阶段就清掉 |
| 批量队列 | ✅ | `BatchQueue`：串行处理多张图（同一组参数/预设），每张完成后报告进度，失败不中断队列 |
| CLI | ⛔ | iPadOS 无 CLI 等价路径；macOS 可通过 `xcodebuild` 跑测试但无独立 CLI |
| 联机拍摄 | ⛔ | iPadOS 无 WIA/USB PTP 的等价路径；相机厂商 SDK 不在范围 |
| XMP 导入 | ✅ | `XMPImporter`：正则抽 crs: 属性，约 40 键映射到 `EditParameters`（曝光/色温/色调/对比/饱和/HSL/色轮等），未知键跳过并报告 |
| 用量统计 | ⛔ | 本项目没有点数语义，不需要 |

## 4. 工程与验证

| imagecake | 本仓 |
|---|---|
| 1000+ C++ 断言（Catch2 风格自研） | 148 格 XCTest（几何/色彩/色轮与 HSL/色轮坐标/画布视口/空间滤波/补光与高光/文件名模板/去色边/撤销栈与笔迹入栈/笔迹栅格化/液化/仿制图章/保护笔刷/文档级渲染管线与跨分辨率重放/笔刷手势采样/**几何变换/老照片修复/修补工具/智能构图/XMP 导入/拼图/ICC/装饰叠加/本地调节**/容器/预设契约） |
| 无头 CLI 回归 | 无（iPadOS 无 CLI） |
| 权重清单 + 双校验 | ✅ 同一份 `models.json`，脚本与 App 共用 |
| 缺件点名令牌 | ✅ `[no_model:file]` / `[fallback:vision]` / `[closed_eyes]` / `[too_large]` / `[patch_scaled]` / `[no_mask]` / `[no_face]` / `[no_person]` |
| 三端（Win/Linux/macOS） | 双端（macOS/iPadOS），SwiftUI 单代码库 |
