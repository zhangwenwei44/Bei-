import SwiftUI

/// 发现页：热搜、推荐歌单、榜单、新歌。
struct DiscoverView: View {
    @EnvironmentObject private var store: PlayerStore
    @State private var feed = DiscoverFeed()
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if let errorMessage, feed.isEmpty {
                    errorState(errorMessage)
                } else if isLoading, feed.isEmpty {
                    LoadingRow()
                } else {
                    hotSearchSection
                    recommendedSection
                    topListSection
                    newSongsSection
                }
            }
            .padding(.bottom, 24)
        }
        .background(AppStyle.background)
        .refreshable { await load() }
        .task { if feed.isEmpty { await load() } }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: 热搜

    @ViewBuilder
    private var hotSearchSection: some View {
        if !feed.hotSearch.isEmpty {
            SectionHeader(title: "热门搜索") {
                NavigationLink {
                    SearchView(initialKeyword: feed.hotSearch.first ?? "")
                } label: {
                    Text("更多")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.accent)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(feed.hotSearch.indices, id: \.self) { index in
                        let keyword = feed.hotSearch[index]
                        NavigationLink {
                            SearchView(initialKeyword: keyword)
                        } label: {
                            HStack(spacing: 4) {
                                if index < 3 {
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(index == 0 ? AppStyle.gold : AppStyle.secondaryText)
                                }
                                Text(keyword)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppStyle.primaryText)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(AppStyle.surfaceHigh, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 推荐歌单

    @ViewBuilder
    private var recommendedSection: some View {
        if !feed.recommendedPlaylists.isEmpty {
            SectionHeader(title: "推荐歌单", subtitle: "编辑精选")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(feed.recommendedPlaylists) { playlist in
                        PlaylistLink(playlist: playlist, width: 148)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 榜单

    @ViewBuilder
    private var topListSection: some View {
        if !feed.topLists.isEmpty {
            SectionHeader(title: "排行榜")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(feed.topLists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        HStack(spacing: 10) {
                            CoverImage(url: playlist.coverURL, seed: playlist.name, size: 52, corner: 8)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(AppStyle.primaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if !playlist.updateFrequency.isEmpty {
                                    Text(playlist.updateFrequency)
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppStyle.tertiaryText)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: 新歌

    @ViewBuilder
    private var newSongsSection: some View {
        if !feed.newSongs.isEmpty {
            SectionHeader(title: "新歌速递") {
                NavigationLink {
                    SongListView(title: "新歌速递", songs: feed.newSongs)
                } label: {
                    Text("全部")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.accent)
                }
            }
            VStack(spacing: 0) {
                ForEach(feed.newSongs) { song in
                    SongRow(song: song,
                            isCurrent: isCurrent(song),
                            isPlaying: store.isPlaying)
                        .songMenu(song)
                        .padding(.horizontal, 16)
                        .onTapGesture { play(song) }
                }
            }
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

    private func isCurrent(_ song: Song) -> Bool { store.current?.id == song.id }

    private func play(_ song: Song) {
        let list = feed.newSongs
        guard let index = list.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(list, startAt: index)
        Haptics.soft()
    }

    // MARK: 加载

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        let client = NetEaseClient.shared
        async let hot = try? client.hotSearch()
        async let recommended = try? client.recommendedPlaylists(limit: 12)
        async let tops = try? client.topLists()
        async let fresh = try? client.newSongs(limit: 10)

        feed.hotSearch = await hot ?? []
        feed.recommendedPlaylists = await recommended ?? []
        feed.topLists = await tops ?? []
        feed.newSongs = await fresh ?? []

        if feed.isEmpty {
            errorMessage = "拿不到网络内容，检查一下网络或稍后再试"
        }
    }
}
