import Foundation

/// 酷狗音乐直连接口。搜索 / 歌词 / 榜单 / 封面都走这里。
///
/// 播放地址的 `v5/url` 需要设备指纹（mid / dfid / clientver 组合），无设备态下
/// 官方会返回 `err clientver or mid or dfid or clienttime`，所以直连只作为
/// 「顺手一试」；真正的地址由第三方音源解析（洛雪脚本那套）兜住。
final class KugouClient {
    static let shared = KugouClient()

    // 签名常量（公开客户端参数）
    private let gateway = "https://gateway.kugou.com"
    private let appID = "1005"
    private let signSalt = "OIlwieks28dk2k092lksi2UIkp"
    private let clientVersion = "20489"
    private let songClientVersion = "11430"
    private let searchSalt = "y9tjae~n)k)vn[8"
    private let playKeySalt = "57ae12eb6890223e355ccfcb74edf70d"

    private let session: URLSession
    private let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private let searchUA = "IPhone-20549-Search#183534257/723988397/625045823/284854956-SearchGeneralInfoWithKeyWordV8"

    private let mid: String
    private let dfid: String

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)

        // 设备指纹：mid = MD5(guid) 前 15 位十六进制转十进制，和官方客户端一致
        let guid = UUID().uuidString
        let hex = Data(guid.utf8).md5Hex()
        let prefix = String(hex.prefix(15))
        mid = UInt64(prefix, radix: 16).map(String.init) ?? hex
        let dfidHex = String(Data("aurora-dfid".utf8).md5Hex().prefix(15))
        dfid = UInt64(dfidHex, radix: 16).map(String.init) ?? dfidHex
    }

    // MARK: - 签名

    /// 参数按 key 排序后拼接，两端拼盐再 MD5。
    private func sign(_ params: [String: String], salt: String, data: String = "") -> String {
        let body = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
        return Data("\(salt)\(body)\(data)\(salt)".utf8).md5Hex()
    }

    // MARK: - 搜索

    /// 搜索歌曲。返回空数组表示没搜到。
    func searchSongs(keyword: String, page: Int = 1, limit: Int = 30) async throws -> [Song] {
        var params: [String: String] = [
            "ab_tag": "1",
            "ability": "57343",
            "albumhide": "1",
            "apiver": "22",
            "appid": "1000",
            "area_code": "1",
            "clienttime": String(Int(Date().timeIntervalSince1970)),
            "clientver": "20549",
            "com_user_type": "0",
            "cursor": String(max(page, 1)),
            "dfid": dfid,
            "is_gpay": "0",
            "iscorrection": "1",
            "keyword": keyword,
            "mid": mid,
            "mode_ability": "0",
            "nocollect": "0",
            "osversion": "16.0",
            "platform": "IOSFilter",
            "recver": "2",
            "req_ai": "1",
            "search_ability": "31",
            "search_source": "搜索",
            "sec_aggre": "1",
            "sec_aggre_bitmap": "22",
            "style_type": "3",
            "tag": "em",
            "token": "",
            "userid": "0",
            "uuid": mid,
        ]
        params["signature"] = sign(params, salt: searchSalt)

        let json = try await getJSON(path: "/complexsearch/v3/search/mixed",
                                     host: gateway,
                                     params: params,
                                     headers: [
                                         "User-Agent": searchUA,
                                         "KG-RF": "D4407D2505656C0FDC1621BA6FA3FEB5",
                                         "KG-FAKE": "359933394",
                                         "KG-FAKE-TYPE": "29,1",
                                         "KG-RC": "1",
                                         "UNI-UserAgent": "iOS16.0-Phone-1009-0-WiFi",
                                     ])
        guard let data = json["data"] as? [String: Any],
              let groups = data["lists"] as? [[String: Any]] else { return [] }

        var songs: [Song] = []
        for group in groups where (Self.string(group["type"]) ?? "").lowercased() == "song" {
            let rows = (group["info"] as? [[String: Any]] ?? [])
                + (group["lists"] as? [[String: Any]] ?? [])
            songs.append(contentsOf: rows.compactMap { Song(kugouJSON: $0) })
            if songs.count >= limit { break }
        }
        return Array(songs.prefix(limit))
    }

    // MARK: - 歌词

    /// 歌词。酷狗的歌词接口只认 http，且缺 Referer 会 400。
    func lyric(hash: String, duration: Double) async -> String? {
        let upper = hash.uppercased()
        let millis = Int(duration * 1000)
        let searchParams: [String: String] = [
            "ver": "1", "man": "yes", "client": "pc",
            "hash": upper, "duration": String(millis),
        ]
        guard let search = try? await getJSON(path: "/search",
                                              host: "http://lyrics.kugou.com",
                                              params: searchParams,
                                              headers: ["Referer": "https://www.kugou.com/"]),
              let candidates = search["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let id = first["id"],
              let accessKey = first["accesskey"] else { return nil }

        let downloadParams: [String: String] = [
            "ver": "1", "client": "pc", "id": "\(id)",
            "accesskey": "\(accessKey)", "fmt": "lrc", "charset": "utf8",
        ]
        guard let download = try? await getJSON(path: "/download",
                                                host: "http://lyrics.kugou.com",
                                                params: downloadParams,
                                                headers: ["Referer": "https://www.kugou.com/"]),
              let content = download["content"] as? String,
              let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - 播放地址

    /// 直连播放地址。设备指纹过不了时返回 nil，交给第三方音源。
    func songURL(hash: String,
                 audioID: String?,
                 albumID: String?,
                 quality: MusicQuality) async -> String? {
        let fileHash = hash.lowercased()
        let level: String
        switch quality {
        case .standard: level = "128"
        case .higher, .exHigh: level = "320"
        case .lossless: level = "flac"
        case .hires: level = "high"
        }

        var params: [String: String] = [
            "action": "play",
            "album_id": albumID ?? "0",
            "area_code": "1",
            "behavior": "play",
            "cdnBackup": "1",
            "cmd": "26",
            "clientver": songClientVersion,
            "hash": fileHash,
            "module": "",
            "page_id": "151369488",
            "pid": "2",
            "pidversion": "3001",
            "ppage_id": "463467626,350369493,788954147",
            "quality": level,
            "ssa_flag": "is_fromtrack",
            "version": songClientVersion,
            "appid": appID,
            "clienttime": String(Int(Date().timeIntervalSince1970)),
            "mid": mid,
        ]
        params["key"] = Data("\(fileHash)\(playKeySalt)\(appID)\(mid)0".utf8).md5Hex()
        if let audioID, !audioID.isEmpty { params["album_audio_id"] = audioID }
        params["signature"] = sign(params, salt: signSalt)

        guard let json = try? await getJSON(path: "/v5/url",
                                            host: gateway,
                                            params: params,
                                            headers: [
                                                "User-Agent": "Mozilla/5.0 (Linux; Android 12; K) AppleWebKit/537.36 Chrome/120 Mobile",
                                                "kg-rc": "1",
                                                "kg-thash": "5d816a0",
                                                "kg-rec": "1",
                                                "kg-rf": "B9EDA08A64250DEFFBCADDEE00F8F25F",
                                                "dfid": dfid,
                                                "mid": mid,
                                                "x-router": "trackercdn.kugou.com",
                                            ]) else { return nil }
        for key in ["play_backup_url", "play_url", "url", "src", "backup_url"] {
            if let value = json[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - 榜单

    /// 酷狗排行榜列表。
    func topLists() async -> [Playlist] {
        guard let json = try? await getJSON(path: "/rank/list?json=true",
                                            host: "https://m.kugou.com",
                                            params: [:],
                                            headers: [:]),
              let rank = json["rank"] as? [String: Any],
              let list = rank["list"] as? [[String: Any]] else { return [] }

        return list.compactMap { item -> Playlist? in
            let rankID = KugouClient.string(item["rankid"]) ?? KugouClient.string(item["id"]) ?? ""
            guard !rankID.isEmpty else { return nil }
            let name = KugouClient.string(item["rankname"]) ?? "榜单"
            var cover = KugouClient.string(item["img9"]) ?? KugouClient.string(item["imgurl"])
            // 酷狗的封面地址带 {size} 占位
            if let raw = cover {
                cover = raw.replacingOccurrences(of: "{si}", with: "300")
                    .replacingOccurrences(of: "{size}", with: "300")
            }
            return Playlist(id: "kg-rank:\(rankID)",
                            name: name,
                            coverURL: cover.flatMap { URL(string: $0) },
                            trackCount: KugouClient.intValue(item["songcount"]) ?? 0,
                            creatorName: "酷狗音乐",
                            source: .kugou,
                            kugouRankID: rankID,
                            updateFrequency: KugouClient.string(item["update_frequency"]) ?? "")
        }
    }

    /// 榜单里的歌曲。
    func rankSongs(rankID: String, limit: Int = 50) async -> [Song] {
        var params: [String: String] = [
            "appid": appID,
            "clienttype": "android",
            "clientver": clientVersion,
            "page": "1",
            "pagesize": String(max(limit, 1)),
            "topid": rankID,
            "key": sign(["v": clientVersion, "topid": rankID], salt: signSalt),
        ]
        params["jsoncallback"] = "kgCloudJsonpCallback123"
        params["sign"] = Data("\(signSalt)\(clientVersion)\(clientVersion)\(signSalt)".utf8).md5Hex()

        guard let raw = try? await getRaw(path: "/yy/rank/song",
                                         host: "http://m.kugou.com",
                                         params: params,
                                         headers: ["User-Agent": browserUA]),
              let data = Self.extractJSONP(raw) else { return [] }
        let list = data["data"] as? [[String: Any]] ?? data["info"] as? [[String: Any]] ?? []
        return Array(list.compactMap { Song(kugouJSON: $0) }.prefix(limit))
    }

    // MARK: - 请求

    private func getJSON(path: String,
                         host: String,
                         params: [String: String],
                         headers: [String: String]) async throws -> [String: Any] {
        let raw = try await getRaw(path: path, host: host, params: params, headers: headers)
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw KugouError.decoding
        }
        return object
    }

    private func getRaw(path: String,
                        host: String,
                        params: [String: String],
                        headers: [String: String]) async throws -> String {
        var components = URLComponents(string: host + path)
        if !params.isEmpty {
            components?.queryItems = params
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw KugouError.badURL }

        var request = URLRequest(url: url)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-Hans-CN;q=1", forHTTPHeaderField: "Accept-Language")
        if headers["User-Agent"] == nil {
            request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if host.contains("kugou.com") && !path.contains("rank") {
            request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw KugouError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 酷狗有些接口用 JSONP 包裹。
    static func extractJSONP(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return nil }
        let slice = String(raw[start...end])
        return try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any]
    }

    static func string(_ raw: Any?) -> String? {
        if let value = raw as? String, !value.isEmpty { return value }
        if let value = raw as? Int { return String(value) }
        if let value = raw as? NSNumber { return value.stringValue }
        return nil
    }

    static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }
}

enum KugouError: LocalizedError {
    case badURL
    case httpStatus(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .badURL: return "请求地址无效"
        case .httpStatus(let code): return "酷狗接口返回 \(code)"
        case .decoding: return "酷狗返回的数据解析失败"
        }
    }
}
