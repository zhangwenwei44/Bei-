import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 曲库页：收藏、下载、本地、歌单、最近播放。
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
    @State private var section: Section = .favorites

    private enum Section: Int, CaseIterable {
        case favorites, downloads, local, playlists, history

        var title: String {
            switch self {
            case .favorites: return "收藏"
            case .downloads: return "下载"
            case .local: return "本地"
            case .playlists: return "歌单"
            case .history: return "最近"
            }
        }

        var icon: String {
            switch self {
            case .favorites: return "heart"
            case .downloads: return "arrow.down.circle"
            case .local: return "iphone"
            case .playlists: return "music.note.list"
            case .history: return "clock"
            }
        }
    }

    private var songs: [Song] {
        switch section {
        case .favorites: return library.favorites
        case .downloads: return library.downloads
        case .local: return library.localSongs
        case .history: return library.history
        case .playlists: return []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
            content
        }
        .background(AppStyle.background)
        .navigationTitle("我的音乐")
        .navigationBarTitleDisplayMode(.large)
        .fileImporter(isPresented: $isImporterPresented,
                      allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { importLocal(urls) }
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

    // MARK: 分段

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Section.allCases, id: \.rawValue) { item in
                    TagChip(text: item.title, isSelected: section == item) {
                        section = item
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var content: some View {
        if section == .playlists {
            playlistsView
        } else if songs.isEmpty {
            emptyState
        } else {
            songList
        }
    }

    private var songList: some View {
        List {
            ForEach(songs) { song in
                SongRow(song: song,
                        isCurrent: store.current?.id == song.id,
                        isPlaying: store.isPlaying,
                        trailing: trailing(for: song))
                    .songMenu(song)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Color.white.opacity(0.06))
                    .onTapGesture { play(song) }
            }
            .onDelete(perform: delete)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
                               message: "在歌曲上右键就能收藏")
            case .downloads:
                EmptyStateView(icon: "arrow.down.circle",
                               title: "还没有下载",
                               message: "在歌曲菜单里选「下载」，之后离线也能听")
            case .local:
                EmptyStateView(icon: "iphone",
                               title: "还没有本地音乐",
                               message: "从「文件」里导入音频")
            case .history:
                EmptyStateView(icon: "clock", title: "还没有播放记录")
            case .playlists:
                EmptyStateView(icon: "music.note.list", title: "还没有歌单")
            }
        }
        .overlay(alignment: .bottom) {
            actionButton
                .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch section {
        case .local:
            Button {
                isImporterPresented = true
            } label: {
                Label("导入本地音频", systemImage: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(AppStyle.accent)
        case .playlists:
            Button {
                newPlaylistName = ""
                isCreatingPlaylist = true
            } label: {
                Label("新建歌单", systemImage: "plus")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(AppStyle.accent)
        case .history:
            Button("清空记录") { library.clearHistory() }
                .font(.system(size: 14, weight: .medium))
                .buttonStyle(.bordered)
                .tint(AppStyle.accent)
        default:
            EmptyView()
        }
    }

    // MARK: 歌单

    private var playlistsView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if library.playlists.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "还没有歌单")
                } else {
                    ForEach(library.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: Playlist(id: playlist.id,
                                                                  name: playlist.name,
                                                                  coverURL: nil,
                                                                  trackCount: playlist.count),
                                              localPlaylist: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(AppStyle.surfaceHigh)
                                    Image(systemName: "music.note")
                                        .foregroundStyle(AppStyle.secondaryText)
                                }
                                .frame(width: 46, height: 46)
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
            .padding(.bottom, 90)
        }
        .overlay(alignment: .bottom) {
            actionButton.padding(.bottom, 40)
        }
    }

    // MARK: 行为

    private func play(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(songs, startAt: index)
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
        case .history:
            library.removeHistory(ids: targets.map(\.id))
        case .playlists:
            break
        }
    }

    /// 导入本地音频：复制到 Documents，保证沙盒重启后仍可播放。
    private func importLocal(_ urls: [URL]) {
        Task {
            var imported: [Song] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }

                let needsCopy = !url.path.hasPrefix(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path)
                let target: URL
                if needsCopy {
                    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Aurora Imports", isDirectory: true)
                    if !FileManager.default.fileExists(atPath: folder.path) {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    }
                    target = folder.appendingPathComponent(url.lastPathComponent)
                    if FileManager.default.fileExists(atPath: target.path) {
                        try? FileManager.default.removeItem(at: target)
                    }
                    guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { continue }
                } else {
                    target = url
                }

                let asset = AVURLAsset(url: target)
                let duration = (try? await asset.load(.duration)).map { $0.seconds } ?? 0
                imported.append(Song(id: Song.localID(for: target.path),
                                     title: target.deletingPathExtension().lastPathComponent,
                                     artist: "本地音频",
                                     url: target,
                                     tags: ["本地"],
                                     isLocal: true,
                                     duration: duration.isFinite ? duration : 0,
                                     source: .local))
            }
            await MainActor.run { library.addLocal(imported) }
        }
    }
}
