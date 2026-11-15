import SwiftUI
import UIKit
import ImageIO
// 🔴 2026-11-15：下载页「备份 / 恢复」要选文件夹（UTType.folder）。
import UniformTypeIdentifiers

// MARK: - 横幅广告配置（🔴 2026-11-13：纯本机，不读写服务器）

/// 「实验室」里选的图只存 Documents/AuroraBanners，重启仍在；
/// 没有自定义图时 DiscoverView 的 adBanner 用 Assets 默认图（BannerAd1/BannerAd2 按奇偶）。
///
/// 🔴 2026-11-13 用户要求「横幅广告也改成本地修改不上传服务器」：
///    整套 Supabase 云端同步（启动拉取 + 10 分钟轮询 + 改图自动上传）已删除。
///    云端大图一张 15–20MB，进一次发现页拉一遍、主线程整张解码，
///    是 iPhone 14 / iOS 27 上「推荐页有时候卡死」的主要嫌疑点。
final class BannerConfig: ObservableObject {
    static let shared = BannerConfig()
    @Published private(set) var images: [UIImage?] = []

    private let prefix = "aurora_banner_"
    private struct Meta: Codable { var custom: [Bool] }

    private init() { reload() }

    private static func dir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("AuroraBanners", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func metaURL() -> URL { dir().appendingPathComponent("meta.json") }

    private func readMeta() -> Meta {
        if let data = try? Data(contentsOf: Self.metaURL()),
           let m = try? JSONDecoder().decode(Meta.self, from: data) {
            return m
        }
        // 🔴 2026-11-15：用户要求「默认 2 移除，只保留 1」。
        return Meta(custom: [false])
    }

    private func writeMeta(_ meta: Meta) {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: Self.metaURL(), options: .atomic)
        }
    }

    /// 新版存 JPEG；老版本留下的 PNG 仍然认，升级不会丢已设置的横幅。
    private func imageURL(_ index: Int) -> URL {
        let jpg = Self.dir().appendingPathComponent("\(prefix)\(index).jpg")
        if FileManager.default.fileExists(atPath: jpg.path) { return jpg }
        return Self.dir().appendingPathComponent("\(prefix)\(index).png")
    }

    /// 🔴 直接从文件解出限尺寸缩略图，不把 4000×3000 原图整张解进内存。
    ///    旧版 `UIImage(contentsOfFile:)` 在 App 启动（`reload()`）时同步解码，
    ///    几张大图能把主线程堵住几秒 —— 真机上就是「推荐页有时候卡死」。
    static func thumbnail(from url: URL, maxPixel: Int = 1000) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    private static func scaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let ratio = maxSide / longest
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func reload() {
        var meta = readMeta()
        // 🔴 2026-11-15：老版本默认两张。第 2 张仍是内置默认图（没自定义）
        //    → 直接移除该位置，实验室里只剩「横幅广告 1」。用户自己换过图的
        //    第 2 张保留、不丢数据；迁移只跑一次。
        let migratedKey = "aurora.banner.singleDefault.v1"
        if !UserDefaults.standard.bool(forKey: migratedKey) {
            if meta.custom.count == 2, !meta.custom[1] {
                meta.custom = Array(meta.custom.prefix(1))
                writeMeta(meta)
            }
            UserDefaults.standard.set(true, forKey: migratedKey)
        }
        var imgs: [UIImage?] = []
        for i in 0..<meta.custom.count {
            imgs.append(meta.custom[i] ? Self.thumbnail(from: imageURL(i)) : nil)
        }
        images = imgs
    }

    func set(_ image: UIImage, at index: Int) {
        let scaledImage = Self.scaled(image, maxSide: 1600)
        guard let data = scaledImage.jpegData(compressionQuality: 0.82) else { return }
        let url = Self.dir().appendingPathComponent("\(prefix)\(index).jpg")
        try? data.write(to: url, options: .atomic)
        // 旧 PNG 留着也没关系（imageURL 优先 jpg），顺手删掉省空间。
        try? FileManager.default.removeItem(at: Self.dir().appendingPathComponent("\(prefix)\(index).png"))
        var meta = readMeta()
        while meta.custom.count <= index { meta.custom.append(false) }
        meta.custom[index] = true
        // 🔴 @Published 数组必须「复制→改→整体替换」：原地改下标不会触发 publisher，
        //    旧版是靠 syncCloud() 里手动 objectWillChange.send() 才刷新的（现已删除）。
        var next = images
        while next.count <= index { next.append(nil) }
        next[index] = Self.thumbnail(from: url) ?? scaledImage
        images = next
        writeMeta(meta)
    }

    func reset(at index: Int) {
        guard images.indices.contains(index) else { return }
        var meta = readMeta()
        if meta.custom.indices.contains(index) { meta.custom[index] = false }
        try? FileManager.default.removeItem(at: Self.dir().appendingPathComponent("\(prefix)\(index).jpg"))
        try? FileManager.default.removeItem(at: Self.dir().appendingPathComponent("\(prefix)\(index).png"))
        var next = images
        next[index] = nil
        images = next
        writeMeta(meta)
    }

    /// 新增一张横幅位（默认用 App 内置图，随后可「更换」）。
    func append() {
        var meta = readMeta()
        meta.custom.append(false)
        var next = images
        next.append(nil)
        images = next
        writeMeta(meta)
    }

    // MARK: - 展示

    /// 🔴 只用本机自定义图，不再读写云端；元素为 nil 表示该位置用 App 内置默认图。
    var effectiveImages: [UIImage?] { images }
}

// MARK: - 图片选择（iOS 15：UIImagePickerController 包装）

/// 从相册选一张图，通过 onImagePicked 回调返回（UIImage 不遵守 Equatable，故不用 @Binding + onChange）。
struct AuroraImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImagePicked: (UIImage) -> Void
    var onCancel: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: AuroraImagePicker
        init(_ p: AuroraImagePicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController,
                                  didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImagePicked(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel?()
            parent.dismiss()
        }
    }
}

// MARK: - 下载中心（下载中进度 + 下载历史）

struct DownloadCenterView: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var library = LibraryStore.shared

    // 🔴 2026-11-15：备份 / 从备份恢复 / 多选删除
    private enum FolderMode { case backup, restore }

    /// 后台 IO 完成后的返回值（显式 Sendable，避免并发检查告警）。
    private struct FolderOutcome: Sendable {
        var text: String
        var needsBootstrap: Bool
    }

    @State private var folderMode: FolderMode = .backup
    @State private var showFolderPicker = false
    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []
    @State private var isWorking = false
    @State private var noticeText = ""
    @State private var showNotice = false
    @State private var showDeleteConfirm = false

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let active = downloads.items.filter { $0.state.isActive }

                    // 🔴 v2.9.14：下载音质选择（每次询问 / 固定档位）
                    HStack {
                        Text("下载音质")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppStyle.secondaryText)
                        Spacer(minLength: 0)
                        Menu {
                            Button("每次询问") {
                                downloads.defaultDownloadQuality = nil
                                Haptics.light()
                            }
                            ForEach(MusicQuality.allCases) { quality in
                                Button(quality.title) {
                                    downloads.defaultDownloadQuality = quality
                                    Haptics.light()
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(downloads.defaultDownloadQuality?.title ?? "每次询问")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppStyle.accent)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(AppStyle.accent)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AppStyle.accent.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                    if !active.isEmpty {
                        sectionTitle("下载中")
                        ForEach(active) { item in
                            activeRow(item)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(AppStyle.surface)
                                )
                        }
                    }

                    let history = library.downloads
                    if !history.isEmpty {
                        sectionTitle("下载历史")
                        ForEach(history) { song in
                            historyRow(song, history: history)
                        }
                    }

                    if active.isEmpty && history.isEmpty {
                        EmptyStateView(icon: "arrow.down.circle",
                                       title: "还没有下载",
                                       message: "去搜索或榜单里下载歌曲吧")
                            .padding(.top, 80)
                    }
                }
                .padding(.bottom, 110)
            }
            .background(AppStyle.background)
            .navigationTitle(isEditing ? "已选 \(selectedIDs.count) 项" : "下载")
            .navigationBarTitleDisplayMode(.inline)
            .kugouNavigationBarBackground()
            .toolbar { downloadToolbar }
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                handleFolderPick(result)
            }
            .overlay(alignment: .bottom) { editingBar }
            .confirmationDialog("删除已选歌曲？",
                                isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("删除 \(selectedIDs.count) 首", role: .destructive) { deleteSelected() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会删除这些歌曲在本机的下载文件，删除后无法恢复。")
            }
            .alert("提示", isPresented: $showNotice) {
                Button("好", role: .cancel) {}
            } message: {
                Text(noticeText)
            }
        }
    }

    // MARK: 顶栏：备份 / 恢复 / 多选

    @ToolbarContentBuilder
    private var downloadToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isWorking {
                ProgressView()
            } else if isEditing {
                Button("完成") { exitEditing() }
            } else {
                // 顶栏三个独立按钮：备份 / 从备份恢复 / 多选。
                Button {
                    folderMode = .backup
                    showFolderPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("备份下载歌曲")
                .disabled(library.downloads.isEmpty && downloads.items.isEmpty)

                Button {
                    folderMode = .restore
                    showFolderPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("从备份恢复")

                Button("多选") {
                    withAnimation(.easeInOut(duration: 0.2)) { isEditing = true }
                    Haptics.light()
                }
                .disabled(library.downloads.isEmpty)
            }
        }
    }

    // MARK: 底部：全选 / 删除

    @ViewBuilder
    private var editingBar: some View {
        if isEditing {
            HStack(spacing: 12) {
                Button {
                    toggleSelectAll()
                } label: {
                    Text(selectedIDs.count == library.downloads.count ? "取消全选" : "全选")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppStyle.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(AppStyle.surface, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    showDeleteConfirm = true
                } label: {
                    Label("删除已选 \(selectedIDs.count)", systemImage: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(selectedIDs.isEmpty ? Color.gray.opacity(0.45) : Color.red,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(selectedIDs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: 历史行（编辑态带勾选圈）

    @ViewBuilder
    private func historyRow(_ song: Song, history: [Song]) -> some View {
        HStack(spacing: 8) {
            if isEditing {
                Image(systemName: selectedIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selectedIDs.contains(song.id) ? AppStyle.accent : AppStyle.tertiaryText)
                    .transition(.scale.combined(with: .opacity))
            }
            SongRow(song: song,
                    isCurrent: store.current?.id == song.id,
                    isPlaying: store.isPlaying,
                    trailing: nil,
                    onPlay: {
                        if let idx = history.firstIndex(where: { $0.id == song.id }) {
                            store.setQueueOrigin(id: "history", title: "最近播放")
                            store.play(history, startAt: idx)
                            Haptics.soft()
                        }
                    })
                .equatable()
                .songMenu(song)
                // 编辑态整行只响应「切换选中」，不触发播放 / 菜单。
                .allowsHitTesting(!isEditing)
        }
        .padding(.leading, isEditing ? 4 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEditing else { return }
            toggleSelection(song)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isEditing && selectedIDs.contains(song.id)
                      ? AppStyle.accent.opacity(0.12)
                      : AppStyle.surface)
        )
    }

    // MARK: 交互

    private func exitEditing() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditing = false
            selectedIDs.removeAll()
        }
    }

    private func toggleSelection(_ song: Song) {
        if selectedIDs.contains(song.id) {
            selectedIDs.remove(song.id)
        } else {
            selectedIDs.insert(song.id)
        }
        Haptics.light()
    }

    private func toggleSelectAll() {
        if selectedIDs.count == library.downloads.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(library.downloads.map(\.id))
        }
        Haptics.light()
    }

    private func deleteSelected() {
        let targets = library.downloads.filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        for song in targets {
            DownloadManager.shared.delete(song)
        }
        Haptics.success()
        noticeText = "已删除 \(targets.count) 首歌曲。"
        showNotice = true
        exitEditing()
    }

    private func handleFolderPick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            noticeText = "没有选择文件夹：\(error.localizedDescription)"
            showNotice = true
        case .success(let urls):
            guard let url = urls.first else { return }
            performFolderTask(url)
        }
    }

    /// 备份 / 恢复都是大量文件 IO，放后台执行，完成后回主线程刷新。
    private func performFolderTask(_ url: URL) {
        isWorking = true
        let isBackup = folderMode == .backup
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> FolderOutcome in
                do {
                    if isBackup {
                        let (folder, summary) = try DownloadBackup.backup(to: url)
                        let text = summary.isEmpty
                            ? "当前没有可备份的歌曲。"
                            : "已备份 \(summary.songs) 首歌、\(summary.files) 个文件（\(summary.sizeText)）到「\(folder.lastPathComponent)」。"
                        return FolderOutcome(text: text, needsBootstrap: false)
                    } else {
                        let summary = try DownloadBackup.restore(from: url)
                        let text = summary.isEmpty
                            ? "这个文件夹里没有找到可恢复的歌曲。"
                            : "已恢复 \(summary.songs) 首歌、\(summary.files) 个文件。"
                        return FolderOutcome(text: text, needsBootstrap: true)
                    }
                } catch {
                    return FolderOutcome(text: "操作失败：\(error.localizedDescription)",
                                         needsBootstrap: false)
                }
            }.value

            if outcome.needsBootstrap {
                // 恢复后按磁盘索引重建下载列表（会同步 LibraryStore.downloads）。
                DownloadManager.shared.bootstrap()
            }
            noticeText = outcome.text
            isWorking = false
            showNotice = true
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppStyle.secondaryText)
            .padding(.leading, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func activeRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: item.song.artworkURL,
                       fallbackKeys: item.song.coverFallbackKeys,
                       seed: "\(item.song.artist)-\(item.song.title)",
                       size: 48, corner: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.song.cleanTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(item.state == .waiting ? "等待中…" : "下载中 \(Int(item.progress * 100))%")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.secondaryText)
                ProgressView(value: item.progress)
                    .tint(AppStyle.accent)
                    .frame(height: 4)
            }
            Spacer(minLength: 0)
            Button {
                DownloadManager.shared.delete(item.song)
                Haptics.light()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - 排行榜（接入酷狗榜单，TOP500 置顶）

struct RankingsView: View {
    @State private var lists: [Playlist] = []
    @State private var isLoading = true
    @State private var errorMsg: String?

    var body: some View {
        CompatNavigationStack {
            Group {
                if isLoading {
                    VStack { ProgressView().padding(.top, 80) }
                } else if let err = errorMsg {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "加载失败", message: err)
                        .padding(.top, 60)
                } else if lists.isEmpty {
                    EmptyStateView(icon: "trophy", title: "暂无榜单", message: "稍后重试")
                        .padding(.top, 60)
                } else {
                    // 🔴 v2.9.17：按榜单名关键词归类，用 Section 分组展示
                    let grouped = Dictionary(grouping: lists) { Self.rankCategory($0) }
                    List {
                        ForEach(Self.rankCategoryOrder, id: \.self) { cat in
                            if let items = grouped[cat], !items.isEmpty {
                                Section {
                                    ForEach(items) { playlist in
                                        NavigationLink {
                                            PlaylistDetailView(playlist: playlist)
                                        } label: {
                                            rankRow(playlist)
                                        }
                                    }
                                } header: {
                                    Text(cat)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(AppStyle.secondaryText)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("排行榜")
            .navigationBarTitleDisplayMode(.inline)
            .kugouNavigationBarBackground()
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        errorMsg = nil
        defer { isLoading = false }
        let all = await KugouClient.shared.topLists()
        // 酷狗 TOP500（rankid=8888）排最前，满足「排行榜接入酷狗 TOP500 列表」
        lists = all.sorted {
            ($0.kugouRankID == "8888" ? 0 : 1) < ($1.kugouRankID == "8888" ? 0 : 1)
        }
    }

    // 🔴 v2.9.17：榜单分类（按榜名关键词归类，顺序固定）
    private static let rankCategoryOrder: [String] = [
        "总榜", "飙升榜", "网络热歌", "国风", "民谣", "纯音乐", "电子", "欧美/外语", "DJ", "其他"
    ]

    private static func rankCategory(_ playlist: Playlist) -> String {
        let n = playlist.name
        if n.contains("TOP500") || n.contains("500") { return "总榜" }
        if n.contains("飙升") { return "飙升榜" }
        if n.contains("热歌") || n.contains("短视频") || n.contains("视频号") { return "网络热歌" }
        if n.contains("国潮") || n.contains("国风") || n.contains("中国风") { return "国风" }
        if n.contains("民谣") { return "民谣" }
        if n.contains("纯音乐") { return "纯音乐" }
        if n.contains("电音") || n.contains("电子") { return "电子" }
        if n.contains("欧美") || n.contains("韩语") || n.contains("日语") || n.contains("韩流") || n.contains("英文") { return "欧美/外语" }
        if n.contains("DJ") { return "DJ" }
        return "其他"
    }

    // 榜单行（Section 内复用，避免重复写）
    private func rankRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: playlist.coverURL,
                       fallbackKeys: [playlist.id],
                       seed: playlist.name,
                       size: 50, corner: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(playlist.kugouRankID == "8888" ? "酷狗 TOP500 · 每日更新" : "酷狗榜单")
                    .font(.system(size: 12))
                    .foregroundStyle(playlist.kugouRankID == "8888"
                                     ? AppStyle.accent : AppStyle.tertiaryText)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 实验室（🔴 2026-11-13 开放：横幅广告 + 我的音乐卡片背景，全部本机保存）

/// 🔴 2026-11-13：实验室改为**开放**，不再验证管理员账号 / 云账号；
///    解锁码生成器入口整体移除（只保留设置页「版本」连点 7 次的隐藏入口）。
///    横幅不再上传服务器，我的音乐卡片背景设置也从卡片上的齿轮搬到这里。
struct LabView: View {
    @ObservedObject private var banner = BannerConfig.shared
    @ObservedObject private var cardBackground = ProfileCardBackground.shared

    /// iOS 15：链式叠多个 .sheet(isPresented:) 只有最后一个生效 → 单个 .sheet(item:) 统一分发。
    private enum PickerTarget: Identifiable {
        case banner(Int)
        case card
        var id: String {
            switch self {
            case .banner(let i): return "banner-\(i)"
            case .card: return "card"
            }
        }
    }
    @State private var pickerTarget: PickerTarget?

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    bannerSection
                    cardSection
                    Text("横幅与卡片背景都只保存在本机，不会上传到服务器。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .padding(16)
                .padding(.bottom, 40)
            }
            .background(AppStyle.background)
            .navigationTitle("实验室")
            .navigationBarTitleDisplayMode(.inline)
            .kugouNavigationBarBackground()
        }
        .sheet(item: $pickerTarget) { target in
            AuroraImagePicker(onImagePicked: { img in
                switch target {
                case .banner(let i): banner.set(img, at: i)
                case .card: cardBackground.set(img)
                }
                pickerTarget = nil
            }, onCancel: { pickerTarget = nil })
            .ignoresSafeArea()
        }
    }

    // MARK: 横幅广告（纯本机）

    private var bannerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("横幅广告管理")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer(minLength: 0)
                Button {
                    banner.append()
                    Haptics.light()
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppStyle.accent)
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(0..<banner.images.count), id: \.self) { index in
                bannerRow(index: index)
            }
            Text("选择图片后即时生效，只保存在本机；恢复默认即使用 App 内置图。点「添加」可增加更多横幅位。")
                .font(.system(size: 11))
                .foregroundStyle(AppStyle.tertiaryText)
        }
        .padding(16)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 我的音乐顶部卡片背景（纯本机）

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("我的音乐卡片背景")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AppStyle.primaryText)
            ZStack {
                LinearGradient(colors: [AppStyle.accent.opacity(0.18), AppStyle.accent.opacity(0.07)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let bg = cardBackground.image {
                    GeometryReader { geo in
                        Image(uiImage: bg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                    Color.white.opacity(0.30)
                } else {
                    Text("默认渐变背景")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.secondaryText)
                }
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Button { pickerTarget = .card } label: {
                    Text("从相册选择图片")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppStyle.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(AppStyle.accent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                Button { cardBackground.clear() } label: {
                    Text("恢复默认")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppStyle.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(AppStyle.surfaceHigh,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text("卡片大小与推荐页横幅一致；设置只保存在本机。")
                .font(.system(size: 11))
                .foregroundStyle(AppStyle.tertiaryText)
        }
        .padding(16)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func bannerRow(index: Int) -> some View {
        HStack(spacing: 12) {
            if let img = previewImage(at: index) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppStyle.surfaceHigh)
                    .frame(width: 96, height: 54)
                    .overlay(
                        Text("默认图")
                            .font(.system(size: 11))
                            .foregroundStyle(AppStyle.tertiaryText)
                    )
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("横幅广告 \(index + 1)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                HStack(spacing: 10) {
                    Button { pickerTarget = .banner(index) } label: {
                        Text("更换").font(.system(size: 13, weight: .medium)).foregroundStyle(AppStyle.accent)
                    }
                    .buttonStyle(.plain)
                    Button { banner.reset(at: index) } label: {
                        Text("恢复默认").font(.system(size: 13, weight: .medium)).foregroundStyle(AppStyle.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func previewImage(at index: Int) -> UIImage? {
        banner.images.indices.contains(index) ? banner.images[index] : nil
    }
}
