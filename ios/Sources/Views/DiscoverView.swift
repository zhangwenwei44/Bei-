import SwiftUI

/// 发现页。酷狗只有排行榜这一类在线歌单，所以这里就是榜单宫格。
struct DiscoverView: View {
    @EnvironmentObject private var store: PlayerStore
    @State private var feed = DiscoverFeed()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var guessSongs: [Song] = []
    @State private var isLoadingGuess = false
    @State private var artistPhotos: [String: URL] = [:]

    /// 热门歌手名单。酷狗没有免签名的热门歌手接口，先放一份经典名单，
    /// 点击直接跳歌手搜索结果。
    static let hotArtists: [String] = [
        "周杰伦", "林俊杰", "陈奕迅", "邓紫棋", "薛之谦", "周深",
        "毛不易", "梁静茹", "王心凌", "李荣浩", "张碧晨", "许嵩",
    ]

    /// 猜你喜欢的抽词池：随机挑两个词各搜一页，拼成一组推荐。
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
                    guessSection
                    hotArtistsSection
                    topListSection
                }
            }
            .padding(.bottom, 24)
        }
        .background(AppStyle.background)
        .refreshable { await load() }
        .task { if feed.isEmpty { await load() } }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.large)
        // 悬浮迷你播放条会盖住榜单宫格最后一行，让出底部空间
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: store.current == nil ? 0 : 62)
                .accessibilityHidden(true)
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
                Text("搜歌曲、歌手")
                    .font(.system(size: 14))
                    .foregroundStyle(AppStyle.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(AppStyle.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: 榜单

    /// 三列宫格的封面边长。按最窄机型（375pt 宽）算：
    /// (375 - 左右各 16 - 列间距 12×2) / 3 ≈ 106，宽屏上留白多一点也协调。
    private let rankTileSize: CGFloat = 106

    // MARK: 猜你喜欢

    private var guessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("猜你喜欢")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer()
                Button {
                    Task { await loadGuess() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("换一批")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(AppStyle.accent)
                }
                .buttonStyle(.plain)
                .disabled(isLoadingGuess)
            }
            .padding(.horizontal, 16)

            if !guessSongs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(guessSongs) { song in
                            Button {
                                playGuess(song)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    CoverImage(url: song.artworkURL,
                                               fallbackKeys: [song.kugouAlbumID].compactMap { $0 },
                                               seed: song.title,
                                               size: 124,
                                               corner: 12)
                                    Text(song.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(AppStyle.primaryText)
                                        .lineLimit(1)
                                    Text(song.artist)
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppStyle.secondaryText)
                                        .lineLimit(1)
                                }
                                .frame(width: 124)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .songMenu(song)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 24)
    }

    private func playGuess(_ song: Song) {
        guard let index = guessSongs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(guessSongs, startAt: index)
        Haptics.soft()
    }

    // MARK: 热门歌手

    private var hotArtistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("热门歌手")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppStyle.primaryText)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Self.hotArtists, id: \.self) { name in
                        NavigationLink {
                            SearchView(initialKeyword: name)
                        } label: {
                            VStack(spacing: 6) {
                                ArtistAvatar(name: name, url: artistPhotos[name], size: 64)
                                Text(name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppStyle.primaryText)
                                    .lineLimit(1)
                            }
                            .frame(width: 66)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var topListSection: some View {
        if !feed.topLists.isEmpty {
            SectionHeader(title: "排行榜", subtitle: "酷狗热榜 · 官方每日更新")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)],
                      spacing: 18) {
                ForEach(filteredLists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        // 酷狗发现页的榜单是一水儿的封面宫格：大图在上，
                        // 榜单名和更新说明压在下面，不再套卡片框
                        VStack(alignment: .leading, spacing: 6) {
                            CoverImage(url: playlist.coverURL,
                                       fallbackKeys: [playlist.id],
                                       seed: playlist.name,
                                       size: rankTileSize,
                                       corner: 10)
                            Text(playlist.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppStyle.primaryText)
                                .lineLimit(1)
                            if playlist.trackCount > 0 {
                                // 真实曲目数在榜单页的 global.total 里，由 loadTrackCounts 异步补。
                                Text("\(playlist.trackCount) 首")
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppStyle.accent)
                            } else if !playlist.updateFrequency.isEmpty {
                                Text(playlist.updateFrequency)
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppStyle.tertiaryText)
                                    .lineLimit(1)
                            } else {
                                // 正在加载曲目数
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var filteredLists: [Playlist] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return feed.topLists }
        return feed.topLists.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
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
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        feed.topLists = await KugouClient.shared.topLists()
        if feed.isEmpty {
            errorMessage = "拿不到榜单，检查一下网络或稍后再试"
            return
        }
        // 猜你喜欢先刷出来（两次搜索就够），再慢慢补榜单曲目数
        await loadGuess()
        // 热门歌手头像并发拉（singerimg 接口），拉到就刷新
        await loadArtistPhotos()
        // 曲目数要单独请求榜单页才拿得到（列表接口里没有 songcount），
        // 只补前若干个，避免一进页面就打 55 个请求。
        await loadTrackCounts(for: feed.topLists.prefix(12))
    }

    /// 并发拉取热门歌手头像。限制 6 并发避免卡网络，失败就保持文字占位。
    private func loadArtistPhotos() async {
        let client = KugouClient.shared
        // 信号量限流：最多 6 个并发
        let sem = AsyncStream.makeStream(of: Void.self)
        let concurrency = 6
        var active = 0
        for name in Self.hotArtists {
            while active >= concurrency { _ = await sem.stream.first(where: { _ in true }) }
            active += 1
            Task {
                defer {
                    active -= 1
                    sem.continuation.yield()
                }
                if let url = await client.artistPhoto(name: name) {
                    await MainActor.run { artistPhotos[name] = url }
                }
            }
        }
    }

    /// 猜你喜欢：随机挑两个热词各搜一页，按 id 去重后拼一组推荐。
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

    /// 并发补齐真实曲目数（4 并发），补到就刷新界面。
    private func loadTrackCounts(for lists: ArraySlice<Playlist>) async {
        let client = KugouClient.shared
        // (playlistID, rankID) -> (index in feed.topLists, total)
        typealias Hit = (String, String, Int, Int)
        var hits: [Hit] = []
        await withTaskGroup(of: Hit?.self) { group in
            let concurrency = 4
            let sem = AsyncStream.makeStream(of: Void.self)
            var active = 0
            for (index, playlist) in lists.enumerated() {
                guard let rankID = playlist.kugouRankID else { continue }
                while active >= concurrency { _ = await sem.stream.first(where: { _ in true }) }
                active += 1
                group.addTask { [playlist.id] in
                    defer {
                        active -= 1
                        sem.continuation.yield()
                    }
                    if let total = await client.rankTotal(rankID: rankID) {
                        return (playlist.id, rankID, index, total)
                    }
                    return nil
                }
            }
            for await hit in group {
                if let hit { hits.append(hit) }
            }
        }
        // 一次性合并到 feed（主线程）
        await MainActor.run {
            for (pid, _, _, total) in hits {
                if let idx = feed.topLists.firstIndex(where: { $0.id == pid }) {
                    feed.topLists[idx].trackCount = total
                }
            }
        }
    }
}

/// 歌手圆形头像：有头像 URL 就显示图，没有就用首字+渐变底色占位（保证任何情况下不空白）。
private struct ArtistAvatar: View {
    let name: String
    let url: URL?
    var size: CGFloat = 64

    var body: some View {
        if let url {
            CoverImage(url: url, seed: name, size: size, corner: size / 2)
        } else {
            ZStack {
                Circle()
                    .fill(AppStyle.accent.opacity(0.25))
                Text(name.prefix(1))
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
            }
            .frame(width: size, height: size)
        }
    }
}

