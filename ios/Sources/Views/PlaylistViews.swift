import SwiftUI

/// 收藏的在线歌单（只记 ID，够用即可）。
enum CollectionState {
    private static let key = "aurora.collected.playlists"

    static func isCollected(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id)
    }

    static func set(_ collected: Bool, for id: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == id }
        if collected { list.insert(id, at: 0) }
        UserDefaults.standard.set(list, forKey: key)
    }
}

/// 通用歌曲列表页：用于「全部 XX」和本地歌单。
struct SongListView: View {
    let title: String
    let songs: [Song]
    var subtitle: String?

    @EnvironmentObject private var store: PlayerStore

    var body: some View {
        VStack(spacing: 0) {
            if songs.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "这里还没有歌曲")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // 副标题行
                        HStack {
                            Text(subtitle ?? "\(songs.count) 首")
                                .font(.system(size: 12))
                                .foregroundStyle(AppStyle.tertiaryText)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        ForEach(songs) { song in
                            SongRow(song: song,
                                    isCurrent: store.current?.id == song.id,
                                    isPlaying: store.isPlaying)
                                .equatable()
                                .songMenu(song)
                                .onTapGesture { play(song) }
                                Divider().padding(.leading, 74)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .background(AppStyle.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 v2.9.6(修正)：二级页/弹窗的导航栏统一改成白色（主页那四个保持淡蓝渐变）
        .kugouNavigationBarBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.play(songs)
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(songs.isEmpty)
            }
        }
    }

    private func play(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(songs, startAt: index)
        Haptics.soft()
    }
}

/// 歌单详情：在线歌单加载曲目，本地歌单直接展示。
struct PlaylistDetailView: View {
    let playlist: Playlist
    var localPlaylist: LibraryStore.UserPlaylist?
    /// 页面外部已经加载好的歌曲列表 —— 传了就跳过网络请求，直接用。
    /// 场景：DiscoverView 的「新歌推荐」板块，
    ///       歌曲已经搜索好了，点"更多"push 进来时直接复用，省一次网络请求。
    var initialSongs: [Song]? = nil

    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isCollected = false
    @State private var didLoadCollection = false

    // 多选
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

    /// 🔴 2026-11-07：沉浸式头部状态（容器与 toolbar 共用，顶栏配色才能随滚动同步）。
    @StateObject private var headerState = ImmersiveHeaderState()

    private var displaySongs: [Song] {
        if let localPlaylist { return library.songs(in: localPlaylist) }
        return songs
    }

    /// 🔴 5 个推荐板块没有自己的封面 → 用第一首歌的封面放大当大图；
    /// 歌单/专辑有自己的封面就用自己的。
    private var heroURL: URL? {
        playlist.coverURL ?? displaySongs.first?.artworkURL
    }

    var body: some View {
        ImmersiveSongListContainer(
            state: headerState,
            // 🔴 歌曲异步加载完 URL 才出现 → 用身份串让大图浮层刷新一次 rootView。
            heroKey: "\(heroURL?.absoluteString ?? "-")|\(playlist.name)|\(displaySongs.count)",
            hero: {
                ImmersiveCoverHero(
                    url: heroURL,
                    fallbackKeys: [playlist.id],
                    seed: playlist.name,
                    title: playlist.name,
                    subtitle: playlist.creatorName.isEmpty ? nil : playlist.creatorName,
                    detail: displaySongs.isEmpty ? nil : "\(displaySongs.count) 首",
                    headerHeight: headerState.headerHeight
                )
            },
            sticky: { actionBar },
            content: {
                if isLoading, displaySongs.isEmpty {
                    LoadingRow()
                } else if let errorMessage, displaySongs.isEmpty {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "加载失败", message: errorMessage)
                } else if displaySongs.isEmpty {
                    EmptyStateView(icon: "music.note.list",
                                   title: "歌单里还没有歌曲",
                                   message: "重新下拉试试，或换一个榜单")
                } else {
                    VStack(spacing: 0) {
                        ForEach(displaySongs) { song in
                            let selected = selectedIDs.contains(song.id)
                            HStack(spacing: 0) {
                                if isSelecting {
                                    Button {
                                        if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                    } label: {
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 24))
                                            .foregroundStyle(selected ? AppStyle.accent : AppStyle.tertiaryText)
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                }
                                SongRow(song: song,
                                        isCurrent: store.current?.id == song.id,
                                        isPlaying: store.isPlaying,
                                        artistFontSize: 11)
                                    .equatable()
                                    .songMenu(song)
                                    .padding(.horizontal, 16)
                                    .onTapGesture {
                                        if isSelecting {
                                            if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                        } else { play(song) }
                                    }
                                    .contextMenu {
                                        if let localPlaylist {
                                            Button(role: .destructive) {
                                                library.remove(song, fromPlaylist: localPlaylist.id)
                                            } label: {
                                                Label("从歌单移除", systemImage: "minus.circle")
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
                // 🔴 底部留白：让最后一首歌能滚到迷你播放条上方（2026-11-08 用户反馈被遮挡）。
                Color.clear.frame(height: ImmersiveStyle.listBottomInset)
            }
        )
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 系统返回按钮的 chevron 是全局蓝色，改不了逐页颜色 → 隐藏后自绘。
        .navigationBarBackButtonHidden(true)
        // 🔴 大图在顶（深色）= 白字状态栏；收起后毛玻璃浅底 = 黑字状态栏。
        .compatToolbarDynamicScheme(dark: headerState.navFrostOpacity < 0.5)
        .kugouNavigationBarBackground(.clear, transparent: true)
        .onChange(of: isSelecting) { newValue in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                store.isAnyMultiSelecting = newValue
            }
        }
        .onDisappear { store.isAnyMultiSelecting = false }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !selectedIDs.isEmpty {
                let selected = displaySongs.filter { selectedIDs.contains($0.id) }
                HStack(spacing: 0) {
                    Button {
                        store.play(selected); Haptics.soft()
                        isSelecting = false; selectedIDs.removeAll()
                    } label: {
                        VStack(spacing: 4) { Image(systemName: "play.fill").font(.system(size: 18)); Text("播放").font(.system(size: 11)) }
                            .foregroundStyle(AppStyle.primaryText).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.plain)
                    Divider().frame(height: 24)
                    Button {
                        Task { for song in selected { if song.isRemote { _ = try? await downloads.download(song) } } }
                        Haptics.soft(); isSelecting = false; selectedIDs.removeAll()
                    } label: {
                        VStack(spacing: 4) { Image(systemName: "arrow.down.circle").font(.system(size: 18)); Text("下载").font(.system(size: 11)) }
                            .foregroundStyle(AppStyle.primaryText).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.plain)
                    Divider().frame(height: 24)
                    Menu {
                        if library.playlists.isEmpty { Text("还没有歌单") }
                        ForEach(library.playlists) { pl in
                            Button(pl.name) {
                                for song in selected { library.add(song, toPlaylist: pl.id) }
                                Haptics.soft(); isSelecting = false; selectedIDs.removeAll()
                            }
                        }
                    } label: {
                        VStack(spacing: 4) { Image(systemName: "text.badge.plus").font(.system(size: 18)); Text("加歌单").font(.system(size: 11)) }
                            .foregroundStyle(AppStyle.primaryText).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.plain)
                }
                .background(AppStyle.surface)
                .overlay(Rectangle().fill(AppStyle.stroke).frame(height: 0.5), alignment: .top)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isSelecting {
                    Text("已选 \(selectedIDs.count) 首")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(headerState.navContentColor)
                } else {
                    ImmersiveNavTitle(title: playlist.name,
                                      color: headerState.navContentColor,
                                      opacity: headerState.navFrostOpacity)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button {
                        if selectedIDs.count == displaySongs.count { selectedIDs.removeAll() }
                        else { selectedIDs = Set(displaySongs.map(\.id)) }
                    } label: {
                        Text(selectedIDs.count == displaySongs.count ? "取消全选" : "全选")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(headerState.navContentColor)
                    }
                } else {
                    // 🔴 2026-11-08：收藏蓝胶囊移除，右上角只留三点竖；
                    // 收藏 / 下载全部 / 多选下载统一收进菜单，功能不丢。
                    Menu {
                        if localPlaylist == nil {
                            Button {
                                isCollected.toggle()
                                CollectionState.set(isCollected, for: playlist.id)
                                Haptics.light()
                            } label: {
                                Label(isCollected ? "取消收藏" : "收藏歌单",
                                      systemImage: isCollected ? "heart.slash" : "heart")
                            }
                        }
                        Button { Task { await downloadAllSongs() } } label: {
                            Label("下载全部", systemImage: "arrow.down.circle")
                        }
                        Button { isSelecting = true; selectedIDs.removeAll() } label: {
                            Label("多选下载", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .rotationEffect(.degrees(90))
                            .foregroundStyle(headerState.navContentColor)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button { isSelecting = false; selectedIDs.removeAll() } label: {
                        Text("完成")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(headerState.navContentColor)
                    }
                } else {
                    ImmersiveBackButton(color: headerState.navContentColor)
                }
            }
        }
        .task {
            if !didLoadCollection {
                didLoadCollection = true
                isCollected = CollectionState.isCollected(playlist.id)
            }
            await load()
        }
    }

    /// 🔴 2026-11-08 用户指定：吸顶行只保留
    ///   ① 「蓝色圆钮 ▶ + 播放全部 + 灰色曲目数」；② 最右侧多选按钮（布局列表图标）。
    ///   「下载全部」文字按钮与原来的选歌播放 Menu 一并移除（下载全部收进顶栏三点竖菜单）。
    private var actionBar: some View {
        HStack(spacing: 12) {
            ImmersivePlayAllButton(count: displaySongs.count) {
                store.play(displaySongs)
                Haptics.light()
            }

            Spacer(minLength: 0)

            Button {
                isSelecting = true
                selectedIDs.removeAll()
            } label: {
                ImmersiveMultiSelectIcon(color: AppStyle.primaryText)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func play(_ song: Song) {
        guard let index = displaySongs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(displaySongs, startAt: index)
        Haptics.soft()
    }

    /// 一键下载歌单全部歌曲（队列走 DownloadManager）
    private func downloadAllSongs() async {
        let remote = displaySongs.filter { $0.isRemote }
        Log.info("下载", "歌单下载全部：\(remote.count) 首")
        for s in remote {
            _ = try? await downloads.download(s)
        }
        Haptics.soft()
    }

    private func load() async {
        if localPlaylist != nil { return }
        if let initialSongs, !initialSongs.isEmpty {
            songs = initialSongs
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            if let rankID = playlist.kugouRankID {
                // 榜单：rankSongs
                songs = try await KugouClient.shared.rankSongs(rankID: rankID, limit: 50)
                if songs.isEmpty { errorMessage = "榜单接口返回了 0 首歌，可能是 rankid \(rankID) 已失效。" }
            } else if playlist.id.hasPrefix("kg-special:") {
                // 普通歌单：specialid
                let specialID = String(playlist.id.dropFirst("kg-special:".count))
                songs = try await KugouClient.shared.specialSongs(specialID: specialID)
                if songs.isEmpty { errorMessage = "歌单接口返回了 0 首歌，specialid \(specialID) 可能已失效。" }
            } else {
                errorMessage = "这个歌单没有可用的数据源 ID，无法加载歌曲。"
                return
            }
        } catch {
            // 之前这里直接吞成空数组，歌单空白查不到原因
            errorMessage = error.localizedDescription
        }
        // 没封面时用第一首歌的专辑图顶上
        CoverResolver.shared.bind(from: songs, to: [playlist.id])
        // 榜单接口的曲目不带图，只有专辑 id。这里不等用户滚到哪儿补到哪儿，
        // 直接并发把整页封面拉齐，边拉边刷列表（最多 6 路并发，别把接口打疼）。
        await enrichCovers()
    }

    /// 按专辑 id 补齐没封面的歌。补到一个刷一个。
    private func enrichCovers() async {
        let candidates = songs.enumerated()
            .filter { $0.element.artworkURL == nil && !$0.element.kugouAlbumID.isEmpty }
            .map { ($0.offset, $0.element.kugouAlbumID) }
        guard !candidates.isEmpty else { return }

        var queue = candidates.makeIterator()
        await withTaskGroup(of: (Int, URL?).self) { group in
            var inFlight = 0
            func refill() {
                while inFlight < 6, let next = queue.next() {
                    group.addTask {
                        let url = await KugouClient.shared.albumCover(albumID: next.1)
                        return (next.0, url)
                    }
                    inFlight += 1
                }
            }
            refill()
            for await (offset, url) in group {
                inFlight -= 1
                if let url, offset < songs.count, songs[offset].artworkURL == nil {
                    songs[offset].artworkURL = url
                }
                refill()
            }
        }
    }
}

// MARK: - 专辑详情

struct AlbumDetailView: View {
    let album: Album

    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    // 🔴 2026-11-08：与歌单详情页一致，多选入口移到吸顶行右侧。
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    /// 🔴 2026-11-07：与歌单详情共用沉浸式头部状态。
    @StateObject private var headerState = ImmersiveHeaderState()

    private var isFavorited: Bool { library.isAlbumFavorite(album) }

    private var heroURL: URL? { album.coverURL ?? songs.first?.artworkURL }

    var body: some View {
        ImmersiveSongListContainer(
            state: headerState,
            heroKey: "\(heroURL?.absoluteString ?? "-")|\(album.name)|\(songs.count)",
            hero: {
                ImmersiveCoverHero(
                    url: heroURL,
                    fallbackKeys: album.albumID.isEmpty ? [] : ["al:\(album.albumID)"],
                    seed: album.name,
                    title: album.name,
                    subtitle: album.artist,
                    detail: songs.isEmpty ? nil : "\(songs.count) 首",
                    headerHeight: headerState.headerHeight
                )
            },
            sticky: { actionBar },
            content: {
                if isLoading, songs.isEmpty {
                    LoadingRow()
                } else if let errorMessage, songs.isEmpty {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "加载失败", message: errorMessage)
                } else if songs.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "专辑里没找到歌曲", message: "可能这个专辑在酷狗上的信息较少")
                } else {
                    VStack(spacing: 0) {
                        ForEach(songs) { song in
                            let selected = selectedIDs.contains(song.id)
                            HStack(spacing: 0) {
                                if isSelecting {
                                    Button {
                                        if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                    } label: {
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 24))
                                            .foregroundStyle(selected ? AppStyle.accent : AppStyle.tertiaryText)
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                }
                                SongRow(song: song,
                                        isCurrent: store.current?.id == song.id,
                                        isPlaying: store.isPlaying)
                                    .equatable()
                                    .songMenu(song)
                                    .padding(.horizontal, 16)
                                    .onTapGesture {
                                        if isSelecting {
                                            if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                        } else { play(song) }
                                    }
                            }
                        }
                    }
                }
                // 🔴 底部留白：让最后一首歌能滚到迷你播放条上方（2026-11-08 用户反馈被遮挡）。
                Color.clear.frame(height: ImmersiveStyle.listBottomInset)
            }
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .compatToolbarDynamicScheme(dark: headerState.navFrostOpacity < 0.5)
        .kugouNavigationBarBackground(.clear, transparent: true)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isSelecting {
                    Text("已选 \(selectedIDs.count) 首")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(headerState.navContentColor)
                } else {
                    ImmersiveNavTitle(title: album.name,
                                      color: headerState.navContentColor,
                                      opacity: headerState.navFrostOpacity)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button {
                        if selectedIDs.count == songs.count { selectedIDs.removeAll() }
                        else { selectedIDs = Set(songs.map(\.id)) }
                    } label: {
                        Text(selectedIDs.count == songs.count ? "取消全选" : "全选")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(headerState.navContentColor)
                    }
                } else {
                    // 🔴 2026-11-08：收藏蓝胶囊移除，右上角只留三点竖。
                    Menu {
                        Button {
                            _ = library.toggleAlbumFavorite(album)
                            Haptics.light()
                        } label: {
                            Label(isFavorited ? "取消收藏" : "收藏专辑",
                                  systemImage: isFavorited ? "heart.slash" : "heart")
                        }
                        Button { Task { await downloadAllAlbumSongs() } } label: {
                            Label("下载全部", systemImage: "arrow.down.circle")
                        }
                        Button { isSelecting = true; selectedIDs.removeAll() } label: {
                            Label("多选下载", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .rotationEffect(.degrees(90))
                            .foregroundStyle(headerState.navContentColor)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button { isSelecting = false; selectedIDs.removeAll() } label: {
                        Text("完成")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(headerState.navContentColor)
                    }
                } else {
                    ImmersiveBackButton(color: headerState.navContentColor)
                }
            }
        }
        .onChange(of: isSelecting) { newValue in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                store.isAnyMultiSelecting = newValue
            }
        }
        .onDisappear { store.isAnyMultiSelecting = false }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !selectedIDs.isEmpty {
                let selected = songs.filter { selectedIDs.contains($0.id) }
                HStack(spacing: 0) {
                    Button {
                        store.play(selected); Haptics.soft()
                        isSelecting = false; selectedIDs.removeAll()
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppStyle.primaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }.buttonStyle(.plain)
                    Divider().frame(height: 24)
                    Button {
                        Task { for song in selected { if song.isRemote { _ = try? await downloads.download(song) } } }
                        Haptics.soft(); isSelecting = false; selectedIDs.removeAll()
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppStyle.primaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }.buttonStyle(.plain)
                }
                .background(AppStyle.surface)
                .overlay(Rectangle().fill(AppStyle.stroke).frame(height: 0.5), alignment: .top)
            }
        }
        .task { await load() }
    }

    /// 🔴 2026-11-08：与歌单页统一 —— 「蓝色圆钮 + 播放全部 + 数量」+ 右侧多选按钮，
    ///    「下载全部」移到顶栏三点竖菜单。
    private var actionBar: some View {
        HStack(spacing: 12) {
            ImmersivePlayAllButton(count: songs.count) {
                store.play(songs)
                Haptics.light()
            }

            Spacer(minLength: 0)

            Button {
                isSelecting = true
                selectedIDs.removeAll()
            } label: {
                ImmersiveMultiSelectIcon(color: AppStyle.primaryText)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func play(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(songs, startAt: index)
        Haptics.soft()
    }

    private func downloadAllAlbumSongs() async {
        let remote = songs.filter { $0.isRemote }
        Log.info("下载", "专辑下载全部：\(remote.count) 首")
        for s in remote { _ = try? await downloads.download(s) }
        Haptics.soft()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        // 用 "{artist} {album}" 组合关键词搜索，从结果里过滤出专辑名精确匹配的歌曲
        // artist 里可能带 "、" 分隔多个歌手，取第一个
        let leadArtist = album.artist.components(separatedBy: CharacterSet(charactersIn: "、/,")).first?.trimmingCharacters(in: .whitespaces) ?? album.artist
        let keyword = "\(leadArtist) \(album.name)"
        async let p1 = try? KugouClient.shared.searchSongs(keyword: keyword, page: 1)
        async let p2 = try? KugouClient.shared.searchSongs(keyword: keyword, page: 2)
        var found: [Song] = []
        found.append(contentsOf: await p1 ?? [])
        found.append(contentsOf: await p2 ?? [])
        var seen = Set<String>()
        found = found.filter { seen.insert($0.id).inserted }
        // 优先用 album_id 精确匹配（如果有），否则用专辑名模糊匹配
        let filtered: [Song]
        if !album.albumID.isEmpty {
            filtered = found.filter { $0.kugouAlbumID == album.albumID }
        } else {
            filtered = found.filter {
                let songAlbum = $0.album.trimmingCharacters(in: .whitespaces)
                return !songAlbum.isEmpty && songAlbum.localizedCaseInsensitiveContains(album.name)
            }
        }
        songs = filtered.isEmpty ? found : filtered
        if songs.isEmpty { errorMessage = "没找到专辑相关的歌曲" }
    }
}
