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
    /// 非正方形显示区域：传了就铺满，默认回退到 size×size
    var displayWidth: CGFloat? = nil
    var displayHeight: CGFloat? = nil

    @State private var image: UIImage?
    @State private var resolved: URL?

    private var effectiveURL: URL? {
        url ?? resolved ?? CoverResolver.shared.firstAvailable(fallbackKeys)
    }

    private var w: CGFloat { displayWidth ?? size }
    private var h: CGFloat { displayHeight ?? size }

    var body: some View {
        ZStack {
            // 兜底统一纯白背景
            LinearGradient(colors: [Color(white: 0.97), Color(white: 0.93)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: w, height: h)
                    .clipped()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: min(w, h) * 0.32, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: w, height: h)
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: taskKey) { await load() }
    }

    private var taskKey: String {
        // 只能用外部输入做 key。绝不能依赖 resolve 后回填到登记表的地址：
        // 榜单一次批量补封面会持续改登记表，导致所有行 key 集体变化、
        // 正在进行的请求被集体取消再重发，形成满屏「已取消」的请求风暴。
        if let url {
            return url.absoluteString + "|" + size.description
        }
        return "k:" + fallbackKeys.joined(separator: ",") + "|" + size.description
    }

    private func load() async {
        // 直连地址和登记表都没有时，尝试按 key 联网补一次（al:专辑id）。
        var target = effectiveURL
        if target == nil, !fallbackKeys.isEmpty {
            target = await CoverResolver.shared.resolveCover(for: fallbackKeys)
        }
        guard let target else {
            image = nil
            return
        }
        if target.isFileURL, let data = try? Data(contentsOf: target) {
            image = Self.decodeImageData(data, maxPixelSize: size * 3)
            return
        }
        if let loaded = await CoverLoader.download(target, maxPixelSize: size * 3) {
            image = loaded
        }
    }

    /// 在后台线程用 ImageIO 解码图片数据，避免主线程解码阻塞 120Hz。
    /// `maxPixelSize` 是缩略图的最长边像素（传 size*3 留出 3x 屏幕的清晰度）。
    static func decodeImageData(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            // 兜底：直接用 UIImage 构造（SwiftUI 渲染时才真正解码，但保证有图）
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

/// 封面图片下载。优先 https：设备上 ATS 会拦明文 http（Info.plist 放行了也没用），
/// 所以 http 地址一律先换 https 试，https 不通再回头试原地址。
enum CoverLoader {
    // 同一时刻对同一 URL 的并发请求合并成一个任务，
    // 避免榜单/歌单几十行同时为同一张图发请求。
    // 注意：锁全部收在这个同步类内部——NSLock.lock/unlock 在 async 函数里
    // 直接调用会产生编译器警告（CI 零警告即失败）。
    private static let inflight = InflightTasks()

    static func download(_ url: URL, maxPixelSize: CGFloat = 300) async -> UIImage? {
        await request(url, maxPixelSize: maxPixelSize)
    }

    private static func request(_ target: URL, maxPixelSize: CGFloat) async -> UIImage? {
        if let cached = CoverCache.shared.image(for: target) {
            return cached
        }
        let key = target.absoluteString
        if let existing = inflight.existing(key) {
            return await existing.value
        }
        let task = Task<UIImage?, Never> {
            defer { inflight.remove(key) }
            return await performRequest(target, maxPixelSize: maxPixelSize)
        }
        inflight.insert(key, task)
        return await task.value
    }

    /// 在途请求登记表（所有方法都是同步的，锁不暴露到 async 上下文）。
    private final class InflightTasks {
        private var map: [String: Task<UIImage?, Never>] = [:]
        private let lock = NSLock()

        func existing(_ key: String) -> Task<UIImage?, Never>? {
            lock.lock(); defer { lock.unlock() }
            return map[key]
        }

        func insert(_ key: String, _ task: Task<UIImage?, Never>) {
            lock.lock(); map[key] = task; lock.unlock()
        }

        func remove(_ key: String) {
            lock.lock(); map[key] = nil; lock.unlock()
        }
    }

    /// 对任何 URL，都同时生成 https 和 http 两个候选地址，按「非 http 优先」排列。
    /// 这样无论 API 给的是 http:// 还是 https://，都有另一个 protocol 兜底。
    private static func candidateURLs(for target: URL) -> [URL] {
        let orig = target.absoluteString
        var urls: [URL] = [target]
        if orig.hasPrefix("http://") {
            let secure = "https://" + orig.dropFirst("http://".count)
            if let u = URL(string: secure) { urls.insert(u, at: 0) }
        } else if orig.hasPrefix("https://") {
            let insecure = "http://" + orig.dropFirst("https://".count)
            if let u = URL(string: insecure) { urls.append(u) }
        }
        return urls
    }

    private static func performRequest(_ target: URL, maxPixelSize: CGFloat) async -> UIImage? {
        // 排队期间可能已被别的任务下载好
        if let cached = CoverCache.shared.image(for: target) {
            return cached
        }
        let urls = Self.candidateURLs(for: target)
        for url in urls {
            if let result = await downloadSingle(url, maxPixelSize: maxPixelSize) {
                // 命中后给所有候选 URL 都存一份，下次任何 scheme 进来都能命中
                for u in urls { CoverCache.shared.store(result, for: u) }
                return result
            }
        }
        Log.warn("封面", "所有候选 URL 都失败：\(urls.map { $0.absoluteString }.joined(separator: " | "))")
        return nil
    }

    /// 单 URL 下载：内部 request 逻辑抽取复用。
    private static func downloadSingle(_ target: URL, maxPixelSize: CGFloat) async -> UIImage? {
        var request = URLRequest(url: target)
        request.timeoutInterval = 10
        request.setValue("AuroraMusic/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                Log.error("封面", "加载失败 HTTP \(code) / \(data.count) 字节 <- \(target.absoluteString)")
                return nil
            }
            guard let loaded = CoverImage.decodeImageData(data, maxPixelSize: maxPixelSize) else {
                return nil
            }
            CoverCache.shared.store(loaded, for: target)
            Log.info("封面", "✓ \(data.count)B \(target.scheme!)/\(target.host ?? "?")")
            return loaded
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError {
                return nil
            }
            Log.error("封面", "请求出错：\(error.localizedDescription) <- \(target.absoluteString)")
            return nil
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
                           fallbackKeys: song.coverFallbackKeys,
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
                // 歌手名：带箭头提示可点（但点击事件交给外层 NavigationLink）
                HStack(spacing: 4) {
                    Text(song.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let trailing {
                trailing
            } else {
                RowTrailingButtons(song: song)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

/// 行尾：收藏 + 下载 + 更多（三按钮并列，不再藏菜单）
private struct RowTrailingButtons: View {
    let song: Song
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        HStack(spacing: 10) {
            // 收藏
            Button {
                _ = library.toggleFavorite(song)
                Haptics.light()
            } label: {
                Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart")
                    .font(.system(size: 17))
                    .foregroundStyle(library.isFavorite(song) ? AppStyle.like : AppStyle.tertiaryText)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            // 下载（本地歌变灰禁用）
            Button {
                if song.isRemote {
                    Haptics.light()
                    Task { _ = try? await downloads.download(song) }
                }
            } label: {
                Image(systemName: song.source == .local ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(song.source == .local ? AppStyle.tertiaryText.opacity(0.4) : AppStyle.tertiaryText)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(song.source == .local)

            // 更多菜单（歌手主页 + 分享）
            Menu {
                Button {
                    NotificationCenter.default.post(name: .navigateToArtist, object: song)
                } label: {
                    Label("查看歌手", systemImage: "person")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
    }
}

/// 让 SongRow 支持 .equatable() —— 列表滚动时只有 song.id / isCurrent / isPlaying / showsCover 变了才重建 Cell。
/// trailing 是 AnyView 不走等式比较（trailing 频繁变化本身就是信号，说明 Cell 应该重建）。
extension SongRow: Equatable {
    static func == (lhs: SongRow, rhs: SongRow) -> Bool {
        lhs.song.id == rhs.song.id
        && lhs.isCurrent == rhs.isCurrent
        && lhs.isPlaying == rhs.isPlaying
        && lhs.showsCover == rhs.showsCover
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
            if width > 0 {
                CoverImage(url: playlist.coverURL,
                           fallbackKeys: [playlist.id],
                           seed: playlist.name,
                           size: width,
                           corner: 10)
            } else {
                // Grid 自适应：正方形封面
                GeometryReader { geo in
                    CoverImage(url: playlist.coverURL,
                               fallbackKeys: [playlist.id],
                               seed: playlist.name,
                               size: geo.size.width,
                               corner: 10)
                }
                .aspectRatio(1, contentMode: .fit)
            }
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
        .frame(maxWidth: width > 0 ? width : .infinity, alignment: .leading)
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

/// 自动换行的胶囊标签流（搜索历史 / 热门搜索用）。
/// 基于 iOS 16 的 Layout 协议做简易流式排版。
struct FlowChips: View {
    let items: [String]
    var action: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button {
                    Haptics.light()
                    action(item)
                } label: {
                    Text(item)
                        .font(.system(size: 13))
                        .foregroundStyle(AppStyle.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AppStyle.surface, in: Capsule())
                        .overlay(Capsule().stroke(AppStyle.stroke, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 全局导航通知

extension Notification.Name {
    /// 外部请求导航到歌手详情页，object = Song
    static let navigateToArtist = Notification.Name("aurora.navigateToArtist")
}
