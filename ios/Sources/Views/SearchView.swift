import SwiftUI

/// 搜索页：单曲 / 歌单 / 歌手 / 专辑。
struct SearchView: View {
    /// 🔴 v2.9.16：搜索类型（综合 / 歌单 / 单曲 / 专辑），搜索框内可选择。
    private enum SearchScope: String, CaseIterable, Identifiable {
        case comprehensive, playlist, song, album
        var id: String { rawValue }
        var title: String {
            switch self {
            case .comprehensive: return "综合"
            case .playlist: return "歌单"
            case .song: return "单曲"
            case .album: return "专辑"
            }
        }
    }

    var initialKeyword: String = ""

    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var keyword = ""
    @State private var submitted = ""
    @State private var results = SearchResults()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var history: [String] = []
    @FocusState private var isFieldFocused: Bool

    // 分页无限滚动
    @State private var songPage = 1
    @State private var albumPage = 1
    @State private var hasMoreSongs = true
    @State private var hasMoreAlbums = true
    @State private var isLoadingMore = false

    // 多选模式
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var scope: SearchScope = .comprehensive

    var body: some View {
        VStack(spacing: 0) {
            searchField
            // 🔴 v2.9.7：原来这里有「单曲 / 专辑」两个切换按钮，用户要求移除。
            // 单曲和专辑现在合成一份连续列表（先单曲、再专辑）。
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
        // 🔴 v2.9.6(修正)：顶部淡蓝渐变钉在页面顶部，上滑不消失（与主页一致）。
        .kugouPinnedTopFade(height: 280)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .kugouNavigationBarTint()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button {
                        isSelecting = false
                        selectedIDs.removeAll()
                    } label: {
                        Text("完成")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button {
                        if selectedIDs.count == results.songs.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(results.songs.map(\.id))
                        }
                    } label: {
                        Text(selectedIDs.count == results.songs.count ? "取消全选" : "全选")
                            .font(.system(size: 14, weight: .medium))
                    }
                } else if !submitted.isEmpty, !results.songs.isEmpty {
                    // 🔴 v2.9.7：多选只对单曲有效（多选状态管的是 results.songs），
                    // 原来靠 `scope == .songs` 判断，现在 scope 已删除，
                    // 改成「有单曲结果时才显示」。
                    Button {
                        isSelecting = true
                        selectedIDs.removeAll()
                    } label: {
                        Label("多选", systemImage: "checkmark.circle")
                    }
                    .font(.system(size: 13))
                } else if !submitted.isEmpty {
                    Button("清空") {
                        submitted = ""
                        keyword = ""
                        results = SearchResults()
                        isSelecting = false
                        selectedIDs.removeAll()
                        refreshSearchHint()   // 🔴 v2.9.7(二)：换个新的「猜你想搜」
                    }
                    .font(.system(size: 13))
                }
            }
        }
        .onAppear {
            history = Self.loadHistory()
            // 🔴 v2.9.7(二)：进页面换一个「猜你想搜」提示词
            refreshSearchHint()
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
            // 🔴 v2.9.16：搜索类型选择按钮（综合 / 歌单 / 单曲 / 专辑）
            Menu {
                ForEach(SearchScope.allCases) { s in
                    Button {
                        scope = s
                        if !submitted.isEmpty { runSearch(submitted) }
                    } label: {
                        HStack(spacing: 4) {
                            if scope == s { Image(systemName: "checkmark") }
                            Text(s.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(scope.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppStyle.primaryText)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppStyle.secondaryText)
                }
            }
            .fixedSize()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(AppStyle.secondaryText)
                // 🔴 v2.9.7(二)：搜索框加入「猜你想搜」—— 空闲时占位符显示一个随机热词
                TextField(searchHint.isEmpty ? "歌曲、歌手、歌单" : "猜你想搜：\(searchHint)", text: $keyword)
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
            .frame(height: 34)
            .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !submitted.isEmpty {
                Button("取消") {
                    submitted = ""
                    keyword = ""
                    results = SearchResults()
                    isFieldFocused = false
                    refreshSearchHint()   // 🔴 v2.9.7(二)：换个新的「猜你想搜」
                }
                .font(.system(size: 13))
                .foregroundStyle(AppStyle.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: 结果

    @ViewBuilder
    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // 🔴 v2.9.16：按搜索类型显示对应板块（综合 = 单曲+歌单+专辑；其余只显示本类型）
                if scope == .song || scope == .comprehensive {
                    ForEach(Array(results.songs.enumerated()), id: \.element.id) { idx, song in
                        let selected = selectedIDs.contains(song.id)
                        HStack(spacing: 12) {
                            if isSelecting {
                                Button {
                                    if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                } label: {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22))
                                        .foregroundStyle(selected ? AppStyle.accent : AppStyle.tertiaryText)
                                }
                                .buttonStyle(.plain)
                            }
                            SongRow(song: song,
                                    isCurrent: store.current?.id == song.id,
                                    isPlaying: store.isPlaying)
                                    .equatable()
                                    .songMenu(song)
                                    .onTapGesture {
                                        if isSelecting {
                                            if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                        } else { play(song) }
                                    }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppStyle.surface.opacity(0.5))
                        .cornerRadius(10)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                        .onAppear {
                            // 滑到底部触发加载更多（倒数第 5 条时触发）
                            if idx == results.songs.count - 5 {
                                Task { await loadMoreSongs() }
                            }
                        }

                        Divider()
                            .padding(.leading, 60)
                    }
                    // 底部加载指示器
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            ProgressView().controlSize(.small)
                            Text("加载中...").font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText)
                        } else if !hasMoreSongs {
                            Text("— 到底了 —").font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }

                // 歌单板块
                if (scope == .playlist || scope == .comprehensive), !results.playlists.isEmpty {
                    Text("歌单")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppStyle.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 6)

                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(results.playlists) { playlist in
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                HStack(spacing: 14) {
                                    CoverImage(url: playlist.coverURL,
                                               fallbackKeys: [playlist.id],
                                               seed: playlist.name, size: 56, corner: 10)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(AppStyle.primaryText)
                                            .lineLimit(2)
                                        Text(playlist.creatorName.isEmpty ? "酷狗音乐" : playlist.creatorName)
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppStyle.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppStyle.surface.opacity(0.5))
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // 专辑板块
                if (scope == .album || scope == .comprehensive), !results.albums.isEmpty {
                    Text("专辑")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppStyle.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 6)

                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(results.albums) { album in
                            NavigationLink {
                                AlbumDetailView(album: album)
                            } label: {
                                HStack(spacing: 14) {
                                    CoverImage(url: album.coverURL,
                                               fallbackKeys: album.albumID.isEmpty ? [] : ["al:\(album.albumID)"],
                                               seed: album.name, size: 56, corner: 10)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(album.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(AppStyle.primaryText)
                                            .lineLimit(2)
                                        Text(album.artist)
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppStyle.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button {
                                        _ = library.toggleAlbumFavorite(album)
                                        Haptics.light()
                                    } label: {
                                        Image(systemName: library.isAlbumFavorite(album) ? "heart.fill" : "heart")
                                            .font(.system(size: 16))
                                            .foregroundStyle(library.isAlbumFavorite(album) ? AppStyle.like : AppStyle.tertiaryText)
                                            .frame(width: 36, height: 36)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppStyle.surface.opacity(0.5))
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !selectedIDs.isEmpty {
                selectedActionBar
            }
        }
        .onChange(of: isSelecting) { newValue in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                store.isAnyMultiSelecting = newValue
            }
        }
        .onDisappear { store.isAnyMultiSelecting = false }
    }

    /// 多选模式下的底部操作条。
    private var selectedActionBar: some View {
        let selected = results.songs.filter { selectedIDs.contains($0.id) }
        return HStack(spacing: 0) {
            actionButton(title: "播放", icon: "play.fill") {
                store.play(selected)
                Haptics.soft()
                isSelecting = false
                selectedIDs.removeAll()
            }
            Divider().frame(height: 24)
            actionButton(title: "下载", icon: "arrow.down.circle") {
                Task {
                    for song in selected {
                        if song.isRemote { _ = try? await downloads.download(song) }
                    }
                }
                Haptics.soft()
                isSelecting = false
                selectedIDs.removeAll()
            }
            Divider().frame(height: 24)
            Menu {
                if library.playlists.isEmpty {
                    Text("还没有歌单")
                }
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) {
                        for song in selected { library.add(song, toPlaylist: playlist.id) }
                        Haptics.soft()
                        isSelecting = false
                        selectedIDs.removeAll()
                    }
                }
            } label: {
                actionButton(title: "加入歌单", icon: "text.badge.plus") {}
            }
        }
        .background(AppStyle.surface)
        .overlay(
            Rectangle().fill(AppStyle.stroke).frame(height: 0.5),
            alignment: .top
        )
    }

    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(AppStyle.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
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

    /// 🔴 v2.9.7(二)：「猜你想搜」—— 搜索框的随机提示词（从热门词里随机挑一个）。
    /// 每次进入搜索页 / 清空搜索时换一个。
    @State private var searchHint: String = ""

    private func refreshSearchHint() {
        searchHint = Self.hotKeywords.randomElement() ?? ""
    }

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

        // 重置分页状态
        songPage = 1; albumPage = 1
        hasMoreSongs = true; hasMoreAlbums = true

        let client = KugouClient.shared
        switch scope {
        case .song:
            do {
                let firstPage = try await client.searchSongs(keyword: text, page: 1)
                var seen = Set<String>()
                let found = firstPage.filter { seen.insert($0.id).inserted }
                hasMoreSongs = firstPage.count >= 30
                Log.info("搜索", "keyword=\(text)[单曲] page=1 found=\(found.count) hasMore=\(hasMoreSongs)")
                guard submitted == text else { return }
                results = SearchResults(songs: found, playlists: [], artists: [], albums: [])
                if results.isEmpty { errorMessage = "换个关键词试试" }
            } catch {
                errorMessage = error.localizedDescription
            }
        case .playlist:
            let (pls, total) = await client.searchPlaylists(keyword: text, page: 1)
            Log.info("搜索", "keyword=\(text)[歌单] \(pls.count)/\(total)")
            guard submitted == text else { return }
            results = SearchResults(songs: [], playlists: pls, artists: [], albums: [])
            if results.isEmpty { errorMessage = "换个关键词试试" }
        case .album:
            let albums = await client.searchAlbums(keyword: text, page: 1)
            Log.info("搜索", "keyword=\(text)[专辑] \(albums.count)")
            guard submitted == text else { return }
            results = SearchResults(songs: [], playlists: [], artists: [], albums: albums)
            hasMoreAlbums = albums.count >= 30
            if results.isEmpty { errorMessage = "换个关键词试试" }
        case .comprehensive:
            do {
                async let songsTask = try client.searchSongs(keyword: text, page: 1)
                async let plsTask = client.searchPlaylists(keyword: text, page: 1)
                async let albumsTask = client.searchAlbums(keyword: text, page: 1)
                let (found, pls, albums) = try await (songsTask, plsTask, albumsTask)
                var seen = Set<String>()
                let songs = found.filter { seen.insert($0.id).inserted }
                hasMoreSongs = found.count >= 30
                let artists = Self.artistHints(from: songs)
                let albumList = Self.albumHints(from: songs)
                hasMoreAlbums = albumList.count >= 20
                Log.info("搜索", "keyword=\(text)[综合] songs=\(songs.count) playlists=\(pls.playlists.count) albums=\(albumList.count)")
                guard submitted == text else { return }
                results = SearchResults(songs: songs, playlists: pls.playlists, artists: artists, albums: albumList)
                if results.isEmpty { errorMessage = "换个关键词试试" }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 无限滚动加载下一页歌曲
    private func loadMoreSongs() async {
        guard !isLoadingMore, hasMoreSongs, !submitted.isEmpty else { return }
        isLoadingMore = true; defer { isLoadingMore = false }
        let next = songPage + 1
        let client = KugouClient.shared
        guard let more = try? await client.searchSongs(keyword: submitted, page: next) else { return }
        var seen = Set(results.songs.map(\.id))
        let newItems = more.filter { seen.insert($0.id).inserted }
        results.songs.append(contentsOf: newItems)
        songPage = next
        hasMoreSongs = more.count >= 30
        Log.info("搜索", "loadMore page=\(next) added=\(newItems.count) total=\(results.songs.count)")
    }

    /// 酷狗结果里没有独立歌手节点，这里从歌曲的歌手名聚合出「热门歌手」入口。
    private static func artistHints(from songs: [Song]) -> [Artist] {
        var seen = Set<String>()
        var coverMap: [String: URL?] = [:] // artist name -> first artwork
        for song in songs {
            for name in song.artist.components(separatedBy: "、").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                coverMap[name] = song.artworkURL
            }
        }
        seen.removeAll()
        var result: [Artist] = []
        for song in songs {
            for name in song.artist.components(separatedBy: "、").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                let cover = coverMap[name] ?? song.artworkURL
                result.append(Artist(id: "kw:\(name)", name: name, coverURL: cover))
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
