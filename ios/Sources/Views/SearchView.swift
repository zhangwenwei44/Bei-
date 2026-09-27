import SwiftUI

/// 鎼滅储椤碉細鍗曟洸 / 姝屽崟 / 姝屾墜 / 涓撹緫銆?struct SearchView: View {
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
        case songs, playlists, artists, albums

        var title: String {
            switch self {
            case .songs: return "鍗曟洸"
            case .playlists: return "姝屽崟"
            case .artists: return "姝屾墜"
            case .albums: return "涓撹緫"
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
                    EmptyStateView(icon: "magnifyingglass", title: "娌℃悳鍒?, message: errorMessage)
                } else {
                    resultList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppStyle.background)
        .navigationTitle("鎼滅储")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !submitted.isEmpty {
                    Button("娓呯┖") {
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

    // MARK: 鎼滅储妗?
    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(AppStyle.secondaryText)
                TextField("姝屾洸銆佹瓕鎵嬨€佹瓕鍗?, text: $keyword)
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
                Button("鍙栨秷") {
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

    // MARK: 缁撴灉

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
                case .artists:
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(results.artists) { artist in
                                NavigationLink {
                                    ArtistView(artist: artist)
                                } label: {
                                    SimpleCard(title: artist.name,
                                               subtitle: artist.albumCount.map { "\($0) 张专辑" },
                                               url: artist.coverURL,
                                               fallbackKeys: [artist.id])
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                case .albums:
                    VStack(spacing: 0) {
                        ForEach(results.albums) { album in
                            NavigationLink {
                                AlbumView(album: album)
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(url: album.coverURL, fallbackKeys: [album.id], seed: album.name, size: 52, corner: 6)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(album.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(AppStyle.primaryText)
                                            .lineLimit(1)
                                        Text(album.artistName)
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppStyle.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
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

    // MARK: 鎼滅储鍘嗗彶

    private var historyView: some View {
        Group {
            if history.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "鎼滅偣浠€涔堝惂",
                               message: "鏀寔姝屽悕銆佹瓕鎵嬨€佹瓕鍗曞拰涓撹緫")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("鏈€杩戞悳绱?)
                            .font(.system(size: 13))
                            .foregroundStyle(AppStyle.secondaryText)
                        Spacer()
                        Button("娓呯┖") {
                            history = []
                            Self.saveHistory(history)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)

                    ForEach(history, id: \.self) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "clock")
                                .font(.system(size: 13))
                                .foregroundStyle(AppStyle.tertiaryText)
                            Text(item)
                                .font(.system(size: 14))
                                .foregroundStyle(AppStyle.primaryText)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .onTapGesture { runSearch(item) }
                    }
                }
            }
        }
    }

    // MARK: 琛屼负

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

        let client = NetEaseClient.shared
        async let songs = try? client.searchSongs(keyword: text)
        async let playlists = try? client.searchPlaylists(keyword: text)
        async let artists = try? client.searchArtists(keyword: text)
        async let albums = try? client.searchAlbums(keyword: text)

        let newResults = SearchResults(songs: await songs ?? [],
                                       playlists: await playlists ?? [],
                                       artists: await artists ?? [],
                                       albums: await albums ?? [])
        guard submitted == text else { return }
        results = newResults
        if newResults.isEmpty {
            errorMessage = "鎹釜鍏抽敭璇嶈瘯璇?
        }
    }

    private static let historyKey = "aurora.search.history"

    private static func loadHistory() -> [String] {
        UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    private static func saveHistory(_ value: [String]) {
        UserDefaults.standard.set(value, forKey: historyKey)
    }
}
