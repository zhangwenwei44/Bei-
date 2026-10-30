import SwiftUI
import UIKit

// MARK: - 横幅广告配置（管理员可运行时更换）

/// 横幅广告图片的本地覆盖：管理员在「实验室」里选图后存到 Documents/AuroraBanners，
/// DiscoverView 的 adBanner 优先用这里的图，没有则用 Assets 里的默认图（BannerAd1/BannerAd2）。
final class BannerConfig: ObservableObject {
    static let shared = BannerConfig()
    @Published var images: [UIImage?] = [nil, nil]
    private let names = ["aurora_banner_0.png", "aurora_banner_1.png"]

    private init() { reload() }

    func reload() {
        let dir = Self.dir()
        for i in 0..<2 {
            let url = dir.appendingPathComponent(names[i])
            images[i] = FileManager.default.fileExists(atPath: url.path) ? UIImage(contentsOfFile: url.path) : nil
        }
    }

    func set(_ image: UIImage, at index: Int) {
        guard (0..<2).contains(index) else { return }
        let url = Self.dir().appendingPathComponent(names[index])
        if let data = image.pngData() { try? data.write(to: url, options: .atomic) }
        images[index] = image
    }

    func reset(at index: Int) {
        guard (0..<2).contains(index) else { return }
        try? FileManager.default.removeItem(at: Self.dir().appendingPathComponent(names[index]))
        images[index] = nil
    }

    static func dir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("AuroraBanners", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

// MARK: - 图片选择（iOS 15：UIImagePickerController 包装）

/// 从相册选一张图，通过 onImagePicked 回调返回（UIImage 不遵守 Equatable，故不用 @Binding + onChange）。
struct AuroraImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImagePicked: (UIImage) -> Void

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
    @State private var showPicker0 = false
    @State private var showPicker1 = false
    @State private var showGenerator = false

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
        .sheet(isPresented: $showPicker0) {
            AuroraImagePicker { img in banner.set(img, at: 0) }
        }
        .sheet(isPresented: $showPicker1) {
            AuroraImagePicker { img in banner.set(img, at: 1) }
        }
        .sheet(isPresented: $showGenerator) {
            LicenseGeneratorView()
        }
    }

    private var notAdmin: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 38))
                .foregroundStyle(AppStyle.accent)
            Text("请以管理员身份登录")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppStyle.primaryText)
            Text("登录 Aurora 云账号后即可管理横幅广告与解锁码")
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppStyle.background)
    }

    private var adminPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 横幅广告管理
                VStack(alignment: .leading, spacing: 10) {
                    Text("横幅广告管理")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    bannerRow(index: 0, title: "横幅广告 1", show: $showPicker0) { banner.reset(at: 0) }
                    bannerRow(index: 1, title: "横幅广告 2", show: $showPicker1) { banner.reset(at: 1) }
                    Text("选择图片后即时生效；恢复默认即使用 App 内置图。")
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

    private func bannerRow(index: Int, title: String,
                           show: Binding<Bool>,
                           reset: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            if let img = banner.images[index] {
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
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                HStack(spacing: 10) {
                    Button { show.wrappedValue = true } label: {
                        Text("更换").font(.system(size: 13, weight: .medium)).foregroundStyle(AppStyle.accent)
                    }
                    .buttonStyle(.plain)
                    Button { reset() } label: {
                        Text("恢复默认").font(.system(size: 13, weight: .medium)).foregroundStyle(AppStyle.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
