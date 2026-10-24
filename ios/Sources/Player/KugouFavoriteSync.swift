import Foundation

/// 🔴 v2.7.7：把「收藏」镜像到酷狗云歌单「默认收藏」。
///
/// 用户要求：收藏的歌自动保存到酷狗歌单「默认收藏」，收藏专辑时把专辑里的歌也存进去。
/// 全部 fire-and-forget：失败只记日志，绝不影响本地收藏操作。
final class KugouFavoriteSync {
    static let shared = KugouFavoriteSync()
    private init() {}

    /// 酷狗里「默认收藏」歌单的 listid 缓存（登录用户维度）。
    private var cachedListID: String?
    private var cachedForUser: String?

    // MARK: 入口

    /// 收藏了一首歌（本地收藏成功后调用）。
    func songFavorited(_ song: Song) {
        guard KugouAuth.shared.isLoggedIn else { return }
        Task { [weak self] in
            await self?.add([song])
        }
    }

    /// 收藏了一张专辑：搜出专辑里的歌，一并存进「默认收藏」。
    func albumFavorited(_ album: Album) {
        guard KugouAuth.shared.isLoggedIn else { return }
        Task { [weak self] in
            guard let self else { return }
            let songs = await Self.albumSongs(album)
            guard !songs.isEmpty else {
                Log.info("酷狗", "专辑《\(album.name)》没搜到歌曲，跳过同步到默认收藏")
                return
            }
            await self.add(songs)
        }
    }

    // MARK: 核心

    private func add(_ songs: [Song]) async {
        do {
            let listid = try await defaultFavoriteListID()
            guard !listid.isEmpty else { return }
            var ok = 0
            for song in songs where !song.kugouHash.isEmpty {
                do {
                    try await KugouClient.shared.addSongToPlaylist(listid, song: song)
                    ok += 1
                } catch {
                    // 已在歌单里 / VIP 限制等单首失败不打断后面的
                    Log.error("酷狗", "同步收藏《\(song.cleanTitle)》失败：\(error.localizedDescription)")
                }
            }
            if ok > 0 {
                Log.info("酷狗", "已把 \(ok)/\(songs.count) 首收藏同步到酷狗「默认收藏」")
            }
        } catch {
            Log.error("酷狗", "同步收藏失败：\(error.localizedDescription)")
        }
    }

    /// 找到「默认收藏」歌单：酷狗账号默认第一个就是收藏歌单；
    /// 名字精确等于「默认收藏」的优先；都没有就新建一个。
    private func defaultFavoriteListID() async throws -> String {
        let auth = KugouAuth.shared
        if let cached = cachedListID, cachedForUser == auth.userId, !cached.isEmpty {
            return cached
        }
        let lists = try await KugouClient.shared.userPlaylists()
        let hit = lists.first(where: { $0.name == "默认收藏" }) ?? lists.first
        if let hit {
            cachedListID = hit.id
            cachedForUser = auth.userId
            return hit.id
        }
        // 账号里一个歌单都没有：建一个「默认收藏」
        let newID = try await KugouClient.shared.createPlaylist(name: "默认收藏")
        cachedListID = newID
        cachedForUser = auth.userId
        return newID
    }

    // MARK: 专辑歌曲搜索（照搬 AlbumDetailView.load 的策略）

    private static func albumSongs(_ album: Album) async -> [Song] {
        let leadArtist = album.artist
            .components(separatedBy: CharacterSet(charactersIn: "、/,"))
            .first?.trimmingCharacters(in: .whitespaces) ?? album.artist
        let keyword = "\(leadArtist) \(album.name)"
        async let p1 = try? KugouClient.shared.searchSongs(keyword: keyword, page: 1)
        async let p2 = try? KugouClient.shared.searchSongs(keyword: keyword, page: 2)
        var found: [Song] = []
        found.append(contentsOf: await p1 ?? [])
        found.append(contentsOf: await p2 ?? [])
        var seen = Set<String>()
        found = found.filter { seen.insert($0.id).inserted }
        if !album.albumID.isEmpty {
            return found.filter { $0.kugouAlbumID == album.albumID }
        }
        return found.filter { $0.album.trimmingCharacters(in: .whitespaces) == album.name }
    }
}
