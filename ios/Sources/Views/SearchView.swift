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
            // 🔴 2026-11-09：「取消」从搜索框右侧挪到导航栏左上角（用户要求）。
            //    多选时左上角仍是「完成」，两者互斥。
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button {
                        isSelecting = false
                        selectedIDs.removeAll()
                    } label: {
                        Text("完成")
                            .font(.system(size: 14, weight: .medium))
                    }
                } else if !submitted.isEmpty || !keyword.isEmpty {
                    // 输入中（还没按搜索键）也给「取消」，避免用户输入后找不到返回入口。
                    Button("取消") { resetSearch() }
                        .font(.system(size: 14))
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
                    // 🔴 v2.9.7：多选只对单曲有效（多选状态管的是 results.songs）。
                    // 🔴 2026-11-09：图标统一成项目里各歌单页用的「布局列表」多选图标
                    //    （ImmersiveMultiSelectIcon），不再是蓝色圆圈对勾。
                    Button {
                        isSelecting = true
                        selectedIDs.removeAll()
                    } label: {
                        ImmersiveMultiSelectIcon(color: AppStyle.accent)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if !submitted.isEmpty {
                    Button("清空") { resetSearch() }
                        .font(.system(size: 13))
                }
            }
        }
        .onAppear {
            history = Self.loadHistory()
            // 🔴 2026-11-10：进页面随机起一个轮显起点，避免每次都从同一首歌开始
            hotSongIndex = Int.random(in: 0..<Self.hotSongNames.count)
            if !initialKeyword.isEmpty, submitted.isEmpty {
                keyword = initialKeyword
                runSearch(initialKeyword)
            }
        }
        // 🔴 每 3 秒切下一首热门歌名；搜索中 / 输入中 / 已聚焦时暂停，不打扰用户。
        .onReceive(hotSongTimer) { _ in
            guard submitted.isEmpty, keyword.isEmpty, !isFieldFocused else { return }
            hotSongIndex = (hotSongIndex + 1) % Self.hotSongNames.count
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

                // 🔴 2026-11-10：「猜你想搜」静态文案移除，改成热门歌曲名轮显 + 点击即搜。
                //    聚焦后让位给普通输入框；轮显文字只占自身宽度，右侧空白仍可点进输入。
                TextField(isFieldFocused ? "歌曲、歌手、歌单" : "", text: $keyword)
                    .font(.system(size: 14))
                    .foregroundStyle(AppStyle.primaryText)
                    .focused($isFieldFocused)
                    .submitLabel(.search)
                    .onSubmit { runSearch(keyword) }
                    .autocorrectionDisabled()
                    .overlay(alignment: .leading) {
                        if keyword.isEmpty && !isFieldFocused {
                            ZStack(alignment: .leading) {
                                Text(currentHotSong)
                                    .font(.system(size: 14))
                                    .foregroundStyle(AppStyle.tertiaryText)
                                    .lineLimit(1)
                                    .id("hot-\(hotSongIndex)")
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { runSearch(currentHotSong) }
                            .animation(.easeInOut(duration: 0.32), value: hotSongIndex)
                        }
                    }
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                }
                // 🔴 v2.9.18：右侧搜索按钮改为「搜索」文字按钮，彻底移除放大镜图标
                Button {
                    runSearch(keyword)
                } label: {
                    Text("搜索")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppStyle.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // 🔴 2026-11-09：「取消」已移到导航栏左上角，搜索框独占整行、不再挤一个按钮。
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// 清空本次搜索、回到「最近搜索 / 热门搜索」页（左上角「取消」与「清空」共用）。
    private func resetSearch() {
        submitted = ""
        keyword = ""
        results = SearchResults()
        isSelecting = false
        selectedIDs.removeAll()
        isFieldFocused = false
        // 回到空闲页后轮显继续（下一拍自己会切到下一首）。
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
                                    MultiSelectCheckbox(isSelected: selected)
                                }
                                .buttonStyle(.plain)
                            }
                            SongRow(song: song,
                                    isCurrent: store.current?.id == song.id,
                                    isPlaying: store.isPlaying,
                                    onPlay: {
                                        if isSelecting {
                                            if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                        } else { play(song) }
                                    })
                                    .equatable()
                                    .songMenu(song)
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
                            .padding(.leading, 80)
                            .padding(.trailing, 28)
                    }
                    // 底部加载指示器
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            SkeletonInlineRow()
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
                store.setQueueOrigin(id: "search", title: "搜索结果")
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
            // 🔴 2026-11-08：加歌单 → 加入酷狗账号歌单（不再提示「还没有歌单」）。
            AddSelectedToKugouButton(songs: selected) {
                VStack(spacing: 4) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 18))
                    Text("加歌单")
                        .font(.system(size: 11))
                }
                .foregroundStyle(AppStyle.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
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

    /// 🔴 2026-11-10：搜索框轮显用的真实热门歌曲名（替代「猜你想搜：标签词」）。
    ///    点一下直接以该歌名发起搜索；用稳定内置列表，不依赖需要签名的热搜接口。
    static let hotSongNames: [String] = [
        "晴天", "起风了", "孤勇者", "稻香", "夜空中最亮的星",
        "演员", "泡沫", "光年之外", "平凡之路", "海阔天空",
        "后来", "十年", "青花瓷", "告白气球", "消愁", "成都",
        "情罪", "可能", "罗刹海市", "奢香夫人",
    ]

    @State private var hotSongIndex = 0
    private let hotSongTimer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()

    private var currentHotSong: String {
        Self.hotSongNames[hotSongIndex % Self.hotSongNames.count]
    }

    // MARK: 行为

    private func play(_ song: Song) {
        let list = results.songs
        guard let index = list.firstIndex(where: { $0.id == song.id }) else { return }
        store.setQueueOrigin(id: "search", title: "搜索结果")
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
