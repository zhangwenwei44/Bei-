import SwiftUI
import UIKit

/// 全局配色。以酷狗音乐的蓝为主色，浅色下蓝白相间。
///
/// 所有颜色都通过 `UIColor` 的 trait 闭包做成自适应的：
/// 之前这里是写死的 `Color.white` / 近黑底，所以整个 App 只能走深色。
/// 改成语义化的自适应色之后，210 处 `AppStyle.` 引用会自动跟着系统外观切换，
/// 不用逐个视图去改。
enum AppStyle {
    /// 按当前外观取值。用 UIColor 闭包而不是 `Color.primary`，
    /// 是因为需要在浅/深两套里精确指定品牌色而不是跟随系统默认。
    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    private static func hex(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }

    /// 酷狗品牌蓝 #2CA2F9
    static let accent = dynamic(light: hex(0x2CA2F9), dark: hex(0x3EA9FF))
    /// 强调色上的文字。蓝底上用白字，深色模式下也保持白字以保证对比度
    static let onAccent = Color.white

    /// 页面底色
    static let background = dynamic(light: hex(0xF6F7F9), dark: hex(0x0E0E11))
    /// 卡片底色
    static let surface = dynamic(light: hex(0xFFFFFF), dark: hex(0x1C1C1F))
    /// 卡片上的次级块（按钮底、分隔块）
    static let surfaceHigh = dynamic(light: hex(0xEDF0F4), dark: hex(0x2A2A2E))
    /// 卡片描边，浅色下没有阴影时靠它分隔层次
    static let stroke = dynamic(light: hex(0xE3E6EB), dark: hex(0x3A3A3F))

    static let like = dynamic(light: hex(0xFF4D67), dark: hex(0xFF5C73))
    static let gold = dynamic(light: hex(0xF5A623), dark: hex(0xFFC043))

    static let primaryText = dynamic(light: hex(0x14181F), dark: hex(0xFFFFFF))
    static let secondaryText = dynamic(light: hex(0x5B6472), dark: hex(0xFFFFFF).withAlphaComponent(0.62))
    static let tertiaryText = dynamic(light: hex(0x98A1AF), dark: hex(0xFFFFFF).withAlphaComponent(0.38))
}

/// 主题模式。
enum ThemeMode: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 全局主题偏好的存取。改动后所有界面自动跟随。
enum ThemeSettings {
    private static let key = "aurora.themeMode"

    static var mode: ThemeMode {
        get {
            let raw = UserDefaults.standard.string(forKey: key)
            return raw.flatMap { ThemeMode(rawValue: $0) } ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
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
            Log.warn("封面", "「\(seed)」没有任何可用地址")
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
        // 酷狗图床在没有 Referer 时会 403
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, let loaded = UIImage(data: data) else {
                Log.error("封面", "「\(seed)」加载失败 HTTP \(code) / \(data.count) 字节 <- \(target.absoluteString)")
                return
            }
            CoverCache.shared.store(loaded, for: target)
            image = loaded
        } catch {
            Log.error("封面", "「\(seed)」请求出错：\(error.localizedDescription) <- \(target.absoluteString)")
        }
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
                           fallbackKeys: song.kugouHash.isEmpty ? [] : ["kg:\(song.kugouHash)"],
                           seed: "\(song.artist)-\(song.title)",
                           size: 44)
                .overlay(alignment: .bottomTrailing) {
                    if isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppStyle.onAccent)
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
                // 之前 gate 在 !library.playlists.isEmpty，导致一个歌单都没有时
                // 根本无法从歌曲菜单加歌，新建出来的歌单永远是空的
                Menu("添加到歌单") {
                    if library.playlists.isEmpty {
                        Text("还没有歌单")
                    }
                    ForEach(library.playlists) { playlist in
                        Button(playlist.name) { library.add(song, toPlaylist: playlist.id) }
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
            .foregroundStyle(isSelected ? AppStyle.onAccent : AppStyle.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? AppStyle.accent : AppStyle.surfaceHigh,
                        in: Capsule())
    }
}
