import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// 曲库页 —— 顶栏切换「我的音乐 / 酷狗音乐」
struct LibraryView: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var kugouAuth = KugouAuth.shared

    @State private var topTab: TopTab = .local

    enum TopTab { case local, kugou }

    var body: some View {
        CompatNavigationStack {
            VStack(spacing: 0) {
                // 🔴 顶栏 Tab 切换
                topBar

                TabView(selection: $topTab) {
                    LocalLibraryPage()
                        .tag(TopTab.local)
                    KugouLibraryPage()
                        .tag(TopTab.kugou)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.none, value: topTab)
            }
            .background(AppStyle.background)
            .navigationTitle(topTab == .local ? "我的音乐" : "酷狗音乐")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    kugouAvatarButton
                }
            }
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 6) {
            topButton(title: "我的音乐", selected: topTab == .local) { topTab = .local }
            topButton(title: "酷狗音乐", selected: topTab == .kugou) { topTab = .kugou }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func topButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? AppStyle.accent : AppStyle.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(selected ? AppStyle.accent.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // 🔴 顶栏右上角：酷狗登录头像（或登录按钮）
    @ViewBuilder
    private var kugouAvatarButton: some View {
        if kugouAuth.isLoggedIn {
            NavigationLink {
                KugouAccountCenter()
            } label: {
                HStack(spacing: 6) {
                    CoverImage(url: kugouAuth.avatarURL, seed: kugouAuth.nickname,
                               size: 32, corner: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kugouAuth.nickname.isEmpty ? kugouAuth.userId : kugouAuth.nickname)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppStyle.primaryText)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if kugouAuth.isVip {
                                Text("VIP")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color(red: 1.0, green: 0.85, blue: 0.2), in: Capsule())
                            }
                            Text("已登录酷狗")
                                .font(.system(size: 10))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                // 弹登录免责声明 → 再弹扫码登录
                NotificationCenter.default.post(name: .auroraShowKugouLogin, object: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "music.mic")
                    Text("登录")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(AppStyle.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 本地音乐页面

private struct LocalLibraryPage: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var section: Section = .favorites
    @State private var isCreatingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var renamingID: String?
    @State private var renamingName = ""

    private enum Section: Int, CaseIterable, Identifiable {
        case favorites, albums, artists, downloads, local, playlists
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .favorites: return "收藏"
            case .albums: return "专辑"
            case .artists: return "歌手"
            case .downloads: return "下载"
            case .local: return "本地"
            case .playlists: return "歌单"
            }
        }
        var icon: String {
            switch self {
            case .favorites: return "heart.fill"
            case .albums: return "square.stack.fill"
            case .artists: return "person.crop.circle.fill"
            case .downloads: return "arrow.down.circle.fill"
            case .local: return "iphone"
            case .playlists: return "music.note.list"
            }
        }
    }

    private var songs: [Song] {
        switch section {
        case .favorites: return library.favorites
        case .downloads: return library.downloads
        case .local: return library.localSongs
        case .playlists, .albums, .artists: return []
        }
    }
    private func count(for item: Section) -> Int {
        switch item {
        case .favorites: return library.favorites.count
        case .albums: return library.albumFavorites.count
        case .artists: return library.artistFavorites.count
        case .downloads: return library.downloads.count
        case .local: return library.localSongs.count
        case .playlists: return library.playlists.count
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                statTiles
                historyStrip
                sectionHeader
                content
            }
        }
        .alert("新建歌单", isPresented: $isCreatingPlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("取消", role: .cancel) { newPlaylistName = "" }
            Button("创建") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { _ = library.createPlaylist(name: name) }
                newPlaylistName = ""
            }
        }
        .alert("重命名歌单", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("歌单名称", text: $renamingName)
            Button("取消", role: .cancel) { renamingID = nil }
            Button("保存") {
                if let id = renamingID { library.renamePlaylist(id: id, name: renamingName) }
                renamingID = nil
            }
        }
    }

    private var statTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Section.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { section = item }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 12))
                            Text(item.title).font(.system(size: 13, weight: section == item ? .semibold : .regular))
                        }
                        .foregroundStyle(section == item ? .white : AppStyle.secondaryText)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(section == item ? AppStyle.accent : AppStyle.surface, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        }
        .padding(.top, 4).padding(.bottom, 10)
    }

    @ViewBuilder private var historyStrip: some View {
        if !library.history.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("最近播放").font(.system(size: 15, weight: .bold)).foregroundStyle(AppStyle.primaryText)
                    Spacer()
                    if library.history.count > 8 { Button("清空") { library.clearHistory() }.font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText) }
                }.padding(.horizontal, 16).padding(.bottom, 10)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(library.history.prefix(16)) { song in
                            Button {
                                guard let index = library.history.firstIndex(where: { $0.id == song.id }) else { return }
                                store.play(Array(library.history), startAt: index); Haptics.soft()
                            } label: {
                                VStack(spacing: 6) {
                                    CoverImage(url: song.artworkURL, seed: "\(song.artist)-\(song.title)", size: 108, corner: 10)
                                    Text(song.title).font(.system(size: 12)).foregroundStyle(AppStyle.primaryText).lineLimit(1).frame(width: 108, alignment: .leading)
                                    Text(song.artist).font(.system(size: 11)).foregroundStyle(AppStyle.tertiaryText).lineLimit(1).frame(width: 108, alignment: .leading)
                                }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 16)
                }
            }.padding(.bottom, 18)
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.system(size: 17, weight: .bold)).foregroundStyle(AppStyle.primaryText)
                Text("共 \(count(for: section)) 项").font(.system(size: 11)).foregroundStyle(AppStyle.tertiaryText)
            }
            Spacer()
            sectionAction
        }.padding(.horizontal, 16).padding(.bottom, 10)
    }

    @ViewBuilder private var sectionAction: some View {
        switch section {
        case .playlists:
            Button { isCreatingPlaylist = true } label: {
                Label("新建", systemImage: "plus").font(.system(size: 12, weight: .medium))
            }
        default:
            if !songs.isEmpty {
                Button("全部播放") { store.play(songs); Haptics.soft() }.font(.system(size: 12, weight: .medium))
            }
        }
    }

    @ViewBuilder private var content: some View {
        if section == .playlists { playlistsContent }
        else if section == .albums { albumsContent }
        else if section == .artists { artistsContent }
        else if songs.isEmpty { localEmptyState }
        else { songList }
    }

    private var localEmptyState: some View {
        let (icon, title, msg) = {
            switch section {
            case .favorites: return ("heart", "还没有收藏", "在歌曲上长按就能收藏")
            case .downloads: return ("arrow.down.circle", "还没有下载", "在歌曲菜单里选「下载」")
            case .local: return ("iphone", "还没有本地音乐", "点导入从文件里选音频")
            default: return ("music.note.list", "暂无", "")
            }
        }()
        return EmptyStateView(icon: icon, title: title, message: msg).padding(.bottom, 60)
    }

    private var songList: some View {
        LazyVStack(spacing: 0) {
            ForEach(songs) { song in
                SongRow(song: song, isCurrent: store.current?.id == song.id, isPlaying: store.isPlaying)
                    .equatable().songMenu(song).padding(.horizontal, 16)
                    .onTapGesture {
                        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
                        store.play(songs, startAt: index); Haptics.soft()
                    }
            }
        }.padding(.bottom, 24)
    }

    private var playlistsContent: some View {
        LazyVStack(spacing: 0) {
            if library.playlists.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "还没有歌单", message: "点右上角「新建」").padding(.bottom, 60)
            } else {
                ForEach(library.playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: Playlist(id: playlist.id, name: playlist.name, coverURL: nil, trackCount: playlist.count), localPlaylist: playlist)
                    } label: {
                        let psongs = library.songs(in: playlist)
                        HStack(spacing: 12) {
                            CoverImage(url: psongs.compactMap { $0.artworkURL }.first, seed: playlist.name, size: 52, corner: 8)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name).font(.system(size: 15, weight: .medium)).foregroundStyle(AppStyle.primaryText).lineLimit(1)
                                Text("\(playlist.count) 首").font(.system(size: 12)).foregroundStyle(AppStyle.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppStyle.tertiaryText)
                        }.padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button { renamingID = playlist.id; renamingName = playlist.name } label: { Label("重命名", systemImage: "pencil") }
                        Button(role: .destructive) { library.deletePlaylist(id: playlist.id) } label: { Label("删除歌单", systemImage: "trash") }
                    }
                }
            }
        }.padding(.bottom, 24)
    }

    private var albumsContent: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
            ForEach(library.albumFavorites) { album in
                NavigationLink { AlbumDetailView(album: album) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        CoverImage(url: album.coverURL,
                                   fallbackKeys: album.albumID.isEmpty ? [] : ["al:\(album.albumID)"],
                                   seed: album.name, size: 160, corner: 10)
                        Text(album.name).font(.system(size: 13, weight: .medium)).foregroundStyle(AppStyle.primaryText).lineLimit(1)
                        Text(album.artist).font(.system(size: 11)).foregroundStyle(AppStyle.tertiaryText).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 16).padding(.bottom, 24)
    }

    private var artistsContent: some View {
        VStack(spacing: 0) {
            ForEach(library.artistFavorites) { artist in
                Button {
                    Haptics.soft()
                    Task {
                        guard let songs = try? await KugouClient.shared.searchSongs(keyword: artist.name, limit: 100), !songs.isEmpty else { return }
                        store.play(songs)
                    }
                } label: {
                    HStack(spacing: 12) {
                        CoverImage(url: artist.coverURL, fallbackKeys: [artist.id], seed: artist.name, size: 46, corner: 23)
                        Text(artist.name).font(.system(size: 14, weight: .medium)).foregroundStyle(AppStyle.primaryText).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppStyle.tertiaryText)
                    }.padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().padding(.leading, 72)
            }
        }.background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16).padding(.bottom, 24)
    }
}

// MARK: - 酷狗音乐页面

private struct KugouLibraryPage: View {
    @ObservedObject private var kugouAuth = KugouAuth.shared
    @State private var playlists: [KugouClient.KugouPlaylist] = []
    @State private var isLoading = false
    @State private var errorMsg: String?
    @State private var showDisclaimer = false

    var body: some View {
        Group {
            if !kugouAuth.isLoggedIn {
                kugouNotLoggedInView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        kugouHeader
                        kugouContent
                    }
                }
                .refreshable { await reloadPlaylists() }
            }
        }
        .sheet(isPresented: $showDisclaimer) {
            KugouDisclaimerView {
                showDisclaimer = false
                NotificationCenter.default.post(name: .auroraShowKugouLogin, object: nil)
            }
        }
        .task(id: kugouAuth.isLoggedIn) {
            if kugouAuth.isLoggedIn { await reloadPlaylists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .auroraKugouLoginSuccess)) { _ in
            Task { await reloadPlaylists() }
        }
    }

    // MARK: 未登录态

    private var kugouNotLoggedInView: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(AppStyle.accent.opacity(0.12)).frame(width: 88, height: 88)
                Image(systemName: "music.mic.fill").font(.system(size: 40)).foregroundStyle(AppStyle.accent)
            }
            .padding(.bottom, 20)

            Text("登录酷狗音乐")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(AppStyle.primaryText)
                .padding(.bottom, 6)

            Text("扫码登录后，可以在这里查看你的酷狗歌单、同步收藏")
                .font(.system(size: 13)).foregroundStyle(AppStyle.tertiaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)

            Button {
                showDisclaimer = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder")
                    Text("扫码登录酷狗")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(AppStyle.accent, in: Capsule())
                .shadow(color: AppStyle.accent.opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: 已登录头

    private var kugouHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                CoverImage(url: kugouAuth.avatarURL, fallbackKeys: ["kg-user:\(kugouAuth.userId)"],
                           seed: kugouAuth.nickname, size: 56, corner: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(kugouAuth.nickname.isEmpty ? "酷狗用户 \(kugouAuth.userId)" : kugouAuth.nickname)
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(AppStyle.primaryText)
                        if kugouAuth.isVip {
                            Text("VIP").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color(red: 1.0, green: 0.85, blue: 0.2), in: Capsule())
                        }
                    }
                    Text("酷狗音乐已连接")
                        .font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText)
                }
                Spacer()
                Button {
                    kugouAuth.logout()
                    playlists.removeAll()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 14)).foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: 歌单列表

    @ViewBuilder
    private var kugouContent: some View {
        if isLoading {
            VStack { ProgressView().padding(.top, 60) }
        } else if let err = errorMsg {
            EmptyStateView(icon: "exclamationmark.triangle", title: "加载失败", message: err).padding(.top, 60)
        } else if playlists.isEmpty {
            EmptyStateView(icon: "music.note.list", title: "还没有酷狗歌单", message: "在酷狗 App 里创建一个吧").padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("我的酷狗歌单").font(.system(size: 15, weight: .bold)).foregroundStyle(AppStyle.primaryText)
                    Spacer()
                    Text("\(playlists.count) 个").font(.system(size: 11)).foregroundStyle(AppStyle.tertiaryText)
                }.padding(.horizontal, 16).padding(.bottom, 8)

                ForEach(playlists) { playlist in
                    NavigationLink {
                        KugouPlaylistDetail(listid: playlist.id, name: playlist.name)
                    } label: {
                        HStack(spacing: 12) {
                            CoverImage(url: nil, seed: playlist.name, size: 54, corner: 8)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(AppStyle.primaryText).lineLimit(1)
                                Text("酷狗歌单")
                                    .font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppStyle.tertiaryText)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider().padding(.leading, 82)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func reloadPlaylists() async {
        isLoading = true
        errorMsg = nil
        defer { isLoading = false }
        do {
            playlists = try await KugouClient.shared.userPlaylists()
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}

// MARK: - 酷狗歌单详情

struct KugouPlaylistDetail: View {
    let listid: String
    let name: String
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var kugouAuth = KugouAuth.shared
    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var errorMsg: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                content
            }
        }
        .background(AppStyle.background)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            CoverImage(url: nil, seed: name, size: 64, corner: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 16, weight: .bold)).foregroundStyle(AppStyle.primaryText).lineLimit(1)
                Text("酷狗歌单 · \(songs.count) 首").font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText)
            }
            Spacer()
            if !songs.isEmpty {
                Button {
                    Haptics.soft()
                    store.queueID = "kugou-list:\(listid)"
                    store.play(songs, startAt: 0)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        Text("播放全部").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(AppStyle.accent))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack { ProgressView().padding(.top, 80) }
        } else if let err = errorMsg {
            EmptyStateView(icon: "exclamationmark.triangle", title: "加载失败", message: err).padding(.top, 60)
        } else if songs.isEmpty {
            EmptyStateView(icon: "music.note.list", title: "歌单是空的").padding(.top, 60)
        } else {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                SongRow(song: song,
                        isCurrent: store.current?.id == song.id,
                        isPlaying: store.isPlaying,
                        trailing: nil)
                    .equatable().songMenu(song).padding(.horizontal, 16)
                    .onTapGesture {
                        store.queueID = "kugou-list:\(listid)"
                        store.play(songs, startAt: index); Haptics.soft()
                    }
                if index < songs.count - 1 {
                    Divider().padding(.leading, 16 + 48 + 12 + 44)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            songs = try await KugouClient.shared.playlistSongs(listid: listid)
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}

// MARK: - 酷狗账号中心

struct KugouAccountCenter: View {
    @ObservedObject private var kugouAuth = KugouAuth.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        Circle().fill(AppStyle.accent.opacity(0.12)).frame(width: 80, height: 80)
                        CoverImage(url: kugouAuth.avatarURL,
                                   fallbackKeys: ["kg-user:\(kugouAuth.userId)"],
                                   seed: kugouAuth.nickname, size: 64, corner: 32)
                    }
                    Text(kugouAuth.nickname.isEmpty ? "酷狗用户 \(kugouAuth.userId)" : kugouAuth.nickname)
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(AppStyle.primaryText)
                    if kugouAuth.isVip {
                        Text("酷狗 VIP").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Color(red: 1.0, green: 0.85, blue: 0.2), in: Capsule())
                    }
                }
                .padding(.top, 30).padding(.bottom, 16)

                VStack(spacing: 0) {
                    HStack {
                        Text("用户 ID").foregroundStyle(AppStyle.secondaryText)
                        Spacer()
                        Text(kugouAuth.userId).foregroundStyle(AppStyle.primaryText)
                            .font(.system(size: 13, design: .monospaced))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().padding(.leading, 16)
                    HStack {
                        Text("登录状态").foregroundStyle(AppStyle.secondaryText)
                        Spacer()
                        Text("已连接酷狗").foregroundStyle(.green).font(.system(size: 13))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)

                Button(role: .destructive) {
                    kugouAuth.logout()
                    dismiss()
                } label: {
                    Text("退出酷狗登录").frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                Text("退出后不会删除本地歌曲和下载记录")
                    .font(.system(size: 11)).foregroundStyle(AppStyle.tertiaryText)
            }
        }
        .navigationTitle("酷狗账号")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 首次登录免责声明（QQ公告同款风格）

struct KugouDisclaimerView: View {
    @Environment(\.dismiss) private var dismiss
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.20, green: 0.55, blue: 0.95),
                                     Color(red: 0.10, green: 0.25, blue: 0.60)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // 图标 + 标题
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(.white.opacity(0.18)).frame(width: 72, height: 72)
                        Image(systemName: "music.mic.fill").font(.system(size: 38)).foregroundStyle(.white)
                    }
                    Text("登录酷狗音乐")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    Text("扫码后会把你的酷狗歌单同步到这里 🎵")
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.bottom, 22)

                // 提示列表
                VStack(alignment: .leading, spacing: 10) {
                    bullet(icon: "lock.shield", text: "登录凭证只保存在本机 UserDefaults，不上云同步")
                    bullet(icon: "folder", text: "你的酷狗歌单会拉取到「我的音乐」下")
                    bullet(icon: "person.2", text: "需要保持正常网络，酷狗接口偶尔会限流")
                    bullet(icon: "hand.raised", text: "请遵守酷狗用户协议，不要抓取付费内容")
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 26)

                // 按钮
                VStack(spacing: 12) {
                    Button {
                        dismiss()
                        onContinue()
                    } label: {
                        Text("我知道了，继续扫码")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(red: 0.10, green: 0.35, blue: 0.80))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.white, in: RoundedRectangle(cornerRadius: 28))
                            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text("取消登录").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 18)

                Spacer(minLength: 0)
            }
        }
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.93))
        }
    }
}

// MARK: - 通知名扩展

extension Notification.Name {
    /// 全局请求弹酷狗登录 Sheet（LibraryView 顶栏按钮 / TabBar 按钮）
    static let auroraShowKugouLogin = Notification.Name("aurora.showKugouLogin")
    /// 酷狗登录成功，各页面刷新歌单
    static let auroraKugouLoginSuccess = Notification.Name("aurora.kugouLoginSuccess")
}
