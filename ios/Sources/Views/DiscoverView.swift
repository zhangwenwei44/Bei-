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

    @ViewBuilder
    private var topListSection: some View {
        if !feed.topLists.isEmpty {
            SectionHeader(title: "酷狗排行榜", subtitle: "共 \(feed.topLists.count) 个")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(filteredLists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        HStack(spacing: 10) {
                            CoverImage(url: playlist.coverURL,
                                       fallbackKeys: [playlist.id],
                                       seed: playlist.name,
                                       size: 52,
                                       corner: 8)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(AppStyle.primaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if playlist.trackCount > 0 {
                                    // 真实曲目数在榜单页的 global.total 里，由 loadTrackCounts 异步补。
                                    // 补不到就不显示，而不是显示一个错的数字。
                                    HStack(spacing: 4) {
                                        Text("\(playlist.trackCount) 首")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(AppStyle.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(AppStyle.accent.opacity(0.12),
                                                        in: Capsule())
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                        .padding(10)
                        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppStyle.stroke, lineWidth: 0.5)
                        )
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
