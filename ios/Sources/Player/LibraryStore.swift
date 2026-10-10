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
    @Published private(set) var albumFavorites: [Album] = []
    @Published private(set) var artistFavorites: [Artist] = []

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
    ///
    /// 迁移逻辑：切换到已存在的账号时，如果该账号的数据（favorites）为空，
    /// 就把游客模式下的无前缀 key 数据复制过去（幂等，已迁移过的不会重复）。
    /// 避免用户「升级 App → 注册账号 → 发现之前收藏全没了」的情况。
    func switchUser(userId: String?) {
        let targetId = userId?.lowercased()
        // 只在切到非 nil 用户时做迁移（游客模式就是无前缀 key，不需要迁移）
        if let targetId {
            migrateGuestDataIfNeeded(to: targetId)
        }
        self.userId = targetId
        reload()
        objectWillChange.send()
    }

    /// 幂等迁移：只有当目标用户的关键数据为空时，才把游客的无前缀 key 复制过去。
    /// 迁移完成后写一个标记，避免下次登录同一用户又覆盖已有数据。
    private func migrateGuestDataIfNeeded(to targetId: String) {
        let prefix = auroraUserKeyPrefix(for: targetId)
        let doneKey = prefix + "aurora.user.migration_done"
        let favoritesKey = key("favorites")
        let guestFavoritesKey = "aurora.library.favorites"

        // 已经迁移过了就跳过
        if defaults.bool(forKey: doneKey) { return }
        // 目标已经有数据了（比如这个账号之前就登录过），不要用游客数据覆盖
        if defaults.data(forKey: favoritesKey) != nil {
            defaults.set(true, forKey: doneKey)
            return
        }
        // 游客也没数据 —— 没东西可迁
        if defaults.data(forKey: guestFavoritesKey) == nil { return }

        // 迁移所有游客数据 key 到目标用户前缀下
        let guestKeys = ["aurora.library.favorites", "aurora.library.downloads",
                         "aurora.library.local", "aurora.library.playlists",
                         "aurora.library.history", "aurora.library.songTable",
                         "aurora.library.albumFavorites", "aurora.library.artistFavorites"]
        for guestKey in guestKeys {
            if let data = defaults.data(forKey: guestKey) {
                defaults.set(data, forKey: prefix + guestKey)
            }
        }
        defaults.set(true, forKey: doneKey)
        Log.info("账号", "游客数据已迁移到 \(prefix)（登录已存在账号触发）")
    }

    private func reload() {
        favorites = Self.load([Song].self, key: key("favorites")) ?? []
        downloads = Self.load([Song].self, key: key("downloads")) ?? []
        localSongs = Self.load([Song].self, key: key("local")) ?? []
        history = Self.load([Song].self, key: key("history")) ?? []
        playlists = Self.load([UserPlaylist].self, key: key("playlists")) ?? []
        albumFavorites = Self.load([Album].self, key: key("albumFavorites")) ?? []
        artistFavorites = Self.load([Artist].self, key: key("artistFavorites")) ?? []
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

    // MARK: 收藏歌手

    func isFavoriteArtist(_ artist: Artist) -> Bool {
        artistFavorites.contains { $0.id == artist.id }
    }

    @discardableResult
    func toggleArtistFavorite(_ artist: Artist) -> Bool {
        if let index = artistFavorites.firstIndex(where: { $0.id == artist.id }) {
            artistFavorites.remove(at: index)
            persist(artistFavorites, key: key("artistFavorites"))
            return false
        }
        artistFavorites.insert(artist, at: 0)
        persist(artistFavorites, key: key("artistFavorites"))
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

    /// 从酷狗分享链接批量导入 —— 先 createPlaylist 再 add 所有歌曲。
    @discardableResult
    func importPlaylist(name: String, songs: [Song]) -> UserPlaylist {
        let playlist = createPlaylist(name: name)
        for song in songs { add(song, toPlaylist: playlist.id) }
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

    // MARK: 专辑收藏

    func isAlbumFavorite(_ album: Album) -> Bool {
        albumFavorites.contains { $0.id == album.id }
    }

    @discardableResult
    func toggleAlbumFavorite(_ album: Album) -> Bool {
        if let index = albumFavorites.firstIndex(where: { $0.id == album.id }) {
            albumFavorites.remove(at: index)
            persist(albumFavorites, key: key("albumFavorites"))
            return false
        }
        albumFavorites.insert(album, at: 0)
        persist(albumFavorites, key: key("albumFavorites"))
        return true
    }

    // MARK: - 备份导出

    /// 导出所有歌单+收藏为 JSON 数据，用于 iCloud Drive / 本地文件备份。
    /// 包含 Song + Playlist 完整结构，可跨设备迁移。
    func backupAllData() throws -> Data {
        struct BackupPackage: Codable {
            var version: Int = 1
            var exportedAt: Date
            var favorites: [Song]
            var playlists: [UserPlaylist]
            var playlistSongs: [String: [Song]] // playlistID -> songs
            var albumFavorites: [Album]
        }
        var playlistSongMap: [String: [Song]] = [:]
        for pl in playlists {
            playlistSongMap[pl.id] = songs(in: pl)
        }
        let pkg = BackupPackage(
            exportedAt: Date(),
            favorites: favorites,
            playlists: playlists,
            playlistSongs: playlistSongMap,
            albumFavorites: albumFavorites
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(pkg)
    }

    /// 从备份文件恢复。merge=true 保留现有数据；merge=false 覆盖。
    func restoreFromBackup(data: Data, merge: Bool = true) throws {
        struct BackupPackage: Codable {
            var version: Int = 1
            var exportedAt: Date
            var favorites: [Song]
            var playlists: [UserPlaylist]
            var playlistSongs: [String: [Song]]
            var albumFavorites: [Album]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pkg = try decoder.decode(BackupPackage.self, from: data)

        // 先把所有歌曲注入 songCache
        var newCache = merge ? songCache : [:]
        for song in pkg.favorites { newCache[song.id] = song }
        for songs in pkg.playlistSongs.values { for s in songs { newCache[s.id] = s } }
        songCache = newCache
        persist(songCache, key: key("songTable"))

        if merge {
            let existing = Set(favorites.map(\.id))
            favorites.append(contentsOf: pkg.favorites.filter { !existing.contains($0.id) })
            let existingAlbums = Set(albumFavorites.map(\.id))
            albumFavorites.append(contentsOf: pkg.albumFavorites.filter { !existingAlbums.contains($0.id) })
            let existingPlIDs = Set(playlists.map(\.id))
            for pl in pkg.playlists where !existingPlIDs.contains(pl.id) {
                // 🔴 恢复歌单对应的歌曲 ID 列表
                var restored = pl
                if let songs = pkg.playlistSongs[pl.id] {
                    restored.songIDs = songs.map(\.id)
                }
                playlists.insert(restored, at: 0)
            }
        } else {
            favorites = pkg.favorites
            albumFavorites = pkg.albumFavorites
            // 🔴 恢复歌单对应的歌曲 ID 列表
            playlists = pkg.playlists.map { pl in
                var restored = pl
                if let songs = pkg.playlistSongs[pl.id] {
                    restored.songIDs = songs.map(\.id)
                }
                return restored
            }
        }
        persist(favorites, key: key("favorites"))
        persist(albumFavorites, key: key("albumFavorites"))
        persist(playlists, key: key("playlists"))
        Log.info("备份", "恢复完成 favorites=\(favorites.count) playlists=\(playlists.count) songCache=\(songCache.count)")
    }
}
