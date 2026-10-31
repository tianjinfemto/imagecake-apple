import SwiftUI
import UniformTypeIdentifiers

// 素材库面板（像素蛋糕的"项目/相册视图"那一层）。
//
// 它以 sheet 形式打开而不是塞进右侧检查器：缩略图网格需要**宽度**，
// 在 300pt 的一栏里只能排两列，等于把"一组片子"退化成"两个文件名"。
// 检查器那六个标签页也已经放不下第七段 segmented picker。
//
// 面板只做三件事，都是"管一组片子"的最小闭环：
//   1. 选目录 → 扫出素材（只扫一层，非图片跳过）；
//   2. 按状态筛选（未修/已修/已出片）——状态从 sidecar 接，不是手点的；
//   3. 点开某张进编辑器；「下一张未修」和「存进度」支撑连续作业。
// 在线选片、团队协作、云端同步不做（见 docs/pixcake-parity.md §4 的平台缺口）。

struct LibraryPanel: View {
    @EnvironmentObject private var model: EditorModel
    var onClose: () -> Void = {}

    @State private var showFolderPicker = false
    /// 每个文件的缩略图。按文件名索引：URL 每次扫描都是新值，按 URL 存会一路 miss。
    @State private var thumbnails: [String: CGImage] = [:]
    /// 已经试过的文件。解码失败时字典里不会有条目，拿它防止无限重试。
    @State private var attempted: Set<String> = []
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 168), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Tokens.border)
            content
        }
        .background(Tokens.bgWindow)
        .frame(minWidth: 520, minHeight: 460)
        .fileImporter(isPresented: $showFolderPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.openLibrary(folder: url)
                thumbnails = [:]
                attempted = []
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("素材库").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                    Text(model.libraryFolder?.lastPathComponent ?? "未选择项目目录")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    showFolderPicker = true
                } label: {
                    Label(model.libraryFolder == nil ? "选择目录…" : "更换目录", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                Button("关闭") { onClose() }
                    .buttonStyle(.bordered)
            }

            if !model.libraryItems.isEmpty {
                HStack(spacing: 8) {
                    Picker("筛选", selection: $model.libraryFilter) {
                        ForEach(LibraryFilter.allCases) { item in
                            Text("\(item.title)（\(count(for: item))）").tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Spacer()
                    Button("下一张未修") { model.openNextUnedited() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("存当前进度") { model.saveCurrentProgress() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!model.hasImage)
                }
            }

            if !model.libraryNote.isEmpty {
                Text(model.libraryNote)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(model.libraryNote.contains("[") ? Tokens.danger : Tokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private func count(for filter: LibraryFilter) -> Int {
        ImageLibrary.filter(model.libraryItems, by: filter).count
    }

    // MARK: - 网格

    @ViewBuilder
    private var content: some View {
        if model.libraryItems.isEmpty {
            VStack(spacing: 10) {
                Text(model.libraryFolder == nil ? "还没有项目目录" : "这个目录里没有可打开的图片")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textSecondary)
                Text("素材库只读一层目录，认 JPEG/PNG/HEIC/TIFF/WebP/BMP/GIF；RAW 请在「打开」里单张选。")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button("选择目录…") { showFolderPicker = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.visibleLibraryItems) { item in
                        cell(item)
                    }
                }
                .padding(12)
            }
        }
    }

    private func cell(_ item: LibraryItem) -> some View {
        let isCurrent = model.currentItem?.url == item.url
        return Button {
            Task { await model.open(url: item.url) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    thumbnail(for: item)
                    Label(item.status.title, systemImage: item.status.icon)
                        .labelStyle(.iconOnly)
                        .padding(4)
                        .background(Tokens.bgElevated.opacity(0.85), in: Circle())
                        .foregroundStyle(item.status == .exported ? Tokens.ok : Tokens.textPrimary)
                        .padding(4)
                }
                Text(item.fileName)
                    .font(.system(size: 9))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(4)
            .background(Tokens.bgPanel, in: RoundedRectangle(cornerRadius: Tokens.corner))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.corner)
                    .stroke(isCurrent ? Tokens.accent : Tokens.border.opacity(0.7), lineWidth: isCurrent ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnail(for item: LibraryItem) -> some View {
        if let image = thumbnails[item.fileName] {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            Rectangle()
                .fill(Tokens.bgCanvas)
                .frame(height: 96)
                .overlay {
                    if attempted.contains(item.fileName) {
                        // 解不出来也要给个东西看：空图与"正在读"必须分得开。
                        Image(systemName: "questionmark")
                            .foregroundStyle(Tokens.textSecondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .task {
                    // 256 档缩略图：走的是与打开同一条解码路径（含 EXIF 转正），
                    // 网格里的方向和大小才与点开后的图一致。
                    guard !attempted.contains(item.fileName) else { return }
                    attempted.insert(item.fileName)
                    if let loaded = try? await ImageLoader.load(url: item.url, maxEdge: 256) {
                        thumbnails[item.fileName] = Self.thumbnailImage(loaded.linear)
                    }
                }
        }
    }

    /// 线性档 → 显示域 → CGImage。缩略图专用：不走预览管线（一张图不该付
    /// 整条链的代价），但也用同一条 sRGB 传递函数，颜色才不至于两套口径。
    static func thumbnailImage(_ linear: LinearImage) -> CGImage? {
        let size = linear.size
        guard size.pixelCount > 0, linear.pixels.count >= size.pixelCount * 4 else { return nil }
        var pixels = linear.pixels
        for i in 0 ..< size.pixelCount {
            let o = i * 4
            for c in 0 ..< 3 {
                let s = Swift.min(Swift.max(pixels[o + c], 0), 1)
                pixels[o + c] = s <= 0.0031308 ? s * 12.92 : 1.055 * pow(s, 1.0 / 2.4) - 0.055
            }
        }
        return DisplayImage(size: size, pixels: pixels).cgImage()
    }
}
