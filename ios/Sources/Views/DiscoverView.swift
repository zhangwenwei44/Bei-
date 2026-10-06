import SwiftUI

/// 发现页。搜索入口 → 热门歌手 → 猜你喜欢（列表） → 5 个精选榜单（列表） → 网络歌单推荐。
struct DiscoverView: View {
    @EnvironmentObject private var store: PlayerStore
    @State private var feed = DiscoverFeed()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var guessSongs: [Song] = []
    @State private var isLoadingGuess = false
    @State private var artistPhotos: [String: URL] = [:]
    @State private var recommendedPlaylists: [Playlist] = []

    /// 保留的 5 个精选榜单 rankID（按用户要求）。
    static let whitelistRankIDs: Set<String> = [
        "82831",  // 网络热歌榜
        "6666",   // 飙升榜（酷狗飙升榜）
        "52144",  // 短视频热歌榜
        "24971",  // DJ热歌榜
        "85432",  // 百万收藏榜
    ]

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
                    hotArtistsSection
                    guessSection
                    topListSection
                    playlistsSection
                }
            }
            .padding(.bottom, 24)
        }
        .background(AppStyle.background)
        .refreshable { await load() }
        .task { if feed.isEmpty { await load() } }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.large)
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

    // MARK: 热门歌手（搜索框正下方）

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
        .padding(.bottom, 20)
    }

    // MARK: 猜你喜欢（列表模式）

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
                VStack(spacing: 0) {
                    ForEach(guessSongs.prefix(6)) { song in
                        Button {
                            playGuess(song)
                        } label: {
                            GuessSongRow(song: song)
                        }
                        .buttonStyle(.plain)
                        .songMenu(song)
                        Divider().padding(.leading, 68)
                    }
                }
                .padding(.horizontal, 16)
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 24)
    }

    private func playGuess(_ song: Song) {
        guard let index = guessSongs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(guessSongs, startAt: index)
        Haptics.soft()
    }

    // MARK: 排行榜（仅 5 个精选 + 列表模式）

    @ViewBuilder
    private var topListSection: some View {
        if !filteredLists.isEmpty {
            SectionHeader(title: "热门榜单", subtitle: "每日更新")
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
            .padding(.bottom, 24)
        }
    }

    private var filteredLists: [Playlist] {
        let whitelist = Self.whitelistRankIDs
        return feed.topLists.filter { whitelist.contains($0.kugouRankID ?? "") }
    }

    // MARK: 网络歌单推荐

    @ViewBuilder
    private var playlistsSection: some View {
        if !recommendedPlaylists.isEmpty {
            SectionHeader(title: "网络歌单推荐", subtitle: "来自酷狗精选")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(recommendedPlaylists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(url: playlist.coverURL,
                                           fallbackKeys: [playlist.id],
                                           seed: playlist.name,
                                           size: 120,
                                           corner: 10)
                                    .frame(width: 120, height: 120)
                                Text(playlist.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppStyle.primaryText)
                                    .lineLimit(2)
                                    .frame(width: 120, alignment: .leading)
                                Text(playlist.creatorName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppStyle.secondaryText)
                                    .lineLimit(1)
                                    .frame(width: 120, alignment: .leading)
                            }
                            .frame(width: 120)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 8)
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
        if !feed.topLists.isEmpty && !artistPhotos.isEmpty && !guessSongs.isEmpty {
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
        if artistPhotos.isEmpty { await loadArtistPhotos() }
        if recommendedPlaylists.isEmpty {
            recommendedPlaylists = await KugouClient.shared.recommendedPlaylists()
        }
        // 只给 whitelist 的 5 个榜单补曲目数，省掉其余 50 个的请求
        let whitelist = Self.whitelistRankIDs
        let whitelistedSlices = feed.topLists.filter { whitelist.contains($0.kugouRankID ?? "") }
        await loadTrackCounts(for: whitelistedSlices.prefix(5))
    }

    private func loadArtistPhotos() async {
        let client = KugouClient.shared
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

// MARK: - 猜你喜欢行

private struct GuessSongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: song.artworkURL,
                       fallbackKeys: [song.kugouAlbumID].compactMap { $0 },
                       seed: song.title,
                       size: 44,
                       corner: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "play.circle")
                .font(.system(size: 22))
                .foregroundStyle(AppStyle.accent.opacity(0.6))
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

// MARK: - 歌手头像

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
