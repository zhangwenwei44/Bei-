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
///
/// 多用户隔离：所有 UserDefaults key 按当前 userId 加前缀
/// `aurora.user.<userId>.`。未登录（userId=nil）时用无前缀的 key，
/// 这样老用户升级后数据不会丢（默认就是游客模式）。
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

    /// 当前用户的 key 前缀。nil = 游客（无前缀，兼容老数据）。
    private(set) var userId: String?

    struct UserPlaylist: Identifiable, Codable, Hashable {
        var id = UUID().uuidString
        var name: String
        var songIDs: [String] = []
        var createdAt: Date = Date()

        var count: Int { songIDs.count }
    }

    private init() {
        reload()
    }

    // MARK: - 多用户切换

    /// 切换到指定用户的命名空间。传 nil = 切回游客（无前缀 key）。
    func switchUser(userId: String?) {
        self.userId = userId?.lowercased()
        reload()
        objectWillChange.send()
    }

    private func reload() {
        favorites = Self.load([Song].self, key: key("favorites")) ?? []
        downloads = Self.load([Song].self, key: key("downloads")) ?? []
        localSongs = Self.load([Song].self, key: key("local")) ?? []
        history = Self.load([Song].self, key: key("history")) ?? []
        playlists = Self.load([UserPlaylist].self, key: key("playlists")) ?? []
        songCache = Self.load([String: Song].self, key: key("songTable")) ?? [:]
        indexAll()
    }

    /// 构造完整的 UserDefaults key：`aurora.user.<userId>.library.<suffix>` 或 `aurora.library.<suffix>`（游客）。
    private func key(_ suffix: String) -> String {
        let prefix = auroraUserKeyPrefix(for: userId)
        return prefix + "aurora.library." + suffix
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        // 之前 try? 静默丢弃：歌曲表写失败时，歌单里存的 ID 就永远还原不回歌曲，
        // 表现为「列表写着 N 首、详情页空的」。
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            Log.error("曲库", "写 \(key) 失败：\(error.localizedDescription)")
        }
    }

    /// 收藏 / 下载 / 本地 / 听过的歌都登记进歌曲表，保证歌单能还原曲目。
    private func indexAll() {
        remember(favorites + downloads + localSongs + history)
    }

    // MARK: 收藏

    func isFavorite(_ song: Song) -> Bool {
        favorites.contains { $0.id == song.id }
    }

    @discardableResult
    func toggleFavorite(_ song: Song) -> Bool {
        if let index = favorites.firstIndex(where: { $0.id == song.id }) {
            favorites.remove(at: index)
            persist(favorites, key: key("favorites"))
            return false
        }
        favorites.insert(song, at: 0)
        persist(favorites, key: key("favorites"))
        remember(song)
        return true
    }

    // MARK: 下载

    func registerDownload(_ song: Song) {
        guard !downloads.contains(where: { $0.id == song.id }) else { return }
        downloads.insert(song, at: 0)
        persist(downloads, key: key("downloads"))
        remember(song)
    }

    /// DownloadManager 启动时同步磁盘上的真实下载列表。
    func setDownloads(_ songs: [Song]) {
        downloads = songs
        persist(downloads, key: key("downloads"))
        songs.forEach { remember($0) }
    }

    func removeDownload(_ song: Song) {
        downloads.removeAll { $0.id == song.id }
        persist(downloads, key: key("downloads"))
    }

    // MARK: 本地导入

    func addLocal(_ songs: [Song]) {
        let existing = Set(localSongs.map(\.id))
        let fresh = songs.filter { !existing.contains($0.id) }
        localSongs = fresh + localSongs
        persist(localSongs, key: key("local"))
        fresh.forEach { remember($0) }
    }

    func removeLocal(id: String) {
        localSongs.removeAll { $0.id == id }
        persist(localSongs, key: key("local"))
    }

    // MARK: 歌单

    func createPlaylist(name: String) -> UserPlaylist {
        let playlist = UserPlaylist(name: name)
        playlists.insert(playlist, at: 0)
        persist(playlists, key: key("playlists"))
        return playlist
    }

    func deletePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
        persist(playlists, key: key("playlists"))
    }

    func renamePlaylist(id: String, name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        persist(playlists, key: key("playlists"))
    }

    func add(_ song: Song, toPlaylist id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard !playlists[index].songIDs.contains(song.id) else { return }
        playlists[index].songIDs.append(song.id)
        persist(playlists, key: key("playlists"))
        remember(song)
    }

    func remove(_ song: Song, fromPlaylist id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].songIDs.removeAll { $0 == song.id }
        persist(playlists, key: key("playlists"))
    }

    /// 歌单里存的是歌曲 ID，这里用歌曲表把它还原成完整对象。
    ///
    /// 歌曲表和歌单是两个独立的 UserDefaults key，任一侧写失败就会出现
    /// 「列表写着 N 首、详情页却是空的」。这里对解析不出来的 ID 做一次自愈：
    /// 先查收藏/下载/本地/历史，实在找不到再从线上按 kugouHash 补回来。
    func songs(in playlist: UserPlaylist) -> [Song] {
        if playlist.songIDs.contains(where: { songCache[$0] == nil }) {
            recoverMissingSongs(for: playlist.songIDs)
        }
        return playlist.songIDs.compactMap { songCache[$0] }
    }

    /// 用历史 / 收藏 / 本地 / 下载里还在的歌曲补回丢失的条目。
    private func recoverMissingSongs(for ids: [String]) {
        let pools = [history, favorites, localSongs, downloads]
        var recovered = 0
        for id in ids where songCache[id] == nil {
            for pool in pools {
                if let song = pool.first(where: { $0.id == id }) {
                    songCache[id] = song
                    recovered += 1
                    break
                }
            }
        }
        if recovered > 0 { persist(songCache, key: key("songTable")) }
    }

    /// 内存里缓存一份歌曲表，避免每次都全量解码 UserDefaults。
    private func remember(_ song: Song) {
        remember([song])
    }

    private func remember(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        for song in songs { songCache[song.id] = song }
        persist(songCache, key: key("songTable"))
    }

    // MARK: 历史

    func recordHistory(_ song: Song) {
        history.removeAll { $0.id == song.id }
        history.insert(song, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        persist(history, key: key("history"))
        remember(song)
    }

    func clearHistory() {
        history = []
        persist(history, key: key("history"))
    }

    func removeHistory(ids: [String]) {
        history.removeAll { ids.contains($0.id) }
        persist(history, key: key("history"))
    }
}
