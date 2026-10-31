import SwiftUI
import UIKit

// MARK: - 横幅广告配置（管理员可运行时更换 / 添加多张）

/// 横幅广告图片的本地覆盖：管理员在「实验室」里选图后存到 Documents/AuroraBanners，
/// DiscoverView 的 adBanner 优先用这里的图，没有则用 Assets 里的默认图（BannerAd1/BannerAd2 按奇偶循环）。
///
/// 🔴 v2.9.11：改为支持动态数量（管理员可「添加」多张），用 meta.json 记录哪些下标是自定义图，
/// 避免「恢复默认」后文件缺失导致下标错乱。
final class BannerConfig: ObservableObject {
    static let shared = BannerConfig()
    @Published var images: [UIImage?] = []
    /// 🔴 v2.9.14：云端（管理员设置）横幅，所有设备共享展示。
    /// 用 `[UIImage?]` 保留占位：某张图下载失败也占一个位置，数量与云端一致。
    @Published private(set) var cloudImages: [UIImage?] = []
    /// 🔴 v2.9.14：云端同步状态，直接显示在「实验室」里，让管理员能看到同步成没成功。
    @Published private(set) var syncState: SyncState = .idle
    /// 是否已经拿到过云端数据（区分「云端为空」和「还没拉过」）。
    private var hasCloudData = false

    enum SyncState: Equatable {
        case idle
        case syncing
        case done(String)
        case failed(String)
    }

    private let prefix = "aurora_banner_"
    private let ext = ".png"

    private struct Meta: Codable { var custom: [Bool] }

    private var refreshTimer: Timer?

    private init() {
        reload()
        // 🔴 v2.9.14：启动即拉一次云端横幅，并开启 60s 定时刷新——
        // 管理员在另一台设备改了横幅，本机最多 1 分钟内自动更新（原来只在进页面时拉一次）。
        Task { [self] in await pullCloud() }
        DispatchQueue.main.async { [weak self] in self?.startAutoRefresh() }
    }

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
        // 默认两张（对应最初的 BannerAd1/BannerAd2）
        return Meta(custom: [false, false])
    }

    private func writeMeta(_ meta: Meta) {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: Self.metaURL(), options: .atomic)
        }
    }

    func reload() {
        let meta = readMeta()
        var imgs: [UIImage?] = []
        for i in 0..<meta.custom.count {
            let url = Self.dir().appendingPathComponent("\(prefix)\(i)\(ext)")
            imgs.append(meta.custom[i] && FileManager.default.fileExists(atPath: url.path)
                        ? UIImage(contentsOfFile: url.path) : nil)
        }
        images = imgs
    }

    func set(_ image: UIImage, at index: Int) {
        var meta = readMeta()
        while meta.custom.count <= index { meta.custom.append(false) }
        let url = Self.dir().appendingPathComponent("\(prefix)\(index)\(ext)")
        if let data = image.pngData() { try? data.write(to: url, options: .atomic) }
        meta.custom[index] = true
        // 数组长度不足时补齐
        while images.count <= index { images.append(nil) }
        images[index] = image
        writeMeta(meta)
        syncCloud()
    }

    func reset(at index: Int) {
        guard images.indices.contains(index) else { return }
        var meta = readMeta()
        if meta.custom.indices.contains(index) { meta.custom[index] = false }
        try? FileManager.default.removeItem(at: Self.dir().appendingPathComponent("\(prefix)\(index)\(ext)"))
        images[index] = nil
        writeMeta(meta)
        syncCloud()
    }

    /// 🔴 v2.9.11：新增一张横幅位（默认用 App 内置图，管理员随后可「更换」）。
    func append() {
        var meta = readMeta()
        meta.custom.append(false)
        images.append(nil)
        writeMeta(meta)
        syncCloud()
    }

    // MARK: - 云端同步（跨设备共享管理员设置的横幅）

    /// 云端拉取到的横幅（所有设备共用，由 BannerSync 填充）。
    func applyCloud(_ imgs: [UIImage?]) {
        cloudImages = imgs
        hasCloudData = true
        objectWillChange.send()
    }

    /// 异步从云端拉取横幅（App 启动 / 进入发现页 / 定时刷新时调用）。
    /// 失败会自动重试 2 次；**拉取失败时保留本机已有横幅，不会被清空**。
    /// - Returns: 是否成功拿到云端数据。
    @discardableResult
    func pullCloud(retry: Int = 2) async -> Bool {
        let (imgs, err) = await BannerSync.fetch()
        if let imgs {
            await MainActor.run { self.applyCloud(imgs) }
            autoPushIfNeeded()
            return true
        }
        // 失败：退避后重试
        if retry > 0 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return await pullCloud(retry: retry - 1)
        }
        await MainActor.run { syncState = .failed(err ?? "云端横幅拉取失败") }
        Log.warn("横幅", "云端横幅拉取最终失败：\(err ?? "未知错误")")
        return false
    }

    /// 🔴 v2.9.15：本机横幅比云端多时自动推一次。
    /// 安全前提：**只有本机确实有自定义图才推**（别人设备本地是空的 → 绝不会把云端清空）。
    /// 覆盖场景：管理员换了新图但上传失败过，安装新版后自动补传。
    private func autoPushIfNeeded() {
        let local = images.compactMap { $0 }
        guard !local.isEmpty else { return }
        let cloudCount = cloudImages.compactMap { $0 }.count
        guard local.count > cloudCount else { return }
        guard CloudAccount.shared.isSignedIn else { return }
        Log.info("横幅", "本机 \(local.count) 张 > 云端 \(cloudCount) 张，自动补传")
        syncCloud()
    }

    /// 定时刷新（60s 一次）：管理员在别的设备改了横幅，本机自动跟上。
    func startAutoRefresh() {
        stopAutoRefresh()
        // 注意：闭包里用 BannerConfig.shared 而不是捕获 self ——
        // Timer 的 block 是 @Sendable，捕获非 Sendable 的 self 会触发并发告警，
        // 而本 CI 有「有编译警告就判失败」的检查。
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { await BannerConfig.shared.pullCloud(retry: 0) }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 实际展示用图：优先云端（管理员设置、跨设备共享），否则用本机自定义图。
    /// 元素为 nil 表示该位置用 App 内置默认图。
    var effectiveImages: [UIImage?] {
        hasCloudData ? cloudImages : images
    }

    /// 管理端编辑后同步到云端（fire-and-forget）。同时乐观更新 cloudImages 让本机即时看到。
    private func syncCloud() {
        let banners = images.enumerated().compactMap { idx, img -> (String, UIImage)? in
            guard let img else { return nil }
            return ("横幅广告 \(idx + 1)", img)
        }
        cloudImages = banners.map { $0.1 }
        hasCloudData = true
        objectWillChange.send()
        syncState = .syncing
        Task { [self] in
            if let err = await BannerSync.upload(banners) {
                await MainActor.run { self.syncState = .failed(err) }
                Log.warn("横幅", "云端同步失败：\(err)")
            } else {
                await MainActor.run {
                    self.syncState = .done(banners.isEmpty ? "已同步（云端暂无横幅）" : "已同步到云端（\(banners.count) 张）")
                }
            }
        }
    }

    /// 手动「立即同步到云端」（把本机当前设置重新推上去）。
    func pushToCloudNow() {
        syncCloud()
    }

    /// 手动「刷新云端横幅」（从云端拉一次）。
    func refreshFromCloud() async {
        syncState = .syncing
        let ok = await pullCloud(retry: 1)
        if ok {
            await MainActor.run { self.syncState = .done("已从云端刷新") }
        }
    }
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
                            SongRow(song: song,
                                     isCurrent: store.current?.id == song.id,
                                     isPlaying: store.isPlaying,
                                     trailing: nil)
                                .equatable()
                                .songMenu(song)
                                .onTapGesture {
                                    if let idx = history.firstIndex(where: { $0.id == song.id }) {
                                        store.play(history, startAt: idx)
                                        Haptics.soft()
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(AppStyle.surface)
                                )
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
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .kugouNavigationBarBackground()
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
                       size: 48, corner: 8)
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
                    List {
                        ForEach(lists) { playlist in
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
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
}

// MARK: - 实验室（管理员页：横幅图片更换 + 解锁码）

struct LabView: View {
    @ObservedObject private var cloud = CloudAccount.shared
    @ObservedObject private var banner = BannerConfig.shared
    // 🔴 v2.9.11：单一图片选择器 + 下标驱动，支持任意张数横幅
    @State private var showPickerIndex: Int? = nil
    @State private var showGenerator = false
    // 未登录页的登录表单
    @State private var loginEmail = ""
    @State private var loginPassword = ""
    @State private var loginError: String? = nil

    var body: some View {
        CompatNavigationStack {
            Group {
                if cloud.isSignedIn {
                    adminPanel
                } else {
                    notAdmin
                }
            }
            .navigationTitle("实验室")
            .navigationBarTitleDisplayMode(.inline)
            .kugouNavigationBarBackground()
        }
        .sheet(isPresented: Binding(
            get: { showPickerIndex != nil },
            set: { if !$0 { showPickerIndex = nil } }
        )) {
            AuroraImagePicker(
                onImagePicked: { img in
                    if let i = showPickerIndex { banner.set(img, at: i) }
                    showPickerIndex = nil
                },
                onCancel: { showPickerIndex = nil }
            )
        }
        .sheet(isPresented: $showGenerator) {
            LicenseGeneratorView()
        }
    }

    // MARK: 未登录：不展示任何管理内容，仅提供登录入口
    private var notAdmin: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(AppStyle.accent)
                Text("实验室需要管理员权限")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                Text("登录 Aurora 云账号后即可管理横幅广告与解锁码")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .multilineTextAlignment(.center)

                // 🔴 v2.9.11：登录入口（邮箱 + 密码）
                VStack(spacing: 10) {
                    TextField("邮箱", text: $loginEmail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    SecureField("密码（至少 6 位）", text: $loginPassword)
                        .textContentType(.password)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    if let err = loginError {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                    Button {
                        loginError = nil
                        Task {
                            do {
                                try await cloud.signIn(email: loginEmail, password: loginPassword)
                            } catch {
                                loginError = CloudAccount.localizedCloudError(error)
                            }
                        }
                    } label: {
                        if cloud.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("登录").font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(cloud.isBusy)
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
            }
            .padding(.top, 70)
        }
        .background(AppStyle.background)
    }

    private var adminPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 横幅广告管理
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("横幅广告管理")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppStyle.primaryText)
                        Spacer(minLength: 0)
                        // 🔴 v2.9.11：添加横幅位
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
                    // 🔴 v2.9.14：本机没有但云端有的横幅位也要列出来（管理员在别的设备改过的情况）
                    ForEach(Array(0..<max(banner.images.count, banner.cloudImages.count)), id: \.self) { index in
                        bannerRow(index: index)
                    }
                    Text("选择图片后即时生效；恢复默认即使用 App 内置图。点「添加」可增加更多横幅位。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .padding(16)
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                // 🔴 v2.9.14：云端同步状态 + 手动同步 / 刷新
                // （原来只写日志，用户看不到结果，以为"没上传到服务器"）
                VStack(alignment: .leading, spacing: 10) {
                    Text("云端同步")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)

                    HStack(spacing: 6) {
                        Image(systemName: syncIcon)
                            .font(.system(size: 13))
                            .foregroundStyle(syncColor)
                        Text(syncText)
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button {
                            banner.pushToCloudNow()
                            Haptics.light()
                        } label: {
                            Text("立即同步到云端")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppStyle.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(AppStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await banner.refreshFromCloud() }
                            Haptics.light()
                        } label: {
                            Text("刷新云端横幅")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppStyle.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(AppStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Text("改完横幅会自动上传到云端，其他手机约 1 分钟内自动更新；本机每 60 秒自动拉取一次云端横幅。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .padding(16)
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                // 解锁码
                VStack(alignment: .leading, spacing: 10) {
                    Text("解锁码")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    Text("生成 / 管理设备授权码（含管理员口令校验）。")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)
                    Button {
                        showGenerator = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill")
                            Text("打开授权码生成器")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .background(AppStyle.background)
    }

    // MARK: 🔴 v2.9.14 云端同步状态

    private var syncText: String {
        switch banner.syncState {
        case .idle:
            return "尚未同步。修改横幅后会自动上传到云端。"
        case .syncing:
            return "正在同步到云端…"
        case .done(let msg):
            return msg
        case .failed(let msg):
            return "同步失败：\(msg)"
        }
    }

    private var syncIcon: String {
        switch banner.syncState {
        case .idle: return "icloud"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.icloud.fill"
        case .failed: return "exclamationmark.icloud.fill"
        }
    }

    private var syncColor: Color {
        switch banner.syncState {
        case .idle: return AppStyle.tertiaryText
        case .syncing: return AppStyle.accent
        case .done: return .green
        case .failed: return .red
        }
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
                    Button { showPickerIndex = index } label: {
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

    /// 预览用图：优先本机设置的图，没有就显示云端那张（管理员在别的设备改过时也能看到）。
    private func previewImage(at index: Int) -> UIImage? {
        if let local = banner.images.indices.contains(index) ? banner.images[index] : nil {
            return local
        }
        if banner.cloudImages.indices.contains(index) { return banner.cloudImages[index] }
        return nil
    }
}
