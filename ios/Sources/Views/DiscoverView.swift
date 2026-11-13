import SwiftUI
import UIKit

/// 发现页（新版）。Tab 栏 → 搜索框 → 2×2 宫格卡片 → 心情问候 + 歌曲列表 → 热门榜单。
struct DiscoverView: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var kugouAuth = KugouAuth.shared
    /// 🔴 v2.9.11：云账号（=管理员）登录后，主页右上角酷狗账号上方显示「管理员」标识
    @ObservedObject private var cloud = CloudAccount.shared
    @State private var feed = DiscoverFeed()
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// 🔴 2026-11-12：冷启动「一个内容都没拿到」时的自动补试次数（最多 2 轮）。
    @State private var autoRetryCount = 0
    @State private var guessSongs: [Song] = []
    /// 🔴 2026-11-13：猜你喜欢的「备用池」——去重后不足 30 首时从这里补齐，
    /// 里面全是酷狗真实榜单数据，绝不再用「每日推荐」那一批。
    @State private var guessPool: [Song] = []
    @State private var isLoadingGuess = false
    @State private var dailySongs: [Song] = []
    @State private var hotArtists: [Artist] = []
    /// 🔴 2026-11-09：新增「歌手」Tab —— 全部歌手（首页热门 + 继续分页补齐），
    /// 按英文名/拼音首字母分组 A–Z，右侧字母条快速定位。
    @State private var allArtists: [Artist] = []
    @State private var isLoadingArtists = false
    @State private var artistsLoaded = false
    /// 🔴 2026-11-12：歌手 Tab 改成「滚到底再加载下一批」，不再进 Tab 就翻完 25 页。
    @State private var artistPage = 0
    @State private var hasMoreArtists = true
    /// 🔴 2026-11-12：连续「整批都是重复歌手」的次数；连续 2 批才判定到底，
    ///    避免单次网络抖动 / 翻页偶发重复就提前结束（只显示 80 位的元凶之一）。
    @State private var artistEmptyStreak = 0
    @State private var isLoadingMoreArtists = false
    /// 🔴 2026-11-12 第三轮：歌手分组结果缓存。
    ///    `artistGroups` 原来是 computed property，页面每次 body 重算都会对
    ///    【全部 1000+ 位歌手】重新做字典分组 + 组内排序，滚动时累积成主线程卡顿。
    ///    现在只在数据 / 搜索词变化时算一次，body 只读缓存。
    @State private var artistGroupsCache: [ArtistGroup] = []
    @State private var filteredArtistGroupsCache: [ArtistGroup] = []
    /// 后台自动补齐任务只跑一条，切 Tab 回来时恢复而不重复起任务。
    @State private var artistAutoLoading = false
    /// 🔴 2026-11-09：歌手 Tab 的搜索框只过滤本页已加载的歌手，不跳全局搜索。
    @State private var artistQuery = ""
    // 🔴 v2.9.17：热门歌手专辑板块数据（歌手 + 他的一张专辑），从 hotArtists 现拉。
    @State private var artistAlbums: [ArtistAlbum] = []
    @State private var playingArtistID: String?
    @State private var recommendedPlaylists: [Playlist] = []
    @State private var squarePage = 1
    @State private var squareTotal = 0
    @State private var isLoadingMore = false
    @State private var selectedTab: DiscoverTab = .recommend
    @State private var pendingArtist: Artist?

    // 🔴 2026-11-12：横幅轮播的 @State / Timer 已抽到独立子视图 AdBannerCarousel。
    //    挂在整页上时，每 4 秒一次 withAnimation 都会让 DiscoverView 整页 body
    //    重算（十几个推荐板块 + 歌手 A–Z 全量分组），是主页偶发卡死的主因之一。
    // 🔴 2026-11-11：榜单卡片背景的 3 秒轮播已删除 —— 每轮换 url 都强制重建
    //    CoverImage（.id 变化 → @State 清空 → .task 重新联网），弱网下新图根本来不及
    //    加载就又换下一张，用户看到的永远是一片灰底 + 模糊，也就是「图片显示不出来 /
    //    被毛玻璃盖住」。现在固定用该榜第 1 首歌的封面，与标题图标、第 1 行小封面
    //    同源，缓存必命中，打开即显示。

    // 歌单页搜索（搜索歌单而不是歌曲）
    @State private var playlistQuery = ""
    @State private var playlistSearchResults: [Playlist] = []
    @State private var playlistSearchTotal = 0
    @State private var playlistSearchPage = 1
    @State private var isSearchingPlaylists = false
    @State private var playlistSearchExhausted = false

    // 榜单页：每个榜单的前 3 首预览（rankID → 歌曲）
    @State private var rankPreviewSongs: [String: [Song]] = [:]
    /// 顶部宫格横翻页码
    @State private var rankCardPage = 0

    // 三个新推荐板块
    @State private var ktvSongs: [Song] = []
    @State private var classicSongs: [Song] = []
    /// 🔴 v2.9.7(二)：「DJ推荐」板块数据池（经典推荐下面新加的板块）
    @State private var djSongs: [Song] = []
    @State private var newSongs: [Song] = []
    /// 🔴 2026-11-11：新歌推荐独立加载，防重入（下拉刷新与首屏 task 可能同时发起）。
    @State private var isLoadingNewSongs = false
    /// 🔴 v2.9.6：「至臻音质」主题歌单的歌曲（供「歌单推荐」大卡使用）
    @State private var hallSongs: [Song] = []

    /// 🔴 2026-11-13：骨架屏的「延迟许可」。
    /// 冷启动 0.4 秒内数据就回来时根本不显示骨架，避免闪一下灰块；
    /// 只有真正等得久（且本机没有任何快照）才允许出现。
    @State private var skeletonAllowed = false

    /// 🔴 2026-11-13：**启动即有内容**。
    /// 从本地快照同步恢复首屏数据（内存缓存，只有进程首次读盘，<10ms）。
    /// 这样 `feed.isEmpty == false`，启动时不会命中 `FeedSkeleton()`；
    /// 随后 `.task` 里的 `load(force: true)` 在后台静默刷新，界面不会空窗。
    init() {
        let cached = DiscoverFeedCache.shared.load()
        _feed = State(initialValue: cached?.feed ?? DiscoverFeed())
        _guessSongs = State(initialValue: cached?.guessSongs ?? [])
        _guessPool = State(initialValue: cached?.guessPool ?? [])
        _dailySongs = State(initialValue: cached?.dailySongs ?? [])
        _dailyPick = State(initialValue: cached.flatMap { $0.dailyPick })
        _guessPick = State(initialValue: cached.flatMap { $0.guessPick })
        _hotArtists = State(initialValue: cached?.hotArtists ?? [])
        _recommendedPlaylists = State(initialValue: cached?.recommendedPlaylists ?? [])
        _ktvSongs = State(initialValue: cached?.ktvSongs ?? [])
        _classicSongs = State(initialValue: cached?.classicSongs ?? [])
        _djSongs = State(initialValue: cached?.djSongs ?? [])
        _newSongs = State(initialValue: cached?.newSongs ?? [])
        _hallSongs = State(initialValue: cached?.hallSongs ?? [])
    }

    /// 榜单 Tab 展示的榜单（按酷狗「排行榜」页顺序排列）。
    /// 截图里 15 个榜：未音原创榜 / AI音乐榜 / 华语流行音乐原创榜 / 原创音乐榜
    /// 这 4 个 2026 新榜酷狗公开接口还没放出来（rank/list 只有 56 个旧榜），
    /// 等接口放出来再把 rankid 补这里即可。
    /// 旧白名单里的 18016(新歌推荐榜)/21845(华语金曲榜)/96069(会员热歌榜) 已从
    /// rank/list 下线，一并移除；真正的会员热歌榜是 35811。
    static let rankOrder: [String] = [
        "49225",  // 80后热歌榜
        "49223",  // 90后热歌榜
        "49224",  // 00后热歌榜
        "35811",  // 会员热歌榜
        "33166",  // 欧美金曲榜
        "33163",  // 影视金曲榜
        "65234",  // 儿歌榜
        "60170",  // 闽南语榜
        "46910",  // 综艺新歌榜
        "30972",  // 酷狗音乐人原创榜
        "37361",  // 酷狗识曲榜
        "82831",  // 网络热歌榜
        "6666",   // 飙升榜
        "52144",  // 短视频热歌榜
        "24971",  // DJ热歌榜
        "85432",  // 百万收藏榜
    ]

    /// 🔴 v2.5.50：热门歌手横向翻页的当前页码（每页 5 行）

    var body: some View {
        // 🔴 2026-11-09：外层包 ScrollViewReader —— 新增「歌手」板块的右侧 A–Z
        //    快速定位要 scrollTo 到分组锚点。与「我的音乐 → 下载歌曲」的
        //    DownloadIndex 同一套做法（overlay 挂在 ScrollView 上、不随内容滚）。
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // 🔴 2026-11-12：只有【所有板块】都空才展示「加载失败」。
                    //    以前只看 feed.isEmpty（= 榜单空），榜单接口偶发失败就把
                    //    已经加载好的猜你喜欢/每日推荐全部盖掉，逼用户点重试。
                    if let errorMessage,
                       feed.isEmpty,
                       guessSongs.isEmpty, dailySongs.isEmpty,
                       hotArtists.isEmpty, recommendedPlaylists.isEmpty,
                       ktvSongs.isEmpty, classicSongs.isEmpty,
                       djSongs.isEmpty, newSongs.isEmpty, hallSongs.isEmpty {
                        errorState(errorMessage)
                    } else if isLoading, feed.isEmpty, skeletonAllowed {
                        // 🔴 2026-11-10：首屏加载不再用菊花，按推荐 Tab 真内容摆骨架 + 匀速扫光。
                        // 🔴 2026-11-13：加了本地快照 + 0.4s 延迟许可后，正常启动根本走不到这里；
                        //    只有「首次安装、本机无任何快照且网络确实慢」才会出现骨架。
                        FeedSkeleton()
                    } else {
                        // 歌单 Tab：搜索框变成「搜索歌单」；其它 Tab 保持全局搜索入口
                        if selectedTab == .playlists {
                            playlistSearchBar
                        } else {
                            // 🔴 2026-11-09：推荐 Tab「横幅广告上面的搜索框」移除（用户要求）；
                            //    歌手 Tab 换成「只搜本页歌手」的本地过滤框；其余 Tab 保持全局搜索入口。
                            if selectedTab == .artists {
                                artistSearchBar
                            } else if selectedTab != .recommend {
                                searchEntry
                            }
                            // 🔴 v2.9.9：横幅广告自动轮播（仅在推荐 Tab）
                            if selectedTab == .recommend {
                                adBanner
                                // 🔴 v2.9.10：横幅广告下方入口栏（下载 / MV / 排行榜 / 歌单广场 / 实验室）
                                entryBar
                            }
                        }
                        tabContent
                    }
                }
                .id("tab-top")
                .padding(.bottom, 24)
                // 🔴 歌手板块右侧字母索引留出空间，避免挡住歌手行。
                .padding(.trailing, selectedTab == .artists ? 18 : 0)
            }
            // 🔴 2026-11-09：歌手板块右侧 A–Z 快速定位条（只列筛选后实际有歌手的字母）
            .overlay(alignment: .trailing) {
                if selectedTab == .artists {
                    ArtistLetterIndex(letters: filteredArtistGroups.map(\.letter), proxy: proxy)
                        .padding(.trailing, 3)
                }
            }
            .onChange(of: selectedTab) { tab in
                withAnimation { proxy.scrollTo("tab-top", anchor: .top) }
                if tab == .artists { Task { await startArtistLoading() } }
            }
            // 🔴 搜索框只过滤本页已加载歌手，词变了重算一次分组缓存。
            .onChange(of: artistQuery) { _ in refreshArtistGroups() }
            // 🔴 v2.9.6(修正)：酷狗风格背景 —— 顶部淡蓝渐变钉在页面顶部，上滑不消失。
            // 渐变挂在 ScrollView 自身的背景上（相对可视区域固定），而不是滚动内容里。
            .kugouPinnedTopFade(height: 280)
            .refreshable { await load(force: true) }
            .task {
                // 🔴 2026-11-13：启动时不再等「feed 为空」才加载。
                //    本地快照已经让首帧有内容，这里静默刷新（force 会重拉每日推荐 /
                //    猜你喜欢 / 热门歌手，并在 load() 内并发发起新歌推荐），
                //    界面全程不空窗，也不会因为 isLoading 命中骨架屏。
                //    ⚠️ 新歌推荐仍由 load(force:) 里的非结构化 Task 并发发起
                //    （.task 随视图消失会被取消，那条链路不会）。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    // 只有「本机无快照 + 0.4s 还没出内容」才允许显示骨架。
                    if isLoading, feed.isEmpty { skeletonAllowed = true }
                }
                await load(force: true)
            }
            // 🔴 2026-11-13 第二轮：这里原来还挂了两条并发链路，都是「两栏重复 / 首页卡死」的元凶：
            //    ① `Task { await loadGuess() }` —— 猜你喜欢与 load() 里的串行链抢着写 @State，
            //       常常在「两栏去重」跑完之后才把**未去重的原始数据**写回来；
            //    ② `Task { await BannerConfig.shared.pullCloud() }` 每进一次发现页就拉一遍
            //       十几 MB 的云端横幅大图，解码全压在主线程上（iPhone 14 偶发卡死）。
            //       横幅已改成本机设置、不读写服务器，这条链路整体删除。
            //    另外 `.task(id: 登录态) { await loadDailySongs() }` 也会绕过去重单独重拉每日推荐，
            //    一并移除；每日推荐由 load() 按自然日统一刷新。
            .navigationBarTitleDisplayMode(.inline)
            // 🔴 v2.9.6：状态栏/导航栏那一段刷成淡蓝，和下面的渐变带连成一片
            .kugouNavigationBarTint()
            // 🔴 2026-11-12：修「有些用户顶栏跟系统状态栏间距太大」。
            //    旧版空标题的 inline 导航栏（约 44pt）**再加**一层
            //    safeAreaInset(edge:.top) 放 tab 行，等于顶部叠了两层占位，
            //    状态栏到「推荐/歌单/榜单」之间空出一大块淡蓝。
            //    现在把 tab 行放进导航栏 principal：导航栏本来就钉在状态栏
            //    正下方、实色 appearance 会挡住上滑穿帮，既消掉多余间距，
            //    也不隐藏导航栏（不影响 push 出去的二级页）。
            .toolbar {
                ToolbarItem(placement: .principal) {
                    tabBar.background(AppStyle.pageGradientTop)
                }
            }
            // 🔴 底部留白已由 RootView 的 .safeAreaInset(edge:.bottom) 统一处理
            // （播放条现在是 TabView 的 inset 内容，不是浮层）。
            // 这里再 inset 一次会变成双重留白。
            // 监听全局歌手导航通知
            .onReceive(NotificationCenter.default.publisher(for: .navigateToArtist)) { note in
                guard let song = note.object as? Song else { return }
                pendingArtist = Artist(id: "kw:\(song.artist)",
                                       name: song.artist.trimmingCharacters(in: .whitespaces),
                                       coverURL: song.artworkURL)
            }
            .background(
                NavigationLink(isActive: Binding(
                    get: { pendingArtist != nil },
                    set: { if !$0 { pendingArtist = nil } }
                )) {
                    if let artist = pendingArtist {
                        ArtistDetailView(artist: artist)
                    }
                } label: { EmptyView() }
            )
        }
    }

    // MARK: Tab 栏

    private var tabBar: some View {
        HStack(alignment: .bottom, spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {  // 24→16 缩小间距
                ForEach(DiscoverTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                    } label: {
                        VStack(spacing: 6) {
                            Text(tab.title)
                                .font(.system(size: 14, weight: selectedTab == tab ? .semibold : .regular))  // 16→14
                                .foregroundStyle(selectedTab == tab ? AppStyle.accent : AppStyle.primaryText)
                                .fixedSize()  // 🔴 禁止截断
                                .lineLimit(1)  // 🔴 单行
                            Capsule()
                                .fill(selectedTab == tab ? AppStyle.accent : Color.clear)
                                .frame(width: tab.title.count == 2 ? 18 : 24, height: 3)
                        }
                        .frame(minWidth: 0)  // 🔴 允许压缩
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 12)

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                // 🔴 2026-11-13：登录态标识（绿点 + 已连接）放在名字上方（kugouAvatar 内部）
                kugouAvatar
            }
            .padding(.trailing, 12)
        }
        .frame(height: 40)
    }

    /// 🔴 2026-11-13 第七轮：酷狗账号登录后的「已连接」不再写死绿色，
    ///    改成接入音源健康状态（见文件末尾 `SourceStatusBadge`）：
    ///    音源列表里是绿点（可用）就绿、红点（无用）就红；发光圈也改小了。
    ///    未登录但登录了云账号时仍保留原来的「管理员」文字标识。
    @ViewBuilder
    private var accountStatusBadge: some View {
        if kugouAuth.isLoggedIn {
            SourceStatusBadge()
        } else if cloud.isSignedIn {
            Text("管理员")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
        }
    }

    @ViewBuilder
    private var kugouAvatar: some View {
        if kugouAuth.isLoggedIn {
            NavigationLink {
                KugouAccountCenter()
            } label: {
                HStack(spacing: 5) {
                    CoverImage(url: kugouAuth.avatarURL,
                               fallbackKeys: ["kg-user:\(kugouAuth.userId)"],
                               seed: kugouAuth.nickname,
                               size: 30, corner: 8)  // 🔴 v2.8.4 头像改方形
                    // 🔴 2026-11-13：登录态显示在「名字」上方（绿点 + 已连接）
                    VStack(alignment: .leading, spacing: 1) {
                        accountStatusBadge
                        Text(kugouAuth.nickname.isEmpty ? "酷狗" : kugouAuth.nickname)
                            .font(.system(size: 13, weight: .medium))  // 12→13
                            .foregroundStyle(AppStyle.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                NotificationCenter.default.post(name: .auroraShowKugouLogin, object: nil)
            } label: {
                HStack(spacing: 3) {
                    // 酷狗品牌登录图标（绿圆白话筒），替代通用 SF Symbol
                    KugouLogoIcon(size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        accountStatusBadge
                        Text("登录")
                            .font(.system(size: 13, weight: .medium))  // 12→13
                            .foregroundStyle(AppStyle.secondaryText)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 搜索入口

    private var searchEntry: some View {
        NavigationLink {
            SearchView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(AppStyle.secondaryText)
                Text("搜索歌曲、歌手、专辑")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.secondaryText)
                Spacer()
                Image(systemName: "mic")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.secondaryText.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: 🔴 2026-11-12 横幅广告轮播

    /// 轮播状态与计时器都关在 AdBannerCarousel 里（见文件末尾）。
    /// 父页面每 4 秒不再重算，主页滚动 / 冷启动明显更稳。
    private var adBanner: some View { AdBannerCarousel() }

    // MARK: 🔴 v2.9.10 横幅广告下方入口栏

    /// 入口栏入口（🔴 v2.9.11：移除 MV，保留 下载 / 排行榜 / 歌单广场 / 实验室）。
    private enum DiscoverEntry: String, CaseIterable {
        case download, ranking, square, source, lab
        var title: String {
            switch self {
            case .download: return "下载"
            case .ranking: return "排行榜"
            case .square: return "歌单广场"
            case .source: return "音源"
            case .lab: return "实验室"
            }
        }
        var icon: String {
            switch self {
            case .download: return "arrow.down.circle.fill"
            case .ranking: return "trophy.fill"
            case .square: return "music.note.list"
            case .source: return "waveform"
            case .lab: return "flask.fill"
            }
        }
        /// 🔴 v2.9.11：主符号在用户系统上不存在时的备选（`Image(systemName:)` 找不到会静默渲染空白）。
        /// 排行榜的 `trophy.fill` 在部分系统上缺失 → 用户只看到一个空的黄色方块。
        var iconFallback: String {
            switch self {
            case .download: return "arrow.down.circle"
            case .ranking: return "trophy"
            case .square: return "music.note.list"
            case .source: return "waveform"
            case .lab: return "flask"
            }
        }
        var color: Color {
            switch self {
            case .download: return Color(red: 0.20, green: 0.78, blue: 0.42)
            case .ranking: return Color(red: 0.98, green: 0.70, blue: 0.20)
            case .square: return Color(red: 0.30, green: 0.60, blue: 0.95)
            case .source: return Color(red: 0.15, green: 0.75, blue: 0.65)
            case .lab: return Color(red: 0.60, green: 0.42, blue: 0.92)
            }
        }
    }

    /// 🔴 v2.9.11：实验室入口**对所有人可见**（用户要求保留按钮），
    /// 但点进去必须**验证管理员账号密码**才能进管理面板（LabView 里把关）。
    /// 之前所有人都能看到并点进「实验室」（里面只判"有没有登录云账号"），
    /// 结果别人登录后把管理员的云端横幅换掉了（2026-11-01 真实事故）。

    private var entryBar: some View {
        // 🔴 v2.9.13：入口行与横幅「一样宽」——左右各 16pt，
        // 4 个入口按剩余空间均分，间距自动加大铺满整行（不再挤在左边）。
        let n = CGFloat(DiscoverEntry.allCases.count)
        let total = UIScreen.main.bounds.width - 32 // 与横幅一致：左右各 16
        let gap = max(10, (total - n * 50) / (n - 1)) // 50 = 图标方块边长
        return HStack(spacing: gap) {
            ForEach(DiscoverEntry.allCases, id: \.self) { entry in
                entryItem(entry)
            }
        }
        .frame(width: total, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func entryItem(_ entry: DiscoverEntry) -> some View {
        switch entry {
        case .download, .ranking, .source, .lab:
            NavigationLink { destination(for: entry) } label: { entryLabel(entry) }
                .buttonStyle(.plain)
        case .square:
            Button { selectedTab = .playlists } label: { entryLabel(entry) }
                .buttonStyle(.plain)
        }
    }

    private func entryLabel(_ entry: DiscoverEntry) -> some View {
        VStack(spacing: 6) {
        ZStack {
            // 🔴 v2.9.15：所有入口统一浅色圆角方块背景（实验室也加上，与旁边按钮一致）
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(entry.color.opacity(0.16))
            if entry == .lab, let img = UIImage(named: "LabIcon") {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                } else {
                    // 🔴 v2.9.11：用 SafeIcon，符号不存在时自动换备选，不会渲染成空白方块
                    SafeIcon(systemName: entry.icon,
                             fallback: entry.iconFallback,
                             font: .system(size: 20, weight: .semibold),
                             foreground: entry.color)
                }
            }
            .frame(width: 50, height: 50)
            Text(entry.title)
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.primaryText)
        }
            .frame(width: 50) // 🔴 v2.9.13：与图标同宽，保证首尾图标与横幅左右边缘对齐
        }

    @ViewBuilder
    private func destination(for entry: DiscoverEntry) -> some View {
        switch entry {
        case .download: DownloadCenterView()
        case .ranking: RankingsView()
        case .source: SourceSettingsView().kugouNavigationBarBackground()
        case .lab: LabView()
        default: EmptyView()
        }
    }

    /// 歌单页搜索框：输入关键词搜酷狗歌单（/api/v3/search/special），清空回到推荐流
    private var playlistSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(AppStyle.secondaryText)
            TextField("搜索歌单", text: $playlistQuery)
                .font(.system(size: 13))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !playlistQuery.isEmpty {
                Button {
                    playlistQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(AppStyle.secondaryText.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        // 输入防抖 350ms 后搜索；空串直接回到推荐歌单
        .task(id: playlistQuery) {
            let q = playlistQuery.trimmingCharacters(in: .whitespaces)
            if q.isEmpty {
                playlistSearchResults = []
                playlistSearchTotal = 0
                playlistSearchPage = 1
                playlistSearchExhausted = false
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, q == playlistQuery.trimmingCharacters(in: .whitespaces) else { return }
            await searchPlaylists(reset: true)
        }
    }

    // MARK: Tab 内容切换

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .recommend: recommendContent
        case .ranks: ranksContent
        case .playlists: playlistsContent
        case .artists: artistsContent
        case .audiobook: audiobookContent
        }
    }

    // MARK: 🔴 2026-11-09 歌手 Tab（全部歌手按字母排序 + 右侧 A–Z 索引）

    /// 按首字母分组（A–Z；非字母归 #），组内按名字排序。
    /// `Artist.initialLetter` 已处理中文拼音首字母（周杰伦 → Z）。
    private struct ArtistGroup: Identifiable {
        let letter: String
        let artists: [Artist]
        var id: String { letter }
    }

    /// 分组逻辑抽出来：全量列表和搜索结果共用同一套 A–Z 规则。
    private func makeArtistGroups(_ source: [Artist]) -> [ArtistGroup] {
        var map: [String: [Artist]] = [:]
        for artist in source {
            map[artist.initialLetter, default: []].append(artist)
        }
        let letters = map.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
        return letters.map { letter in
            let sorted = (map[letter] ?? []).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return ArtistGroup(letter: letter, artists: sorted)
        }
    }

    private var artistGroups: [ArtistGroup] { artistGroupsCache }

    /// 数据 / 搜索词变化后显式重算一次，避免逐帧全量分组排序。
    private func refreshArtistGroups() {
        let groups = makeArtistGroups(allArtists)
        artistGroupsCache = groups
        let q = artistSearchText
        guard !q.isEmpty else {
            filteredArtistGroupsCache = groups
            return
        }
        let matched = allArtists.filter { artist in
            artist.name.localizedCaseInsensitiveContains(q)
            || artist.initialLetter.localizedCaseInsensitiveContains(q)
        }
        filteredArtistGroupsCache = makeArtistGroups(matched)
    }

    private var artistSearchText: String {
        artistQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 🔴 2026-11-09：只在本页歌手里按名字 / 拼音首字母过滤，不触发网络搜索。
    private var filteredArtistGroups: [ArtistGroup] { filteredArtistGroupsCache }

    /// 🔴 2026-11-09：歌手 Tab 专用搜索框 —— 不跳 SearchView，只改本页列表。
    private var artistSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(AppStyle.secondaryText)
            TextField("搜索歌手", text: $artistQuery)
                .font(.system(size: 13))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !artistQuery.isEmpty {
                Button { artistQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(AppStyle.secondaryText.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var artistsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(allArtists.isEmpty
                     ? "歌手"
                     : (artistSearchText.isEmpty
                        ? "全部歌手 · \(allArtists.count) 位"
                        : "找到 \(filteredArtistGroups.reduce(0) { $0 + $1.artists.count }) 位歌手"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer()
                if isLoadingArtists {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if allArtists.isEmpty {
                ListRowsSkeleton(rows: 7)
                    .padding(.vertical, 20)
            } else if filteredArtistGroups.isEmpty {
                EmptyStateView(icon: "magnifyingglass",
                               title: "没有找到相关歌手",
                               message: "换个歌手名或首字母试试")
                    .padding(.top, 40)
            } else {
                // 嵌套在页面外层 LazyVStack 里，pinnedViews 不会真的吸顶，去掉避免误导。
                LazyVStack(spacing: 0) {
                    ForEach(filteredArtistGroups) { group in
                        Section {
                            ForEach(group.artists) { artist in
                                NavigationLink {
                                    ArtistDetailView(artist: artist)
                                } label: {
                                    ArtistRow(artist: artist)
                                }
                                .buttonStyle(.plain)
                                if artist.id != group.artists.last?.id {
                                    Divider().padding(.leading, 68)
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.letter)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(AppStyle.accent)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                            .background(AppStyle.background.opacity(0.94))
                        }
                        .id("artist-sec-\(group.letter)")
                    }
                    // 🔴 2026-11-12：触底哨兵放在【懒加载容器内部】，只有真正滚到
                    //    列表末尾才会出现 → 触发下一批。不再一进 Tab 就翻完 25 页。
                    if hasMoreArtists, artistSearchText.isEmpty {
                        HStack {
                            Spacer()
                            if isLoadingMoreArtists { ProgressView().controlSize(.small) }
                            Spacer()
                        }
                        .frame(height: 36)
                        // 🔴 2026-11-12：哨兵一直留在视图树里，只是被新数据推到更下面，
                        //    `.onAppear` 只触发一次 → 旧版最多两批（40+40=80 位）就停。
                        //    每批加载完换 id 重建：用户仍停在底部就继续下一批；
                        //    列表变长后哨兵离开可视区，自然停止，不会一次拉完全部。
                        .id("artist-sentinel-\(artistPage)")
                        .onAppear { Task { await startArtistLoading() } }
                    }
                }
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)
            }

            if artistsLoaded && artistSearchText.isEmpty && !allArtists.isEmpty {
                Text(hasMoreArtists
                     ? "正在加载更多歌手…"
                     : "已加载全部 \(allArtists.count) 位歌手")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
    }

    /// 🔴 2026-11-12 第三轮：修「歌手页还是获取不到全部歌手」（截图停在 160 位）。
    ///
    /// 实测酷狗 `/api/v3/singer/list?sort=1&category=0`：
    ///   · page 1~75 每页都返回 20 条全新数据，`total = 2684455`；
    ///   · `pagesize` 直接给 100 / 200 / 500 也都能一次返回对应条数。
    /// 所以「只有 160 位」不是接口到底，而是代码自己提前收工：
    ///   ① 旧版 `if batch.count < 20 { reachedEnd = true }` —— 只要某一页解析
    ///      去重后不足 20 条（字段缺失 / host 降级），立刻判「已到底」；
    ///   ② 触底哨兵的 `.onAppear` 在嵌套 LazyVStack 里极不可靠，用户滚到底
    ///      也不一定再触发，加载就永远停在中途。
    ///
    /// 现在改成：**进入 Tab 后后台自动分批补齐全部**，不依赖任何 onAppear。
    ///   · 每批 2 页 × 100 = 200 位，一批只赋值一次 → 不会逐页刷新整页；
    ///   · 每批之间是网络 await，主线程完全空闲，不卡滚动；
    ///   · 全部歌手分组只算一次（refreshArtistGroups），body 只读缓存；
    ///   · 触底哨兵保留，仅作可见的「加载中」指示，不再是加载的唯一途径。
    @MainActor
    private func startArtistLoading() async {
        guard !artistAutoLoading else { return }
        artistAutoLoading = true
        defer { artistAutoLoading = false }
        await loadArtistBatch(reset: true)
        // 只要还在这个 Tab 且还有后续页，就一直往下补齐（网络 await 天然让出主线程）。
        while hasMoreArtists, selectedTab == .artists, !Task.isCancelled {
            await loadArtistBatch(reset: false)
        }
    }

    @MainActor
    private func loadArtistBatch(reset: Bool) async {
        if reset {
            guard !artistsLoaded, !isLoadingArtists else { return }
        } else {
            guard hasMoreArtists, !isLoadingMoreArtists, !isLoadingArtists else { return }
        }
        if reset { isLoadingArtists = true } else { isLoadingMoreArtists = true }
        defer {
            if reset { isLoadingArtists = false } else { isLoadingMoreArtists = false }
        }

        let perPage = 100      // 单页 100 位，12 页 = 1200 位
        let pageLimit = 12
        var collected: [Artist] = reset ? [] : allArtists
        var seen = Set(collected.map(\.id))
        var page = reset ? 1 : artistPage + 1
        var addedTotal = 0
        var emptyStreak = reset ? 0 : artistEmptyStreak
        var reachedEnd = false

        for _ in 0..<2 {
            if page > pageLimit { reachedEnd = true; break }
            let batch = await KugouClient.shared.hotArtistsPage(page: page, perPage: perPage)
            page += 1
            // 🔴 单页空 / 单页不足 perPage **都不判到底**：弱网抖动、host 降级、
            //    字段缺失都会造成短页。连续 3 页全空才认输，且继续往下翻。
            if batch.isEmpty {
                emptyStreak += 1
                if emptyStreak >= 3 { reachedEnd = true; break }
                continue
            }
            emptyStreak = 0
            var added = 0
            for artist in batch where !seen.contains(artist.id) {
                seen.insert(artist.id)
                collected.append(artist)
                added += 1
            }
            addedTotal += added
        }
        artistPage = max(0, page - 1)
        artistEmptyStreak = emptyStreak
        if reachedEnd || artistPage >= pageLimit { hasMoreArtists = false }
        // 🔴 一批只刷新一次；分组缓存同步重算一次。
        let snapshot = collected
        allArtists = snapshot
        refreshArtistGroups()
        if reset { artistsLoaded = true }
        Log.info("歌手", "本批 +\(addedTotal)，共 \(snapshot.count) 位，page=\(artistPage)，还有=\(hasMoreArtists)")
    }

    /// 右侧 A–Z 快速定位条（只列出实际有歌手的字母，点击滚到该分组）。
    private struct ArtistLetterIndex: View {
        let letters: [String]
        let proxy: ScrollViewProxy

        var body: some View {
            VStack(spacing: 1) {
                ForEach(letters, id: \.self) { letter in
                    Button {
                        withAnimation { proxy.scrollTo("artist-sec-\(letter)", anchor: .top) }
                        Haptics.light()
                    } label: {
                        Text(letter)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(AppStyle.tertiaryText)
                            .frame(width: 16, height: 13)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: 听书 Tab — 施工中

    private var audiobookContent: some View {
        VStack {
            Spacer()
            Image(systemName: "hammer.fill")
                .font(.system(size: 50))
                .foregroundStyle(AppStyle.secondaryText)
            Text("听书板块")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppStyle.primaryText)
                .padding(.top, 16)
            Text("正在施工中！敬请期待！有什么好的建议请QQ群反馈！感谢！！")
                .font(.system(size: 14))
                .foregroundStyle(AppStyle.tertiaryText)
                .padding(.top, 4)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 推荐 Tab — 完整 Feed 流

    private var recommendContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 🔴 v2.9.12：新歌推荐上移到「每日推荐 / 猜你喜欢」（bigCardsGrid）之上
            newSongSection
            // 🔴 v2.9.7(二)：用户要求「新歌推荐」下面加回「经典推荐」，
            // 经典推荐下面再加「DJ推荐」，然后才接「歌单推荐」→「专辑推荐」→「榜单推荐」。
            bigCardsGrid
            classicSection
            djSection
            userPlaylistSection
            // 🔴 v2.9.11：热门歌手（横向头像排）下移到「歌单推荐」下面
            artistStripSection
            artistAlbumSection
            rankRecommendSection
        }
    }

    // 🔴 v2.9.4：新歌推荐 —— 由「2×2 翻页宫格」改成 **单行横向滚动**。
    //
    // 翻页要按页码来回切，横滑一屏能看到更多，也不再需要底部页码圆点。
    // 🔴 v2.9.7：下面是「歌单推荐」（同样单排横滑）、「专辑推荐」（大卡横滑）、
    // 「榜单推荐」（榜单大卡）。
    private var newSongSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("新歌推荐") {
                NavigationLink {
                    PlaylistDetailView(
                        playlist: Playlist(id: "local-new", name: "新歌推荐",
                                           coverURL: nil, trackCount: newSongs.count,
                                           creatorName: "Aurora 推荐", source: .kugou),
                        initialSongs: newSongs)
                } label: {
                    HStack(spacing: 2) { Text("更多").font(.system(size: 12)); Image(systemName: "chevron.right").font(.system(size: 10)) }
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            if newSongs.isEmpty {
                // 🔴 2026-11-10：加载菊花 → 按真实卡片版式摆灰色占位块 + 匀速扫光。
                SlideCardsSkeleton()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(newSongs) { song in
                            slideSongCard(song, queue: newSongs, size: 108)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// 横滑歌曲卡：封面 + 歌名 + 歌手（「新歌推荐」用）。
    private func slideSongCard(_ song: Song, queue: [Song], size: CGFloat) -> some View {
        Button {
            guard let start = queue.firstIndex(where: { $0.id == song.id }) else { return }
            store.play(queue, startAt: start)
            Haptics.soft()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverImage(url: song.artworkURL,
                           fallbackKeys: song.coverFallbackKeys,
                           seed: "\(song.artist)-\(song.title)",
                           size: size,
                           corner: 10)
                Text(song.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .lineLimit(1)
            }
            .frame(width: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 🔴 v2.9.7 歌单推荐（原「推荐用户的歌单」）

    /// 「歌单推荐」：酷狗歌单广场里用户创建的歌单，单排横滑。
    ///
    /// 显示方式与上面的「新歌推荐」一致（一行横滑、无页码点）：
    /// 封面 + 歌单名 + 创建者。数据复用首页已经加载好的 recommendedPlaylists，不额外发请求。
    private var userPlaylistSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("歌单推荐") {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = .playlists }
                } label: {
                    HStack(spacing: 2) { Text("更多").font(.system(size: 12)); Image(systemName: "chevron.right").font(.system(size: 10)) }
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            if recommendedPlaylists.isEmpty {
                // 🔴 2026-11-10：加载菊花 → 按真实卡片版式摆灰色占位块 + 匀速扫光。
                SlideCardsSkeleton()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(recommendedPlaylists.prefix(12))) { playlist in
                            slidePlaylistCard(playlist)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// 横滑歌单卡：封面 + 歌单名 + 创建者（与「新歌推荐」的横滑歌曲卡同一套版式）。
    private func slidePlaylistCard(_ playlist: Playlist) -> some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverImage(url: playlist.coverURL,
                           fallbackKeys: [playlist.id],
                           seed: playlist.name,
                           size: 108,
                           corner: 10)
                Text(playlist.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(playlist.creatorName.isEmpty ? "酷狗音乐" : playlist.creatorName)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .lineLimit(1)
            }
            .frame(width: 108)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 🔴 v2.9.17 热门歌手专辑（原「专辑推荐」板块改为展示热门歌手的专辑）

    /// 热门歌手 + 他的一张专辑（用于「热门歌手专辑」板块的卡片数据）。
    private struct ArtistAlbum: Identifiable {
        let id: String
        let artist: Artist
        let album: Album
    }

    /// 为前 8 位热门歌手各取一张专辑（按歌手顺序逐位 searchAlbums）。
    private func loadArtistAlbums() async {
        let picks = Array(hotArtists.prefix(8))
        guard !picks.isEmpty else { return }
        let client = KugouClient.shared
        var result: [ArtistAlbum] = []
        for artist in picks {
            let albums = await client.searchAlbums(keyword: artist.name)
            if let album = albums.first {
                result.append(ArtistAlbum(id: artist.id, artist: artist, album: album))
            }
        }
        artistAlbums = result
        Log.info("发现页", "热门歌手专辑加载 \(artistAlbums.count)/\(picks.count)")
    }


    /// 一张卡：一位热门歌手 + 他的一张专辑（封面 + 专辑名 + 歌手名）。
    /// 点整张卡进 AlbumDetailView（专辑详情页会按专辑 id 拉歌）。
    private func artistAlbumCard(artist: Artist, album: Album) -> some View {
        NavigationLink {
            AlbumDetailView(album: album)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CoverImage(url: album.coverURL,
                           fallbackKeys: album.albumID.isEmpty ? [] : ["al:\(album.albumID)"],
                           seed: album.name, size: 116, corner: 10)
                    .frame(width: 116, height: 116)
                Text(album.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                    .frame(width: 116, alignment: .leading)
                Text(artist.name)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .lineLimit(1)
                    .frame(width: 116, alignment: .leading)
            }
            .frame(width: 116)
        }
        .buttonStyle(.plain)
    }

    /// 「热门歌手专辑」板块：横向滑动，每张卡 = 一位热门歌手的一张专辑。
    /// 数据来自首页已加载的 hotArtists，各自用 searchAlbums 取一张专辑（并发，不重复请求）。
    private var artistAlbumSection: some View {
        let pairs = artistAlbums
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("热门歌手专辑") { EmptyView() }

            if pairs.isEmpty {
                // 🔴 2026-11-10：加载菊花 → 按真实卡片版式摆灰色占位块 + 匀速扫光。
                SlideCardsSkeleton()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(pairs) { pair in
                            artistAlbumCard(artist: pair.artist, album: pair.album)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // 🔴 v2.6.7：统一板块标题（标题 + 右侧「更多」）——
    // 之前每个板块各写各的（字号 16/17 不一、上下间距 8/10/18/22/24 不一），
    // 整页看起来很乱。现在全页共用这一套。
    private func sectionHeader(_ title: String, @ViewBuilder more: () -> some View) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppStyle.primaryText)
            Spacer()
            more()
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    // MARK: 🔴 v2.9.7 榜单推荐

    /// 「榜单推荐」要展示的 4 个榜（酷狗 rankID → 展示名）。
    /// 顺序按用户指定的：会员热歌榜 / 网络热歌榜 / 酷狗飙升榜 / 百万收藏榜。
    private static let recommendRankIDs: [(id: String, displayName: String)] = [
        ("35811", "会员热歌榜"),
        ("82831", "网络热歌榜"),
        ("6666", "酷狗飙升榜"),
        ("85432", "百万收藏榜"),
    ]

    /// 推荐页里的「榜单推荐」数据源：从已加载的榜单里挑出这 4 个。
    /// 数据复用首页已加载的 feed.topLists，不额外发列表请求。
    private var recommendRankLists: [(playlist: Playlist, displayName: String)] {
        let byID = Dictionary(grouping: feed.topLists) { $0.kugouRankID ?? "" }
        return Self.recommendRankIDs.compactMap { entry in
            guard let playlist = byID[entry.id]?.first else { return nil }
            // 展示名统一用用户指定的（接口可能返回「飙升榜」而不是「酷狗飙升榜」，
            // 同一份数据在两个板块里名字不一致会很怪）。
            // 注意：只覆盖展示用的名字，不改 Playlist 本体 —— 它还要传给详情页。
            return (playlist, entry.displayName)
        }
    }

    // MARK: 🔴 2026-11-13 榜单推荐（改成与「每日推荐」一致的单行横滑封面卡）
    //
    // 原来是一列 4 张「大卡」：整张专辑图铺底 + 榜名 + 3 首带排名的小封面，
    // 和上面的每日推荐（108pt 方形封面 + 名字 + 副标题，横滑一排）不是一套视觉。
    // 现在统一成 slideSongCard 同款版式；点卡片进榜单详情，
    // 原来大卡上的播放键 / 前 3 首在详情页里都有，功能不丢。
    private var rankRecommendSection: some View {
        let lists = recommendRankLists
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("榜单推荐") {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = .ranks }
                } label: {
                    HStack(spacing: 2) {
                        Text("更多").font(.system(size: 12))
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }
                    .foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            if lists.isEmpty {
                // 🔴 2026-11-10：加载菊花 → 按真实卡片版式摆灰色占位块 + 匀速扫光。
                SlideCardsSkeleton()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(lists, id: \.playlist.id) { item in
                            rankStyleCard(playlist: item.playlist, displayName: item.displayName)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
        }
        // 这 4 个榜的前 3 首预览要单独拉 —— 榜单 Tab 的预拉取只在切到那个 Tab 时才跑。
        .task(id: lists.map(\.playlist.id)) {
            await loadRankPreviews(for: lists.map(\.playlist))
        }
    }

    /// 与「每日推荐」的 slideSongCard 完全同款：108pt 方形封面 + 名字 + 副标题。
    /// 封面优先取该榜第 1 首歌的专辑图（榜单自带封面常常是纯色文字块）。
    private func rankStyleCard(playlist: Playlist, displayName: String) -> some View {
        let songs = rankPreviewSongs[playlist.kugouRankID ?? ""] ?? []
        let first = songs.first
        let trackCount = playlist.trackCount > 0 ? playlist.trackCount : songs.count
        let subtitle = trackCount > 0
            ? "\(rankFrequencyText(playlist.updateFrequency)) · \(trackCount) 首"
            : rankFrequencyText(playlist.updateFrequency)
        return NavigationLink {
            PlaylistDetailView(playlist: playlist)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverImage(url: first?.artworkURL ?? playlist.coverURL,
                           fallbackKeys: first?.coverFallbackKeys ?? [],
                           seed: first.map { "\($0.artist)-\($0.title)" } ?? displayName,
                           size: 108, corner: 10)
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .lineLimit(1)
            }
            .frame(width: 108)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 🔴 v2.9.8 经典推荐 / DJ推荐 —— 改成和新歌推荐一致的「单行横滑卡片」

    /// 复用「新歌推荐」的横滑卡版式（封面 + 歌名 + 歌手，点卡即播）。
    /// 「更多」push 进完整列表页（复用已加载好的歌曲，省一次请求）。
    private func horizontalSongSection(title: String, playlistID: String, songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title) {
                NavigationLink {
                    PlaylistDetailView(
                        playlist: Playlist(id: playlistID, name: title,
                                           coverURL: nil, trackCount: songs.count,
                                           creatorName: "Aurora 推荐", source: .kugou),
                        initialSongs: songs)
                } label: {
                    HStack(spacing: 2) {
                        Text("更多").font(.system(size: 12))
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }
                    .foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            if songs.isEmpty {
                // 🔴 2026-11-10：加载菊花 → 按真实卡片版式摆灰色占位块 + 匀速扫光。
                SlideCardsSkeleton()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(songs) { song in
                            slideSongCard(song, queue: songs, size: 108)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var classicSection: some View {
        horizontalSongSection(title: "经典推荐", playlistID: "local-classic", songs: classicSongs)
    }

    private var djSection: some View {
        horizontalSongSection(title: "DJ推荐", playlistID: "local-dj", songs: djSongs)
    }

    // MARK: 大卡横排（每日推荐 + 猜你喜欢）+ 精选榜单每2张小卡叠加

    // MARK: 大卡横排（每日推荐 + 猜你喜欢）—— 🔴 v2.9.10：改成与「新歌推荐」一致的「单行横滑歌曲卡」
    // （封面 + 歌名 + 歌手，点卡即播；「更多」进入完整列表）。原来 2 张大卡 + 小榜卡叠加的设计一并移除。
    private var bigCardsGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            horizontalSongSection(title: "每日推荐", playlistID: "local-daily", songs: dailySongs)
            horizontalSongSection(title: "猜你喜欢", playlistID: "local-guess", songs: guessSongs)
        }
    }

    /// 酷狗 TOP500 旗舰榜单（rankid=8888）
    private var top500Playlist: Playlist? {
        feed.topLists.first { $0.kugouRankID == "8888" }
    }

    /// 🔴 v2.9.7：卡片上随机展示的那**一首**歌（用户要求：随机显示一首在卡片上面）。
    /// ⚠️ 必须用 @State 存住 —— 之前是计算属性，body 每次重算都重新洗牌，
    /// 播放/暂停一下卡片上的歌名就换，看着很跳。数据（重新）加载完成时才换。
    @State private var dailyPick: Song?
    @State private var guessPick: Song?

    private var guessSubtitle: String {
        if let pick = guessPick { return "\(pick.title) · \(pick.artist)" }
        return personalizedHint
    }

    private var dailySubtitle: String {
        if let pick = dailyPick { return "\(pick.title) · \(pick.artist)" }
        return "酷狗每日推荐 · 每天同步"
    }

    private var personalizedHint: String {
        // 🔴 2026-11-11：旧版显示「抖音热歌、华语经典」两个本地抽词，属于假数据；
        //    现在「猜你喜欢」全部来自酷狗真实推荐接口（30 首）。
        "酷狗推荐 · 每日更新"
    }

    // MARK: 心情问候

    /// 🔴 v2.6.7：热门歌手 —— 由「每页 5 行的翻页列表」改成**横向头像排**。
    ///
    /// 之前页面上同时有「歌手翻页」和「新歌翻页」两个翻页器 + 两组页码圆点，
    /// 视觉噪音很大（用户反馈"主页推荐页不好看"）。歌手用头像排更直观，
    /// 一屏能看到 7~8 个，也不用再翻页。
    private var artistStripSection: some View {
        Group {
            if !hotArtists.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("热门歌手") {
                        NavigationLink {
                            MoreArtistsView(initial: hotArtists)
                        } label: {
                            HStack(spacing: 2) {
                                Text("更多").font(.system(size: 12))
                                Image(systemName: "chevron.right").font(.system(size: 10))
                            }
                            .foregroundStyle(AppStyle.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(hotArtists) { artist in
                                NavigationLink {
                                    ArtistDetailView(artist: artist)
                                } label: {
                                    VStack(spacing: 6) {
                                        CoverImage(url: artist.coverURL,
                                                   fallbackKeys: [artist.id],
                                                   seed: artist.name,
                                                   size: 60,
                                                   corner: 30)
                                            .overlay(alignment: .bottomTrailing) {
                                                if playingArtistID == artist.id {
                                                    PlayingBarsIndicator(isPlaying: store.isPlaying)
                                                        .padding(3)
                                                        .background(AppStyle.accent, in: Circle())
                                                        .offset(x: 3, y: 3)
                                                }
                                            }
                                        Text(artist.name)
                                            .font(.system(size: 11))
                                            .foregroundStyle(AppStyle.primaryText)
                                            .lineLimit(1)
                                            .frame(width: 60)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                    }
                }
            }
        }
    }

    // MARK: 热门榜单

    private var hotRanksSection: some View {
        Group {
            if !filteredLists.isEmpty {
                HStack {
                    Text("热门榜单")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 10)

                VStack(spacing: 0) {
                    ForEach(filteredLists.prefix(3)) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            RankRow(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 72)
                    }
                }
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 榜单 Tab（参考酷狗「排行榜」页排版）

    /// 顶部宫格卡片配色（对应酷狗排行榜的彩色方块）
    private let rankCardColors: [Color] = [
        Color(red: 0.62, green: 0.36, blue: 0.90),  // 紫
        Color(red: 0.28, green: 0.75, blue: 0.52),  // 绿
        Color(red: 0.25, green: 0.62, blue: 0.95),  // 蓝
        Color(red: 0.20, green: 0.78, blue: 0.72),  // 青
        Color(red: 0.32, green: 0.33, blue: 0.40),  // 深灰
        Color(red: 0.58, green: 0.24, blue: 0.30),  // 暗红
        Color(red: 0.93, green: 0.56, blue: 0.26),  // 橙
        Color(red: 0.36, green: 0.48, blue: 0.88),  // 靛蓝
    ]

    private var ranksContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if filteredLists.isEmpty {
                SlideCardsSkeleton(count: 3)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
            } else {
                rankCardPager
                rankPreviewList
            }
        }
        .task(id: filteredLists.map(\.id)) { await loadRankPreviews() }
    }

    /// 顶部横翻宫格：每页 3×2 张彩色榜单卡，下面小圆点指示页码
    private var rankCardPager: some View {
        VStack(spacing: 10) {
            let chunks = stride(from: 0, to: filteredLists.count, by: 6).map {
                Array(filteredLists[$0..<min($0 + 6, filteredLists.count)])
            }
            TabView(selection: $rankCardPage) {
                ForEach(Array(chunks.enumerated()), id: \.offset) { pageIndex, chunk in
                    let cols = [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)]
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(Array(chunk.enumerated()), id: \.element.id) { slot, playlist in
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                rankCard(playlist: playlist,
                                         color: rankCardColors[(pageIndex * 6 + slot) % rankCardColors.count])
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 232)  // 两行卡(约106)+行距10
            .onChange(of: rankCardPage) { _ in Haptics.soft() }

            // 页码圆点（酷狗样式：当前页蓝色短条）
            HStack(spacing: 5) {
                ForEach(0..<max(chunks.count, 1), id: \.self) { idx in
                    Capsule()
                        .fill(idx == rankCardPage ? AppStyle.accent : AppStyle.secondaryText.opacity(0.25))
                        .frame(width: idx == rankCardPage ? 16 : 6, height: 6)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: rankCardPage)
        }
        .padding(.top, 12)
    }

    /// 单张榜单卡：彩色渐变底 + 白字榜名居中 + 左下播放量 + 右下播放键
    private func rankCard(playlist: Playlist, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.85), color],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 0) {
                Spacer()
                Text(playlist.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                Spacer()
                HStack(alignment: .bottom) {
                    Text(Self.playCountText(playlist.playCount))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(8)
        }
        .frame(height: 106)
    }

    /// 下方榜单预览大卡：榜名 + 更新频率 + 封面(播放量角标) + 前 3 首
    private var rankPreviewList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("热门榜单")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppStyle.primaryText)
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 10)

            VStack(spacing: 12) {
                ForEach(filteredLists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        rankPreviewCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    /// 榜单预览大卡：榜名 + 更新频率 + 封面(播放量角标) + 前 3 首
    /// - Parameter displayName: 覆盖展示的榜名（nil = 用 playlist 自带的名字）。
    ///   推荐页的「榜单推荐」用它统一成用户指定的名称。
    /// - Parameter coverFromFirstSong: 封面用**第一首歌的专辑图**而不是榜单自己的封面。
    ///   榜单封面是「会员热歌榜」这种纯色文字图，看着不像歌；用首曲专辑图更像歌单。
    private func rankPreviewCard(playlist: Playlist,
                                 displayName: String? = nil,
                                 coverFromFirstSong: Bool = false) -> some View {
        let songs = rankPreviewSongs[playlist.kugouRankID ?? ""] ?? []
        // 🔴 v2.9.7：封面优先用第一首歌的专辑图（没有才退回榜单自身封面）
        let coverURL: URL? = {
            guard coverFromFirstSong else { return playlist.coverURL }
            return songs.first?.artworkURL ?? playlist.coverURL
        }()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(displayName ?? playlist.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Spacer()
                Text(rankFrequencyText(playlist.updateFrequency))
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }

            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .bottomLeading) {
                    CoverImage(url: coverURL,
                               fallbackKeys: [playlist.id],
                               seed: playlist.name,
                               size: 92, corner: 8)
                    // 左下播放量角标
                    Text(Self.playCountText(playlist.playCount))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(5)
                }
                .frame(width: 92, height: 92)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .padding(5)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if songs.isEmpty {
                        // 预览还没拉回来：占位行
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(AppStyle.secondaryText.opacity(0.12))
                                .frame(height: 12)
                        }
                        .padding(.top, 4)
                    } else {
                        ForEach(Array(songs.prefix(3).enumerated()), id: \.element.id) { index, song in
                            Button {
                                store.queueID = playlist.id
                                store.play(rankPreviewSongs[playlist.kugouRankID ?? ""] ?? [song], startAt: index)
                                Haptics.soft()
                            } label: {
                                HStack(spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(AppStyle.secondaryText)
                                        .frame(width: 12)
                                    Text("\(song.title) - \(song.artist)")
                                        .font(.system(size: 13))
                                        .foregroundStyle(AppStyle.primaryText)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 拉每个榜单的前 3 首做预览（并发 4，缺的才拉）
    private func loadRankPreviews() async {
        await loadRankPreviews(for: filteredLists)
    }

    /// 拉指定榜单的前 3 首做预览（并发 4，缺的才拉）。
    /// 榜单 Tab 拉全部；推荐页的「榜单推荐」只拉那 4 个，避免多打无用请求。
    private func loadRankPreviews(for lists: [Playlist]) async {
        let missing = lists.filter { rankPreviewSongs[$0.kugouRankID ?? ""] == nil }
        guard !missing.isEmpty else { return }
        let client = KugouClient.shared
        typealias Hit = (String, [Song])
        var hits: [Hit] = []
        await withTaskGroup(of: Hit?.self) { group in
            let concurrency = 4
            let sem = AsyncStream.makeStream(of: Void.self)
            nonisolated(unsafe) var active = 0
            for playlist in missing {
                guard let rankID = playlist.kugouRankID else { continue }
                while active >= concurrency { _ = await sem.stream.first(where: { _ in true }) }
                active += 1
                group.addTask {
                    defer {
                        active -= 1
                        Task { sem.continuation.yield(()) }
                    }
                    let songs = (try? await client.rankSongs(rankID: rankID, limit: 3)) ?? []
                    return (rankID, songs)
                }
            }
            for await hit in group {
                if let hit { hits.append(hit) }
            }
        }
        guard !hits.isEmpty else { return }
        var updated = rankPreviewSongs
        for (rankID, songs) in hits where updated[rankID] == nil {
            updated[rankID] = songs
        }
        rankPreviewSongs = updated
        Log.info("榜单", "预览拉取 \(hits.count) 个榜单")
    }

    private func rankFrequencyText(_ freq: String) -> String {
        let f = freq.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? "每日更新" : "\(f)更新"
    }

    /// 播放量格式化：1114932 -> 111.4万 / 89123 -> 8.9万
    static func playCountText(_ count: Int) -> String {
        guard count > 0 else { return "" }
        if count >= 10_000 {
            let w = Double(count) / 10_000
            let s = w >= 100 ? String(format: "%.0f", w) : String(format: "%.1f", w)
            let trimmed = s.hasSuffix(".0") ? String(s.dropLast(2)) : s
            return "\(trimmed)万"
        }
        return String(count)
    }

    // MARK: 歌单 Tab

    private var playlistsContent: some View {
        Group {
            let searching = !playlistQuery.trimmingCharacters(in: .whitespaces).isEmpty
            let lists = searching ? playlistSearchResults : recommendedPlaylists
            if searching ? (playlistSearchResults.isEmpty && isSearchingPlaylists)
                         : recommendedPlaylists.isEmpty {
                SlideCardsSkeleton(count: 4)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 16)
            } else if lists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 34))
                        .foregroundStyle(AppStyle.tertiaryText)
                    Text("没找到相关歌单")
                        .font(.system(size: 13))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                let cols = [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(lists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            PlaylistCard(playlist: playlist, width: 0)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }

                    // 底部加载触发器：推荐流按 squareTotal 翻页；搜索按 playlistSearchTotal 翻页
                    if searching {
                        if !playlistSearchExhausted,
                           playlistSearchResults.count < playlistSearchTotal {
                            SkeletonInlineRow()
                                .padding(.vertical, 10)
                                .onAppear { Task { await searchPlaylists(reset: false) } }
                        }
                    } else if recommendedPlaylists.count < squareTotal {
                        SkeletonInlineRow()
                            .padding(.vertical, 10)
                            .onAppear { Task { await loadMorePlaylists() } }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }

    /// 歌单搜索（reset=true 从第一页重来，否则追加下一页）。
    private func searchPlaylists(reset: Bool) async {
        guard !isSearchingPlaylists else { return }
        let q = playlistQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isSearchingPlaylists = true
        defer { isSearchingPlaylists = false }
        let page = reset ? 1 : playlistSearchPage + 1
        let result = await KugouClient.shared.searchPlaylists(keyword: q, page: page)
        guard q == playlistQuery.trimmingCharacters(in: .whitespaces) else { return } // 关键词已变，丢弃
        if reset { playlistSearchResults = [] }
        var existing = Set(playlistSearchResults.map(\.id))
        for p in result.playlists where !existing.contains(p.id) {
            playlistSearchResults.append(p)
            existing.insert(p.id)
        }
        playlistSearchPage = page
        playlistSearchTotal = result.total
        // 接口返回空页：到底了，别再重复请求
        if result.playlists.isEmpty || (result.total > 0 && playlistSearchResults.count >= result.total) {
            playlistSearchExhausted = true
        }
    }

    private var filteredLists: [Playlist] {
        // 按 rankOrder 固定排序（不再跟随接口返回顺序），同 rankid 去重取第一个
        let byID = Dictionary(grouping: feed.topLists) { $0.kugouRankID ?? "" }
        return Self.rankOrder.compactMap { byID[$0]?.first }
    }

    // MARK: 行为

    private func playGuessAll() {
        guard !guessSongs.isEmpty else { return }
        store.queueID = "guess"
        store.play(guessSongs, startAt: 0)
        Haptics.soft()
    }

    private func playDailyAll() {
        guard !dailySongs.isEmpty else { return }
        store.queueID = "daily"
        store.play(dailySongs, startAt: 0)
        Haptics.soft()
    }

    /// 点歌手行：搜索该歌手的歌并直接开始播放。
    private func playArtist(_ artist: Artist) {
        Haptics.soft()
        Task {
            if playingArtistID != nil { return }
            await MainActor.run { playingArtistID = artist.id }
            defer { Task { @MainActor in playingArtistID = nil } }
            guard let songs = try? await KugouClient.shared.searchSongs(
                keyword: artist.name, limit: 100), !songs.isEmpty else { return }
            store.play(songs, startAt: 0)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            EmptyStateView(icon: "wifi.exclamationmark", title: "加载失败", message: message)
            Button("重试") { Task { await load() } }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppStyle.accent)
        }
    }

    /// 🔴 v2.9.8：搜索歌单并**随机打散**。
    ///
    /// 背景：① 酷狗搜索接口一页固定 30 首（`searchSongs` 的 limit 参数不生效），
    /// 要 100 首必须自己翻页；② 用户要求「不要老是显示同样的歌在前面」，
    /// 所以每次加载都重新洗牌，配合下拉刷新能看到不同的排布。
    ///
    /// - Parameters:
    ///   - keyword: 搜索关键词
    ///   - count: 最终返回多少首
    ///   - excluding: 需要剔除的歌名关键词（子串匹配）
    private func shuffledSearchSongs(keyword: String,
                                     count: Int,
                                     excluding excludedTitles: [String] = []) async -> [Song] {
        let perPage = 30
        // 过滤会砍掉一些歌，多取一点余量，保证最终仍然能凑够 count 首
        let target = count + excludedTitles.count * 3
        var collected: [Song] = []
        var seen = Set<String>()
        var page = 1
        while collected.count < target && page <= 8 {
            let batch = (try? await KugouClient.shared.searchSongs(keyword: keyword, page: page)) ?? []
            if batch.isEmpty { break }
            for song in batch where !seen.contains(song.id) {
                seen.insert(song.id)
                collected.append(song)
            }
            page += 1
        }
        var result = collected
        if !excludedTitles.isEmpty {
            result = result.filter { song in
                !excludedTitles.contains { song.title.contains($0) }
            }
        }
        result.shuffle()
        return Array(result.prefix(count))
    }

    /// 🔴 v2.9.8：经典推荐 —— 100 首、随机顺序；《吻别》仍然排最后（之前的特例需求保留）。
    private func loadClassicSongs() async -> [Song] {
        let loaded = await shuffledSearchSongs(keyword: "华语经典 怀旧", count: 100)
        let kiss = loaded.filter { $0.title.contains("吻别") }
        let rest = loaded.filter { !$0.title.contains("吻别") }
        return rest + kiss
    }

    /// 🔴 v2.9.8：DJ推荐 —— 100 首、随机顺序。
    private func loadDJSongs() async -> [Song] {
        await shuffledSearchSongs(keyword: "热门DJ 舞曲", count: 100)
    }

    // MARK: 加载

    /// 🔴 2026-11-14：新歌推荐改接**酷狗官方「新歌榜」**（rankid=74534，每日更新）。
    /// 旧实现是 `searchSongs(keyword: "新歌榜")` —— 拿关键词去搜索接口碰运气，
    /// 返回的是歌名/歌单混杂结果，既不是真实新歌，还要为凑数串行翻页 + 逐个补封面。
    /// 现在一次 `/rank/info` 请求直接拿官方新歌榜的 30 首，自带 album_sizable_cover 封面；
    /// 保持榜单原序（真实排名），不再随机打乱、也不再用黑名单筛老歌。
    private func loadNewSongs(force: Bool = false) async {
        if isLoadingNewSongs { return }
        if !force, !newSongs.isEmpty { return }
        isLoadingNewSongs = true
        defer { isLoadingNewSongs = false }
        var picked = await KugouClient.shared.newSongRecommendations(limit: 28)
        if picked.isEmpty {
            // 弱网偶发失败：隔 0.6s 补一次，避免骨架一直挂着。
            try? await Task.sleep(nanoseconds: 600_000_000)
            picked = await KugouClient.shared.newSongRecommendations(limit: 28)
        }
        // 裁成 4 的倍数：横滑卡片每屏整整齐齐，不出现半行。
        let trimmed = Array(picked.prefix(picked.count / 4 * 4))
        guard !trimmed.isEmpty else { return }
        newSongs = trimmed
        Log.info("发现页", "新歌推荐 \(trimmed.count) 首（酷狗新歌榜 74534 真实数据）")
    }

    private func load(force: Bool = false) async {
        guard !isLoading else { return }
        // 🔴 2026-11-13：每日推荐按「自然日」与酷狗同步，跨天自动重拉一次，
        //    即使其它板块都有缓存也不能跳过（否则每天看到的还是昨天那批歌）。
        let stale = dailyStale
        if !force, !stale,
           !feed.topLists.isEmpty, !guessSongs.isEmpty,
           !dailySongs.isEmpty, !hotArtists.isEmpty,
           !recommendedPlaylists.isEmpty {
            return
        }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        // 下拉刷新时顺手刷新「新歌推荐」。
        // ⚠️ 「猜你喜欢」不再在 force 时另起 Task：它必须与「每日推荐」串行，
        //    否则两栏同时拉取、后写的那份没法做去重，会出现一模一样的歌。
        if force {
            Task { await loadNewSongs(force: true) }
        }
        // 🔴 2026-11-13：把「每日推荐 / 猜你喜欢」提到榜单之前。
        //    topLists() 冷启动要 3 次退避重试（最多 1.8s）甚至卡更久，
        //    放在前面会拖慢首屏这两栏；现在先出歌，再补榜单。
        //    顺序固定：先拿酷狗官方每日推荐，再拉猜你喜欢（不同数据源），最后统一去重。
        if force || stale || dailySongs.isEmpty { await loadDailySongs() }
        if force || stale || guessSongs.isEmpty { await loadGuess() }
        await reconcileDailyAndGuess()
        if feed.topLists.isEmpty {
            // 🔴 2026-11-12：冷启动时网络栈刚就绪，首个 topLists() 常常直接失败。
            //    旧版一次失败就立刻把 errorMessage 摆出来并 return，用户每次开 App
            //    都要手动点「重试」才有画面。现在做 3 次退避重试；即使全失败也
            //    **不 return**，继续把其它板块拉出来，首屏不再是一片「加载失败」。
            for attempt in 0..<3 {
                let lists = await KugouClient.shared.topLists()
                if !lists.isEmpty {
                    feed.topLists = lists
                    break
                }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1)))
                }
            }
        }
        if force || hotArtists.isEmpty {
            hotArtists = await KugouClient.shared.hotArtists(count: 50)
        }
        // 🔴 v2.9.17：热门歌手专辑板块 —— 取前 8 位歌手各自的一张专辑（并发拉）。
        if artistAlbums.isEmpty {
            Task { await loadArtistAlbums() }
        }
        if recommendedPlaylists.isEmpty {
            let result = await KugouClient.shared.recommendedPlaylists(page: 1)
            recommendedPlaylists = result.playlists
            squareTotal = result.total
            squarePage = 1
        }
        // 三个新推荐板块
        if ktvSongs.isEmpty { ktvSongs = (try? await KugouClient.shared.searchSongs(keyword: "KTV必点 经典", limit: 30)) ?? [] }
        // 🔴 v2.9.8：经典推荐 / DJ推荐 各 100 首 + 随机顺序。
        // 各要翻 4 页搜索接口，串行太慢 → 并发拉取。
        async let classicTask = loadClassicSongs()
        async let djTask = loadDJSongs()
        let (loadedClassic, loadedDJ) = await (classicTask, djTask)
        if classicSongs.isEmpty { classicSongs = loadedClassic }
        if djSongs.isEmpty { djSongs = loadedDJ }
        // 🔴 2026-11-11：新歌推荐已拆到 `loadNewSongs()`，由视图 .task 与 load() **并发**发起，
        //    不再压在这条串行链末尾（详见该方法注释）。这里保持原样，别再搬回来。
        // 🔴 v2.9.6：「至臻音质」主题歌单（供「歌单推荐」大卡用）
        if hallSongs.isEmpty {
            hallSongs = (try? await KugouClient.shared.searchSongs(keyword: "至臻音质 臻品母带", limit: 20)) ?? []
        }
        let whitelistedSlices = filteredLists
        await loadTrackCounts(for: whitelistedSlices.prefix(5))
        // 🔴 2026-11-12：只有全部板块都空，才说明这次真的一条内容都没拿到。
        //    此时不让用户点「重试」，自动再补一次（最多 2 轮）；只要有任何板块
        //    出了内容，就清掉错误态并把计数归零。
        let totallyEmpty = feed.topLists.isEmpty && guessSongs.isEmpty
            && dailySongs.isEmpty && hotArtists.isEmpty
            && recommendedPlaylists.isEmpty && ktvSongs.isEmpty
            && classicSongs.isEmpty && djSongs.isEmpty
            && newSongs.isEmpty && hallSongs.isEmpty
        if totallyEmpty {
            errorMessage = "拿不到榜单，检查一下网络或稍后再试"
            if autoRetryCount < 2 {
                autoRetryCount += 1
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await load(force: true)
                }
            }
        } else {
            errorMessage = nil
            autoRetryCount = 0
            saveSnapshot()
        }
    }

    /// 🔴 2026-11-13：把这次拿到的首屏数据落盘，供下次冷启动**首帧直接出内容**。
    /// 编码在后台队列（DiscoverFeedCache），这里只做值拷贝。
    private func saveSnapshot() {
        guard !feed.topLists.isEmpty || !dailySongs.isEmpty || !guessSongs.isEmpty else { return }
        let snap = DiscoverSnapshot(feed: feed,
                                    guessSongs: guessSongs,
                                    guessPool: guessPool,
                                    dailySongs: dailySongs,
                                    dailyPick: dailyPick,
                                    guessPick: guessPick,
                                    hotArtists: hotArtists,
                                    recommendedPlaylists: recommendedPlaylists,
                                    ktvSongs: ktvSongs,
                                    classicSongs: classicSongs,
                                    djSongs: djSongs,
                                    newSongs: newSongs,
                                    hallSongs: hallSongs,
                                    savedAt: Date().timeIntervalSince1970)
        DiscoverFeedCache.shared.save(snap)
    }

    private static let dailyDayStoreKey = "aurora.discover.dailyDay"

    /// 本地自然日戳（不是 UTC，跨零点就换）。
    private var dayStamp: String {
        let c = Calendar(identifier: .gregorian)
        let d = c.dateComponents([.year, .month, .day], from: Date())
        return "\(d.year ?? 0)-\(d.month ?? 0)-\(d.day ?? 0)"
    }

    /// 今天还没成功同步过酷狗官方每日推荐 → 需要重拉。
    private var dailyStale: Bool {
        UserDefaults.standard.string(forKey: Self.dailyDayStoreKey) != dayStamp
    }

    private func markDailyFresh() {
        UserDefaults.standard.set(dayStamp, forKey: Self.dailyDayStoreKey)
    }

    // MARK: - 🔴 2026-11-13 第二轮：两栏重复的真正根因与统一出口
    //
    //  ① `guessYouLike()` 未登录时回退到 `everydayRecommendSongs()`，
    //     而「每日推荐」正是这个接口 —— 同一个请求、同一份 30 首，必然一模一样；
    //  ② 首屏 `.task` 里另起过一个非结构化 Task 并发跑 `loadGuess()`，
    //     常在「去重」跑完之后才把原始（未去重）数据写回 `guessSongs`；
    //  ③ `.task(id: 登录态)` 也会单独重拉每日推荐、绕过去重。
    //  现在：两栏用**不同**数据源，且所有写入路径最后都过一次 `applyDailyAndGuess()`。

    /// 歌名 + 歌手归一化：不同接口给同一首歌的 hash/id 可能不一样，双保险。
    private func songKey(_ s: Song) -> String {
        (s.cleanTitle + "|" + s.artist).lowercased().filter { !$0.isWhitespace }
    }

    private func rememberGuessCandidates(_ songs: [Song]) {
        var next = guessPool
        var seen = Set(next.map(\.id))
        for s in songs where !seen.contains(s.id) {
            next.append(s)
            seen.insert(s.id)
        }
        if next.count > 120 { next = Array(next.prefix(120)) }
        // @State 数组也整体替换，避免原地改动与 SwiftUI 遍历撞车。
        if next.count != guessPool.count { guessPool = next }
    }

    /// 唯一的上屏出口：按当前每日推荐剔除重复，不足 30 首从备用池补齐。
    /// 无论数据从哪条并发路径回来，最终展示的都是「与每日推荐不重复」的那一批。
    private func applyDailyAndGuess() {
        guard !dailySongs.isEmpty else { return }
        let dailyIDs = Set(dailySongs.map(\.id))
        let dailyKeys = Set(dailySongs.map { songKey($0) })
        var seen = Set<String>()
        var result: [Song] = []
        for s in guessSongs + guessPool {
            if dailyIDs.contains(s.id) || dailyKeys.contains(songKey(s)) { continue }
            if !seen.insert(s.id).inserted { continue }
            result.append(s)
            if result.count >= 30 { break }
        }
        // 备用池还没数据时不要硬清空界面；下面的 reconcile 会继续拉真实榜单补池。
        guard result.count >= 3 else { return }
        if result.map(\.id) != guessSongs.map(\.id) {
            guessSongs = result
            guessPick = result.first(where: { $0.artworkURL != nil }) ?? result.first
            Log.info("发现页", "两栏去重后 猜你喜欢 \(result.count) 首（每日推荐 \(dailySongs.count) 首）")
        }
    }

    /// 备用池不够时按酷狗真实榜单补齐（飙升榜 / 网络热歌榜 / TOP500）。
    private func reconcileDailyAndGuess() async {
        guard !dailySongs.isEmpty else { return }
        applyDailyAndGuess()
        if guessSongs.count < 20 {
            for rid in ["6666", "82831", "8888"] {
                guard let extra = try? await KugouClient.shared.rankSongs(rankID: rid, limit: 60),
                      !extra.isEmpty else { continue }
                rememberGuessCandidates(extra)
                applyDailyAndGuess()
                if guessSongs.count >= 20 { break }
            }
        }
    }

    /// 🔴 2026-11-13：每日推荐直接同步酷狗 App 的官方「每日推荐」（30 首、每天更新）。
    ///    旧版要求登录，未登录就整段回退 TOP500，和猜你喜欢/榜单内容撞车；
    ///    现在未登录也走官方接口（实测可用），只有接口真的失败才回退 TOP500。
    private func loadDailySongs() async {
        if let recs = await KugouClient.shared.dailyRecommendSongs(limit: 30),
           !recs.isEmpty {
            var enriched = recs
            // 推荐接口部分歌可能没封面 → 优先拿有封面的做封面卡；没封面的反查专辑补图
            var pick = enriched.first(where: { $0.artworkURL != nil }) ?? enriched.first
            if let p = pick, p.artworkURL == nil, !p.kugouAlbumID.isEmpty,
               let cover = await KugouClient.shared.albumCover(albumID: p.kugouAlbumID) {
                var fixed = p
                fixed.artworkURL = cover
                if let idx = enriched.firstIndex(where: { $0.id == p.id }) {
                    enriched[idx].artworkURL = cover
                }
                pick = fixed
            }
            dailySongs = enriched
            dailyPick = pick
            markDailyFresh()
            // 每日推荐换了 → 立刻按新列表重新给猜你喜欢去重。
            applyDailyAndGuess()
            Log.info("发现页", "每日推荐(酷狗官方同步) \(enriched.count) 首，封面：\(pick?.title ?? "-")")
            return
        }
        // 回退：酷狗 TOP500 前 30 首（同样是酷狗真实数据），补齐第一首封面。
        guard let songs = try? await KugouClient.shared.rankSongs(rankID: "8888", limit: 30),
              !songs.isEmpty else {
            Log.warn("发现页", "每日推荐 TOP500 0 首")
            return
        }
        var enriched = songs
        if enriched[0].artworkURL == nil, !enriched[0].kugouAlbumID.isEmpty,
           let cover = await KugouClient.shared.albumCover(albumID: enriched[0].kugouAlbumID) {
            enriched[0].artworkURL = cover
        }
        dailySongs = enriched
        // 🔴 v2.9.8：卡片上随机展示的那一首必须带封面，否则卡片掉成灰渐变占位（用户反馈）。
        // 优先在「已有封面」的歌里随机；若随机到的没封面、整列又没现成封面，
        // 则取第一首有 albumID 的歌反查专辑封面兜底（最多 1 次网络请求）。
        var pick = enriched.randomElement()
        if let p = pick, p.artworkURL == nil {
            if let withCover = enriched.first(where: { $0.artworkURL != nil }) {
                pick = withCover
            } else if let toEnrich = enriched.first(where: { !$0.kugouAlbumID.isEmpty }),
                      let cover = await KugouClient.shared.albumCover(albumID: toEnrich.kugouAlbumID) {
                var fixed = toEnrich
                fixed.artworkURL = cover
                if let idx = enriched.firstIndex(where: { $0.id == toEnrich.id }) {
                    enriched[idx].artworkURL = cover
                    dailySongs = enriched
                }
                pick = fixed
            }
        }
        dailyPick = pick
        applyDailyAndGuess()
        Log.info("发现页", "每日推荐(回退TOP500) \(enriched.count) 首，第一首：\(enriched[0].title) - \(enriched[0].artist)")
    }

    /// 🔴 2026-11-13 第二轮：「猜你喜欢」改用**与每日推荐不同**的酷狗真实数据源。
    ///   登录 → 私人 FM 个性化推荐（/personal_recommend）；
    ///   未登录 / 风控 200101 → 酷狗真实榜单（飙升榜 6666 → 网络热歌榜 82831 → DJ 热歌榜 24971）。
    ///   ⚠️ 绝不再回退 `/everyday_song_recommend`——那是「每日推荐」的数据源，
    ///      两栏会拿到同一批歌（用户截图里「心之火(DJ版)/DAY BY DAY/落」三首完全重复）。
    private func loadGuess() async {
        guard !isLoadingGuess else { return }
        isLoadingGuess = true
        defer { isLoadingGuess = false }

        var songs: [Song] = await KugouClient.shared.guessYouLike(limit: 30) ?? []
        if songs.isEmpty {
            for rid in ["6666", "82831", "24971"] {
                if let ranked = try? await KugouClient.shared.rankSongs(rankID: rid, limit: 30),
                   !ranked.isEmpty {
                    songs = ranked
                    Log.info("发现页", "猜你喜欢(酷狗榜单 \(rid)) \(ranked.count) 首")
                    break
                }
            }
        }
        guard !songs.isEmpty else {
            Log.warn("发现页", "猜你喜欢 0 首")
            return
        }

        // 真实推荐接口已带 sizable_cover；这里只给个别缺图的歌按 albumID 补一次封面。
        let needCover = songs.filter { $0.artworkURL == nil && !$0.kugouAlbumID.isEmpty }
        if !needCover.isEmpty {
            await withTaskGroup(of: (String, URL?).self) { group in
                for song in needCover {
                    group.addTask { await (song.kugouAlbumID, KugouClient.shared.albumCover(albumID: song.kugouAlbumID)) }
                }
                for await (aid, cover) in group {
                    if let cover {
                        for i in songs.indices where songs[i].kugouAlbumID == aid {
                            songs[i].artworkURL = cover
                        }
                    }
                }
            }
        }

        // 先入备用池，再走统一出口：即使本方法是被并发 Task 调用的，
        // 最后一步也会按「当前每日推荐」重新去重，不会出现两栏撞车。
        rememberGuessCandidates(songs)
        guessSongs = songs
        var pick = songs.randomElement()
        if let g = pick, g.artworkURL == nil,
           let withCover = songs.first(where: { $0.artworkURL != nil }) {
            pick = withCover
        }
        guessPick = pick
        applyDailyAndGuess()
        Log.info("发现页", "猜你喜欢(酷狗真实数据) \(songs.count) 首，第一首：\(songs[0].title) - \(songs[0].artist)")
    }

    /// 歌单广场滚动加载下一页（共 20 页 600 个）
    private func loadMorePlaylists() async {
        guard !isLoadingMore, recommendedPlaylists.count < squareTotal else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let nextPage = squarePage + 1
        let result = await KugouClient.shared.recommendedPlaylists(page: nextPage)
        guard !result.playlists.isEmpty else {
            // 接口翻到底了：把 total 收口，隐藏底部加载触发器，避免反复空请求
            squareTotal = recommendedPlaylists.count
            return
        }
        var existing = Set(recommendedPlaylists.map(\.id))
        for p in result.playlists where !existing.contains(p.id) {
            recommendedPlaylists.append(p)
            existing.insert(p.id)
        }
        squarePage = nextPage
        Log.info("发现页", "歌单广场第 \(nextPage) 页，累计 \(recommendedPlaylists.count)/\(squareTotal)")
    }

    private func loadTrackCounts(for lists: ArraySlice<Playlist>) async {
        let client = KugouClient.shared
        typealias Hit = (String, String, Int, Int)
        var hits: [Hit] = []
        await withTaskGroup(of: Hit?.self) { group in
            let concurrency = 4
            let sem = AsyncStream.makeStream(of: Void.self)
            nonisolated(unsafe) var active = 0
            for (index, playlist) in lists.enumerated() {
                guard let rankID = playlist.kugouRankID else { continue }
                let pid = playlist.id
                let rid = rankID
                while active >= concurrency { _ = await sem.stream.first(where: { _ in true }) }
                active += 1
                group.addTask {
                    defer {
                        active -= 1
                        sem.continuation.yield()
                    }
                    if let total = await client.rankTotal(rankID: rid) {
                        return (pid, rid, index, total)
                    }
                    return nil
                }
            }
            for await hit in group {
                if let hit { hits.append(hit) }
            }
        }
        await MainActor.run {
            for (pid, _, _, total) in hits {
                if let idx = feed.topLists.firstIndex(where: { $0.id == pid }) {
                    feed.topLists[idx].trackCount = total
                }
            }
        }
    }
}

// MARK: - 🔴 2026-11-12 横幅轮播（独立子视图）

/// 轮播状态 + 4 秒计时器都关在这个视图里。
///
/// 以前 `@State adIndex` / `Timer.publish(...).autoconnect()` 挂在 DiscoverView 上，
/// 每 4 秒一次 `withAnimation` 会让**整页 body** 重算：十几个推荐板块、
/// 歌手 A–Z 全量分组排序、ScrollViewReader 里几百个懒加载子视图全部跟着失效，
/// 真机上就表现成「主页有时候会卡死 / 滑动掉帧」。
/// 现在重算范围只剩横幅自己，父页面只在切 Tab / 数据到达时才刷新。
private struct AdBannerCarousel: View {
    @ObservedObject private var bannerConfig = BannerConfig.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var adIndex = 0
    private let adTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        let imgs: [UIImage?] = bannerConfig.effectiveImages.isEmpty
            ? [nil, nil] : bannerConfig.effectiveImages
        let count = imgs.count
        let h = (UIScreen.main.bounds.width - 32) * 7 / 16 // 16:7
        return TabView(selection: $adIndex) {
            ForEach(Array(imgs.indices), id: \.self) { i in
                bannerImage(at: i, in: imgs)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: h)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomTrailing) { dots(count: count) }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onReceive(adTimer) { _ in
            // 🔴 2026-11-13：App 退到后台 / 页面已不在前台时别再驱动 TabView 翻页。
            //    新系统（用户反馈 iOS 27）在后台收到 withAnimation 时更容易触发
            //    布局重入；前台外一律跳过，回前台后由下一次 tick 自然恢复。
            guard scenePhase == .active, count > 1 else { return }
            let cur = min(adIndex, count - 1)
            withAnimation(.easeInOut(duration: 0.4)) {
                adIndex = (cur + 1) % count
            }
        }
        // 云端 / 本机换图后张数可能变少，把越界 selection 拉回来，避免空白页。
        .onChange(of: count) { newCount in
            if adIndex >= newCount { adIndex = 0 }
        }
    }

    /// 右下角自定义页码点：当前页长条、其余圆点。
    private func dots(count: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == adIndex ? Color.white : Color.white.opacity(0.5))
                    .frame(width: i == adIndex ? 14 : 6, height: 6)
            }
        }
        .padding(6)
        .background(Capsule().fill(Color.black.opacity(0.28)))
        .padding(.trailing, 10)
        .padding(.bottom, 10)
    }

    /// 优先自定义 / 云端图；该位置没图时回退 Assets 默认图（按奇偶循环）。
    private func bannerImage(at index: Int, in imgs: [UIImage?]) -> some View {
        let fallback = (index % 2 == 0) ? "BannerAd1" : "BannerAd2"
        return Group {
            if let ui = imgs[index] {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Image(fallback).resizable().scaledToFill()
            }
        }
    }
}

// MARK: - Tab 枚举

enum DiscoverTab: String, CaseIterable, Hashable {
    /// 🔴 2026-11-09：用户要求「榜单后面加一个歌手板块」—— 顺序按 allCases，
    ///    所以 artists 必须排在 ranks 之后、audiobook 之前。
    case recommend, playlists, ranks, artists, audiobook
    var title: String {
        switch self {
        case .recommend: return "推荐"
        case .ranks: return "榜单"
        case .playlists: return "歌单"
        case .artists: return "歌手"
        case .audiobook: return "听书"
        }
    }
}

// MARK: - 封面功能卡（每日推荐 / 猜你喜欢）

/// 大封面 + 标签叠加 + 底部标题副标题 + 播放按钮。
struct CoverFeatureCard: View {
    let width: CGFloat
    let height: CGFloat
    let coverURL: URL?
    let title: String
    let subtitle: String
    var isPlaying: Bool = false
    var showPlayButton: Bool = true
    var showText: Bool = true   // 小卡传 false 隐藏所有文字
    /// 🔴 v2.9.7：副标题最多显示几行（默认 1；「每日推荐」「猜你喜欢」传 3 显示多首歌）
    var subtitleLineLimit: Int = 1
    var onPlay: () -> Void = {}

    private var corner: CGFloat { 14 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 封面图（传完整宽高让 scaledToFill 铺满整个卡片）
            CoverImage(url: coverURL,
                       fallbackKeys: [],
                       seed: title,
                       size: min(width, height),
                       corner: corner,
                       displayWidth: width,
                       displayHeight: height)

            // 底部黑色半透明渐变遮罩（有文字才需要）
            if showText {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    LinearGradient(colors: [.clear, Color.black.opacity(0.75)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: height * 0.5)
                }
                .frame(width: width, height: height)
            }

            // 标题 + 副标题 + 播放按钮（底部）
            HStack(alignment: .bottom) {
                if showText {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: width * 0.13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: width * 0.075))
                                .foregroundStyle(.white.opacity(0.85))
                                // 🔴 v2.9.7：副标题可以放多首歌名（多行显示），
                                // 单行时行为和以前一样。
                                .lineLimit(subtitleLineLimit)
                                .minimumScaleFactor(0.5)
                        }
                    }
                }
                if showPlayButton {
                    Spacer()
                    Button {
                        onPlay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.25), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { onPlay() })
                }
            }
            .padding(10)
            .frame(width: width)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - 纯色图标卡（百万收藏 / 新歌推荐）

/// 渐变背景 + 大图标 + 左上角标题。
struct IconFeatureCard: View {
    let width: CGFloat
    let desiredHeight: CGFloat   // 仅用于内部计算字号/图标大小，不锁死 frame
    let title: String
    let systemIcon: String
    let gradientColors: [Color]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: gradientColors,
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)

            Text(title)
                .font(.system(size: width * 0.16, weight: .bold))
                .foregroundStyle(Color(white: 0.15))
                .padding(10)

            Image(systemName: systemIcon)
                .font(.system(size: min(width, desiredHeight) * 0.55, weight: .light))
                .foregroundStyle(Color(white: 0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, width * 0.12)
                .padding(.bottom, desiredHeight * 0.18)
        }
        .frame(width: width)   // 只锁宽度，高度由外层 frame 决定
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Feed 歌曲行

struct FeedSongRow: View {
    let song: Song
    var showLimitTag: Bool = false
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: song.artworkURL,
                       fallbackKeys: song.coverFallbackKeys,
                       seed: "\(song.artist)-\(song.title)",
                       size: 56,
                       corner: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(song.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                // 🔴 用户要求：列表里不再显示 VIP 标签（只在迷你播放器 / 竖屏播放器保留）。
                Text(song.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                _ = library.toggleFavorite(song)
                Haptics.light()
            } label: {
                Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart")
                    .font(.system(size: 20))
                    .foregroundStyle(library.isFavorite(song) ? AppStyle.like : AppStyle.secondaryText.opacity(0.7))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - 歌手行

struct ArtistRow: View {
    let artist: Artist
    var isPlaying: Bool = false
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: artist.coverURL,
                       fallbackKeys: [artist.id],
                       seed: artist.name,
                       size: 46,
                       corner: 23)
            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(fansText)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }
            Spacer()
            if isPlaying {
                ProgressView()
            }
            Button {
                _ = library.toggleArtistFavorite(artist)
                Haptics.light()
            } label: {
                Image(systemName: library.isFavoriteArtist(artist) ? "heart.fill" : "heart")
                    .font(.system(size: 18))
                    .foregroundStyle(library.isFavoriteArtist(artist) ? AppStyle.like : AppStyle.tertiaryText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var fansText: String {
        if artist.fansCount >= 10_000 {
            return String(format: "%.1f万粉丝", Double(artist.fansCount) / 10_000)
        } else if artist.fansCount > 0 {
            return "\(artist.fansCount) 粉丝"
        }
        return "热门歌手"
    }
}

// MARK: - 更多歌手页（热门歌手"更多"入口，无限下拉刷新）

/// 热门歌手「更多」页：先展示首页已加载的歌手，再往底部滚动时逐页加载，
/// 直到接口返回不足一页（到底）。支持顶部下拉刷新（重置后从第一页重新拉取）。
struct MoreArtistsView: View {
    /// 首页推荐流里已加载的热门歌手（通常 50 位），作为首屏内容，避免重复请求。
    let initial: [Artist]

    @State private var artists: [Artist] = []
    /// 下一页要拉的页码。首页 initial 已涵盖前若干页，这里接着往后翻。
    @State private var page: Int = 1
    @State private var isLoadingMore = false
    @State private var hasMore = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if artists.isEmpty {
                    ListRowsSkeleton(rows: 8)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, 16)
                } else {
                    // 用 LazyVStack：只有滚到视口的行才构建，配合底部 onAppear 触发器
                    // 实现无限滚动（前面 VStack 全量渲染 50+ 行会越滚越卡）。
                    LazyVStack(spacing: 0) {
                        ForEach(artists) { artist in
                            artistRow(artist)
                                .id(artist.id)
                            if artist.id != artists.last?.id {
                                Divider().padding(.leading, 68)
                            }
                        }

                        if hasMore {
                            SkeletonInlineRow()
                                .padding(.vertical, 16)
                            // 🔴 滚到底部自动加载下一页；isLoadingMore / hasMore 双保险防重复触发
                            .onAppear { Task { await loadMore() } }
                        } else {
                            Text("已经到底啦 ~")
                                .font(.system(size: 12))
                                .foregroundStyle(AppStyle.tertiaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }
                    .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    // 🔴 给右侧英文选择条留白，避免挡住歌手名
                    .padding(.trailing, 18)
                }
            }
            .background(AppStyle.background)
            .overlay(alignment: .trailing) { alphabetBar(proxy: proxy) }
            .navigationTitle("热门歌手")
            .navigationBarTitleDisplayMode(.inline)
            // 🔴 v2.9.6(修正)：二级页/弹窗的导航栏统一改成白色（主页那四个保持淡蓝渐变）
            .kugouNavigationBarBackground()
            // 顶部下拉刷新：清空后从第一页重新拉取
            .refreshable { await reload() }
            .task {
                guard artists.isEmpty else { return }
                artists = initial
                // initial 已涵盖前 (initial.count/20) 页，接着往后翻
                page = initial.isEmpty ? 1 : (initial.count / 20) + 1
                await loadMore()
            }
        }
    }

    /// 右侧英文选择条：A–Z + #，点击滚到该字母第一位歌手。
    /// 只对已加载出的歌手生效（列表是无限滚动，未加载的字母点了也不跳）。
    private func alphabetBar(proxy: ScrollViewProxy) -> some View {
        // 🔴 两边都必须是 [String]：Array("ABC") 是 [Character]，[String]+[Character]
        // 类型不匹配，会把 ForEach 的泛型推断带崩（CI 上 5 个 error 全是这一行连坐）。
        let letters = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }
        return VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    if let target = artists.first(where: { $0.initialLetter == letter }) {
                        withAnimation { proxy.scrollTo(target.id, anchor: .top) }
                    }
                } label: {
                    Text(letter)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(hasLetter(letter)
                                        ? AppStyle.tertiaryText
                                        : AppStyle.tertiaryText.opacity(0.25))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .disabled(!hasLetter(letter))
            }
        }
        .padding(.trailing, 3)
        .padding(.vertical, 6)
    }

    private func hasLetter(_ letter: String) -> Bool {
        artists.contains { $0.initialLetter == letter }
    }

    private func artistRow(_ artist: Artist) -> some View {
        NavigationLink {
            ArtistDetailView(artist: artist)
        } label: {
            ArtistRow(artist: artist, isPlaying: false)
        }
        .buttonStyle(.plain)
    }

    /// 拉取下一页并追加（按 id 去重，防止 initial 与后续分页重叠）。
    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let batch = await KugouClient.shared.hotArtistsPage(page: page, perPage: 20)
        await MainActor.run {
            let existing = Set(artists.map(\.id))
            for a in batch where !existing.contains(a.id) {
                artists.append(a)
            }
            page += 1
            if batch.isEmpty || batch.count < 20 { hasMore = false }
            Log.info("歌手", "更多页累计 \(artists.count) 位，hasMore=\(hasMore)")
        }
    }

    private func reload() async {
        await MainActor.run {
            // 先重新铺上首页已加载的歌手（秒回首屏），再从其后继续翻页
            artists = initial
            page = initial.isEmpty ? 1 : (initial.count / 20) + 1
            hasMore = true
        }
        await loadMore()
    }
}

// MARK: - 榜单行

private struct RankRow: View {
    let playlist: Playlist
    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: playlist.coverURL,
                       fallbackKeys: [playlist.id],
                       seed: playlist.name,
                       size: 48,
                       corner: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if playlist.trackCount > 0 {
                        Text("\(playlist.trackCount) 首")
                            .font(.system(size: 11))
                            .foregroundStyle(AppStyle.accent)
                    } else if !playlist.updateFrequency.isEmpty {
                        Text(playlist.updateFrequency)
                            .font(.system(size: 11))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                    Text("酷狗")
                        .font(.system(size: 10))
                        .foregroundStyle(AppStyle.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(AppStyle.accent.opacity(0.12), in: Capsule())
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppStyle.tertiaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - 🔴 2026-11-13 第七轮：主页顶栏「已连接」接入当前音源状态
//
// 单独抽成一个小视图订阅 SourceHealth / SourceStore：音源检测每写完一条结果，
// 只重算这一小块，不会让 DiscoverView 整页 body 重算（主页卡顿红线）。
// 颜色规则与「第三方音源」列表里的圆点一致：音源绿=绿、音源红=红。
//   · 有任一启用音源检测为「可用（绿点）」→ 绿点 + 已连接；
//   · 一个可用都没有、且检测出了「无用（红点）」→ 红点 + 未连接；
//   · 还没检测完 / 检测被跳过 → 保持绿点 + 已连接（不误报异常）。
private struct SourceStatusBadge: View {
    @ObservedObject private var health = SourceHealth.shared
    @ObservedObject private var sourceStore = SourceStore.shared

    private var isRed: Bool {
        let enabled = sourceStore.sources.filter { $0.enabled && $0.isUsable }
        guard !enabled.isEmpty else { return false }
        var hasOK = false
        var hasBad = false
        for source in enabled {
            switch health.status(for: source.id) {
            case .ok: hasOK = true
            case .bad: hasBad = true
            default: break
            }
        }
        return !hasOK && hasBad
    }

    private var dotColor: Color {
        isRed ? Color(red: 0.90, green: 0.22, blue: 0.22)
              : Color(red: 0.16, green: 0.76, blue: 0.38)
    }

    private var textColor: Color {
        isRed ? Color(red: 0.78, green: 0.18, blue: 0.18)
              : Color(red: 0.13, green: 0.58, blue: 0.30)
    }

    var body: some View {
        HStack(spacing: 3) {
            // 🔴 发光圈改小：圆点 4pt、光晕 2.2 倍、blur 1.8（见 BreathingStatusDot）。
            BreathingStatusDot(size: 4, color: dotColor)
            Text(isRed ? "未连接" : "已连接")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(textColor)
        }
    }
}
