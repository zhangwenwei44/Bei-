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
    /// 歌手写真缓存（NSCache 线程安全）。key 是歌手名。
    private let photoCache = NSCache<NSString, NSURL>()
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
        let json = try await mixedSearchJSON(keyword: keyword, page: page)
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

    /// 签名后的混合搜索请求。歌曲搜索和歌手写真都从这里拿数据。
    private func mixedSearchJSON(keyword: String, page: Int) async throws -> [String: Any] {
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

        return try await getJSON(path: "/complexsearch/v3/search/mixed",
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
    }

    // MARK: - 封面与歌手写真

    /// 专辑封面。榜单页的歌曲节点不带任何图片字段、只带 album_id，
    /// 所以榜单里的小图要靠这个接口按专辑补。{size} 占位统一换成 300。
    /// 用 https 的 mobiles 域名：http 在设备上会被 ATS 拦，
    /// 而 mobilecdn 这个老域名不支持 https，mobiles 是同一套 v3 接口的 https 入口。
    func albumCover(albumID: String) async -> URL? {
        guard let id = Int(albumID), id > 0 else { return nil }
        guard let json = try? await getJSON(path: "/api/v3/album/info",
                                            host: "https://mobiles.kugou.com",
                                            params: ["albumid": String(id)],
                                            headers: [:]),
              let data = json["data"] as? [String: Any],
              let raw = KugouClient.string(data["imgurl"]) else { return nil }
        let fixed = raw.replacingOccurrences(of: "{si}", with: "300")
            .replacingOccurrences(of: "{size}", with: "300")
        return URL(string: fixed)
    }

    /// 歌手写真。混合搜索的 recommend 分组里有歌手卡片（type=4），
    /// 头像在 singerimg.kugou.com，{size} 占位换成 480。
    ///
    /// 节点字段有两种排布，都得认：
    /// - 大众歌手：singername / first_frame_image 直接在节点顶层
    /// - 小众歌手：这两个字段在顶层是空的，真身在 extra.singername / extra.imgurl；
    ///   imgurl（singerimg 头像）顶层和 extra 里一般都有
    /// 先按歌手名精确匹配；匹配不到再把歌名搜一遍兜底。
    func artistPhoto(name: String, title: String = "") async -> URL? {
        if let cached = photoCache.object(forKey: name as NSString) { return cached as URL }
        if let url = await artistPhoto(name: name, keyword: name) {
            photoCache.setObject(url as NSURL, forKey: name as NSString)
            return url
        }
        // 歌手名搜不出卡片（冷门歌手）时，用歌名再试一次：
        // recommend 分组里常带这首歌的歌手卡片
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty,
              let url = await artistPhoto(name: name, keyword: trimmedTitle) else { return nil }
        photoCache.setObject(url as NSURL, forKey: name as NSString)
        return url
    }

    /// 用指定关键词搜索，在 recommend 分组里找歌手卡片。
    /// 匹配规则：歌手名精确相等优先，其次取第一个带头像的歌手卡片。
    private func artistPhoto(name: String, keyword: String) async -> URL? {
        let lead = name.components(separatedBy: CharacterSet(charactersIn: "、/&，,"))
            .first?
            .trimmingCharacters(in: .whitespaces) ?? name
        guard !keyword.isEmpty,
              let json = try? await mixedSearchJSON(keyword: keyword, page: 1),
              let data = json["data"] as? [String: Any],
              let groups = data["lists"] as? [[String: Any]] else { return nil }

        var fallbackURL: URL?
        for group in groups where (Self.string(group["type"]) ?? "") == "recommend" {
            let nodes = group["lists"] as? [[String: Any]] ?? []
            for node in nodes where (Self.string(node["type"]) ?? "") == "4" {
                let extra = node["extra"] as? [String: Any]
                let matchedName = Self.string(node["singername"])
                    ?? Self.string(extra?["singername"])
                    ?? Self.string(node["title"])
                guard let portrait = Self.portraitURL(node: node, extra: extra) else { continue }
                if matchedName == lead {
                    return portrait
                }
                if fallbackURL == nil { fallbackURL = portrait }
            }
            break
        }
        return fallbackURL
    }

    /// 从歌手卡片里抠出头像地址。优先 imgurl（singerimg 的正式歌手头像），
    /// first_frame_image 是 MV 抽帧，经常是怼脸的奇怪截图，只做兜底。
    private static func portraitURL(node: [String: Any], extra: [String: Any]?) -> URL? {
        let raw = KugouClient.string(node["imgurl"])
            ?? KugouClient.string(extra?["imgurl"])
            ?? KugouClient.string(node["first_frame_image"])
            ?? KugouClient.string(extra?["first_frame_image"])
        guard let raw, raw.contains("singerimg") else { return nil }
        let fixed = raw.replacingOccurrences(of: "{size}", with: "480")
            .replacingOccurrences(of: "{si}", with: "480")
        return URL(string: fixed)
    }

    // MARK: - 歌词

    /// 歌词。缺 Referer 会 400。用 https：http 版会被设备上的 ATS 拦。
    func lyric(hash: String, duration: Double) async -> String? {
        let upper = hash.uppercased()
        let millis = Int(duration * 1000)
        let searchParams: [String: String] = [
            "ver": "1", "man": "yes", "client": "pc",
            "hash": upper, "duration": String(millis),
        ]
        guard let search = try? await getJSON(path: "/search",
                                              host: "https://lyrics.kugou.com",
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
                                                host: "https://lyrics.kugou.com",
                                                params: downloadParams,
                                                headers: ["Referer": "https://www.kugou.com/"]),
              let content = download["content"] as? String,
              let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - 播放地址

    /// /v5/url 从 v1.3.0 起就一直返回 85 字节错误体（errcode + errmsg + status），
    /// 设备指纹/盐/版本号任何一个对不上服务端都会拒绝。每次切歌都白白发 3 次
    /// 请求再失败、再落到第三方音源，用户多等 1 秒。这里加一个进程内熔断：
    /// 连续失败超过阈值就不再试，直到 App 重启或某次成功后清零。
    /// 阈值留 3 次：太低误杀偶发抖动，太高失去熔断意义。
    ///
    /// 用 actor 而不是 NSLock：NSLock 在 async 上下文里会被 Swift 6 严格并发
    /// 检查警告「lock is unavailable from asynchronous contexts」，CI 的
    /// 「Fail on compiler warnings」步骤会把警告当 error 直接终止构建。
    /// actor 是 Swift Concurrency 原生的 async-safe 同步原语，没有这个问题。
    static let failureThreshold = 3
    private actor FailureCounter {
        static let shared = FailureCounter()
        private(set) var count = 0
        func increment() -> Int {
            count += 1
            return count
        }
        func reset() {
            count = 0
        }
    }
    private static let failures = FailureCounter.shared

    /// 直连播放地址。设备指纹过不了时返回 nil，交给第三方音源。
    func songURL(hash: String,
                 audioID: String?,
                 albumID: String?,
                 quality: MusicQuality) async -> String? {
        // 熔断中：之前已经连续失败超过阈值，本次运行期不再试。
        // 第三方音源会兜住解析，用户感知只是少了无谓的等待。
        let failures = await Self.failures.count
        if failures >= Self.failureThreshold {
            Log.info("音乐接口", "/v5/url 已熔断（连续失败 \(failures) 次），跳过直连，交给第三方音源")
            return nil
        }

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
            if let value = json[key] as? String, !value.isEmpty {
                // 成功一次就清零熔断计数：服务端协议可能某天修好，
                // 不能让旧的失败计数永久封住直连。
                await Self.failures.reset()
                return value
            }
        }
        // 这个接口从 v1.3.0 起就一直返回 85 字节错误体。日志里看到字段名是
        // `errcode, errmsg, status`（不是 `error` / `msg`），之前读错了字段，
        // reason 永远落到 fallback 的「响应里没有地址字段」，看不出真正错在哪。
        // errcode 是数字，强制转字符串兜住；errmsg 才是文字。
        let errcode = (json["errcode"] as? NSNumber)?.stringValue
            ?? (json["errcode"] as? Int).map(String.init)
            ?? (json["errcode"] as? String)
            ?? "?"
        let errmsg = (json["errmsg"] as? String)
            ?? (json["msg"] as? String)
            ?? (json["error"] as? String)
            ?? "无文字说明"
        Log.error("音乐接口", "/v5/url 没有返回播放地址：errcode=\(errcode) errmsg=\(errmsg)（字段：\(json.keys.sorted().joined(separator: ","))）")
        // 失败计数 +1，达到阈值后本次运行期熔断，不再浪费一次切歌 3 个请求。
        let total = await Self.failures.increment()
        if total >= Self.failureThreshold {
            Log.warn("音乐接口", "/v5/url 累计失败 \(total) 次，已熔断，本次运行期不再尝试，交给第三方音源")
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
            // 实测字段是 img_9 下划线，不是 img9；写错会静默变成 nil，榜单全没封面
            var cover = KugouClient.string(item["img_9"])
                ?? KugouClient.string(item["img9"])
                ?? KugouClient.string(item["imgurl"])
            // 酷狗的封面地址带 {size} 占位
            if let raw = cover {
                cover = raw.replacingOccurrences(of: "{si}", with: "300")
                    .replacingOccurrences(of: "{size}", with: "300")
            }
            return Playlist(id: "kg-rank:\(rankID)",
                            name: name,
                            coverURL: cover.flatMap { URL(string: $0) },
                            // songcount 字段实际不存在，songinfo 只有 3 条推荐位——
                            // 之前拿 songinfo.count 当曲目数，结果所有榜单都显示「3 首」。
                            // 真实总数在榜单页的 global.total 里，由 rankTotal() 异步补。
                            trackCount: 0,
                            creatorName: "酷狗音乐",
                            source: .kugou,
                            kugouRankID: rankID,
                            updateFrequency: KugouClient.string(item["update_frequency"]) ?? "")
        }
    }

    /// 榜单的真实曲目总数。
    ///
    /// 榜单列表接口里没有 songcount，songinfo 只有 3 条推荐位，不能当曲目数用。
    /// 真实总数在榜单页的 `global.total` 里（TOP500 是 500，其余榜单多为 100）。
    /// 取不到就返回 nil，让界面显示「—」而不是一个错的数字。
    func rankTotal(rankID: String) async -> Int? {
        guard let numericID = Int(rankID), numericID > 0 else { return nil }
        do {
            let html = try await getRaw(path: "/yy/rank/home/1-\(numericID).html",
                                        host: "https://www.kugou.com",
                                        params: [:],
                                        headers: [:])
            // 形如 total: '500'
            guard let range = html.range(of: "total:\\s*'") else { return nil }
            let rest = html[range.upperBound...]
            guard let end = rest.firstIndex(of: "'") else { return nil }
            let digits = rest[rest.startIndex..<end]
            guard let total = Int(digits), total > 0 else { return nil }
            Log.info("榜单", "rankid=\(numericID) 真实曲目数 \(total)")
            return total
        } catch {
            Log.warn("榜单", "rankid=\(numericID) 取曲目数失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 榜单里的歌曲。
    ///
    /// 榜单页（`www.kugou.com/yy/rank/home/1-<rankid>.html`）把曲目塞在
    /// `global.features = [...]` 这个 JS 数组里，取歌只能从这儿抠。
    /// 注意 URL 用的是 `rankid` 而不是 `id`，用错会返回 "You need get the right classid!"。
    func rankSongs(rankID: String, limit: Int = 50) async throws -> [Song] {
        guard let numericID = Int(rankID), numericID > 0 else { throw KugouError.badURL }
        let html = try await getRaw(path: "/yy/rank/home/1-\(numericID).html",
                                    host: "https://www.kugou.com",
                                    params: [:],
                                    headers: [:])
        guard let rows = Self.javascriptArray(named: "global.features", in: html) else {
            Log.error("榜单", "rankid=\(numericID) 的页面里没找到 global.features 数组，收到 \(html.count) 字节：\(html.prefix(120))")
            throw KugouError.parse("榜单页里没找到 global.features 数组（页面结构可能变了，实际收到 \(html.count) 字节）")
        }
        let songs = Array(rows.compactMap { Song(kugouJSON: $0) }.prefix(limit))
        Log.info("榜单", "rankid=\(numericID) 解析到 \(rows.count) 条记录 -> \(songs.count) 首歌")
        if songs.isEmpty {
            Log.error("榜单", "rankid=\(numericID) 有 \(rows.count) 条记录但一首歌都没解析出来，字段名可能又变了")
        }
        return songs
    }

    /// 从 HTML 里取出 `name = [...]` 形式的 JS 数组，括号配平扫描。
    ///
    /// 扫描时跳过字符串字面量，避免歌名里的 `[` `]` 把括号计数带偏。
    /// 注意起始位置要用 `name = [` 里那个开括号本身：如果从 upperBound 之后
    /// 再找 `[`，会跳过整段数组内容、落到页面别处的方括号上，切出垃圾。
    static func javascriptArray(named name: String, in html: String) -> [[String: Any]]? {
        guard let marker = html.range(of: "\(name) = [") else { return nil }
        let start = html.index(before: marker.upperBound)

        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < html.endIndex {
            let ch = html[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == "[" { depth += 1 }
                else if ch == "]" {
                    depth -= 1
                    if depth == 0 {
                        let slice = String(html[start...index])
                        return try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [[String: Any]]
                    }
                }
            }
            index = html.index(after: index)
        }
        return nil
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

        let started = Date()
        let (data, response) = try await session.data(for: request)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        Log.info("网络", "GET \(url.absoluteString) -> \(status) / \(data.count) 字节 / \(elapsed)ms")
        guard (200...299).contains(status) else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            Log.error("网络", "HTTP \(status) \(url.absoluteString) 响应开头: \(preview)")
            throw KugouError.httpStatus(status)
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
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "请求地址无效"
        case .httpStatus(let code): return "酷狗接口返回 \(code)"
        case .decoding: return "酷狗返回的数据解析失败"
        case .parse(let detail): return detail
        }
    }
}
