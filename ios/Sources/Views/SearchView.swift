import SwiftUI

/// 搜索页：单曲 / 歌单 / 歌手 / 专辑。
struct SearchView: View {
    var initialKeyword: String = ""

    @EnvironmentObject private var store: PlayerStore
    @State private var keyword = ""
    @State private var submitted = ""
    @State private var results = SearchResults()
    @State private var scope: Scope = .songs
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var history: [String] = []
    @FocusState private var isFieldFocused: Bool

    private enum Scope: Int, CaseIterable {
        case songs, playlists, albums, artists

        var title: String {
            switch self {
            case .songs: return "单曲"
            case .playlists: return "榜单"
            case .albums: return "专辑"
            case .artists: return "歌手"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            scopeBar

            Group {
                if submitted.isEmpty {
                    historyView
                } else if isLoading {
                    LoadingRow()
                } else if let errorMessage, results.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "没搜到", message: errorMessage)
                } else {
                    resultList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppStyle.background)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !submitted.isEmpty {
                    Button("清空") {
                        submitted = ""
                        keyword = ""
                        results = SearchResults()
                    }
                    .font(.system(size: 13))
                }
            }
        }
        .onAppear {
            history = Self.loadHistory()
            if !initialKeyword.isEmpty, submitted.isEmpty {
                keyword = initialKeyword
                runSearch(initialKeyword)
            }
        }
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(AppStyle.secondaryText)
                TextField("歌曲、歌手、歌单", text: $keyword)
                    .font(.system(size: 14))
                    .foregroundStyle(AppStyle.primaryText)
                    .focused($isFieldFocused)
                    .submitLabel(.search)
                    .onSubmit { runSearch(keyword) }
                    .autocorrectionDisabled()
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(AppStyle.surface, in: Capsule())

            if !submitted.isEmpty {
                Button("取消") {
                    submitted = ""
                    keyword = ""
                    results = SearchResults()
                    isFieldFocused = false
                }
                .font(.system(size: 13))
                .foregroundStyle(AppStyle.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var scopeBar: some View {
        HStack(spacing: 18) {
            ForEach(Scope.allCases, id: \.rawValue) { item in
                Button {
                    scope = item
                } label: {
                    Text(item.title)
                        .font(.system(size: 14, weight: scope == item ? .semibold : .regular))
                        .foregroundStyle(scope == item ? AppStyle.primaryText : AppStyle.secondaryText)
                        .overlay(alignment: .bottom) {
                            if scope == item {
                                Capsule()
                                    .fill(AppStyle.accent)
                                    .frame(width: 16, height: 2)
                                    .offset(y: 6)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: 结果

    @ViewBuilder
    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch scope {
                case .songs:
                    ForEach(results.songs) { song in
                        SongRow(song: song,
                                isCurrent: store.current?.id == song.id,
                                isPlaying: store.isPlaying)
                            .songMenu(song)
                            .padding(.horizontal, 16)
                            .onTapGesture { play(song) }
                    }
                case .playlists:
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        ForEach(results.playlists) { playlist in
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                PlaylistCard(playlist: playlist, width: 160)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                case .albums:
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results.albums) { album in
                            Button {
                                runSearch("\(album.artist) \(album.name)")
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(url: album.coverURL,
                                               fallbackKeys: album.albumID.isEmpty ? [] : ["al:\(album.albumID)"],
                                               seed: album.name,
                                               size: 48,
                                               corner: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(album.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(AppStyle.primaryText)
                                            .lineLimit(1)
                                        Text(album.artist)
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppStyle.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AppStyle.tertiaryText)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                case .artists:
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results.artists) { artist in
                            Button {
                                runSearch(artist.name)
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(url: artist.coverURL, seed: artist.name, size: 44, corner: 22)
                                    Text(artist.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(AppStyle.primaryText)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AppStyle.tertiaryText)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: 搜索历史

    private var historyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !history.isEmpty {
                    HStack {
                        Text("最近搜索")
                            .font(.system(size: 13))
                            .foregroundStyle(AppStyle.secondaryText)
                        Spacer()
                        Button("清空") {
                            history = []
                            Self.saveHistory(history)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                    FlowChips(items: history) { item in
                        keyword = item
                        runSearch(item)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 26)
                }

                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.accent)
                    Text("热门搜索")
                        .font(.system(size: 13))
                        .foregroundStyle(AppStyle.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                FlowChips(items: Self.hotKeywords) { item in
                    keyword = item
                    runSearch(item)
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 热门搜索词。酷狗的热搜接口要签名，先放一份稳定的热门标签，
    /// 点一下直接出结果，比空白页热闹得多。
    static let hotKeywords: [String] = [
        "抖音热歌", "周杰伦", "华语经典", "粤语金曲", "薛之谦",
        "伤感情歌", "欧美流行", "网络热歌", "轻音乐", "邓紫棋",
        "90后回忆", "KTV必点", "民谣", "说唱", "影视金曲", "深夜循环",
    ]

    // MARK: 行为

    private func play(_ song: Song) {
        let list = results.songs
        guard let index = list.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(list, startAt: index)
        Haptics.soft()
    }

    private func runSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keyword = trimmed
        submitted = trimmed
        isFieldFocused = false
        history = [trimmed] + history.filter { $0 != trimmed }
        if history.count > 20 { history.removeLast(history.count - 20) }
        Self.saveHistory(history)
        Task { await search(trimmed) }
    }

    private func search(_ text: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = KugouClient.shared
        async let songs = try? client.searchSongs(keyword: text)
        async let topLists = client.topLists()

        // 酷狗没有歌单/歌手搜索实体，榜单直接从榜单列表里按关键词过滤
        let found = await songs ?? []
        let ranks = await topLists
        let filteredRanks = ranks.filter { $0.name.localizedCaseInsensitiveContains(text) }
        let artists = Self.artistHints(from: found)
        let albums = Self.albumHints(from: found)

        guard submitted == text else { return }
        results = SearchResults(songs: found, playlists: filteredRanks, artists: artists, albums: albums)
        if results.isEmpty {
            errorMessage = "换个关键词试试"
        }
    }

    /// 酷狗结果里没有独立歌手节点，这里从歌曲的歌手名聚合出「热门歌手」入口。
    private static func artistHints(from songs: [Song]) -> [Artist] {
        var seen = Set<String>()
        var result: [Artist] = []
        for song in songs {
            for name in song.artist.components(separatedBy: "、").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                result.append(Artist(id: "kw:\(name)", name: name, coverURL: nil))
            }
        }
        return Array(result.prefix(20))
    }

    /// 从歌曲的专辑名聚合出「专辑」板块（酷狗结果无独立专辑实体）。
    private static func albumHints(from songs: [Song]) -> [Album] {
        var seen = Set<String>()
        var result: [Album] = []
        for song in songs {
            let name = song.album.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != song.title else { continue } // 过滤“专辑名=歌名”的单曲占位
            let key = "\(name)|\(song.artist)"
            guard seen.insert(key).inserted else { continue }
            let cover = song.artworkURL
            result.append(Album(id: "al:\(song.kugouAlbumID.isEmpty ? key : song.kugouAlbumID)",
                                name: name,
                                artist: song.artist,
                                coverURL: cover,
                                albumID: song.kugouAlbumID))
        }
        return Array(result.prefix(20))
    }

    private static let historyKey = "aurora.search.history"

    private static func loadHistory() -> [String] {
        UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    private static func saveHistory(_ value: [String]) {
        UserDefaults.standard.set(value, forKey: historyKey)
    }
}
