import Foundation

/// 网易云音乐直连接口。搜索 / 榜单 / 歌单 / 歌词 / 播放地址都在这里。
///
/// 播放地址分两步：先问官方接口（`songURLs`），拿不到（VIP、无版权）时
/// 再交给 `SourceResolver` 用用户配置的第三方音源解析。
final class NetEaseClient {
    static let shared = NetEaseClient()

    private let domain = "https://music.163.com"
    private let apiDomain = "https://interface.music.163.com"
    private let session: URLSession

    // 模拟 PC 客户端环境
    private let os = "pc"
    private let appver = "3.1.17.204416"
    private let osver = "Microsoft-Windows-10-Professional-build-19045-64bit"
    private let channel = "netease"

    private let nuid = NetEaseClient.randomHex(length: 32)
    private let deviceId = NetEaseClient.randomHex(length: 26)
    private let wnMcid = "\(NetEaseClient.randomLowercase(6)).\(Int(Date().timeIntervalSince1970 * 1000)).01.0"

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    // MARK: - 请求

    private func request(_ uri: String, payload: [String: Any], crypto: String) async throws -> [String: Any] {
        let url: URL
        let enc: [String: String]
        var body = payload
        body["csrf_token"] = ""
        var cookie: String
        var userAgent: String
        var referer: String

        if crypto == "eapi" {
            guard let parsed = URL(string: apiDomain + "/eapi" + uri.dropFirst(4)) else {
                throw NetEaseError.unknown("请求地址无效")
            }
            url = parsed
            let header = eapiHeader()
            body["e_r"] = false
            body["header"] = header
            enc = NetEaseCrypto.eapi(body, path: uri)
            cookie = eapiCookieHeader(header: header)
            userAgent = "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"
            referer = apiDomain
        } else {
            guard let parsed = URL(string: domain + "/weapi" + uri.dropFirst(4)) else {
                throw NetEaseError.unknown("请求地址无效")
            }
            url = parsed
            enc = NetEaseCrypto.weapi(body)
            cookie = weapiCookieHeader()
            userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0"
            referer = domain
        }

        let form = enc
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
        guard !form.isEmpty else { throw NetEaseError.crypto }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.httpBody = Data(form.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetEaseError.network }
        guard http.statusCode == 200 else { throw NetEaseError.httpStatus(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetEaseError.decoding
        }
        return json
    }

    private func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private var timestamp: String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }

    private func weapiCookieHeader() -> String {
        var parts = [
            "__remember_me=true",
            "ntes_kaola_ad=1",
            "_ntes_nuid=\(nuid)",
            "_ntes_nnid=\(nuid),\(timestamp)",
            "WNMCID=\(wnMcid)",
            "WEVNSM=1.0.0",
            "osver=\(osver)",
            "deviceId=\(deviceId)",
            "os=\(os)",
            "channel=\(channel)",
            "appver=\(appver)",
            "NMTID=\(NetEaseClient.randomHex(length: 16))",
        ]
        return parts.joined(separator: "; ")
    }

    private func eapiHeader() -> [String: String] {
        [
            "osver": osver,
            "deviceId": deviceId,
            "os": os,
            "appver": appver,
            "versioncode": "140",
            "mobilename": "",
            "buildver": String(timestamp.prefix(10)),
            "resolution": "1920x1080",
            "__csrf": "",
            "channel": channel,
            "requestId": "\(timestamp)_\(String(format: "%04d", Int.random(in: 0...999)))",
        ]
    }

    private func eapiCookieHeader(header: [String: String]) -> String {
        header
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "; ")
    }

    private static func randomHex(length: Int) -> String {
        let chars = Array("0123456789abcdef")
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }

    private static func randomLowercase(_ count: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz")
        return String((0..<count).compactMap { _ in chars.randomElement() })
    }

    // MARK: - 搜索

    private func searchRaw(keyword: String, type: Int, limit: Int, offset: Int = 0) async throws -> [String: Any] {
        let json = try await request("/api/cloudsearch/pc",
                                     payload: ["s": keyword, "type": type, "limit": limit,
                                               "offset": offset, "total": true],
                                     crypto: "weapi")
        return json["result"] as? [String: Any] ?? [:]
    }

    func searchSongs(keyword: String, limit: Int = 40) async throws -> [Song] {
        let result = try await searchRaw(keyword: keyword, type: 1, limit: limit)
        return (result["songs"] as? [[String: Any]] ?? []).compactMap(Song.init(neteaseJSON:))
    }

    func searchPlaylists(keyword: String, limit: Int = 20) async throws -> [Playlist] {
        let result = try await searchRaw(keyword: keyword, type: 1000, limit: limit)
        return (result["playlists"] as? [[String: Any]] ?? []).compactMap(Playlist.init(neteaseJSON:))
    }

    func searchArtists(keyword: String, limit: Int = 20) async throws -> [Artist] {
        let result = try await searchRaw(keyword: keyword, type: 100, limit: limit)
        return (result["artists"] as? [[String: Any]] ?? []).compactMap(Artist.init(neteaseJSON:))
    }

    func searchAlbums(keyword: String, limit: Int = 20) async throws -> [Album] {
        let result = try await searchRaw(keyword: keyword, type: 10, limit: limit)
        return (result["albums"] as? [[String: Any]] ?? []).compactMap(Album.init(neteaseJSON:))
    }

    // MARK: - 歌单 / 榜单

    func playlistTracks(id: Int, limit: Int = 500) async throws -> [Song] {
        let json = try await request("/api/v6/playlist/detail",
                                     payload: ["id": id, "n": limit, "s": 8],
                                     crypto: "eapi")
        let playlist = json["playlist"] as? [String: Any] ?? [:]
        return (playlist["tracks"] as? [[String: Any]] ?? []).compactMap(Song.init(neteaseJSON:))
    }

    func topLists() async throws -> [Playlist] {
        let json = try await request("/api/toplist/detail", payload: [:], crypto: "weapi")
        let list = json["list"] as? [[String: Any]] ?? []
        return Array(list.prefix(12)).compactMap(Playlist.init(neteaseJSON:))
    }

    func recommendedPlaylists(limit: Int = 12) async throws -> [Playlist] {
        let json = try await request("/api/personalized/playlist",
                                     payload: ["limit": limit, "n": limit],
                                     crypto: "weapi")
        return (json["result"] as? [[String: Any]] ?? []).compactMap(Playlist.init(neteaseJSON:))
    }

    // MARK: - 歌手 / 专辑

    func artistHotSongs(id: Int, limit: Int = 60) async throws -> [Song] {
        var songs: [Song] = []
        var seen = Set<String>()
        var offset = 0
        let pageSize = 30

        while songs.count < limit {
            let json = try await request("/api/artist/songs",
                                         payload: ["id": id, "order": "hot", "offset": offset, "limit": pageSize],
                                         crypto: "weapi")
            let list = json["songs"] as? [[String: Any]] ?? []
            guard !list.isEmpty else { break }
            var added = 0
            for item in list {
                guard let song = Song(neteaseJSON: item), seen.insert(song.id).inserted else { continue }
                songs.append(song)
                added += 1
                if songs.count >= limit { break }
            }
            guard added > 0 else { break }
            offset += list.count
            if list.count < pageSize { break }
        }
        return songs
    }

    func albumSongs(id: Int) async throws -> [Song] {
        let json = try await request("/api/album", payload: ["id": id], crypto: "weapi")
        return (json["songs"] as? [[String: Any]] ?? []).compactMap(Song.init(neteaseJSON:))
    }

    // MARK: - 封面

    /// 批量补封面。搜索、歌单返回的歌曲不一定带 `al.picUrl`，
    /// 这时用 song/detail 一次性把缺的补齐，避免列表里一堆灰块。
    func missingCovers(for songs: [Song]) async -> [Int: URL] {
        let missing = songs
            .filter { $0.artworkURL == nil }
            .compactMap { $0.neteaseID }
        guard !missing.isEmpty else { return [:] }

        // 去重 + 分批，song/detail 一次别塞太多
        let ids = Array(Set(missing)).prefix(200)
        let json = try? await request("/api/v3/song/detail",
                                     payload: ["c": "[" + ids.map(String.init).joined(separator: ",") + "]"],
                                     crypto: "weapi")
        let list = json?["songs"] as? [[String: Any]] ?? []
        var result: [Int: URL] = [:]
        for item in list {
            guard let id = NetEaseClient.intValue(item["id"]),
                  let pic = (item["al"] as? [String: Any])?["picUrl"] as? String,
                  !pic.isEmpty,
                  let url = URL(string: pic) else { continue }
            result[id] = url
        }
        return result
    }

    // MARK: - 歌词

    /// 原文 + 翻译。
    func lyric(id: Int) async throws -> (lrc: String, tlyric: String?) {
        let json = try await request("/api/song/lyric",
                                     payload: ["id": id, "lv": -1, "kv": -1, "tv": -1],
                                     crypto: "weapi")
        let lrc = (json["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        let tlyric = (json["tlyric"] as? [String: Any])?["lyric"] as? String
        return (lrc, (tlyric?.isEmpty ?? true) ? nil : tlyric)
    }

    // MARK: - 播放地址

    struct SongURLInfo {
        var url: String?
        /// 只有试听片段（VIP 未解锁）
        var freeTrial: Bool
    }

    func songURLs(ids: [Int], level: MusicQuality) async throws -> [Int: SongURLInfo] {
        guard !ids.isEmpty else { return [:] }
        let idsString = "[" + ids.map(String.init).joined(separator: ",") + "]"
        let json = try await request("/api/song/enhance/player/url/v1",
                                     payload: ["ids": idsString, "level": level.level, "encodeType": "flac"],
                                     crypto: "eapi")
        let data = json["data"] as? [[String: Any]] ?? []
        var result: [Int: SongURLInfo] = [:]
        for item in data {
            guard let id = NetEaseClient.intValue(item["id"]), id > 0 else { continue }
            let raw = item["url"] as? String
            let url = (raw?.isEmpty ?? true) ? nil : raw
            result[id] = SongURLInfo(
                url: url,
                freeTrial: (item["freeTrialInfo"] as? [String: Any]) != nil
            )
        }
        return result
    }

    // MARK: - 发现

    func hotSearch() async throws -> [String] {
        let json = try await request("/api/search/hot", payload: ["type": 1111], crypto: "weapi")
        let hots = (json["result"] as? [String: Any])?["hots"] as? [[String: Any]] ?? []
        return Array(hots.compactMap { $0["first"] as? String }.prefix(12))
    }

    func newSongs(limit: Int = 12) async throws -> [Song] {
        let json = try await request("/api/personalized/newsong",
                                     payload: ["type": 0, "limit": limit],
                                     crypto: "weapi")
        let list = json["result"] as? [[String: Any]] ?? []
        return list.compactMap { item -> Song? in
            if let songJSON = item["song"] as? [String: Any] {
                return Song(neteaseJSON: songJSON)
            }
            return Song(neteaseJSON: item)
        }
    }

    // MARK: - 工具

    static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }
}

enum NetEaseError: LocalizedError {
    case network
    case crypto
    case httpStatus(Int)
    case decoding
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .network: return "网络连接失败，请检查网络"
        case .crypto: return "请求加密失败"
        case .httpStatus(let code): return "服务器响应异常（\(code)）"
        case .decoding: return "数据解析失败"
        case .unknown(let message): return message
        }
    }
}
