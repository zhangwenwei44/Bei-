import SwiftUI

/// 发现页。酷狗只有排行榜这一类在线歌单，所以这里就是榜单宫格。
struct DiscoverView: View {
    @EnvironmentObject private var store: PlayerStore
    @State private var feed = DiscoverFeed()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var query = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let errorMessage, feed.isEmpty {
                    errorState(errorMessage)
                } else if isLoading, feed.isEmpty {
                    LoadingRow()
                } else {
                    searchEntry
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
                                // 补不到就不显示，而不是显示一个错的数字。
                                Text("\(playlist.trackCount) 首")
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppStyle.accent)
                            } else if !playlist.updateFrequency.isEmpty {
                                Text(playlist.updateFrequency)
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppStyle.tertiaryText)
                                    .lineLimit(1)
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
        // 曲目数要单独请求榜单页才拿得到（列表接口里没有 songcount），
        // 只补前若干个，避免一进页面就打 55 个请求。
        await loadTrackCounts(for: feed.topLists.prefix(12))
    }

    /// 逐个补齐真实曲目数，补到就刷新界面。
    private func loadTrackCounts(for lists: ArraySlice<Playlist>) async {
        let client = KugouClient.shared
        for (index, playlist) in lists.enumerated() {
            guard let rankID = playlist.kugouRankID else { continue }
            guard let total = await client.rankTotal(rankID: rankID) else { continue }
            guard index < feed.topLists.count, feed.topLists[index].id == playlist.id else { return }
            feed.topLists[index].trackCount = total
        }
    }
}
