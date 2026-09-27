import SwiftUI
import UIKit

/// 全局配色：近黑底 + 单一强调色，遵循设计规范里的「简约」原则。
enum AppStyle {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let surface = Color(red: 0.106, green: 0.106, blue: 0.118)
    static let surfaceHigh = Color(red: 0.153, green: 0.153, blue: 0.169)
    static let accent = Color(red: 0.204, green: 0.612, blue: 0.973)
    static let like = Color(red: 1.0, green: 0.302, blue: 0.416)
    static let gold = Color(red: 0.957, green: 0.824, blue: 0.290)

    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)
}

// MARK: - 封面

/// 带渐变兜底的封面图。
///
/// `fallbackKeys` 是回退实体的 id（`pl:123` / `ar:456` / `al:789`），
/// 详情页加载完后 CoverResolver 里登记了图，这里就会自动顶上。
struct CoverImage: View {
    let url: URL?
    var fallbackKeys: [String] = []
    var seed: String = "-"
    var size: CGFloat = 48
    var corner: CGFloat = 8

    @State private var image: UIImage?
    @State private var resolved: URL?

    private var effectiveURL: URL? {
        url ?? resolved ?? CoverResolver.shared.firstAvailable(fallbackKeys)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: ArtworkPaletteEngine.palette(for: nil, seed: seed).gradient,
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.32, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: taskKey) { await load() }
    }

    private var taskKey: String {
        (effectiveURL?.absoluteString ?? "-") + "|" + size.description
    }

    private func load() async {
        guard let target = effectiveURL else {
            image = nil
            return
        }
        if target.isFileURL, let data = try? Data(contentsOf: target), let loaded = UIImage(data: data) {
            image = loaded
            return
        }
        if let cached = CoverCache.shared.image(for: target) {
            image = cached
            return
        }
        var request = URLRequest(url: target)
        request.timeoutInterval = 10
        request.setValue("AuroraMusic/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let loaded = UIImage(data: data) else { return }
        CoverCache.shared.store(loaded, for: target)
        image = loaded
    }
}

/// 简单的封面内存缓存。
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

// MARK: - 区块标题

struct SectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

// MARK: - 歌曲行

struct SongRow: View {
    let song: Song
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var showsCover: Bool = true
    var trailing: AnyView?

    init(song: Song,
         isCurrent: Bool = false,
         isPlaying: Bool = false,
         showsCover: Bool = true,
         trailing: AnyView? = nil) {
        self.song = song
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.showsCover = showsCover
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            if showsCover {
                CoverImage(url: song.artworkURL,
                           fallbackKeys: song.neteaseID.map { ["wy:\($0)"] } ?? [],
                           seed: "\(song.artist)-\(song.title)",
                           size: 44)
                .overlay(alignment: .bottomTrailing) {
                    if isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(AppStyle.accent, in: Circle())
                            .offset(x: 4, y: 4)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isCurrent ? AppStyle.accent : AppStyle.primaryText)
                        .lineLimit(1)
                    if song.source == .local {
                        Text("本地")
                            .font(.system(size: 9))
                            .foregroundStyle(AppStyle.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(AppStyle.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(song.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let trailing {
                trailing
            } else if song.duration > 0 {
                Text(song.duration.clockString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AppStyle.tertiaryText)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

// MARK: - 歌曲操作菜单

/// 列表项通用的操作菜单（收藏 / 下载 / 下一首播放 / 加入歌单）。
struct SongMenu: ViewModifier {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    let song: Song

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    store.playNow([song])
                } label: {
                    Label("下一首播放", systemImage: "text.insert")
                }
                Button {
                    store.append([song])
                } label: {
                    Label("添加到播放列表", systemImage: "text.badge.plus")
                }
                Button {
                    _ = library.toggleFavorite(song)
                } label: {
                    Label(library.isFavorite(song) ? "取消收藏" : "收藏", systemImage: "heart")
                }
                if song.isRemote {
                    Button {
                        Task { _ = try? await downloads.download(song) }
                    } label: {
                        Label(downloads.isDownloaded(song) ? "已下载" : "下载", systemImage: "arrow.down.circle")
                    }
                }
                if !library.playlists.isEmpty {
                    Menu("添加到歌单") {
                        ForEach(library.playlists) { playlist in
                            Button(playlist.name) { library.add(song, toPlaylist: playlist.id) }
                        }
                    }
                }
            }
    }
}

extension View {
    func songMenu(_ song: Song) -> some View {
        modifier(SongMenu(song: song))
    }
}

// MARK: - 卡片

struct PlaylistCard: View {
    let playlist: Playlist
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(url: playlist.coverURL,
                       fallbackKeys: [playlist.id],
                       seed: playlist.name,
                       size: width,
                       corner: 10)
            Text(playlist.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppStyle.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if playlist.trackCount > 0 {
                Text("\(playlist.trackCount) 首")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 歌单卡片 + 进入详情。
struct PlaylistLink: View {
    let playlist: Playlist
    var width: CGFloat = 150

    var body: some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
        } label: {
            PlaylistCard(playlist: playlist, width: width)
        }
        .buttonStyle(.plain)
    }
}

struct SimpleCard: View {
    let title: String
    let subtitle: String?
    let url: URL?
    var fallbackKeys: [String] = []
    var size: CGFloat = 60

    var body: some View {
        VStack(spacing: 6) {
            CoverImage(url: url, fallbackKeys: fallbackKeys, seed: title, size: size, corner: size / 2)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.primaryText)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .lineLimit(1)
            }
        }
        .frame(width: size + 16)
    }
}

// MARK: - 状态

/// 顶部数据磁贴：图标 + 数字 + 说明，点一下切换下面的分组。
struct StatTile: View {
    let icon: String
    let title: String
    let value: Int
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? tint : tint.opacity(0.7))
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(isSelected ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text("\(value)")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AppStyle.secondaryText : AppStyle.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(AppStyle.tertiaryText)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppStyle.secondaryText)
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct LoadingRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(AppStyle.accent)
            Text("加载中…")
                .font(.system(size: 13))
                .foregroundStyle(AppStyle.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - 胶囊标签

struct TagChip: View {
    let text: String
    var isSelected: Bool = false
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(isSelected ? Color.black : AppStyle.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? AppStyle.accent : AppStyle.surfaceHigh,
                        in: Capsule())
    }
}
