import SwiftUI

/// 发现页（新版）。Tab 栏 → 搜索框 → 2×2 宫格卡片 → 心情问候 + 歌曲列表 → 热门榜单。
struct DiscoverView: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var kugouAuth = KugouAuth.shared
    @State private var feed = DiscoverFeed()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var guessSongs: [Song] = []
    @State private var isLoadingGuess = false
    @State private var dailySongs: [Song] = []
    @State private var hotArtists: [Artist] = []
    @State private var playingArtistID: String?
    @State private var recommendedPlaylists: [Playlist] = []
    @State private var squarePage = 1
    @State private var squareTotal = 0
    @State private var isLoadingMore = false
    @State private var selectedTab: DiscoverTab = .recommend
    @State private var pendingArtist: Artist?

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
    @State private var newSongs: [Song] = []
    /// 🔴 v2.9.6：「至臻音质」主题歌单的歌曲（供「歌单推荐」大卡使用）
    @State private var hallSongs: [Song] = []

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

    /// 猜你喜欢的抽词池。
    static let guessPool: [String] = [
        "抖音热歌", "华语经典", "粤语金曲", "伤感情歌", "欧美流行",
        "网络热歌", "轻音乐", "90后回忆", "KTV必点", "影视金曲",
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let errorMessage, feed.isEmpty {
                    errorState(errorMessage)
                } else if isLoading, feed.isEmpty {
                    LoadingRow()
                } else {
                    // 歌单 Tab：搜索框变成「搜索歌单」；其它 Tab 保持全局搜索入口
                    if selectedTab == .playlists {
                        playlistSearchBar
                    } else {
                        searchEntry
                    }
                    tabContent
                }
            }
            .padding(.bottom, 24)
        }
        // 🔴 v2.9.6(修正)：酷狗风格背景 —— 顶部淡蓝渐变钉在页面顶部，上滑不消失。
        // 渐变挂在 ScrollView 自身的背景上（相对可视区域固定），而不是滚动内容里。
        .kugouPinnedTopFade(height: 280)
        .refreshable { await load(force: true) }
        .task { if feed.isEmpty { await load() } }
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 v2.9.6：状态栏/导航栏那一段刷成淡蓝，和下面的渐变带连成一片
        .kugouNavigationBarTint()
        .safeAreaInset(edge: .top, spacing: 0) {
            tabBar
                // 🔴 v2.9.6：这一行（刷歌/推荐/乐库…）是钉在顶部的，
                // 不在滚动内容里，所以渐变带盖不到它 —— 单独刷成同一个淡蓝，
                // 和下面内容的渐变起点颜色一致，衔接处看不出硬边。
                .background(AppStyle.pageGradientTop)
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

            kugouAvatar
                .padding(.trailing, 12)
        }
        .frame(height: 44)
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
                    Text(kugouAuth.nickname.isEmpty ? "酷狗" : kugouAuth.nickname)
                        .font(.system(size: 13, weight: .medium))  // 12→13
                        .foregroundStyle(AppStyle.secondaryText)
                        .lineLimit(1)
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
                    Text("登录")
                        .font(.system(size: 13, weight: .medium))  // 12→13
                        .foregroundStyle(AppStyle.secondaryText)
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
        case .audiobook: audiobookContent
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
            bigCardsGrid
            // 🔴 v2.6.7：热门歌手改成横向头像排（不再是翻页列表），
            // 整页只保留「新歌推荐」一个翻页器，视觉噪音小很多。
            artistStripSection
            // 三个新推荐板块 —— 点"更多"push 进完整榜单页（复用已加载好的歌曲，省一次请求）
            newSongSection
            // 🔴 v2.9.6：新歌推荐下面是「推荐用户的歌单」（横滑歌单卡）→「歌单推荐」（横滑大卡）
            userPlaylistSection
            playlistRecommendSection
            songSection(title: "经典推荐", moreDestination: {
                NavigationLink {
                    PlaylistDetailView(
                        playlist: Playlist(id: "local-classic", name: "经典推荐",
                                           coverURL: nil, trackCount: classicSongs.count,
                                           creatorName: "Aurora 推荐", source: .kugou),
                        initialSongs: classicSongs)
                } label: {
                    HStack(spacing: 2) { Text("更多").font(.system(size: 12)); Image(systemName: "chevron.right").font(.system(size: 10)) }
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }, allSongs: classicSongs)
            songSection(title: "KTV必点曲", moreDestination: {
                NavigationLink {
                    PlaylistDetailView(
                        playlist: Playlist(id: "local-ktv", name: "KTV必点曲",
                                           coverURL: nil, trackCount: ktvSongs.count,
                                           creatorName: "Aurora 推荐", source: .kugou),
                        initialSongs: ktvSongs)
                } label: {
                    HStack(spacing: 2) { Text("更多").font(.system(size: 12)); Image(systemName: "chevron.right").font(.system(size: 10)) }
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }, allSongs: ktvSongs)
        }
    }

    // 🔴 v2.9.4：新歌推荐 —— 由「2×2 翻页宫格」改成 **单行横向滚动**。
    //
    // 翻页要按页码来回切，横滑一屏能看到更多，也不再需要底部页码圆点。
    // 下面是「推荐用户的歌单」（同样单排横滑）与「歌单推荐」（大卡横滑）。
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
                HStack {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                }.padding(.horizontal, 16)
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

    // MARK: 🔴 v2.9.6 推荐用户的歌单

    /// 「推荐用户的歌单」：酷狗歌单广场里用户创建的歌单，单排横滑。
    ///
    /// 显示方式与上面的「新歌推荐」一致（一行横滑、无页码点）：
    /// 封面 + 歌单名 + 创建者。数据复用首页已经加载好的 recommendedPlaylists，不额外发请求。
    private var userPlaylistSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("推荐用户的歌单") {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = .playlists }
                } label: {
                    HStack(spacing: 2) { Text("更多").font(.system(size: 12)); Image(systemName: "chevron.right").font(.system(size: 10)) }
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            if recommendedPlaylists.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                }.padding(.horizontal, 16)
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

    // MARK: 🔴 v2.9.4 歌单推荐

    /// 歌单推荐里的一张卡：一个主题歌单（标题 + 首数 + 播放 + 前 2 首预览）。
    private struct RecommendBucket: Identifiable {
        let id: String
        let title: String
        let songs: [Song]
    }

    /// 歌单推荐的数据：把首页已经加载好的几个歌曲池打包成「歌单」，
    /// 不再额外发请求 —— 点进去就是完整列表，点右侧播放键直接整张连播。
    private var recommendBuckets: [RecommendBucket] {
        var buckets: [RecommendBucket] = []
        func add(_ id: String, _ title: String, _ songs: [Song]) {
            guard songs.count >= 2 else { return }
            buckets.append(RecommendBucket(id: id, title: title, songs: songs))
        }
        add("hall", "至臻音质", hallSongs)
        add("new", "新歌推荐", newSongs)
        add("ktv", "KTV必点曲", ktvSongs)
        add("classic", "经典推荐", classicSongs)
        add("hall-fallback", "每日推荐", dailySongs)
        return buckets
    }

    private var playlistRecommendSection: some View {
        let buckets = recommendBuckets
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("歌单推荐") { EmptyView() }

            if buckets.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                }.padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(buckets) { bucket in
                            playlistRecommendCard(bucket)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func playlistRecommendCard(_ bucket: RecommendBucket) -> some View {
        let preview = Array(bucket.songs.prefix(2))
        // 🔴 v2.9.6：卡片左边补一张「第一首歌的封面」——
        // 之前整张卡是纯白的，看着很空；有了封面图才有歌单的感觉。
        let coverSong = bucket.songs.first
        let card =
            HStack(alignment: .top, spacing: 10) {
                CoverImage(url: coverSong?.artworkURL,
                           fallbackKeys: coverSong?.coverFallbackKeys ?? [],
                           seed: coverSong.map { "\($0.artist)-\($0.title)" } ?? bucket.title,
                           size: 62,
                           corner: 8)

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bucket.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppStyle.primaryText)
                            .lineLimit(1)
                        Text("\(bucket.songs.count) 首")
                            .font(.system(size: 11))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }

                    VStack(spacing: 6) {
                        ForEach(Array(preview.enumerated()), id: \.element.id) { index, song in
                            HStack(spacing: 6) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(index == 0 ? AppStyle.accent : AppStyle.tertiaryText)
                                    .frame(width: 12, alignment: .leading)
                                Text(song.cleanTitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppStyle.primaryText)
                                    .lineLimit(1)
                                Text("- \(song.artist)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppStyle.tertiaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .frame(width: 250, height: 118, alignment: .topLeading)
            .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        return ZStack(alignment: .topTrailing) {
            // 整张卡 → 进入完整列表（用零尺寸 NavigationLink 叠在最上层之下，
            // 播放按钮在 ZStack 上层，不会被跳转吞掉）
            card.overlay(alignment: .center) {
                NavigationLink {
                    PlaylistDetailView(
                        playlist: Playlist(id: "local-rec-\(bucket.id)", name: bucket.title,
                                           coverURL: bucket.songs.first?.artworkURL,
                                           trackCount: bucket.songs.count,
                                           creatorName: "Aurora 推荐", source: .kugou),
                        initialSongs: bucket.songs)
                } label: { Color.clear }
                .buttonStyle(.plain)
            }

            Button {
                Haptics.soft()
                store.play(bucket.songs, startAt: 0)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(AppStyle.accent, in: Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .frame(width: 250)
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

    // 通用歌曲板块：标题 + 更多按钮 + 5首歌曲列表
    private func songSection(title: String, @ViewBuilder moreDestination: () -> some View, allSongs: [Song]) -> some View {
        let shown = Array(allSongs.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title) { moreDestination() }

            if shown.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                }.padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song,
                                isCurrent: store.current?.id == song.id,
                                isPlaying: store.isPlaying)
                            .equatable()
                            .songMenu(song)
                            .padding(.horizontal, 16)
                            .onTapGesture {
                                guard let start = allSongs.firstIndex(where: { $0.id == song.id }) else { return }
                                store.play(allSongs, startAt: start); Haptics.soft()
                            }
                        if index < shown.count - 1 {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 大卡横排（每日推荐 + 猜你喜欢）+ 精选榜单每2张小卡叠加

    private var bigCardsGrid: some View {
        let sidePadding: CGFloat = 16
        let screenW = UIScreen.main.bounds.width
        let gap: CGFloat = 10
        // 卡片整体缩放 0.65
        let rawWidth = (screenW - sidePadding * 2 - gap) / 2
        let bigWidth = rawWidth * 0.65
        let bigHeight = bigWidth * 1.5
        // 两小卡叠加：(bigHeight - gap) / 2
        let smallCardHeight = (bigHeight - gap) / 2

        let isPlayingDaily = store.queueID == "daily" && store.isPlaying
        let isPlayingGuess = store.queueID == "guess" && store.isPlaying
        let currentCover = store.current?.artworkURL

        // NavigationLink 塞进 overlay，零尺寸干扰
        func navigable<Label: View>(destination: @escaping () -> some View, label: @escaping () -> Label) -> some View {
            label()
                .overlay(alignment: .center) {
                    NavigationLink { destination() } label: { Color.clear }
                        .buttonStyle(.plain)
                }
        }

        // 小卡叠加容器：VStack + 2张小卡 + 外层 clipped + 锁高度
        func smallCardGroup<Top: View, Bottom: View>(
            top: () -> Top, bottom: () -> Bottom
        ) -> some View {
            VStack(spacing: 0) {
                top().frame(width: smallCardHeight, height: smallCardHeight)
                Spacer(minLength: 0).frame(height: gap)
                bottom().frame(width: smallCardHeight, height: smallCardHeight)
            }
            .frame(width: smallCardHeight, height: bigHeight, alignment: .top)
            .frame(maxHeight: bigHeight, alignment: .top)
            .clipped()
        }

        // 精选榜单 → 每2个一组做小卡叠加
        let ranks = Array(filteredLists.prefix(5))
        // 把 ranks 按 2 个一组打包
        let groups: [(Playlist?, Playlist?)] = stride(from: 0, to: ranks.count, by: 2).map { i in
            (ranks[i], i + 1 < ranks.count ? ranks[i + 1] : nil)
        }

        // Playlist → 封面小卡（纯封面无文字无播放按钮）
        func rankCard(_ playlist: Playlist?) -> some View {
            Group {
                if let playlist {
                    navigable(
                        destination: { PlaylistDetailView(playlist: playlist) },
                        label: {
                            CoverFeatureCard(
                                width: smallCardHeight, height: smallCardHeight,
                                coverURL: playlist.coverURL,
                                title: playlist.name,
                                subtitle: "",
                                isPlaying: false,
                                showPlayButton: false,
                                showText: false
                            )
                        }
                    )
                } else {
                    Color.clear
                        .frame(width: smallCardHeight, height: smallCardHeight)
                }
            }
        }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: gap) {

                // ========== 1. 每日推荐（大卡） ==========
                navigable(
                    destination: {
                        Group {
                            if let t = filteredLists.first(where: { $0.kugouRankID == "8888" })
                                       ?? filteredLists.first {
                                PlaylistDetailView(playlist: t)
                            } else { EmptyView() }
                        }
                    },
                    label: {
                        CoverFeatureCard(
                            width: bigWidth, height: bigHeight,
                            coverURL: (isPlayingDaily ? currentCover : nil)
                                ?? dailySongs.first?.artworkURL
                                ?? top500Playlist?.coverURL
                                ?? filteredLists.first?.coverURL,
                            title: "每日推荐", subtitle: dailySubtitle,
                            isPlaying: isPlayingDaily,
                            onPlay: { if isPlayingDaily { store.pause() } else { playDailyAll() } }
                        )
                    }
                )
                .frame(width: bigWidth, height: bigHeight, alignment: .topLeading)
                .frame(maxHeight: bigHeight, alignment: .top)

                // ========== 2. 猜你喜欢（大卡） ==========
                navigable(
                    destination: {
                        Group {
                            if let t = filteredLists.first(where: { $0.kugouRankID == "52144" })
                                       ?? filteredLists.first {
                                PlaylistDetailView(playlist: t)
                            } else { EmptyView() }
                        }
                    },
                    label: {
                        CoverFeatureCard(
                            width: bigWidth, height: bigHeight,
                            coverURL: (isPlayingGuess ? currentCover : nil)
                                ?? guessSongs.first?.artworkURL,
                            title: "猜你喜欢", subtitle: guessSubtitle,
                            isPlaying: isPlayingGuess,
                            onPlay: { if isPlayingGuess { store.pause() } else { playGuessAll() } }
                        )
                    }
                )
                .frame(width: bigWidth, height: bigHeight, alignment: .topLeading)
                .frame(maxHeight: bigHeight, alignment: .top)

                // ========== 精选榜单：每 2 个一组小卡叠加 ==========
                ForEach(Array(groups.enumerated()), id: \.offset) { _, pair in
                    smallCardGroup(
                        top: { rankCard(pair.0) },
                        bottom: { rankCard(pair.1) }
                    )
                }
            }
            .frame(height: bigHeight)
            .padding(.horizontal, sidePadding)
        }
        .frame(height: bigHeight + 4)
    }

    /// 酷狗 TOP500 旗舰榜单（rankid=8888）
    private var top500Playlist: Playlist? {
        feed.topLists.first { $0.kugouRankID == "8888" }
    }

    private var guessSubtitle: String {
        if let first = guessSongs.first {
            return "\(first.title) · \(first.artist)"
        }
        return personalizedHint
    }

    private var dailySubtitle: String {
        if let first = dailySongs.first {
            return "\(first.title) · \(first.artist)"
        }
        return "酷狗TOP500 · 每日更新"
    }

    private var personalizedHint: String {
        let picks = Self.guessPool.prefix(2)
        return picks.joined(separator: "、")
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
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
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

    private func rankPreviewCard(playlist: Playlist) -> some View {
        let songs = rankPreviewSongs[playlist.kugouRankID ?? ""] ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(playlist.name)
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
                    CoverImage(url: playlist.coverURL,
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
        let lists = filteredLists.filter { rankPreviewSongs[$0.kugouRankID ?? ""] == nil }
        guard !lists.isEmpty else { return }
        let client = KugouClient.shared
        typealias Hit = (String, [Song])
        var hits: [Hit] = []
        await withTaskGroup(of: Hit?.self) { group in
            let concurrency = 4
            let sem = AsyncStream.makeStream(of: Void.self)
            nonisolated(unsafe) var active = 0
            for playlist in lists {
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
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .onAppear { Task { await searchPlaylists(reset: false) } }
                        }
                    } else if recommendedPlaylists.count < squareTotal {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
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

    // MARK: 加载

    private func load(force: Bool = false) async {
        guard !isLoading else { return }
        if !force,
           !feed.topLists.isEmpty, !guessSongs.isEmpty,
           !dailySongs.isEmpty, !hotArtists.isEmpty,
           !recommendedPlaylists.isEmpty {
            return
        }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        if feed.topLists.isEmpty {
            feed.topLists = await KugouClient.shared.topLists()
        }
        if feed.isEmpty {
            errorMessage = "拿不到榜单，检查一下网络或稍后再试"
            return
        }
        if guessSongs.isEmpty { await loadGuess() }
        if force || dailySongs.isEmpty { await loadDailySongs() }
        if force || hotArtists.isEmpty {
            hotArtists = await KugouClient.shared.hotArtists(count: 50)
        }
        if recommendedPlaylists.isEmpty {
            let result = await KugouClient.shared.recommendedPlaylists(page: 1)
            recommendedPlaylists = result.playlists
            squareTotal = result.total
            squarePage = 1
        }
        // 三个新推荐板块
        if ktvSongs.isEmpty { ktvSongs = (try? await KugouClient.shared.searchSongs(keyword: "KTV必点 经典", limit: 30)) ?? [] }
        if classicSongs.isEmpty { classicSongs = (try? await KugouClient.shared.searchSongs(keyword: "华语经典 怀旧", limit: 30)) ?? [] }
        if newSongs.isEmpty {
            let fetched = (try? await KugouClient.shared.searchSongs(keyword: "新歌榜", limit: 28)) ?? []
            // 🔴 v2.5.50：接口偶尔多回 2 首，尾页只剩 2 行很难看 —— 裁成 4 的倍数，
            // 保证每页都是整整齐齐 4 首（28 首 = 7 页）。
            newSongs = Array(fetched.prefix(fetched.count / 4 * 4))
        }
        // 🔴 v2.9.6：「至臻音质」主题歌单（供「歌单推荐」大卡用）
        if hallSongs.isEmpty {
            hallSongs = (try? await KugouClient.shared.searchSongs(keyword: "至臻音质 臻品母带", limit: 20)) ?? []
        }
        let whitelistedSlices = filteredLists
        await loadTrackCounts(for: whitelistedSlices.prefix(5))
    }

    /// 每日推荐：酷狗 TOP500 前 30 首，补齐第一首封面。
    private func loadDailySongs() async {
        guard let songs = try? await KugouClient.shared.rankSongs(rankID: "8888", limit: 100),
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
        Log.info("发现页", "每日推荐 \(enriched.count) 首，第一首：\(enriched[0].title) - \(enriched[0].artist)")
    }

    private func loadGuess() async {
        guard !isLoadingGuess else { return }
        isLoadingGuess = true
        defer { isLoadingGuess = false }
        let picks = Self.guessPool.shuffled().prefix(2)
        var songs: [Song] = []
        var seen = Set<String>()
        for keyword in picks {
            guard let got = try? await KugouClient.shared.searchSongs(keyword: keyword, limit: 8) else { continue }
            for song in got where !seen.contains(song.id) {
                seen.insert(song.id)
                songs.append(song)
                if songs.count >= 10 { break }
            }
            if songs.count >= 10 { break }
        }
        guessSongs = songs
        if let first = songs.first {
            Log.info("发现页", "猜你喜欢 \(songs.count) 首，第一首封面: \(first.artworkURL?.absoluteString.prefix(60) ?? "nil")")
        } else {
            Log.info("发现页", "猜你喜欢 0 首")
        }
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

// MARK: - Tab 枚举

enum DiscoverTab: String, CaseIterable, Hashable {
    case recommend, playlists, ranks, audiobook
    var title: String {
        switch self {
        case .recommend: return "推荐"
        case .ranks: return "榜单"
        case .playlists: return "歌单"
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
                                .lineLimit(1)
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
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            HStack(spacing: 8) {
                                Spacer()
                                ProgressView()
                                Text("加载更多")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppStyle.tertiaryText)
                                Spacer()
                            }
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
