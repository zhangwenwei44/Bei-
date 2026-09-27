import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 曲库页。排版：顶部一排数据磁贴（收藏 / 下载 / 本地 / 歌单），
/// 下面是当前分组的标题行 + 内容列表。
struct LibraryView: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var isImporterPresented = false
    @State private var isCreatingPlaylist = false
    @State private var isRenaming = false
    @State private var renamingID: String?
    @State private var renamingName = ""
    @State private var newPlaylistName = ""
    @State private var isImporting = false
    @State private var importError: String?
    @State private var section: Section = .favorites

    private enum Section: Int, CaseIterable, Identifiable {
        case favorites, downloads, local, playlists

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .favorites: return "收藏"
            case .downloads: return "下载"
            case .local: return "本地"
            case .playlists: return "歌单"
            }
        }

        var icon: String {
            switch self {
            case .favorites: return "heart.fill"
            case .downloads: return "arrow.down.circle.fill"
            case .local: return "iphone"
            case .playlists: return "music.note.list"
            }
        }

        var tint: Color {
            switch self {
            case .favorites: return AppStyle.like
            case .downloads: return AppStyle.accent
            case .local: return .purple
            case .playlists: return AppStyle.gold
            }
        }
    }

    private var songs: [Song] {
        switch section {
        case .favorites: return library.favorites
        case .downloads: return library.downloads
        case .local: return library.localSongs
        case .playlists: return []
        }
    }

    private func count(for item: Section) -> Int {
        switch item {
        case .favorites: return library.favorites.count
        case .downloads: return library.downloads.count
        case .local: return library.localSongs.count
        case .playlists: return library.playlists.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    statTiles
                    historyStrip
                    sectionHeader
                    content
                }
            }
        }
        .background(AppStyle.background)
        .navigationTitle("我的音乐")
        .navigationBarTitleDisplayMode(.large)
        .fileImporter(isPresented: $isImporterPresented,
                      allowedContentTypes: Self.audioImportTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                importLocal(urls)
            case let .failure(error):
                importError = "打开文件选择器失败：\(error.localizedDescription)"
            }
        }
        .alert("导入本地音乐", isPresented: Binding(get: { importError != nil },
                                                set: { if !$0 { importError = nil } })) {
            Button("从「文件」App 拷进来", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    /// 文件选择器有时会拒绝 iOS 沙盒里的文件（尤其是「我的 iPhone」下的），
    /// 这里把能覆盖的类型都放开，并提示一条肯定可行的替代路径。
    private static var audioImportTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .item, .data]
        if let flac = UTType(filenameExtension: "flac") { types.append(flac) }
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        if let aac = UTType(filenameExtension: "aac") { types.append(aac) }
        if let caf = UTType(filenameExtension: "caf") { types.append(caf) }
        return types
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
        .alert("重命名歌单", isPresented: $isRenaming) {
            TextField("歌单名称", text: $renamingName)
            Button("取消", role: .cancel) { renamingID = nil }
            Button("保存") {
                let name = renamingName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renamingID, !name.isEmpty { library.renamePlaylist(id: id, name: name) }
                renamingID = nil
            }
        }
    }

    // MARK: 顶部数据卡

    private var statTiles: some View {
        HStack(spacing: 10) {
            ForEach(Section.allCases) { item in
                StatTile(icon: item.icon,
                         title: item.title,
                         value: count(for: item),
                         tint: item.tint,
                         isSelected: section == item) {
                    withAnimation(.easeInOut(duration: 0.18)) { section = item }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: 最近播放

    @ViewBuilder
    private var historyStrip: some View {
        if !library.history.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("最近播放")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    Spacer()
                    if library.history.count > 8 {
                        Button("清空") { library.clearHistory() }
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(library.history.prefix(16)) { song in
                            Button {
                                playFromHistory(song)
                            } label: {
                                VStack(spacing: 6) {
                                    CoverImage(url: song.artworkURL,
                                               fallbackKeys: song.kugouHash.isEmpty ? [] : ["kg:\(song.kugouHash)"],
                                               seed: "\(song.artist)-\(song.title)",
                                               size: 108,
                                               corner: 10)
                                        .overlay(alignment: .bottomTrailing) {
                                            if store.current?.id == song.id {
                                                Image(systemName: "waveform")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(.white)
                                                    .padding(4)
                                                    .background(AppStyle.accent, in: Circle())
                                                    .offset(x: 4, y: 4)
                                            }
                                        }
                                    Text(song.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppStyle.primaryText)
                                        .lineLimit(1)
                                        .frame(width: 108, alignment: .leading)
                                    Text(song.artist)
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppStyle.tertiaryText)
                                        .lineLimit(1)
                                        .frame(width: 108, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 18)
        }
    }

    // MARK: 分组标题

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }
            Spacer()
            sectionAction
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        switch section {
        case .favorites: return "在歌曲上右键收藏"
        case .downloads: return "下载后可离线播放"
        case .local: return "从「文件」导入的音频"
        case .playlists: return "自建歌单"
        }
    }

    @ViewBuilder
    private var sectionAction: some View {
        switch section {
        case .local:
            Button {
                isImporterPresented = true
            } label: {
                if isImporting {
                    ProgressView()
                } else {
                    Label("导入", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                }
            }
        case .playlists:
            Button {
                newPlaylistName = ""
                isCreatingPlaylist = true
            } label: {
                Label("新建", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
        default:
            if !songs.isEmpty {
                Button("全部播放") {
                    store.play(songs)
                    Haptics.soft()
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if section == .playlists {
            playlistsContent
        } else if songs.isEmpty {
            emptyState
        } else {
            songList
        }
    }

    private var songList: some View {
        LazyVStack(spacing: 0) {
            ForEach(songs) { song in
                SongRow(song: song,
                        isCurrent: store.current?.id == song.id,
                        isPlaying: store.isPlaying,
                        trailing: trailing(for: song))
                    .songMenu(song)
                    .padding(.horizontal, 16)
                    .onTapGesture { play(song) }
            }
            .onDelete(perform: delete)
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func trailing(for song: Song) -> AnyView? {
        if section == .downloads, let item = downloads.item(for: song), item.state.isActive {
            AnyView(
                ZStack {
                    Circle()
                        .stroke(AppStyle.surfaceHigh, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.02, item.progress))
                        .stroke(AppStyle.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 20, height: 20)
            )
        }
    }

    private var emptyState: some View {
        Group {
            switch section {
            case .favorites:
                EmptyStateView(icon: "heart",
                               title: "还没有收藏",
                               message: "在歌曲上长按就能收藏")
            case .downloads:
                EmptyStateView(icon: "arrow.down.circle",
                               title: "还没有下载",
                               message: "在歌曲菜单里选「下载」，之后离线也能听")
            case .local:
                EmptyStateView(icon: "iphone",
                               title: "还没有本地音乐",
                               message: "点右上角「导入」从「文件」里选音频")
            case .playlists:
                EmptyStateView(icon: "music.note.list",
                               title: "还没有歌单",
                               message: "点右上角「新建」，再从歌曲菜单里加进来")
            }
        }
        .padding(.bottom, 60)
    }

    // MARK: 歌单

    private var playlistsContent: some View {
        LazyVStack(spacing: 0) {
            if library.playlists.isEmpty {
                EmptyStateView(icon: "music.note.list",
                               title: "还没有歌单",
                               message: "点右上角「新建」，再从歌曲菜单里加进来")
            } else {
                ForEach(library.playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: Playlist(id: playlist.id,
                                                              name: playlist.name,
                                                              coverURL: nil,
                                                              trackCount: playlist.count),
                                          localPlaylist: playlist)
                    } label: {
                        playlistRow(playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renamingID = playlist.id
                            renamingName = playlist.name
                            isRenaming = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            library.deletePlaylist(id: playlist.id)
                        } label: {
                            Label("删除歌单", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(.bottom, 24)
    }

    private func playlistRow(_ playlist: LibraryStore.UserPlaylist) -> some View {
        let songs = library.songs(in: playlist)
        let cover = songs.compactMap { $0.artworkURL }.first
        return HStack(spacing: 12) {
            CoverImage(url: cover, seed: playlist.name, size: 52, corner: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text("\(playlist.count) 首")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppStyle.tertiaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: 行为

    private func play(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(songs, startAt: index)
        Haptics.soft()
    }

    private func playFromHistory(_ song: Song) {
        let list = Array(library.history)
        guard let index = list.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(list, startAt: index)
        Haptics.soft()
    }

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { songs[$0] }
        switch section {
        case .favorites:
            targets.forEach { _ = library.toggleFavorite($0) }
        case .downloads:
            targets.forEach { downloads.delete($0) }
        case .local:
            targets.forEach { library.removeLocal(id: $0.id) }
        case .playlists:
            break
        }
    }

    /// 导入本地音频：复制到 Documents 保证重启后仍可播放，并抽一张封面出来。
    private func importLocal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            var imported: [Song] = []
            var failures: [String] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }

                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let target: URL
                if url.path.hasPrefix(documents.path) {
                    target = url
                } else {
                    let folder = documents.appendingPathComponent("Aurora Imports", isDirectory: true)
                    if !FileManager.default.fileExists(atPath: folder.path) {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    }
                    target = folder.appendingPathComponent(url.lastPathComponent)
                    if FileManager.default.fileExists(atPath: target.path) {
                        try? FileManager.default.removeItem(at: target)
                    }
                    do {
                        try FileManager.default.copyItem(at: url, to: target)
                    } catch {
                        failures.append(url.lastPathComponent)
                        continue
                    }
                }

                // 选进来但拷不过去的（权限/格式），也直接按沙盒内路径试一次
                guard FileManager.default.fileExists(atPath: target.path) else {
                    failures.append(url.lastPathComponent)
                    continue
                }

                let asset = AVURLAsset(url: target)
                let duration = (try? await asset.load(.duration)).map { $0.seconds } ?? 0
                let title = target.deletingPathExtension().lastPathComponent
                let cover = await LocalArtwork.cover(for: target, title: title)
                imported.append(Song(id: Song.localID(for: target.path),
                                     title: title,
                                     artist: "本地音频",
                                     url: target,
                                     tags: ["本地"],
                                     isLocal: true,
                                     duration: duration.isFinite ? duration : 0,
                                     artworkURL: cover,
                                     source: .local))
            }
            await MainActor.run {
                isImporting = false
                library.addLocal(imported)
                if imported.isEmpty {
                    importError = failures.isEmpty
                        ? "没读到可用的音频文件"
                        : "这些文件读不了：\(failures.joined(separator: "、"))。可以先用「文件」App 打开它们，再分享到本 App"
                } else if !failures.isEmpty {
                    importError = "导入 \(imported.count) 首，失败：\(failures.joined(separator: "、"))"
                }
            }
        }
    }
}
