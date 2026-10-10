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
    /// 专辑封面缓存。key 是 albumID（String）。
    private let albumCoverCache = NSCache<NSString, NSURL>()
    /// 专辑封面正在进行的请求 — actor 内部维护，async-safe。
    private actor AlbumInflight {
        private var set = Set<String>()
        func contains(_ id: String) -> Bool { set.contains(id) }
        func insert(_ id: String) { set.insert(id) }
        func remove(_ id: String) { set.remove(id) }
    }
    private let albumCoverInFlight = AlbumInflight()
    private let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private let searchUA = "IPhone-20549-Search#183534257/723988397/625045823/284854956-SearchGeneralInfoWithKeyWordV8"

    private let mid: String
    private let dfid: String

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 限流：全站最多 5 个并发 HTTP 请求（默认 6，iOS 16 上也够用）。
        // 酷狗 CDN 很稳但 DNS 解析偶发慢，太多并发会同时打 DNS / TLS 握手，
        // 反而让首批请求全部卡在握手阶段。
        config.httpMaximumConnectionsPerHost = 5
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
    ///
    /// 用酷狗官方歌曲搜索接口 `/api/v3/search/song`（之前的 mixedSearch cursor 参数是搜索建议用的，
    /// 对同一关键词无论 cursor=1/2/3/4 都返回相同的第一页，翻页完全不生效）。
    /// 这个新接口有真正的 `page` 和 `pagesize` 参数，每页固定 30 首，可连续翻页。
    ///
    /// 调用方并行翻 4 页（共 120 首），合并去重后返回。
    func searchSongs(keyword: String, page: Int = 1, limit: Int = 500) async throws -> [Song] {
        let json = try? await searchSongJSON(keyword: keyword, page: page, pageSize: 30)
        var songs: [Song] = []
        if let info = json?["data"] as? [String: Any],
           let rows = info["info"] as? [[String: Any]] {
            songs = rows.compactMap { Song(kugouJSON: $0) }
        }
        // 搜索接口完全没封面字段，用 album_id 异步补封面
        var albumIDs = Set<String>()
        for s in songs where s.artworkURL == nil && !s.kugouAlbumID.isEmpty {
            albumIDs.insert(s.kugouAlbumID)
        }
        if !albumIDs.isEmpty {
            Log.info("搜索", "keyword=\(keyword) 补封面 \(albumIDs.count) 个 album_id")
            try await withThrowingTaskGroup(of: (String, URL?).self) { group in
                for aid in albumIDs {
                    group.addTask { [weak self] in
                        let cover = await self?.albumCover(albumID: aid)
                        return (aid, cover)
                    }
                }
                for try await (aid, cover) in group {
                    if let cover {
                        for i in songs.indices where songs[i].kugouAlbumID == aid {
                            songs[i].artworkURL = cover
                        }
                    }
                }
            }
        }
        Log.info("搜索", "keyword=\(keyword) page=\(page) 返回 \(songs.count) 首")
        return songs
    }

    /// 歌曲搜索专用接口。支持 `page` 真正翻页，每页 `pageSize` 首。
    private func searchSongJSON(keyword: String, page: Int, pageSize: Int = 30) async throws -> [String: Any] {
        let params: [String: String] = [
            "showtype": "14",
            "highlight": "em",
            "pagesize": String(pageSize),
            "tag_aggr": "1",
            "tagtype": "全部",
            "plat": "0",
            "sver": "5",
            "keyword": keyword,
            "correct": "1",
            "api_ver": "1",
            "version": "9108",
            "page": String(page),
            "area_code": "1",
            "tag": "1",
            "with_res_tag": "1",
        ]
        // 用 mobiles.kugou.com 的 https 接口，msearchcdn 域名可能 ATS 拦截
        return try await getJSON(path: "/api/v3/search/song",
                                 host: "https://mobiles.kugou.com",
                                 params: params,
                                 headers: [
                                     "User-Agent": searchUA,
                                     "Referer": "https://www.kugou.com/",
                                 ])
    }

    /// 签名后的混合搜索请求。歌曲搜索和歌手写真都从这里拿数据。
    private func mixedSearchJSON(keyword: String, cursor: Int) async throws -> [String: Any] {
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
            "cursor": String(cursor),
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
        // 缓存命中直接返回
        if let cached = albumCoverCache.object(forKey: albumID as NSString) {
            return cached as URL
        }
        // 同一 albumID 的请求已经在飞 — 不重复发，让正在飞的那个回来后写缓存
        let alreadyFlying = await albumCoverInFlight.contains(albumID)
        if !alreadyFlying { await albumCoverInFlight.insert(albumID) }
        if alreadyFlying {
            // 不发请求但等一下 — 其他并发请求结束后缓存就有了
            // 最多等 2 秒，超时直接返回 nil 让调用方下次再来
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
                if let cached = albumCoverCache.object(forKey: albumID as NSString) {
                    return cached as URL
                }
            }
            return nil
        }
        defer {
            Task { await albumCoverInFlight.remove(albumID) }
        }
        guard let json = try? await getJSON(path: "/api/v3/album/info",
                                            host: "https://mobiles.kugou.com",
                                            params: ["albumid": String(id)],
                                            headers: [:]),
              let data = json["data"] as? [String: Any],
              let raw = KugouClient.string(data["imgurl"]) else { return nil }
        let fixed = raw.replacingOccurrences(of: "{si}", with: "300")
            .replacingOccurrences(of: "{size}", with: "300")
        guard let url = URL(string: fixed) else { return nil }
        albumCoverCache.setObject(url as NSURL, forKey: albumID as NSString)
        return url
    }

    /// 歌手写真。三路兜底：
    /// 1) mixedSearchJSON 里找 type=4 歌手卡片（imgurl / first_frame_image）
    /// 2) mixedSearchJSON 里找歌曲节点的 singerimg 字段（最稳，酷狗必返回）
    /// 3) 兜底 MV 抽帧
    func artistPhoto(name: String, title: String = "") async -> URL? {
        if let cached = photoCache.object(forKey: name as NSString) { return cached as URL }
        let lead = name.components(separatedBy: CharacterSet(charactersIn: "、/&，,"))
            .first?.trimmingCharacters(in: .whitespaces) ?? name
        if let url = await artistPhoto(name: name, keyword: lead) {
            photoCache.setObject(url as NSURL, forKey: name as NSString)
            return url
        }
        // 歌名兜底
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        if !trimmedTitle.isEmpty,
           let url = await artistPhoto(name: name, keyword: trimmedTitle) {
            photoCache.setObject(url as NSURL, forKey: name as NSString)
            return url
        }
        return nil
    }

    /// 核心实现：只翻 mixedSearch 第 1 页。
    /// cursor=1/2/3 在 mixedSearch 上返回的是完全相同的第一页数据（酷狗把 cursor 用在
    /// 搜索建议而非正式搜索），之前翻 3 页纯属浪费请求和发热，现在砍到只翻 1 页。
    /// 12 个热门歌手头像直接省掉 24 个无用请求。
    private func artistPhoto(name: String, keyword: String) async -> URL? {
        let lead = name.components(separatedBy: CharacterSet(charactersIn: "、/&，,"))
            .first?.trimmingCharacters(in: .whitespaces) ?? name
        guard !keyword.isEmpty else { return nil }

        // 内存缓存命中直接返回（NSCache 线程安全）
        if let cached = photoCache.object(forKey: keyword as NSString) as URL? {
            return cached
        }

        var fallbackURL: URL?
        guard let json = try? await mixedSearchJSON(keyword: keyword, cursor: 1),
              let data = json["data"] as? [String: Any],
              let groups = data["lists"] as? [[String: Any]] else {
            Log.info("歌手头像", "keyword=\(keyword) mixedSearch 无数据 fallback=\(fallbackURL?.absoluteString ?? "nil")")
            if let fallback = fallbackURL {
                photoCache.setObject(fallback as NSURL, forKey: keyword as NSString)
            }
            return fallbackURL
        }

        for group in groups {
            let nodes = group["lists"] as? [[String: Any]] ?? []
            for node in nodes {
                let extra = node["extra"] as? [String: Any]

                // 路径 1（主）：任何节点只要有 imgurl/Pic/ErectPic 就尝试当歌手卡片
                if let portrait = Self.anyImageURL(node: node, extra: extra) {
                    let matchedName = Self.string(node["singername"])
                        ?? Self.string(extra?["singername"])
                        ?? Self.string(node["title"])
                        ?? Self.string(node["SingerName"])
                        ?? Self.string(node["artistname"])
                        ?? Self.string(node["ArtistName"])
                        ?? Self.string(node["artist"])
                        ?? Self.string(node["Singers"])
                    if matchedName == lead {
                        // 找到 exact 就立即缓存返回
                        photoCache.setObject(portrait as NSURL, forKey: keyword as NSString)
                        Log.info("歌手头像", "keyword=\(keyword) exact=hit")
                        return portrait
                    } else if fallbackURL == nil {
                        fallbackURL = portrait
                    }
                    continue
                }

                // 路径 2：歌曲节点 —— 严格匹配歌手名后，抓 singerimg / AlbumImage / Image
                let matchedArtist = Self.string(node["singername"])
                    ?? Self.string(node["SingerName"])
                    ?? Self.string(node["artistname"])
                    ?? Self.string(node["ArtistName"])
                    ?? Self.string(node["artist"])
                    ?? Self.string(node["Singers"])
                guard matchedArtist == lead else { continue }

                // 歌手头像字段（singerimg 系列）
                for field in ["singerimg", "singerImg", "singer_img", "singermid", "SingerImg"] {
                    if let raw = Self.string(node[field]) {
                        let fixed = raw.replacingOccurrences(of: "{size}", with: "480")
                            .replacingOccurrences(of: "{si}", with: "480")
                        if let url = URL(string: fixed), Self.looksLikeImage(url) {
                            // singerimg 也算 exact — 严格匹配了歌手名
                            photoCache.setObject(url as NSURL, forKey: keyword as NSString)
                            Log.info("歌手头像", "keyword=\(keyword) exact=singerimg")
                            return url
                        }
                    }
                }

                // 兜底：专辑封面（AlbumImage/AlbumImg/Image）— 虽然是专辑不是歌手，但比首字占位好
                if fallbackURL == nil {
                    for field in ["AlbumImage", "albumImage", "AlbumImg", "albumImg", "Image"] {
                        if let raw = Self.string(node[field]) {
                            let fixed = raw.replacingOccurrences(of: "{size}", with: "480")
                                .replacingOccurrences(of: "{si}", with: "480")
                            if let url = URL(string: fixed), Self.looksLikeImage(url) {
                                fallbackURL = url
                                break
                            }
                        }
                    }
                }
            } // for node
        } // for group
        Log.info("歌手头像", "keyword=\(keyword) fallback=\(fallbackURL?.absoluteString ?? "nil")")
        if let fallback = fallbackURL {
            photoCache.setObject(fallback as NSURL, forKey: keyword as NSString)
        }
        return fallbackURL
    }

    /// 统一判断 URL 看起来是图片（扩展名或域名）
    private static func looksLikeImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp", "gif", "bmp"].contains(ext) { return true }
        let host = url.host ?? ""
        return host.contains("kugou") || host.contains("singerimg") || host.contains("imge")
            || host.contains("mdpfile") || host.contains("bdycdn")
    }

    /// 从任何节点（歌手卡、MV 节点、歌曲节点）里抓图片 URL。
    /// 字段优先级：imgurl > first_frame_image > Pic > ErectPic > ThumbGif > ThumbMp4(封面)
    private static func anyImageURL(node: [String: Any], extra: [String: Any]?) -> URL? {
        let fields: [String] = [
            "imgurl", "first_frame_image", "Pic", "ErectPic",
            "ThumbGif", "ThumbMp4", "AlbumImage", "AlbumImg", "Image",
            "singerimg", "singerImg", "singer_img", "singermid", "SingerImg"
        ]
        for field in fields {
            for value in [node[field], extra?[field]] {
                guard let raw = Self.string(value) else { continue }
                let fixed = raw.replacingOccurrences(of: "{size}", with: "480")
                    .replacingOccurrences(of: "{si}", with: "480")
                if let url = URL(string: fixed), Self.looksLikeImage(url) {
                    return url
                }
            }
        }
        return nil
    }

    /// 从歌手卡片里抠出头像地址。优先 imgurl（正式歌手头像），
    /// first_frame_image 是 MV 抽帧，经常是怼脸的奇怪截图，只做兜底。
    /// 域名不再硬卡 singerimg：酷狗不同板块可能走 imge.kugou.com / special.kgou.org
    /// 等不同 CDN，只要 URL 像图片（.jpg/.png/.jpeg）就接受。
    private static func portraitURL(node: [String: Any], extra: [String: Any]?) -> URL? {
        let raw = KugouClient.string(node["imgurl"])
            ?? KugouClient.string(extra?["imgurl"])
            ?? KugouClient.string(node["first_frame_image"])
            ?? KugouClient.string(extra?["first_frame_image"])
        guard let raw,
              let fixed = URL(string: raw.replacingOccurrences(of: "{size}", with: "480")
                                 .replacingOccurrences(of: "{si}", with: "480")),
              ["jpg", "jpeg", "png", "webp"].contains(fixed.pathExtension.lowercased()) ||
              fixed.absoluteString.contains("singerimg") ||
              fixed.absoluteString.contains("kugou") else { return nil }
        return fixed
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
        private var trippedLogged = false
        func increment() -> Int {
            count += 1
            return count
        }
        /// 返回当前 count，超过阈值后第一次调用返回 true，之后返回 false。
        /// 用方法封装，actor 的 stored property 不能直接 await 访问。
        func checkAndMarkTripped(threshold: Int) -> (isTripped: Bool, shouldLog: Bool) {
            let isTripped = count >= threshold
            let shouldLog = isTripped && !trippedLogged
            if isTripped { trippedLogged = true }
            return (isTripped, shouldLog)
        }
        func reset() {
            count = 0
            trippedLogged = false
        }
    }
    private static let failures = FailureCounter.shared

    /// 直连播放地址。设备指纹过不了时返回 nil，交给第三方音源。
    ///
    /// ⛔️ v2.5.0 起永久禁用 —— gateway.kugou.com/v5/url 自 v1.3.0 起 errcode=20006 鉴权失效，
    /// 所有调用点都已在 SourceResolver.resolve 里短路。保留函数体和熔断声明以防未来万一接口恢复。
    func songURL(hash: String,
                 audioID: String?,
                 albumID: String?,
                 quality: MusicQuality) async -> String? {
        // 永久禁用：v5/url errcode=20006 鉴权失效，所有调用方（SourceResolver.resolve）都已跳过此链路。
        // 官方榜单搜索 / lyrics / 封面（m.kugou.com / lyrics.kugou.com）不走这个函数，不受影响。
        // 熔断逻辑（FailureCounter actor）保留声明但不再触发 —— App 重启就清零的进程内熔断没意义。
        /*
        // 熔断中：之前已经连续失败超过阈值，本次运行期不再试。
        let (isTripped, shouldLog) = await Self.failures.checkAndMarkTripped(threshold: Self.failureThreshold)
        if isTripped {
            if shouldLog {
                Log.info("音乐接口", "/v5/url 已熔断（连续失败，跳过直连，交给第三方音源）")
            }
            return nil
        }

        // ... 原始网关 v5/url 请求逻辑保留在此，见 git history ...
        */
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

    // MARK: - 推荐歌单

    /// 网络歌单推荐。走 m.kugou.com/plist/index?json=true，
    /// 返回 user 精选歌单（specialid 歌单），每页 30 个，全库共 600 个。
    /// - Returns: (本页歌单, 全库总数)
    func recommendedPlaylists(page: Int = 1) async -> (playlists: [Playlist], total: Int) {
        guard let json = try? await getJSON(path: "/plist/index",
                                            host: "https://m.kugou.com",
                                            params: ["json": "true",
                                                     "page": String(page)],
                                            headers: [:]),
              let outer = json["plist"] as? [String: Any],
              let list = outer["list"] as? [String: Any],
              let infos = list["info"] as? [[String: Any]] else { return ([], 0) }

        let total = KugouClient.intValue(list["total"]) ?? 0
        let playlists = infos.compactMap { item -> Playlist? in
            guard let specialID = KugouClient.string(item["specialid"]), !specialID.isEmpty else { return nil }
            let name = KugouClient.string(item["specialname"]) ?? "精选歌单"
            var cover = KugouClient.string(item["imgurl"]) ?? ""
            if cover.hasPrefix("http://") { cover = "https://" + cover.dropFirst("http://".count) }
            cover = cover.replacingOccurrences(of: "{si}", with: "300")
                .replacingOccurrences(of: "{size}", with: "300")
            let count = KugouClient.intValue(item["songcount"]) ?? 0
            let creator = KugouClient.string(item["username"]) ?? "酷狗音乐"
            return Playlist(id: "kg-special:\(specialID)",
                            name: name,
                            coverURL: URL(string: cover),
                            trackCount: count,
                            creatorName: creator,
                            source: .kugou,
                            kugouRankID: nil,
                            updateFrequency: "")
        }
        return (playlists, total)
    }

    /// 普通歌单（specialid）里的歌曲。
    ///
    /// 方案 1：mobilecdn `/api/v3/special/song`（JSON，翻页，PC 实测可用）
    /// 方案 2：m.kugou.com 移动端歌单页（HTTPS，iPhone 实测域名可达），
    ///         解析页面里的 dataobj 歌曲块（覆盖 96%+ 曲目）
    func specialSongs(specialID: String, limit: Int = 500) async throws -> [Song] {
        guard Int(specialID) != nil else { throw KugouError.badURL }

        // 方案 1：special/song JSON 翻页
        // mobiles.kugou.com 设备实测可达（搜索同主机）；mobilecdn 部分网络证书不匹配
        let hosts = ["https://mobiles.kugou.com",
                     "http://mobiles.kugou.com",
                     "http://mobilecdn.kugou.com",
                     "https://mobilecdn.kugou.com"]
        for host in hosts {
            if let songs = try? await specialSongsJSON(specialID: specialID,
                                                       host: host, limit: limit),
               !songs.isEmpty {
                Log.info("歌单", "specialid=\(specialID) JSON \(host) 拿到 \(songs.count) 首")
                return songs
            }
        }

        // 方案 2：移动端歌单整页
        Log.info("歌单", "specialid=\(specialID) JSON 全失败，改抓移动端整页")
        for url in ["https://m.kugou.com/plist/list/\(specialID)-1.html",
                    "https://m.kugou.com/plist/list/\(specialID).html",
                    "https://www.kugou.com/plist/list/\(specialID)-1.html",
                    "https://www.kugou.com/plist/list/\(specialID).html"] {
            guard let html = try? await getRaw(path: "",
                                               host: url,
                                               params: [:],
                                               headers: [:]) else { continue }
            let songs = Self.songs(fromSpecialMobileHTML: html)
            if !songs.isEmpty {
                Log.info("歌单", "specialid=\(specialID) 整页解析 \(songs.count) 首 via \(url)")
                return Array(songs.prefix(limit))
            } else {
                Log.info("歌单", "specialid=\(specialID) \(url) 页面解析为空")
            }
        }
        Log.warn("歌单", "specialid=\(specialID) 所有来源全部失败（JSON + 整页）")
        return []
    }

    /// special/song JSON 翻页。
    private func specialSongsJSON(specialID: String, host: String,
                                  limit: Int) async throws -> [Song] {
        var all: [Song] = []
        var page = 1
        var total = Int.max
        while all.count < min(limit, total) && page <= 25 {
            do {
                let json = try await getJSON(path: "/api/v3/special/song",
                                             host: host,
                                             params: ["specialid": specialID,
                                                      "page": String(page),
                                                      "pagesize": "30"],
                                             headers: [:])
                guard let data = json["data"] as? [String: Any],
                      let rows = data["info"] as? [[String: Any]] else {
                    Log.warn("歌单", "specialid=\(specialID) 第 \(page) 页结构不对")
                    break
                }
                total = KugouClient.intValue(data["total"]) ?? total
                all.append(contentsOf: rows.compactMap { Song(kugouJSON: $0) })
                if rows.count < 30 { break }
                page += 1
            } catch {
                Log.warn("歌单", "specialid=\(specialID) JSON \(host) 第 \(page) 页失败：\(error.localizedDescription)")
                throw error
            }
        }
        return Array(all.prefix(limit))
    }

    // MARK: - 分享链接导入

    /// 解析酷狗分享链接 / 短链 / specialid，返回歌单 + 歌曲列表。
    ///
    /// 酷狗分享链接几种格式：
    ///   1. https://t.kugou.com/abc123 —— 短链，HEAD 重定向到真实歌单页
    ///   2. https://www.kugou.com/plist/list/12345.html —— 普通歌单 specialid=12345
    ///   3. https://www.kugou.com/yy/player/share/xxx.html —— 分享页
    ///   4. 纯数字 "12345" —— 直接就是 specialid
    ///   5. 纯字母数字 "abc123" —— 当短链 code 处理
    ///   6. 粘贴文本里有多个东西（比如 App 分享带描述）—— 抠出第一个 URL
    func extractFirstURL(from text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for m in matches {
            if let range = Range(m.range, in: text) {
                let candidate = String(text[range])
                // 只返回 kugou.com 开头的 URL，避免把纯文字链接误识别
                if candidate.lowercased().contains("kugou.com") || candidate.lowercased().hasPrefix("http") {
                    return candidate
                }
            }
        }
        return nil
    }

    func fetchPlaylistByCode(_ input: String) async throws -> (Playlist, [Song]) {
        // 从粘贴文本里抠第一个 URL（酷狗 App 分享出来的链接经常裹在一段文字里）
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KugouError.badURL }
        let extractedURL = extractFirstURL(from: trimmed) ?? trimmed
        Log.info("导入", "解析输入：\(trimmed) → 提取后：\(extractedURL)")

        // 先提取 specialid / rankID
        var specialID: String? = nil
        var rankID: String? = nil

        if let url = URL(string: extractedURL), extractedURL.contains("kugou.com") {
            // 完整 URL — 尝试从路径里抠 specialid 或 rankid
            let path = url.path
            Log.info("导入", "URL 路径：\(path)")
            // /plist/list/{specialid}-1.html 或 /plist/list/{specialid}.html
            if let range = path.range(of: "/plist/list/") {
                let rest = path[range.upperBound...]
                if let dash = rest.firstIndex(of: "-"), let dot = rest.firstIndex(of: ".") {
                    let candidate = String(rest[..<min(dash, dot)])
                    if Int(candidate) != nil {
                        specialID = candidate
                        Log.info("导入", "识别为歌单 specialid=\(specialID!)")
                    } else {
                        Log.warn("导入", "plist/list 路径下抠不出数字 specialid：\(candidate)")
                    }
                } else {
                    Log.warn("导入", "plist/list 路径格式异常：\(path)")
                }
            } else if path.contains("/yy/rank/") || path.contains("/rank/") {
                // 榜单链接 /yy/rank/home/1-{rankid}.html
                let pattern = "/home/\\d+-(\\d+)"
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
                   let r = Range(match.range(at: 1), in: path) {
                    rankID = String(path[r])
                    Log.info("导入", "识别为榜单 rankid=\(rankID!)")
                } else {
                    Log.warn("导入", "榜单路径正则没匹配上：\(path)")
                }
            } else if extractedURL.contains("t.kugou.com") {
                // 短链 — GET 让 URLSession 自动跟随重定向，读最终 response.url
                let config = URLSessionConfiguration.default
                config.httpMaximumConnectionsPerHost = 1
                let session = URLSession(configuration: config)
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                   let finalURL = http.url {
                    Log.info("导入", "短链 GET 重定向到 \(finalURL.absoluteString)")
                    return try await fetchPlaylistByCode(finalURL.absoluteString) // 递归解析真实 URL
                }
                Log.warn("导入", "短链 GET 没拿到重定向 URL")
            } else {
                Log.warn("导入", "不认识的 kugou.com 路径：\(path)")
            }
        } else if Int(extractedURL) != nil {
            // 纯数字 → specialid
            specialID = extractedURL
            Log.info("导入", "纯数字识别为 specialid=\(specialID!)")
        } else {
            // 纯字母数字 → 当短链 code 处理
            let guessed = "https://t.kugou.com/\(extractedURL)"
            Log.info("导入", "纯字母数字 → 尝试短链 \(guessed)")
            return try await fetchPlaylistByCode(guessed)
        }

        // 根据 specialID / rankID 加载
        if let specialID {
            let songs = try await specialSongs(specialID: specialID)

            // 关键：空结果时主动检测歌单是否真的存在
            // 精选歌单（如 8393346）API 有数据 → 正常
            // 用户歌单（如 40551393）→ API 返回 total:0
            //   1) special/info 返回 data:null → 歌单不存在/已删
            //   2) special/info 有 data → 歌单存在但是私有（需要登录）
            if songs.isEmpty {
                let infoJSON = try? await getJSON(path: "/api/v3/special/info",
                                                  host: "https://mobiles.kugou.com",
                                                  params: ["specialid": specialID],
                                                  headers: [:])
                let infoExists = infoJSON?["data"] as? [String: Any] != nil
                if infoExists {
                    throw KugouError.playlistEmpty(specialID)
                } else {
                    throw KugouError.playlistNotFound(specialID)
                }
            }

            var cover = ""
            let name: String
            if let json = try? await getJSON(path: "/api/v3/special/info",
                                             host: "https://mobiles.kugou.com",
                                             params: ["specialid": specialID],
                                             headers: [:]),
               let info = json["data"] as? [String: Any] {
                name = KugouClient.string(info["specialname"]) ?? "导入歌单"
                cover = KugouClient.string(info["imgurl"]) ?? ""
            } else {
                name = "导入歌单 #\(specialID)"
            }
            if cover.hasPrefix("http://") { cover = "https://" + cover.dropFirst("http://".count) }
            let playlist = Playlist(id: "kg-special:\(specialID)",
                                    name: name,
                                    coverURL: URL(string: cover.isEmpty ? "" : cover),
                                    trackCount: songs.count,
                                    creatorName: "酷狗导入",
                                    source: .kugou,
                                    kugouRankID: nil,
                                    updateFrequency: "")
            Log.info("导入", "歌单 \(specialID) 导入成功：\(name) \(songs.count) 首")
            return (playlist, songs)
        } else if let rankID {
            let songs = try await rankSongs(rankID: rankID, limit: 50)
            let name = "酷狗榜单 #\(rankID)"
            let playlist = Playlist(id: "kg-rank:\(rankID)",
                                    name: name,
                                    coverURL: nil,
                                    trackCount: songs.count,
                                    creatorName: "酷狗导入",
                                    source: .kugou,
                                    kugouRankID: rankID,
                                    updateFrequency: "")
            Log.info("导入", "榜单 \(rankID) 导入成功：\(songs.count) 首")
            return (playlist, songs)
        } else {
            throw KugouError.badURL
        }
    }

    /// 热门歌手列表（按热度）。
    ///
    /// 方案 1：mobilecdn `/api/v3/singer/list?sort=1`（JSON，含粉丝数头像）
    /// 方案 2：www.kugou.com 歌手索引页（HTTPS，设备可达）
    func hotArtists(count: Int = 20) async -> [Artist] {
        // 方案 1：singer/list JSON
        for host in ["https://mobiles.kugou.com",
                     "http://mobiles.kugou.com",
                     "http://mobilecdn.kugou.com",
                     "https://mobilecdn.kugou.com"] {
            if let artists = try? await hotArtistsJSON(host: host, count: count),
               !artists.isEmpty {
                Log.info("歌手", "热门歌手 JSON \(host) \(artists.count) 位")
                return artists
            }
        }
        // 方案 2：www 歌手索引页
        if let html = try? await getRaw(path: "/yy/singer/index/1-all-1.html",
                                        host: "https://www.kugou.com",
                                        params: [:],
                                        headers: [:]) {
            let artists = Self.artists(fromSingerIndexHTML: html)
            Log.info("歌手", "热门歌手整页解析 \(artists.count) 位")
            return artists
        }
        return []
    }

    private func hotArtistsJSON(host: String, count: Int) async throws -> [Artist] {
        let pages = max(1, (count + 19) / 20)
        var result: [Artist] = []
        var seen = Set<String>()
        for page in 1...pages {
            let json = try await getJSON(path: "/api/v3/singer/list",
                                         host: host,
                                         params: ["clientver": "9108",
                                                  "page": String(page),
                                                  "pagesize": "20",
                                                  "sort": "1",
                                                  "category": "0"],
                                         headers: [:])
            guard let data = json["data"] as? [String: Any],
                  let rows = data["info"] as? [[String: Any]] else { break }
            for row in rows {
                guard let id = KugouClient.string(row["singerid"]),
                      let name = KugouClient.string(row["singername"]),
                      !seen.contains(id) else { continue }
                seen.insert(id)
                var cover = KugouClient.string(row["imgurl"]) ?? ""
                // singer/list 的 imgurl 是模板：http://singerimg.kugou.com/uploadpic/softhead/{size}/xxx.jpg
                // {size} 需要换成实际尺寸（200 足够手机上圆形头像用）
                if cover.contains("{size}") { cover = cover.replacingOccurrences(of: "{size}", with: "200") }
                if cover.hasPrefix("http://") {
                    cover = "https://" + cover.dropFirst("http://".count)
                }
                let fans = KugouClient.intValue(row["fanscount"]) ?? 0
                result.append(Artist(id: id, name: name,
                                     coverURL: URL(string: cover),
                                     fansCount: fans))
                if result.count >= count { return result }
            }
            if rows.count < 20 { break }
        }
        return result
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
        // 酷狗榜单每页固定 22 首（日志里 TOP500 也是每页 22 首），
        // 翻到每页返回空或 rows.count < 22 就停。
        var allRows: [[String: Any]] = []
        var page = 1
        let maxPages = 25 // 安全上限：TOP500 翻 23 页，其他榜单远少于此
        while allRows.count < limit && page <= maxPages {
            let urlPath = "/yy/rank/home/\(page)-\(numericID).html"
            let html: String
            do {
                html = try await getRaw(path: urlPath,
                                        host: "https://www.kugou.com",
                                        params: [:],
                                        headers: [:])
            } catch {
                Log.warn("榜单", "rankid=\(numericID) 翻到第 \(page) 页失败：\(error.localizedDescription)")
                break
            }
            guard let rows = Self.javascriptArray(named: "global.features", in: html), !rows.isEmpty else {
                Log.info("榜单", "rankid=\(numericID) 第 \(page) 页返回空，停止翻页")
                break
            }
            allRows.append(contentsOf: rows)
            if rows.count < 22 { break } // 最后一页不满，停止
            page += 1
        }
        let songs = Array(allRows.compactMap { Song(kugouJSON: $0) }.prefix(limit))
        Log.info("榜单", "rankid=\(numericID) 解析到 \(allRows.count) 条记录（翻了 \(page-1) 页） -> \(songs.count) 首歌")
        if songs.isEmpty {
            Log.error("榜单", "rankid=\(numericID) 有 \(allRows.count) 条记录但一首歌都没解析出来，字段名可能又变了")
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

    // MARK: 移动端页面解析（整页兜底方案）

    /// 从 m.kugou.com 移动端歌单页解析歌曲。
    ///
    /// 页面里每首歌（以及每组播放块）以 `dataobj='[...]'` 属性内嵌 HTML 实体
    /// 编码的 JSON。解码后括号配平扫描，去重输出。
    static func songs(fromSpecialMobileHTML html: String) -> [Song] {
        let decoded = html
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        var songs: [Song] = []
        var seen = Set<String>()
        let marker = "dataobj='"
        var searchFrom = decoded.startIndex
        while let blockRange = decoded.range(of: marker, range: searchFrom..<decoded.endIndex),
              let arrayEnd = endOfJSONArray(in: decoded, from: blockRange.upperBound) {
            let jsonText = String(decoded[blockRange.upperBound..<arrayEnd])
            if let rows = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [[String: Any]] {
                for row in rows {
                    if let song = Song(kugouJSON: row), !seen.contains(song.id) {
                        seen.insert(song.id)
                        songs.append(song)
                    }
                }
            }
            searchFrom = arrayEnd
        }
        return songs
    }

    /// 从 `[` 开始（或之前）括号配平扫描，返回闭 `]` 的后一个位置。
    /// 跳过双引号字符串与反斜杠转义。
    private static func endOfJSONArray(in text: String, from start: String.Index) -> String.Index? {
        guard let bracket = text.range(of: "[", range: start..<text.endIndex) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = bracket.lowerBound
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == "[" { depth += 1 }
                else if ch == "]" {
                    depth -= 1
                    if depth == 0 { return text.index(after: index) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 从 www.kugou.com 歌手索引页解析热门歌手：
    /// `<a title="周杰伦" class='pic' href=".../singer/info/<id>/"><img ... _src='<头像>' />`
    static func artists(fromSingerIndexHTML html: String) -> [Artist] {
        let pattern = #"(?s)<a\s+title="([^"]+)"\s+class='pic'[^>]*href="[^"]*singer/info/([^"/]+)/"[^>]*>.*?_src='([^']*)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var artists: [Artist] = []
        var seen = Set<String>()
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges >= 3,
                  let nameR = Range(match.range(at: 1), in: html),
                  let idR = Range(match.range(at: 2), in: html) else { return }
            let name = String(html[nameR])
            let id = String(html[idR])
            guard !seen.contains(id) else { return }
            seen.insert(id)
            var cover: URL?
            if match.numberOfRanges >= 4, let imgR = Range(match.range(at: 3), in: html) {
                var raw = String(html[imgR])
                if raw.hasPrefix("http://") {
                    raw = "https://" + raw.dropFirst("http://".count)
                }
                cover = URL(string: raw)
            }
            artists.append(Artist(id: id, name: name, coverURL: cover))
        }
        return artists
    }

    private func getJSON(path: String,
                         host: String,
                         params: [String: String],
                         headers: [String: String]) async throws -> [String: Any] {
        let raw = try await getRaw(path: path, host: host, params: params, headers: headers)
        // 酷狗在 /api/v3/search/song 等接口前面塞 <!--KG_TAG_RES_START--> 注释，
        // JSONSerialization 直接炸。先 try 原样 parse，失败再暴力清掉所有 HTML 注释前缀。
        var candidates: [String] = [raw]
        if (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) == nil {
            // 清掉 <!--...--> 前缀（可能多个），直到 parse 成功
            var s = raw
            var tried = Set<String>()
            tried.insert(s)
            for _ in 0..<5 {
                // 干掉所有 <!--...--> 注释（不管在开头还是中间）
                s = s.replacingOccurrences(of: #"<!--[^>]*-->"#, with: "", options: .regularExpression)
                if tried.contains(s) { break }
                tried.insert(s)
                candidates.append(s)
                // 也试一下只保留第一个 { 之后的部分
                if let idx = s.range(of: "{")?.lowerBound {
                    let fromBrace = String(s[idx...])
                    if !tried.contains(fromBrace) {
                        tried.insert(fromBrace)
                        candidates.append(fromBrace)
                    }
                }
            }
        }

        for s in candidates {
            if let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                return obj
            }
        }
        Log.error("网络", "JSON 解析失败，前 200 字符：\(String(raw.prefix(200)))")
        Log.error("网络", "字节数=\(raw.utf8.count) hasBOM=\(raw.first == "\u{FEFF}")")
        throw KugouError.decoding
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
        if host.contains("kugou.com") && !path.contains("rank") && !path.isEmpty {
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

    // MARK: - 酷狗扫码登录 API

    private let loginBase = "https://login-user.kugou.com"
    // 🔴 必须用 Beans 的 appid，1005/20308 拉不到二维码
    private let qrAppid = "1001"
    private let qrSrcAppid = "2919"

    struct QRLogin: Equatable {
        let key: String
        let url: String
    }

    enum QRState: Equatable {
        case waiting       // 等待扫码
        case scanned       // 已扫码等确认
        case expired       // 二维码过期
        case success(String) // 成功，参数=昵称
        case error(String)  // 错误信息
    }

    /// 生成登录二维码的 key 和扫码 URL
    func qrKey() async throws -> QRLogin {
        let qrcodeText = "https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=\(qrAppid)"
        let params = [
            "appid": qrAppid,
            "type": "1",
            "plat": "4",
            "qrcode_txt": qrcodeText,
            "srcappid": qrSrcAppid,
        ]
        Log.info("酷狗登录", "qrKey 请求 appid=\(qrAppid) srcappid=\(qrSrcAppid)")
        let raw = try await getRaw(path: "/v2/qrcode",
                                    host: loginBase,
                                    params: params,
                                    headers: [
                                        "x-router": "login-user.kugou.com",
                                        "User-Agent": browserUA,
                                    ])
        let json = Self.extractJSONP(raw) ?? (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
        Log.info("酷狗登录", "qrKey 响应 raw=\(String(raw.prefix(400)))")
        // key 在 qrcode.key 或 data.qrcode.key
        let key = Self.deepString(json, path: ["qrcode", "key"]) ?? Self.deepString(json, path: ["data", "qrcode", "key"]) ?? ""
        guard !key.isEmpty else {
            Log.error("酷狗登录", "qrKey 解析失败 json=\(json)")
            throw KugouError.parse("二维码生成失败（key 为空）")
        }
        let url = "https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=\(Self.urlEncode(key))"
        Log.info("酷狗登录", "QR key=\(key.prefix(12))...")
        return QRLogin(key: key, url: url)
    }

    /// 轮询二维码扫描状态
    func pollQR(key: String) async throws -> QRState {
        let params = [
            "plat": "4",
            "appid": qrAppid,
            "srcappid": qrSrcAppid,
            "qrcode": key,
        ]
        let raw = try await getRaw(path: "/v2/get_userinfo_qrcode",
                                    host: loginBase,
                                    params: params,
                                    headers: [
                                        "x-router": "login-user.kugou.com",
                                        "User-Agent": browserUA,
                                    ])
        let json = Self.extractJSONP(raw) ?? (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
        Log.info("酷狗登录", "pollQR 响应 raw=\(String(raw.prefix(300)))")

        let status = Self.deepInt(json, path: ["status"]) ?? Self.deepInt(json, path: ["data", "status"]) ?? 0
        let token = Self.deepString(json, path: ["token"]) ?? Self.deepString(json, path: ["user_token"]) ?? Self.deepString(json, path: ["data", "token"]) ?? ""
        let userId = Self.deepString(json, path: ["userid"]) ?? Self.deepString(json, path: ["data", "userid"]) ?? ""

        switch status {
        case 3: return .expired
        case 2: return .scanned
        default: break
        }
        guard !token.isEmpty, !userId.isEmpty else {
            return .waiting
        }

        let nick = Self.deepString(json, path: ["nickname"]) ?? Self.deepString(json, path: ["data", "nickname"]) ?? ""
        let avatar = Self.deepString(json, path: ["avatar"]) ?? Self.deepString(json, path: ["data", "avatar"]) ?? ""
        let vip = Self.deepInt(json, path: ["vip_type"]) ?? Self.deepInt(json, path: ["data", "vip_type"]) ?? 0

        KugouAuth.shared.saveLogin(userId: userId, token: token, nickname: nick, avatar: avatar, vipType: vip)
        let displayName = nick.isEmpty ? "酷狗音乐用户 \(userId)" : nick
        Log.info("酷狗登录", "成功 user=\(displayName)")
        return .success(displayName)
    }

    // MARK: - 酷狗歌单同步

    struct KugouPlaylist: Identifiable {
        let id: String          // listid
        let name: String
        var songs: [Song]       // 歌单里的歌曲
    }

    /// 拉取当前登录用户的所有歌单
    func userPlaylists() async throws -> [KugouPlaylist] {
        guard KugouAuth.shared.isLoggedIn else { return [] }
        let userId = KugouAuth.shared.userId
        let token = KugouAuth.shared.token

        let allItems: [[String: Any]] = try await fetchAllPages(
            basePath: "/v7/get_all_list",
            host: "https://gateway.kugou.com",
            pageSize: 200,
            extractItems: { json in
                Self.deepArray(json, path: ["lists"]) ?? Self.deepArray(json, path: ["data", "lists"]) ?? []
            }
        ) { page in
            [
                "total_ver": "979",
                "type": "2",
                "page": "\(page)",
                "pagesize": "200",
                "userid": userId,
                "token": token,
            ]
        }

        var playlists: [KugouPlaylist] = []
        for item in allItems {
            guard let listid = Self.string(item["listid"]) ?? Self.string(item["list_id"]) ?? Self.string(item["id"]) else { continue }
            let name = Self.string(item["listname"]) ?? Self.string(item["name"]) ?? "未命名歌单"
            playlists.append(KugouPlaylist(id: listid, name: name, songs: []))
        }
        Log.info("酷狗", "拉到 \(playlists.count) 个云端歌单")
        return playlists
    }

    /// 把当前歌曲保存到指定酷狗歌单
    func addCurrentSongToPlaylist(_ listid: String, song: Song) async throws {
        guard KugouAuth.shared.isLoggedIn else { throw KugouError.parse("请先登录酷狗") }
        let userId = KugouAuth.shared.userId
        let token = KugouAuth.shared.token

        let params = [
            "listid": listid,
            "userid": userId,
            "token": token,
            "resource_id": song.kugouHash,
            "source": "1",
        ]
        let _ = try await getRaw(path: "/v5/add_song_to_list",
                                  host: "https://gateway.kugou.com",
                                  params: params,
                                  headers: ["x-router": "cloudlist.service.kugou.com"])
        Log.info("酷狗", "歌曲已保存到歌单 \(listid)")
    }

    // MARK: - 深值提取工具（简化版，支持 a.b.c 路径链式取值）

    static func deepString(_ json: [String: Any], path: [String]) -> String? {
        var current: Any? = json
        for key in path {
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else {
                return nil
            }
        }
        if let s = current as? String, !s.isEmpty { return s }
        if let n = current as? NSNumber { return n.stringValue }
        return nil
    }

    static func deepInt(_ json: [String: Any], path: [String]) -> Int? {
        var current: Any? = json
        for key in path {
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else {
                return nil
            }
        }
        if let i = current as? Int { return i }
        if let n = current as? NSNumber { return n.intValue }
        if let s = current as? String { return Int(s) }
        return nil
    }

    static func deepArray(_ json: [String: Any], path: [String]) -> [[String: Any]]? {
        var current: Any? = json
        for key in path {
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else {
                return nil
            }
        }
        return current as? [[String: Any]]
    }

    private static func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// 通用分页拉取工具 —— 直到返回数组少于 pageSize
    private func fetchAllPages(basePath: String,
                                host: String,
                                pageSize: Int,
                                extractItems: @escaping ([String: Any]) -> [[String: Any]],
                                paramsForPage: @escaping (Int) -> [String: String]) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        for page in 1...50 {
            let params = paramsForPage(page)
            let raw = try await getRaw(path: basePath, host: host, params: params, headers: [:] as [String: String])
            let json = Self.extractJSONP(raw) ?? (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:] as [String: Any]
            let items = extractItems(json)
            all.append(contentsOf: items)
            if items.count < pageSize { break }
        }
        return all
    }
}

enum KugouError: LocalizedError {
    case badURL
    case httpStatus(Int)
    case decoding
    case parse(String)
    case playlistNotFound(String)
    case playlistEmpty(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "请求地址无效"
        case .httpStatus(let code): return "酷狗接口返回 \(code)"
        case .decoding: return "酷狗返回的数据解析失败"
        case .parse(let detail): return detail
        case .playlistNotFound(let id): return "歌单 \(id) 不存在或已被酷狗删除"
        case .playlistEmpty(let id): return "歌单 \(id) 是空歌单或私有歌单（需要登录酷狗才能导入）"
        }
    }
}
