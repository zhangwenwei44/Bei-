import SwiftUI

/// 鏀惰棌鐨勫湪绾挎瓕鍗曪紙鍙 ID锛屽鐢ㄥ嵆鍙級銆?enum CollectionState {
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

/// 閫氱敤姝屾洸鍒楄〃椤碉細鐢ㄤ簬銆屽叏閮?XX銆嶅拰鏈湴姝屽崟銆?struct SongListView: View {
    let title: String
    let songs: [Song]
    var subtitle: String?

    @EnvironmentObject private var store: PlayerStore

    var body: some View {
        VStack(spacing: 0) {
            if songs.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "杩欓噷杩樻病鏈夋瓕鏇?)
            } else {
                List {
                    Section {
                        ForEach(songs) { song in
                            SongRow(song: song,
                                    isCurrent: store.current?.id == song.id,
                                    isPlaying: store.isPlaying)
                                .songMenu(song)
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(Color.white.opacity(0.06))
                                .onTapGesture { play(song) }
                        }
                    } header: {
                        Text(subtitle ?? "\(songs.count) 棣?)
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

/// 姝屽崟璇︽儏锛氬湪绾挎瓕鍗曞姞杞芥洸鐩紝鏈湴姝屽崟鐩存帴灞曠ず銆?struct PlaylistDetailView: View {
    let playlist: Playlist
    var localPlaylist: LibraryStore.UserPlaylist?

    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isCollected = false
    @State private var didLoadCollection = false

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
                    EmptyStateView(icon: "exclamationmark.triangle", title: "鍔犺浇澶辫触", message: errorMessage)
                } else if displaySongs.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "姝屽崟閲岃繕娌℃湁姝屾洸")
                } else {
                    actionBar
                    VStack(spacing: 0) {
                        ForEach(displaySongs) { song in
                            SongRow(song: song,
                                    isCurrent: store.current?.id == song.id,
                                    isPlaying: store.isPlaying)
                                .songMenu(song)
                                .padding(.horizontal, 16)
                                .onTapGesture { play(song) }
                                .contextMenu {
                                    if let localPlaylist {
                                        Button(role: .destructive) {
                                            library.remove(song, fromPlaylist: localPlaylist.id)
                                        } label: {
                                            Label("浠庢瓕鍗曠Щ闄?, systemImage: "minus.circle")
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
        .toolbar {
            if localPlaylist == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCollected.toggle()
                        CollectionState.set(isCollected, for: playlist.id)
                        Haptics.light()
                    } label: {
                        Image(systemName: isCollected ? "heart.fill" : "heart")
                            .foregroundStyle(isCollected ? AppStyle.like : AppStyle.primaryText)
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
                    if playlist.trackCount > 0 { Text("\(playlist.trackCount) 棣?) }
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
        HStack(spacing: 22) {
            Button {
                store.play(displaySongs)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(AppStyle.accent, in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                store.append(displaySongs)
                Haptics.soft()
            } label: {
                Label("鍔犲叆鎾斁鍒楄〃", systemImage: "text.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.primaryText)
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
                        .font(.system(size: 17))
                        .foregroundStyle(AppStyle.primaryText)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private func play(_ song: Song) {
        guard let index = displaySongs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(displaySongs, startAt: index)
        Haptics.soft()
    }

    private func load() async {
        if localPlaylist != nil { return }
        guard let neteaseID = playlist.neteaseID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            songs = try await NetEaseClient.shared.playlistTracks(id: neteaseID)
            // 歌单没封面时用第一首歌的专辑图顶上
            CoverResolver.shared.bind(from: songs, to: [playlist.id])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 姝屾墜椤点€?struct ArtistView: View {
    let artist: Artist

    @EnvironmentObject private var store: PlayerStore
    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    CoverImage(url: artist.coverURL, fallbackKeys: [artist.id], seed: artist.name, size: 96, corner: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(artist.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(AppStyle.primaryText)
                        Text("鐑棬姝屾洸")
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.secondaryText)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if isLoading, songs.isEmpty {
                    LoadingRow()
                } else if let errorMessage, songs.isEmpty {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "鍔犺浇澶辫触", message: errorMessage)
                } else {
                    VStack(spacing: 0) {
                        ForEach(songs) { song in
                            SongRow(song: song,
                                    isCurrent: store.current?.id == song.id,
                                    isPlaying: store.isPlaying)
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
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func play(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(songs, startAt: index)
        Haptics.soft()
    }

    private func load() async {
        guard let neteaseID = artist.neteaseID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            songs = try await NetEaseClient.shared.artistHotSongs(id: neteaseID, limit: 60)
            // 歌手页的图也用来补上歌单 / 专辑的封面
            CoverResolver.shared.bindArtist(artist.id, from: songs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 涓撹緫椤点€?struct AlbumView: View {
    let album: Album

    @EnvironmentObject private var store: PlayerStore
    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    CoverImage(url: album.coverURL, fallbackKeys: [album.id], seed: album.name, size: 96, corner: 10)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(AppStyle.primaryText)
                        Text(album.artistName)
                            .font(.system(size: 13))
                            .foregroundStyle(AppStyle.secondaryText)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if isLoading, songs.isEmpty {
                    LoadingRow()
                } else if let errorMessage, songs.isEmpty {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "鍔犺浇澶辫触", message: errorMessage)
                } else {
                    VStack(spacing: 0) {
                        ForEach(songs) { song in
                            SongRow(song: song,
                                    isCurrent: store.current?.id == song.id,
                                    isPlaying: store.isPlaying)
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
        .task { await load() }
    }

    private func play(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(songs, startAt: index)
        Haptics.soft()
    }

    private func load() async {
        guard let neteaseID = album.neteaseID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            songs = try await NetEaseClient.shared.albumSongs(id: neteaseID)
            CoverResolver.shared.bind(from: songs, to: [album.id])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
