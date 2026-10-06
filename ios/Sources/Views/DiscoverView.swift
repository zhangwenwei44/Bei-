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
    @State private var recommendedPlaylists: [Playlist] = []
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
                    tabBar
                    searchEntry
                    tabContent
                }
            }
            .padding(.bottom, 24)
        }
        .background(AppStyle.background)
        .refreshable { await load() }
        .task { if feed.isEmpty { await load() } }
        .navigationBarTitleDisplayMode(.inline)
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
            songsSection(songs: guessSongs, showLimitTag: true)
            hotRanksSection
        }
    }

    // MARK: 两大两小横向滚动卡片（大在左，小在右，大卡长柱形）

    private var bigCardsGrid: some View {
        let cardSpacing: CGFloat = 10
        let sidePadding: CGFloat = 16
        let screenW = UIScreen.main.bounds.width - sidePadding * 2
        // 长柱形大卡：窄而高
        let bigWidth = screenW * 0.38
        let bigHeight = bigWidth * 0.8           // 扁矩形，高是宽的 0.8 倍
        let smallStackWidth = screenW - bigWidth * 2 - cardSpacing * 2
        let smallCardHeight = (bigHeight - cardSpacing) / 2   // 两张小卡拼齐大卡高度

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: cardSpacing) {
                // 大卡 1：每日推荐（长柱形）
                if let dailyPlaylist = recommendedPlaylists.first {
                    NavigationLink {
                        PlaylistDetailView(playlist: dailyPlaylist)
                    } label: {
                        CoverFeatureCard(
                            width: bigWidth, height: bigHeight,
                            coverURL: dailyPlaylist.coverURL,
                            title: "每日推荐", subtitle: dailyPlaylist.creatorName,
                            dateText: dateText, tagText: "免费听"
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    CoverFeatureCard(
                        width: bigWidth, height: bigHeight,
                        coverURL: nil,
                        title: "每日推荐", subtitle: "每天都是新的歌单",
                        dateText: dateText, tagText: "免费听"
                    )
                }

                // 大卡 2：猜你喜欢（长柱形，点击播放全部）
                Button {
                    playGuessAll()
                } label: {
                    CoverFeatureCard(
                        width: bigWidth, height: bigHeight,
                        coverURL: guessSongs.first?.artworkURL,
                        title: "猜你喜欢", subtitle: guessSubtitle,
                        dateText: nil, tagText: "免费听"
                    )
                }
                .buttonStyle(.plain)

                // 小卡堆：百万收藏 + 新歌推荐（两张小卡总高 = 大卡高）
                VStack(spacing: cardSpacing) {
                    NavigationLink {
                        if let favRank = filteredLists.first(where: { $0.kugouRankID == "85432" || $0.kugouRankID == "82831" }) {
                            PlaylistDetailView(playlist: favRank)
                        } else if !filteredLists.isEmpty {
                            PlaylistDetailView(playlist: filteredLists[0])
                        }
                    } label: {
                        IconFeatureCard(
                            width: smallStackWidth, height: smallCardHeight,
                            title: "百万收藏", systemIcon: "heart.fill",
                            gradientColors: [
                                Color(red: 1.0, green: 0.47, blue: 0.33),
                                Color(red: 0.94, green: 0.28, blue: 0.42)
                            ]
                        )
                    }
                    .buttonStyle(.plain)

                    IconFeatureCard(
                        width: smallStackWidth, height: smallCardHeight,
                        title: "新歌推荐", systemIcon: "music.note",
                        gradientColors: [
                            Color(red: 1.0, green: 0.72, blue: 0.35),
                            Color(red: 1.0, green: 0.45, blue: 0.30)
                        ]
                    )
                }
            }
            .padding(.horizontal, sidePadding)
        }
        .padding(.bottom, 4)
    }

    private var guessSubtitle: String {
        if !guessSongs.isEmpty {
            return guessSongs.prefix(2).map { $0.artist }.joined(separator: "、")
        }
        return personalizedHint
    }

    private var personalizedHint: String {
        let picks = Self.guessPool.prefix(2)
        return picks.joined(separator: "、")
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
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
        let weekday = Calendar.current.component(.weekday, from: Date())
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekdayName = weekdays[weekday - 1]
        let hour = Calendar.current.component(.hour, from: Date())
        let timePrefix: String
        let emoji: String
        switch hour {
        case 5..<9:   timePrefix = "早上好"; emoji = "🌅"
        case 9..<12:  timePrefix = "上午好"; emoji = "☕"
        case 12..<14: timePrefix = "中午好"; emoji = "🍵"
        case 14..<18: timePrefix = "下午好"; emoji = "🎧"
        case 18..<22: timePrefix = "晚上好"; emoji = "🌙"
        default:      timePrefix = "夜深了"; emoji = "🌙"
        }
        return "\(timePrefix)，今天\(weekdayName)，进来听听看 \(emoji)"
    }

    // MARK: 歌曲列表

    private func songsSection(songs: [Song], showLimitTag: Bool = false) -> some View {
        Group {
            if !songs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(songs.prefix(6)) { song in
                        Button {
                            playSong(song)
                        } label: {
                            FeedSongRow(song: song, showLimitTag: showLimitTag)
                        }
                        .buttonStyle(.plain)
                        .songMenu(song)
                        Divider().padding(.leading, 68)
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
            if !recommendedPlaylists.isEmpty {
                HStack {
                    Text("精选歌单")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(recommendedPlaylists) { playlist in
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                PlaylistCard(playlist: playlist, width: 130)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 16)
            }

            if !filteredLists.isEmpty {
                HStack {
                    Text("精选榜单")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    Spacer()
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

    private var filteredLists: [Playlist] {
        let whitelist = Self.whitelistRankIDs
        return feed.topLists.filter { whitelist.contains($0.kugouRankID ?? "") }
    }

    // MARK: 行为

    private func playGuess(_ song: Song) {
        guard let index = guessSongs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(guessSongs, startAt: index)
        Haptics.soft()
    }

    private func playGuessAll() {
        guard !guessSongs.isEmpty else { return }
        store.play(guessSongs, startAt: 0)
        Haptics.soft()
    }

    private func playSong(_ song: Song) {
        if guessSongs.contains(where: { $0.id == song.id }) {
            playGuess(song)
        } else {
            store.playNow([song])
            Haptics.soft()
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

    private func load() async {
        guard !isLoading else { return }
        if !feed.topLists.isEmpty && !guessSongs.isEmpty && !recommendedPlaylists.isEmpty {
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
        if recommendedPlaylists.isEmpty {
            recommendedPlaylists = await KugouClient.shared.recommendedPlaylists()
        }
        let whitelist = Self.whitelistRankIDs
        let whitelistedSlices = feed.topLists.filter { whitelist.contains($0.kugouRankID ?? "") }
        await loadTrackCounts(for: whitelistedSlices.prefix(5))
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
    let dateText: String?
    let tagText: String?

    private var corner: CGFloat { 14 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 封面图（取较短边作为 CoverImage size，外层撑满）
            CoverImage(url: coverURL,
                       fallbackKeys: [],
                       seed: title,
                       size: min(width, height),
                       corner: corner)
                .frame(width: width, height: height)

            // 底部黑色半透明渐变遮罩
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                LinearGradient(colors: [.clear, Color.black.opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height * 0.5)
            }
            .frame(width: width, height: height)

            // 日期标签（左上角）+ "免费听"标签（右上角）
            VStack {
                HStack {
                    if let dateText {
                        Text(dateText)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    if let tagText {
                        Text(tagText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Spacer()
            }
            .padding(10)
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
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.25), in: Circle())
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
    let height: CGFloat
    let title: String
    let systemIcon: String
    let gradientColors: [Color]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: gradientColors,
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)

            // 大图标（右下偏中，半透明白色）
            Image(systemName: systemIcon)
                .font(.system(size: min(width, height) * 0.55, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
                .position(x: width * 0.72, y: height * 0.62)

            // 左上角标题
            Text(title)
                .font(.system(size: width * 0.16, weight: .bold))
                .foregroundStyle(.white)
                .padding(10)
        }
        .frame(width: width, height: height)
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
                    if showLimitTag {
                        Text("限免")
                            .font(.system(size: 9))
                            .foregroundStyle(AppStyle.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AppStyle.surfaceHigh, in: RoundedRectangle(cornerRadius: 3))
                    }
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
