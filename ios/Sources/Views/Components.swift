import SwiftUI
import UIKit
import CoreImage

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

    // MARK: 🔴 v2.9.6：酷狗风格页面背景（顶部蓝色渐变 → 底部白）

    /// 页面顶部渐变的最深色。
    /// 酷狗首页顶部是**淡蓝**（不是饱和品牌蓝）—— 状态栏是深色文字，
    /// 用饱和蓝会看不清，所以这里取一个很浅的天蓝。
    static let pageGradientTop = dynamic(light: hex(0xC2DEFF), dark: hex(0x18293C))
    /// 渐变中段（过渡色），避免蓝→白断层太生硬。
    static let pageGradientMid = dynamic(light: hex(0xE7F2FF), dark: hex(0x101923))
    /// 渐变淡出后的目标色 —— 与页面底色一致，接缝看不出来。
    static let pageGradientBottom = dynamic(light: hex(0xF6F7F9), dark: hex(0x0E0E11))

    // MARK: 导航栏外观（UIKit 侧）

    /// 导航栏底色（UIKit 侧的 UIColor 版本，和 `pageGradientTop` 同值）。
    /// 用于 `UINavigationBarAppearance`。
    private static let navigationBarBackgroundUIColor = UIColor { trait in
        trait.userInterfaceStyle == .dark ? hex(0x18293C) : hex(0xC2DEFF)
    }

    /// 🔴 v2.9.6(修正)：App 启动时装一次导航栏外观 ——
    /// 背景刷成 `pageGradientTop` 同色，并把系统导航栏**自带的底部分隔线**（Hairline，
    /// 就是搜索/设置页顶栏那条黑线）通过 `shadowColor = .clear` 去掉。
    ///
    /// ⚠️ 必须在 `App.init()` 里调用（appearance 代理只对之后创建的导航栏生效），
    /// 并且不能用 `toolbarBackground(.hidden)` 来去黑线 —— 那会把导航栏的安全区
    /// 一并丢掉，滚动内容会顶到状态栏下面（已实测踩坑）。
    static func installNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = navigationBarBackgroundUIColor
        appearance.shadowColor = .clear
        appearance.shadowImage = UIImage()
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }
}

/// 🔴 v2.9.6：酷狗风格的顶部淡蓝 → 白色渐变带。
///
/// 酷狗首页顶部是**淡蓝 → 白色**的渐变：状态栏、顶部导航栏、搜索框那一带
/// 是淡蓝，往下渐渐淡成白色正文区。
///
/// 画在**滚动内容的底层**（`background(alignment: .top)`）：
/// - 画在底层 → 白卡片、白文字都保持原样，只有卡片之间的空隙透出淡蓝；
/// - 画在顶层 → 整片内容都被染蓝，文字和卡片全糊掉。
///
/// 而且因为它是内容的一部分，往上滑就会跟着滚走。
/// ⚠️ 这正是 v2.9.6 被用户吐槽"上滑蓝色渐变会消失"的原因。
/// 现在**页面主背景统一改用 `kugouPinnedTopFade`**（渐变挂在滚动容器背景上、钉在顶部不消失）；
/// 这里保留 `KugouTopFade` 仅作底层积木，别再直接挂到滚动内容上了。
struct KugouTopFade: View {
    /// 渐变带高度（`fill` 模式忽略此值）
    var height: CGFloat = 200
    /// true = 铺满所在容器的整个高度（用于固定顶栏那种"高度不定"的场景）
    var fill: Bool = false

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [
                AppStyle.pageGradientTop,
                AppStyle.pageGradientMid,
                AppStyle.pageGradientBottom,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        if fill {
            gradient.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            gradient.frame(height: height).frame(maxWidth: .infinity)
        }
    }
}

extension View {
    /// 🔴 v2.9.6：在**滚动内容底层**铺一条酷狗风格的淡蓝渐变带。
    ///
    /// 挂在滚动内容容器（LazyVStack / VStack）上，渐变会跟着内容一起滚走。
    func kugouTopFade(height: CGFloat = 200) -> some View {
        background(alignment: .top) {
            KugouTopFade(height: height)
        }
    }

    /// 🔴 v2.9.6：淡蓝渐变**铺满**当前容器（用于高度不定的固定顶栏）。
    ///
    /// 固定顶栏（比如「我的音乐」的账号卡片 + 板块滑块）高度随内容变，
    /// 用固定高度的渐变带会溢出到下面的列表上，所以这里改成铺满自身高度。
    func kugouTopFadeFill() -> some View {
        background {
            KugouTopFade(fill: true)
        }
    }

    /// 🔴 v2.9.6(修正)：把淡蓝渐变**固定在页面顶部**，上滑不消失。
    ///
    /// 之前的 `kugouTopFade` 把渐变挂在「滚动内容的底层」，内容一上滑渐变就跟着滚走
    ///（用户反馈"上滑蓝色渐变会消失"）。这个版本把渐变挂到**滚动容器
    /// （ScrollView / List / 页面根 VStack）自身的背景**上 —— 背景相对可视区域是固定的，
    /// 所以渐变钉在顶部、上滑不消失。
    ///
    /// 顶部一段 `height` 高的淡蓝→白色渐变带，下面整页铺 `pageGradientBottom`（=页面底色）
    /// 一直到屏幕底；渐变带末端色与页面底色相同，所以上蓝下白无缝衔接、不会露缝。
    /// 渐变带用 `ignoresSafeArea(edges: .top)` **从屏幕最顶端铺下来**（盖住状态栏/导航栏区域），
    /// 导航栏由 `AppStyle.installNavigationBarAppearance()` 刷成同色淡蓝，
    /// 颜色连成一片；渐变只影响背景层，不影响内容的安全区布局。
    /// 注意：`.ignoresSafeArea` 只加在 `background` 里的背景层上，
    /// **绝不能**加在整个视图上（会把内容顶到状态栏下面）。
    func kugouPinnedTopFade(height: CGFloat = 300) -> some View {
        background {
            // 整页底色先铺满（保证渐变带下方绝不会露出别的白，和页面底色完全一致），
            // 再把淡蓝→白色渐变带钉在顶部。渐变带末端色 = pageGradientBottom = 页面底色，
            // 所以顶部蓝和底部白无缝衔接，不会出现"上下颜色不一致"的接缝。
            AppStyle.pageGradientBottom
                .overlay(alignment: .top) {
                    KugouTopFade(height: height)
                }
                .ignoresSafeArea(edges: .top)
        }
    }

    /// 🔴 v2.9.6(修正)：导航栏的刷色**完全交给 `AppStyle.installNavigationBarAppearance()`**
    /// （App 启动时装一次的 UIKit appearance 代理），这里不再叠加任何 SwiftUI 修饰符。
    ///
    /// ⚠️ 踩坑记录（都实测过，别再走回头路）：
    /// - `toolbarBackground(.visible, 颜色)`：布局正常，但 SwiftUI 会用它自己生成的
    ///   外观覆盖 appearance 代理，系统自带的底部分隔线（黑线）会跟着出现；
    /// - `toolbarBackground(.hidden)`：黑线没了，但导航栏不再保留安全区，
    ///   滚动内容会顶到状态栏下面（主页固定 tab 行被内容盖住、设置页大标题和文字重叠）。
    /// - appearance 代理 + `shadowColor = .clear`：布局正常 + 没有黑线，两全其美。
    ///
    /// 各页面保留这个调用只是为了语义清晰（标记"这页导航栏要酷狗淡蓝"），
    /// 实际着色由全局 appearance 完成；若未来需要 per-page 差异，再在这里加修饰符。
    func kugouNavigationBarTint() -> some View {
        self
    }
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

    /// 🔴 播放页大封面专用（v2.5.41）：按 900px 解码 + **跳过共享缓存**。
    /// 共享缓存里通常躺的是列表页存的 180/300px 小图，直接复用会把 ~320pt 的
    /// 大封面放大成糊图（用户反馈"专辑图片模糊"）。高清图不回写缓存，
    /// 免得把小图挤掉后列表又得重新下载。
    static func downloadHiRes(_ url: URL) async -> UIImage? {
        await request(url, maxPixelSize: 900, useCache: false)
    }

    /// 🔴 v2.6.9：歌词页写真专用 —— 按原图分辨率解码，且**不写共享缓存**。
    /// 共享缓存上限 200 张，写真每张解码后约 4MB —— 写进去会把列表封面全挤掉，
    /// 而且锐化前后的两份还会各占一份内存。写真有自己的缓存（ArtistPhotoCache）。
    static func downloadPhoto(_ url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        await request(url, maxPixelSize: maxPixelSize, useCache: false)
    }

    private static func request(_ target: URL, maxPixelSize: CGFloat,
                                useCache: Bool = true) async -> UIImage? {
        if useCache, let cached = CoverCache.shared.image(for: target) {
            return cached
        }
        let key = target.absoluteString
        if let existing = inflight.existing(key) {
            return await existing.value
        }
        let task = Task<UIImage?, Never> {
            defer { inflight.remove(key) }
            return await performRequest(target, maxPixelSize: maxPixelSize, useCache: useCache)
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
    /// 另外 singerimg.kugou.com 在部分运营商网络下 HTTPS 全挂，自动加备用 CDN。
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
        // singerimg.kugou.com 在部分运营商下 HTTPS 全超时 —— 加 CDN 换域名兜底
        if orig.contains("singerimg.kugou.com") {
            let alt1 = orig.replacingOccurrences(of: "singerimg.kugou.com", with: "imge.kugou.com")
            if let u = URL(string: alt1) { urls.append(u) }
            let alt2 = orig.replacingOccurrences(of: "singerimg.kugou.com", with: "mobi.kugou.com")
            if let u = URL(string: alt2) { urls.append(u) }
        }
        // 酷狗 stdmusic 的 480 大图无水印；万一某张 480 不存在，回退 300（带水印也比占位图好）
        if orig.contains("/stdmusic/480/") {
            let small = orig.replacingOccurrences(of: "/stdmusic/480/", with: "/stdmusic/300/")
            if let u = URL(string: small) { urls.append(u) }
        }
        return urls
    }

    private static func performRequest(_ target: URL, maxPixelSize: CGFloat,
                                       useCache: Bool = true) async -> UIImage? {
        // 排队期间可能已被别的任务下载好
        if useCache, let cached = CoverCache.shared.image(for: target) {
            return cached
        }
        let urls = Self.candidateURLs(for: target)
        for url in urls {
            if let result = await downloadSingle(url, maxPixelSize: maxPixelSize) {
                // 命中后给所有候选 URL 都存一份，下次任何 scheme 进来都能命中
                if useCache { for u in urls { CoverCache.shared.store(result, for: u) } }
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

/// 🔴 v2.6.2：歌手写真内存缓存（按歌手名）。歌词页背景用 —— 歌手写真尺寸大，
/// 每次进歌词页重新下载既慢又费流量，缓存到内存里按歌手名复用。
///
/// 🔴 v2.6.8：改成存**一组**写真（轮播用），同一歌手缓存多张。
final class ArtistPhotoCache {
    static let shared = ArtistPhotoCache()
    private let cache = NSCache<NSString, NSArray>()

    // 🔴 v2.6.8：缓存按「歌手」存一组写真，内存占用不小（每张约 3~4MB 解码后），
    // 只缓存最近 2 个歌手（每个歌手 6 张 × 约 4MB），避免长期使用把内存吃满。
    private init() { cache.countLimit = 2 }

    func images(for name: String) -> [UIImage] {
        (cache.object(forKey: name as NSString) as? [UIImage]) ?? []
    }

    func store(_ images: [UIImage], for name: String) {
        guard !images.isEmpty else { return }
        cache.setObject(images as NSArray, forKey: name as NSString)
    }
}

/// 🔴 v2.6.2：歌手写真背景（歌词页）。
/// 取到写真就全屏铺底；取不到就整层不显示，由调用方原来的取色渐变兜底。
///
/// 🔴 v2.6.7：改用酷狗官方「歌手写真」图库（KugouClient.singerPhotoURLs），
/// 不再是歌手主页的小头像；并且**不做模糊**（用户要求"写真不要模糊显示出来"）。
/// 为保证歌词可读，用「上下加重的暗色渐变」压住照片，而不是把照片本身糊掉。
///
/// 🔴 v2.6.8：
/// ① 多张写真轮播（用户要求"要几张换着显示"）——取图库里 3 张，每 8 秒淡入下一张。
/// ② 背景层**不再撑大页面布局**：原来用 `.padding(-60)` 让照片出血，
///    但这会把父级 ZStack 撑到比屏幕大 120pt（歌词页"内容被挤出屏幕"的元凶）。
///    现在照片按容器尺寸铺满 + 外层 frame/clipped 收死。
///
/// 🔴 v2.6.9：清晰度修复（用户反馈"图片模糊，好像被放大了"）：
/// · 去掉多余的 1.18 倍缩放 —— 源图 750px 宽铺满 1125pt 屏本来就要放大 1.5 倍，
///   再叠 1.18 就变成 2.16 倍，画面糊（现在只放大 1.5 倍，可见宽度从 69% 恢复到 82%）。
/// · 解码上限从 1200 提到 1600 —— 之前按 1200 解码反而把 1334 高的原图又缩小了 10%。
/// · 加一道轻锐化（CISharpenLuminance），在**原图**上锐化比放大后再锐化有效。
/// · 写真不走共享封面缓存（每张 4MB，写进去会把列表封面全挤掉）。
struct ArtistPhotoBackdrop: View {
    let artist: String
    let title: String
    /// 🔴 v2.7.5：歌曲 hash —— 用它反查精确的 singerid 取写真，
    /// 避免"苏艺馨 Chency"这类带后缀的歌手名匹配不上（用户反馈取不到写真）。
    var hash: String = ""
    /// 已加载的写真（多张轮播）
    @State private var images: [UIImage] = []
    /// 当前显示第几张
    @State private var currentIndex = 0

    /// 轮播间隔（秒）
    private let rotateInterval: UInt64 = 8_000_000_000
    /// 🔴 v2.7.0：一次最多展示的写真张数（用户要求 6 张轮播；
    /// 每张解码后约 4MB，6 张 ≈ 24MB，所以歌手缓存只留最近 2 个）
    private let maxPhotos = 6

    var body: some View {
        ZStack {
            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    // 🔴 v2.6.8：用 scaleEffect 做出血，**不改变布局尺寸**。
                    // 之前用 padding(-60) 会把背景 ZStack 撑到比屏幕大 120pt，
                    // 歌词页内容因此被挤出屏幕。
                    // 🔴 v2.6.9：去掉多余的 1.18 倍缩放 —— 源图 750px 宽铺满
                    // 1125pt 的屏本来就要放大 1.5 倍，再叠 1.18 就成了"被放大"，
                    // 画面发虚（用户反馈"图片模糊，好像被放大了"）。
                    // 出血改由 .clipped() + 父层满尺寸保证，不再二次放大。
                    .clipped()
                    // 🔴 v2.6.7：不模糊了（用户要求写真清晰显示）。
                    // 可读性靠下面这层「上下加重」的暗色渐变来保证。
                    .overlay(
                        LinearGradient(colors: [.black.opacity(0.42),
                                                .black.opacity(0.18),
                                                .black.opacity(0.52)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .opacity(index == currentIndex ? 1 : 0)
            }
        }
        // 背景层严格等于容器尺寸，不允许溢出影响页面布局
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // 纯背景层，绝不能吃掉歌词滚动和点击
        .allowsHitTesting(false)
        // 🔴 v2.6.4：id 带上歌名 —— 同一歌手连唱多首时也要重新取图
        .task(id: artist + "|" + title + "|" + hash) { await load() }
        // 🔴 v2.6.8：写真轮播（图片数量变化时重启计时）
        .task(id: images.count) { await rotate() }
    }

    // MARK: 取图

    private func load() async {
        var key = artist.trimmingCharacters(in: .whitespaces)
        var titleKey = title
        // 🔴 v2.8.3：播放队列里的歌可能还没补上歌手名（歌单详情页的补齐是后台异步，
        // 队列是值拷贝）。artist 为空时用 hash 反查一次兜底 —— 别直接放弃写真。
        if key.isEmpty, !hash.isEmpty,
           let info = await KugouClient.shared.songInfo(hash: hash) {
            key = info.singername
            if !info.songname.isEmpty { titleKey = info.songname }
        }
        guard !key.isEmpty else { images = []; return }
        images = []
        currentIndex = 0

        // 内存缓存命中：直接播
        let cached = ArtistPhotoCache.shared.images(for: key)
        if !cached.isEmpty {
            images = cached
            return
        }

        // 🔴 v2.6.8：取多张 —— 优先酷狗「歌手写真」图库（几十~几百张），
        // 均匀抽几张（避免连着取到风格雷同的图）。
        var picked: [URL] = []
        let gallery = await KugouClient.shared.singerPhotoURLs(name: key, title: titleKey, hash: hash)
        if !gallery.isEmpty {
            picked = Self.spread(gallery, count: maxPhotos)
        }
        if picked.isEmpty,
           let fallback = await KugouClient.shared.artistPhotoStrict(name: key, title: titleKey) {
            picked = [fallback]
        }
        guard !picked.isEmpty else {
            Log.info("歌词写真", "没取到歌手写真：\(key)")
            return
        }

        // 第一张先显示，其余依次补进来（不阻塞首屏）
        var loaded: [UIImage] = []
        // 一个 CIContext 处理全部写真（创建一次即可，避免每张都重建）
        let context = CIContext(options: nil)
        if let first = await CoverLoader.downloadPhoto(picked[0], maxPixelSize: Self.decodeMaxPixel) {
            let sharp = Self.sharpened(first, context: context)
            loaded.append(sharp)
            images = loaded
        }
        for url in picked.dropFirst() {
            guard let ui = await CoverLoader.downloadPhoto(url, maxPixelSize: Self.decodeMaxPixel) else { continue }
            loaded.append(Self.sharpened(ui, context: context))
            images = loaded
        }
        ArtistPhotoCache.shared.store(loaded, for: key)
    }

    /// 🔴 v2.6.9：解码上限。
    /// 酷狗写真原图是 750×1334，之前按 1200 解码会被**再缩小 10%**（白白丢细节）；
    /// 按 1600 解码则保持原图不缩不放，清晰度最大化。
    private static let decodeMaxPixel: CGFloat = 1600

    /// 轻微锐化 —— 源图 750px 宽要铺满 1125pt 宽的屏，放大 1.5 倍后边缘发软；
    /// 先在**原图**上做一道轻锐化，"糊"的感觉会明显减轻（比放大后再锐化有效）。
    static func sharpened(_ image: UIImage, context: CIContext, amount: Float = 0.35) -> UIImage {
        guard let ci = CIImage(image: image),
              let filter = CIFilter(name: "CISharpenLuminance") else { return image }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(amount, forKey: "inputSharpness")
        guard let output = filter.outputImage else { return image }
        guard let cg = context.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: cg)
    }

    /// 从图库里均匀抽 count 张（首尾都覆盖，风格差异大一点）
    private static func spread(_ urls: [URL], count: Int) -> [URL] {
        guard urls.count > count else { return urls }
        var result: [URL] = []
        let step = Double(urls.count) / Double(count)
        for i in 0..<count {
            let idx = min(urls.count - 1, Int((Double(i) * step).rounded()))
            let url = urls[idx]
            if !result.contains(url) { result.append(url) }
        }
        return result
    }

    // MARK: 轮播

    /// 每 8 秒淡入下一张写真；暂停/离开页面时随 task 取消而停止。
    private func rotate() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: rotateInterval)
            } catch {
                return   // 被取消
            }
            guard !Task.isCancelled, images.count > 1 else { return }
            withAnimation(.easeInOut(duration: 1.2)) {
                currentIndex = (currentIndex + 1) % images.count
            }
        }
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

// MARK: - 正在播放的动态声波指示器

/// 三根错相位跳动的竖条：播放时循环跳动，暂停时平滑收拢静止。
struct PlayingBarsIndicator: View {
    let isPlaying: Bool
    var tint: Color = AppStyle.onAccent
    /// 整体高度（也是圆内可用高度）
    var height: CGFloat = 12

    var body: some View {
        HStack(spacing: height * 0.18) {
            // 三根竖条用不同周期（而非 delay），天然错相位，
            // 避免 repeatForever + delay 组合在部分 SwiftUI 版本下不启动、导致「不动」。
            Bar(isPlaying: isPlaying, tint: tint, maxHeight: height, speed: 0.5)
            Bar(isPlaying: isPlaying, tint: tint, maxHeight: height, speed: 0.72)
            Bar(isPlaying: isPlaying, tint: tint, maxHeight: height, speed: 0.94)
        }
        .frame(height: height)
    }

    private struct Bar: View {
        let isPlaying: Bool
        let tint: Color
        let maxHeight: CGFloat
        let speed: Double
        @State private var up = false

        private var minHeight: CGFloat { maxHeight * 0.32 }

        var body: some View {
            Capsule()
                .fill(tint)
                .frame(width: max(1.5, maxHeight * 0.18),
                       height: up ? maxHeight : minHeight)
                .animation(
                    isPlaying
                        ? .easeInOut(duration: speed).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.18),
                    value: up
                )
                .onAppear { up = isPlaying }
                .onChange(of: isPlaying) { playing in
                    up = playing
                }
        }
    }
}

// MARK: - 歌曲行

struct SongRow: View {
    let song: Song
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var showsCover: Bool = true
    /// 歌手名字号（歌单页要求 11pt，其它列表默认 13pt）
    var artistFontSize: CGFloat = 13
    var trailing: AnyView?

    init(song: Song,
         isCurrent: Bool = false,
         isPlaying: Bool = false,
         showsCover: Bool = true,
         artistFontSize: CGFloat = 13,
         trailing: AnyView? = nil) {
        self.song = song
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.showsCover = showsCover
        self.artistFontSize = artistFontSize
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            if showsCover {
                CoverImage(url: song.artworkURL,
                           fallbackKeys: song.coverFallbackKeys,
                           seed: "\(song.artist)-\(song.title)",
                           size: 50)
                .overlay(alignment: .bottomTrailing) {
                    // 只有「当前播放的这首歌」才显示角标；其余歌曲一律不显示。
                    // 播放时声波跳动，暂停时收拢静止（仍保留标识，表示这是当前曲）。
                    if isCurrent {
                        PlayingBarsIndicator(isPlaying: isPlaying)
                            .padding(4)
                            .background(AppStyle.accent, in: Circle())
                            .offset(x: 4, y: 4)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(song.cleanTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isCurrent ? AppStyle.accent : AppStyle.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if song.source == .local {
                        Text("本地")
                            .font(.system(size: 9))
                            .foregroundStyle(AppStyle.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(AppStyle.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                            .fixedSize()
                    }
                }
                Text(song.artist)
                    .font(.system(size: artistFontSize))
                    .foregroundStyle(AppStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)

            Spacer(minLength: 0)

            if let trailing {
                trailing
            } else {
                RowTrailingButtons(song: song)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// 行尾：收藏 + 下载（两按钮，去掉 ⋯ 给歌名腾空间）
private struct RowTrailingButtons: View {
    let song: Song
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        HStack(spacing: 4) {
            Button {
                _ = library.toggleFavorite(song)
                Haptics.light()
            } label: {
                Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart")
                    .font(.system(size: 16))
                    .foregroundStyle(library.isFavorite(song) ? AppStyle.like : AppStyle.tertiaryText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Button {
                if song.isRemote {
                    Haptics.light()
                    Task { _ = try? await downloads.download(song) }
                }
            } label: {
                Image(systemName: song.source == .local ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(song.source == .local ? AppStyle.tertiaryText.opacity(0.4) : AppStyle.tertiaryText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(song.source == .local)
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
        && lhs.artistFontSize == rhs.artistFontSize
    }
}

// MARK: - 歌曲操作菜单

/// 列表项通用的操作菜单（🔴 v2.8.1：只保留「添加到酷狗歌单」，移除本地「保存到歌单」）。
struct SongMenu: ViewModifier {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var kugouAuth = KugouAuth.shared
    let song: Song
    /// 🔴 v2.6.4：把歌曲存进酷狗云歌单
    @State private var showKugouPicker = false

    func body(content: Content) -> some View {
        content
            // 🔴 v2.8.1：长按菜单只保留「添加到酷狗歌单」——
            // 下一首播放 / 加入播放列表 / 收藏 / 下载 在播放页都有入口；
            // 本地「保存到歌单」已移除，统一走酷狗云歌单（需求：只保留添加到酷狗歌单）。
            // 「移除」由歌单详情页自己的 contextMenu 提供（酷狗歌单=移出歌单，本地歌单=从歌单移除）。
            .contextMenu {
                // 🔴 v2.6.4：存进酷狗云歌单（需要已登录 + 歌曲有酷狗 hash）
                if kugouAuth.isLoggedIn && !song.kugouHash.isEmpty {
                    Button {
                        // 延后一拍再弹 sheet —— contextMenu 正在关闭动画里，
                        // 立刻 present 会撞上「菜单正在消失」而弹不出来
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showKugouPicker = true
                        }
                    } label: {
                        Label("添加到酷狗歌单", systemImage: "icloud.and.arrow.up")
                    }
                } else if !song.kugouHash.isEmpty {
                    // 未登录时给个提示入口，点一下弹扫码登录
                    Button {
                        NotificationCenter.default.post(name: .auroraShowKugouLogin, object: nil)
                    } label: {
                        Label("登录后添加到酷狗歌单", systemImage: "icloud.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showKugouPicker) {
                KugouPlaylistPicker(songs: [song], title: "添加到酷狗歌单")
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
/// iOS 16+ 用 Layout 协议 FlowLayout，iOS 15 fallback 到 LegacyFlowChips。
struct FlowChips: View {
    let items: [String]
    var action: (String) -> Void

    var body: some View {
        if #available(iOS 16.0, *) {
            FlowLayout(spacing: 8) { chips }
        } else {
            LegacyFlowChips(items: items, action: action)
        }
    }

    @ViewBuilder
    private var chips: some View {
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

// FlowLayout 已移到 NavigationCompatibility.swift，iOS 16+ @available 包裹

// MARK: - 全局导航通知

extension Notification.Name {
    /// 外部请求导航到歌手详情页，object = Song
    static let navigateToArtist = Notification.Name("aurora.navigateToArtist")
}

// MARK: - MarqueeText 跑马灯（歌名太长时横向滚动，短则正常显示）

/// 简单可靠的跑马灯：
/// - 外层 GeometryReader 读容器宽度（只有 1 个，不会嵌套出 0）
/// - 内部 Text + fixedSize 自然撑开，不压缩
/// - 用 UIFont.boundingRect 提前算文本宽度（比 PreferenceKey 可靠）
/// - 只有 scroll 状态时才注入第二份文本循环
struct MarqueeText: View {
    let text: String
    var size: CGFloat = 15
    var weight: Font.Weight = .medium
    var color: Color = AppStyle.primaryText

    @State private var containerW: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let spacing: CGFloat = 40

    private var uiFont: UIFont {
        UIFont.systemFont(ofSize: size, weight: {
            switch weight {
            case .bold: return .bold
            case .semibold: return .semibold
            case .medium: return .medium
            case .light: return .light
            default: return .regular
            }
        }())
    }

    private var font: Font { .system(size: size, weight: weight) }

    /// 用 UIFont.boundingRect 算文本自然宽度，不依赖 SwiftUI layout
    private var textW: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: uiFont]
        let s = text as NSString
        let rect = s.boundingRect(
            with: CGSize(width: .greatestFiniteMagnitude, height: uiFont.lineHeight),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        )
        return max(10, ceil(rect.width))
    }

    private var needScroll: Bool { textW > containerW + 1 }
    private var duration: Double { min(max(Double(textW) / 40, 4), 12) }

    var body: some View {
        GeometryReader { proxy in
            // 容器宽度更新
            let w = proxy.size.width
            if w != containerW {
                // 必须异步，不能在 body 里直接改 state
                DispatchQueue.main.async {
                    containerW = w
                    // 容器变了 → 重启滚动
                    offset = 0
                    if textW > w + 1 {
                        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                            offset = -(textW + spacing)
                        }
                    }
                }
            }

            return ZStack(alignment: .leading) {
                // 第一份文本
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: needScroll ? offset : 0)

                // 第二份（循环用）
                if needScroll {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: textW + spacing + offset)
                }
            }
            .clipped()
        }
        .frame(height: uiFont.lineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)   // ← GeometryReader 从父容器拿宽度
        .onAppear {
            // 等一帧让 GeometryReader 先拿到宽度
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if containerW > 0 && textW > containerW + 1 {
                    offset = 0
                    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                        offset = -(textW + spacing)
                    }
                }
            }
        }
        .onChange(of: text) { _ in
            offset = 0
            if containerW > 0 && textW > containerW + 1 {
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    offset = -(textW + spacing)
                }
            }
        }
    }
}

// MARK: - 酷狗音乐品牌登录图标（官方 Logo：蓝底白色圆环 K）

/// 酷狗登录入口专用图标，替代通用 SF Symbol（music.mic.*）。
/// 使用 Assets 里的官方 Logo 图（KugouLogo.imageset，用户提供）。
/// style 仅保留 API 兼容（早期是自绘绿圆话筒的两种样式），现在两种样式渲染相同。
struct KugouLogoIcon: View {
    enum Style { case filled, ring }

    var size: CGFloat = 24
    var style: Style = .filled

    var body: some View {
        Image("KugouLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            // 官方图标本身是方角，圆一点点更贴合 App 内圆角语言
            .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
            .accessibilityLabel("酷狗音乐")
    }
}
