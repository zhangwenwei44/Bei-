import Combine
import Foundation

enum DownloadState: Equatable {
    case waiting
    case downloading
    case done
    case failed(String)

    var isActive: Bool { self == .waiting || self == .downloading }
}

/// 曲库（收藏 / 下载 / 本地 / 歌单 / 历史）的持久化存储。
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var favorites: [Song] = []
    @Published private(set) var downloads: [Song] = []
    @Published private(set) var localSongs: [Song] = []
    @Published private(set) var playlists: [UserPlaylist] = []
    @Published private(set) var history: [Song] = []

    private let defaults = UserDefaults.standard
    /// 「歌曲 ID → 歌曲」索引，歌单靠它还原曲目。
    private var songCache: [String: Song] = [:]
    private enum Key {
        static let favorites = "aurora.library.favorites"
        static let local = "aurora.library.local"
        static let downloads = "aurora.library.downloads"
        static let playlists = "aurora.library.playlists"
        static let history = "aurora.library.history"
        static let songTable = "aurora.library.songTable"
    }

    struct UserPlaylist: Identifiable, Codable, Hashable {
        var id = UUID().uuidString
        var name: String
        var songIDs: [String] = []
        var createdAt: Date = Date()

        var count: Int { songIDs.count }
    }

    private init() {
        favorites = Self.load([Song].self, key: Key.favorites) ?? []
        localSongs = Self.load([Song].self, key: Key.local) ?? []
        history = Self.load([Song].self, key: Key.history) ?? []
        playlists = Self.load([UserPlaylist].self, key: Key.playlists) ?? []
        songCache = Self.load([String: Song].self, key: Key.songTable) ?? [:]
        indexAll()
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    /// 收藏 / 本地 / 听过的歌都登记进歌曲表，保证歌单能还原曲目。
    private func indexAll() {
        remember(favorites + localSongs + history)
    }

    // MARK: 收藏

    func isFavorite(_ song: Song) -> Bool {
        favorites.contains { $0.id == song.id }
    }

    @discardableResult
    func toggleFavorite(_ song: Song) -> Bool {
        if let index = favorites.firstIndex(where: { $0.id == song.id }) {
            favorites.remove(at: index)
            persist(favorites, key: Key.favorites)
            return false
        }
        favorites.insert(song, at: 0)
        persist(favorites, key: Key.favorites)
        remember(song)
        return true
    }

    // MARK: 下载

    func registerDownload(_ song: Song) {
        guard !downloads.contains(where: { $0.id == song.id }) else { return }
        downloads.insert(song, at: 0)
        persist(downloads, key: Key.downloads)
        remember(song)
    }

    /// DownloadManager 启动时同步磁盘上的真实下载列表。
    func setDownloads(_ songs: [Song]) {
        downloads = songs
        persist(downloads, key: Key.downloads)
        songs.forEach { remember($0) }
    }

    func removeDownload(_ song: Song) {
        downloads.removeAll { $0.id == song.id }
        persist(downloads, key: Key.downloads)
    }

    // MARK: 本地导入

    func addLocal(_ songs: [Song]) {
        let existing = Set(localSongs.map(\.id))
        let fresh = songs.filter { !existing.contains($0.id) }
        localSongs = fresh + localSongs
        persist(localSongs, key: Key.local)
        fresh.forEach { remember($0) }
    }

    func removeLocal(id: String) {
        localSongs.removeAll { $0.id == id }
        persist(localSongs, key: Key.local)
    }

    // MARK: 歌单

    func createPlaylist(name: String) -> UserPlaylist {
        let playlist = UserPlaylist(name: name)
        playlists.insert(playlist, at: 0)
        persist(playlists, key: Key.playlists)
        return playlist
    }

    func deletePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
        persist(playlists, key: Key.playlists)
    }

    func renamePlaylist(id: String, name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        persist(playlists, key: Key.playlists)
    }

    func add(_ song: Song, toPlaylist id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard !playlists[index].songIDs.contains(song.id) else { return }
        playlists[index].songIDs.append(song.id)
        persist(playlists, key: Key.playlists)
        remember(song)
    }

    func remove(_ song: Song, fromPlaylist id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].songIDs.removeAll { $0 == song.id }
        persist(playlists, key: Key.playlists)
    }

    /// 歌单里存的是歌曲 ID，这里用歌曲表把它还原成完整对象。
    func songs(in playlist: UserPlaylist) -> [Song] {
        playlist.songIDs.compactMap { songCache[$0] }
    }

    /// 内存里缓存一份歌曲表，避免每次都全量解码 UserDefaults。
    private func remember(_ song: Song) {
        remember([song])
    }

    private func remember(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        for song in songs { songCache[song.id] = song }
        persist(songCache, key: Key.songTable)
    }

    // MARK: 历史

    func recordHistory(_ song: Song) {
        history.removeAll { $0.id == song.id }
        history.insert(song, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        persist(history, key: Key.history)
        remember(song)
    }

    func clearHistory() {
        history = []
        persist(history, key: Key.history)
    }

    func removeHistory(ids: [String]) {
        history.removeAll { ids.contains($0.id) }
        persist(history, key: Key.history)
    }
}
