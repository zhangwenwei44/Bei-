import SwiftUI

/// 发现页（新版）。Tab 栏 → 搜索框 → 2×2 宫格卡片 → 心情问候 + 歌曲列表 → 热门榜单。
struct DiscoverView: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
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

    /// 保留的 5 个精选榜单 rankID。
    static let whitelistRankIDs: Set<String> = [
        "82831",  // 网络热歌榜（百万收藏榜用这个）
        "6666",   // 飙升榜
        "52144",  // 短视频热歌榜
        "24971",  // DJ热歌榜
        "85432",  // 百万收藏榜
    ]

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
                    searchEntry
                    tabContent
                }
            }
            .padding(.bottom, 24)
        }
        .background(AppStyle.background)
        .refreshable { await load(force: true) }
        .task { if feed.isEmpty { await load() } }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            tabBar
                .background(AppStyle.background)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: store.current == nil ? 0 : 62)
                .accessibilityHidden(true)
        }
    }

    // MARK: Tab 栏

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 24) {
                ForEach(DiscoverTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Text(tab.title)
                                .font(.system(size: 16, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundStyle(selectedTab == tab ? AppStyle.accent : AppStyle.primaryText)
                            Capsule()
                                .fill(selectedTab == tab ? AppStyle.accent : Color.clear)
                                .frame(width: tab.title.count == 2 ? 20 : 28, height: 3)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .padding(.bottom, 4)
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
                Text("月亮替我望故乡 最近很火")
                    .font(.system(size: 14))
                    .foregroundStyle(AppStyle.secondaryText)
                Spacer()
                Image(systemName: "mic")
                    .font(.system(size: 14))
                    .foregroundStyle(AppStyle.secondaryText.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(AppStyle.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: Tab 内容切换

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .recommend: recommendContent
        case .ranks: ranksContent
        case .playlists: playlistsContent
        }
    }

    // MARK: 推荐 Tab — 完整 Feed 流

    private var recommendContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            bigCardsGrid
            moodGreeting
            artistsSection
            hotRanksSection
        }
    }

    // MARK: 两大两小横向滚动卡片（左两大 + 右两小叠加）
    // 技术方案：NavigationLink 藏在 ZStack 底层做 Color.clear 幽灵，彻底消灭 padding 干扰

    private var bigCardsGrid: some View {
        let sidePadding: CGFloat = 16
        let screenW = UIScreen.main.bounds.width
        let gap: CGFloat = 10
        // 大卡：整屏三等分再乘 0.85 做小，保证横排能塞下还留空间
        let rawWidth = (screenW - sidePadding * 2 - gap) / 2
        let bigWidth = rawWidth * 0.85
        let bigHeight = bigWidth * 1.5                              // 大卡保持竖长方形
        let topCardHeight = (bigHeight - gap) / 2                  // 上小卡
        let bottomCardHeight = bigHeight - topCardHeight - gap     // 下小卡（剩余高度，恒等式保证齐平）

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

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: gap) {

                // ========== 大卡 1：每日推荐 ==========
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

                // ========== 大卡 2：猜你喜欢 ==========
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

                // ========== 两小叠加 — 上小 topCardHeight，下小 bottomCardHeight ==========
                VStack(spacing: 0) {
                    navigable(
                        destination: {
                            Group {
                                if let favRank = filteredLists.first(where: { $0.kugouRankID == "85432" || $0.kugouRankID == "82831" }) {
                                    PlaylistDetailView(playlist: favRank)
                                } else if !filteredLists.isEmpty {
                                    PlaylistDetailView(playlist: filteredLists[0])
                                } else { EmptyView() }
                            }
                        },
                        label: {
                            IconFeatureCard(
                                width: topCardHeight, desiredHeight: topCardHeight,
                                title: "百万收藏", systemIcon: "heart.fill",
                                gradientColors: [
                                    Color(red: 1.0, green: 0.47, blue: 0.33),
                                    Color(red: 0.94, green: 0.28, blue: 0.42)
                                ]
                            )
                            .frame(width: topCardHeight, height: topCardHeight)
                        }
                    )
                    .frame(width: topCardHeight, height: topCardHeight)

                    Spacer(minLength: 0).frame(height: gap)

                    navigable(
                        destination: {
                            Group {
                                if let newRank = filteredLists.first(where: { $0.kugouRankID == "6666" }) {
                                    PlaylistDetailView(playlist: newRank)
                                } else if !filteredLists.isEmpty {
                                    PlaylistDetailView(playlist: filteredLists[0])
                                } else { EmptyView() }
                            }
                        },
                        label: {
                            IconFeatureCard(
                                width: bottomCardHeight, desiredHeight: bottomCardHeight,
                                title: "新歌推荐", systemIcon: "music.note",
                                gradientColors: [
                                    Color(red: 1.0, green: 0.72, blue: 0.35),
                                    Color(red: 1.0, green: 0.45, blue: 0.30)
                                ]
                            )
                            .frame(width: bottomCardHeight, height: bottomCardHeight)
                        }
                    )
                    .frame(width: bottomCardHeight, height: bottomCardHeight)
                }
                .frame(width: topCardHeight, height: bigHeight, alignment: .top)
                .frame(maxHeight: bigHeight, alignment: .top)
                .clipped()

                // 额外大卡
                navigable(
                    destination: {
                        Group {
                            if let t = filteredLists.first(where: { $0.kugouRankID == "24971" })
                                       ?? filteredLists.first {
                                PlaylistDetailView(playlist: t)
                            } else { EmptyView() }
                        }
                    },
                    label: {
                        CoverFeatureCard(
                            width: bigWidth, height: bigHeight,
                            coverURL: filteredLists.prefix(3).last?.coverURL
                                ?? filteredLists.first?.coverURL,
                            title: "DJ热歌榜",
                            subtitle: filteredLists.prefix(3).last?.name ?? "",
                            isPlaying: false,
                            onPlay: { playDailyAll() }
                        )
                        .frame(width: bigWidth, height: bigHeight)
                    }
                )
                .frame(width: bigWidth, height: bigHeight, alignment: .topLeading)
                .frame(maxHeight: bigHeight, alignment: .top)
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

    private var moodGreeting: some View {
        HStack {
            Text(greetingText)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AppStyle.primaryText)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    private var greetingText: String {
        "热门歌手"
    }

    // MARK: 热门歌手列表

    private var artistsSection: some View {
        Group {
            if !hotArtists.isEmpty {
                let shown = Array(hotArtists.prefix(8))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, artist in
                        NavigationLink {
                            ArtistDetailView(artist: artist)
                        } label: {
                            ArtistRow(artist: artist,
                                      isPlaying: playingArtistID == artist.id)
                        }
                        .buttonStyle(.plain)
                        if index < shown.count - 1 {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
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

    // MARK: 榜单 Tab

    private var ranksContent: some View {
        Group {
            if !filteredLists.isEmpty {
                HStack {
                    Text("热门榜单")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    Spacer()
                    Text("每日更新")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                VStack(spacing: 0) {
                    ForEach(filteredLists) { playlist in
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

    // MARK: 歌单 Tab

    private var playlistsContent: some View {
        Group {
            if recommendedPlaylists.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let cols = [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(recommendedPlaylists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            PlaylistCard(playlist: playlist, width: 0)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }

                    // 底部加载触发器
                    if recommendedPlaylists.count < squareTotal {
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

    private var filteredLists: [Playlist] {
        let whitelist = Self.whitelistRankIDs
        return feed.topLists.filter { whitelist.contains($0.kugouRankID ?? "") }
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
                keyword: artist.name, limit: 30), !songs.isEmpty else { return }
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
            hotArtists = await KugouClient.shared.hotArtists(count: 20)
        }
        if recommendedPlaylists.isEmpty {
            let result = await KugouClient.shared.recommendedPlaylists(page: 1)
            recommendedPlaylists = result.playlists
            squareTotal = result.total
            squarePage = 1
        }
        let whitelist = Self.whitelistRankIDs
        let whitelistedSlices = feed.topLists.filter { whitelist.contains($0.kugouRankID ?? "") }
        await loadTrackCounts(for: whitelistedSlices.prefix(5))
    }

    /// 每日推荐：酷狗 TOP500 前 30 首，补齐第一首封面。
    private func loadDailySongs() async {
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
        guard !result.playlists.isEmpty else { return }
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
    case recommend, ranks, playlists
    var title: String {
        switch self {
        case .recommend: return "推荐"
        case .ranks: return "榜单"
        case .playlists: return "歌单"
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

            // 底部黑色半透明渐变遮罩
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                LinearGradient(colors: [.clear, Color.black.opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height * 0.5)
            }
            .frame(width: width, height: height)

            // 标题 + 副标题 + 播放按钮（底部）
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: width * 0.11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: width * 0.065))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
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
                .foregroundStyle(.white)
                .padding(10)

            Image(systemName: systemIcon)
                .font(.system(size: min(width, desiredHeight) * 0.55, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
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
                       size: 50,
                       corner: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(song.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                _ = library.toggleFavorite(song)
                Haptics.light()
            } label: {
                Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart")
                    .font(.system(size: 18))
                    .foregroundStyle(library.isFavorite(song) ? AppStyle.like : AppStyle.tertiaryText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - 歌手行

private struct ArtistRow: View {
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
