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
                List {
                    Section {
                        ForEach(songs) { song in
                            SongRow(song: song,
                                    isCurrent: store.current?.id == song.id,
                                    isPlaying: store.isPlaying)
                                .equatable()
                                .songMenu(song)
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(AppStyle.stroke)
                                .onTapGesture { play(song) }
                        }
                    } header: {
                        Text(subtitle ?? "\(songs.count) 首")
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppStyle.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
    /// 场景：DiscoverView 的 KTV必点曲/经典推荐/新歌推荐 三个板块，
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

    private var displaySongs: [Song] {
        if let localPlaylist { return library.songs(in: localPlaylist) }
        return songs
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if isLoading, displaySongs.isEmpty {
                    LoadingRow()
                } else if let errorMessage, displaySongs.isEmpty {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "加载失败", message: errorMessage)
                } else if displaySongs.isEmpty {
                    EmptyStateView(icon: "music.note.list",
                                   title: "歌单里还没有歌曲",
                                   message: "重新下拉试试，或换一个榜单")
                } else {
                    actionBar
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
                                        isPlaying: store.isPlaying)
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
            }
            .padding(.bottom, 30)
        }
        .background(AppStyle.background)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
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
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    HStack(spacing: 14) {
                        Button {
                            if selectedIDs.count == displaySongs.count { selectedIDs.removeAll() }
                            else { selectedIDs = Set(displaySongs.map(\.id)) }
                        } label: {
                            Text(selectedIDs.count == displaySongs.count ? "取消全选" : "全选")
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        if !displaySongs.isEmpty {
                            Button { Task { await downloadAllSongs() } } label: {
                                Image(systemName: "arrow.down.circle.dotted").font(.system(size: 16)).frame(width: 36, height: 36)
                            }
                        }
                        if localPlaylist == nil {
                            Button {
                                isCollected.toggle()
                                CollectionState.set(isCollected, for: playlist.id)
                                Haptics.light()
                            } label: {
                                Image(systemName: isCollected ? "heart.fill" : "heart")
                                    .font(.system(size: 16))
                                    .foregroundStyle(isCollected ? AppStyle.like : AppStyle.primaryText)
                                    .frame(width: 36, height: 36)
                            }
                        }
                        if !displaySongs.isEmpty {
                            Button { isSelecting = true; selectedIDs.removeAll() } label: {
                                Image(systemName: "checkmark.circle").font(.system(size: 16)).frame(width: 36, height: 36)
                            }
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button { isSelecting = false; selectedIDs.removeAll() } label: {
                        Text("完成").font(.system(size: 14, weight: .medium))
                    }
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

    private var header: some View {
        HStack(spacing: 14) {
            CoverImage(url: playlist.coverURL, fallbackKeys: [playlist.id], seed: playlist.name, size: 112, corner: 12)
            VStack(alignment: .leading, spacing: 8) {
                Text(playlist.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(3)
                HStack(spacing: 10) {
                    if !playlist.creatorName.isEmpty {
                        Label(playlist.creatorName, systemImage: "person.crop.circle")
                    }
                    if playlist.trackCount > 0 {
                        Text("\(playlist.trackCount) 首")
                    } else if !playlist.creatorName.isEmpty {
                        // 曲目数还没补到，用进度圈代替（iOS 16 兼容）
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            Button {
                store.play(displaySongs); Haptics.light()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 16, weight: .bold))
                    Text("播放全部").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(AppStyle.onAccent)
                .frame(width: 132, height: 42)
                .background(AppStyle.accent, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                Task { await downloadAllSongs() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.dotted").font(.system(size: 16))
                    Text("下载全部").font(.system(size: 14))
                }
                .foregroundStyle(AppStyle.primaryText)
                .frame(height: 42)
                .padding(.horizontal, 16)
                .background(AppStyle.surface.opacity(0.6), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            if displaySongs.count > 1 {
                Menu {
                    ForEach(displaySongs.indices, id: \.self) { offset in
                        Button(displaySongs[offset].title) { store.play(displaySongs, startAt: offset) }
                    }
                } label: {
                    Image(systemName: "list.number")
                        .font(.system(size: 18))
                        .foregroundStyle(AppStyle.primaryText)
                        .frame(width: 36, height: 36)
                        .background(AppStyle.surface.opacity(0.6), in: Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
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

    private var isFavorited: Bool { library.isAlbumFavorite(album) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if isLoading, songs.isEmpty {
                    LoadingRow()
                } else if let errorMessage, songs.isEmpty {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "加载失败", message: errorMessage)
                } else if songs.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "专辑里没找到歌曲", message: "可能这个专辑在酷狗上的信息较少")
                } else {
                    actionBar
                    VStack(spacing: 0) {
                        ForEach(songs) { song in
                            SongRow(song: song,
                                    isCurrent: store.current?.id == song.id,
                                    isPlaying: store.isPlaying)
                                .equatable()
                                .songMenu(song)
                                .padding(.horizontal, 16)
                                .onTapGesture { play(song) }
                        }
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .background(AppStyle.background)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    _ = library.toggleAlbumFavorite(album)
                    Haptics.light()
                } label: {
                    Image(systemName: isFavorited ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorited ? AppStyle.like : AppStyle.primaryText)
                }
            }
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CoverImage(url: album.coverURL,
                       fallbackKeys: album.albumID.isEmpty ? [] : ["al:\(album.albumID)"],
                       seed: album.name,
                       size: 128,
                       corner: 12)
            VStack(alignment: .leading, spacing: 8) {
                Text(album.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(3)
                Text(album.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.secondaryText)
                    .lineLimit(1)
                if !songs.isEmpty {
                    Text("\(songs.count) 首")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var actionBar: some View {
        HStack(spacing: 22) {
            Button {
                store.play(songs)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppStyle.onAccent)
                    .frame(width: 52, height: 52)
                    .background(AppStyle.accent, in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await downloadAllAlbumSongs() }
            } label: {
                Label("下载全部", systemImage: "arrow.down.circle.dotted")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.primaryText)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
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
