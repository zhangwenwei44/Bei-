import Foundation

/// 解析结果。
struct ResolvedAudio: Equatable {
    var url: URL
    var sourceName: String
    var quality: MusicQuality
    /// 是否来自第三方音源。
    var isThirdParty: Bool

    static func == (lhs: ResolvedAudio, rhs: ResolvedAudio) -> Bool {
        lhs.url == rhs.url && lhs.sourceName == rhs.sourceName
    }
}

/// 播放地址解析：官方接口优先，拿不到（VIP / 无版权）时用用户配置的第三方音源。
///
/// 多个音源并发请求，谁先返回可用地址就用谁，避免慢源或失效源拖住播放。
enum SourceResolver {
    /// 解析一首歌的播放地址。
    ///
    /// ⚠️ v2.5.0 起永久强制走第三方 JS 脚本音源。原因：酷狗 gateway.kugou.com/v5/url
    /// 接口自 v1.3.0 起 errcode=20006，鉴权参数失效，直连每次切歌都白白发 3 次请求
    /// 再失败，用户多等 1 秒。第三方 JS 音源（长青 SVIP 等）稳定可用，直接跳过 officialURL。
    /// 酷狗榜单搜索 / lyrics / 封面下载（m.kugou.com / lyrics.kugou.com）保持原样不受影响。
    static func resolve(song: Song,
                        quality: MusicQuality,
                        excludedHosts: Set<String> = []) async -> ResolvedAudio? {
        // 本地文件直接用
        if song.isLocal, let url = song.url {
            return ResolvedAudio(url: url, sourceName: "本地文件", quality: quality, isThirdParty: false)
        }

        // ⛔️ 永久禁用官方 gateway v5/url —— errcode=20006 鉴权失效，不再白费请求
        // if let official = await officialURL(for: song, quality: quality) { return official }

        // 直接走第三方 JS 脚本音源（长青 SVIP 等）
        guard var result = await thirdPartyURL(for: song, quality: quality, excludedHosts: excludedHosts) else {
            return nil
        }

        // 脚本音源经常返回 http:// 明文地址 —— iOS ATS 会拒绝 http 直连音频流，
        // 先探测 https 可用就升级，避免播放时卡顿/中断
        if result.url.scheme == "http",
           let upgraded = await Self.upgradeToHTTPS(result.url) {
            result.url = upgraded
        }
        return result
    }

    /// 探测并升级 http:// → https:// —— 第三方音源脚本返回的 CDN 地址经常是明文 http，
    /// iOS ATS 会导致音频流被拒，表现为播放卡顿/stall。
    /// 只升级，不降级：如果 https 不可用（CDN 本身不支持），返回 nil 让调用方回退。
    private static func upgradeToHTTPS(_ url: URL) async -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http" else { return url }
        components.scheme = "https"
        guard let httpsURL = components.url else { return nil }
        // 轻量 HEAD 请求探测 https 端点是否可达（只拿 header，不下载 body）
        var request = URLRequest(url: httpsURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse,
           (200...399).contains(http.statusCode) {
            return httpsURL
        }
        return nil
    }

    // MARK: - 官方

    /// 直连酷狗。设备指纹过不了时返回 nil，自然落到第三方音源。
    private static func officialURL(for song: Song, quality: MusicQuality) async -> ResolvedAudio? {
        guard !song.kugouHash.isEmpty else { return nil }
        for level in quality.fallbackChain {
            let url = await KugouClient.shared.songURL(hash: song.kugouHash,
                                                       audioID: song.kugouAudioID.isEmpty ? nil : song.kugouAudioID,
                                                       albumID: song.kugouAlbumID.isEmpty ? nil : song.kugouAlbumID,
                                                       quality: level)
            guard let raw = url, let parsed = URL(string: raw), !raw.isEmpty else { continue }
            return ResolvedAudio(url: parsed, sourceName: "酷狗音乐", quality: level, isThirdParty: false)
        }
        return nil
    }

    // MARK: - 第三方

    static func thirdPartyURL(for song: Song,
                              quality: MusicQuality,
                              excludedHosts: Set<String>) async -> ResolvedAudio? {
        let all = SourceStore.shared.sources
        let enabled = SourceStore.shared.enabledSources
        // 音源到底是因为开关关掉还是本身不可用，这里一次说清楚。
        // 之前只打 enabledSources 的个数，看到「1 个音源」根本不知道另外两个去哪了。
        if enabled.count != all.count {
            let detail = all.map { source -> String in
                let reason = !source.enabled ? "已关闭"
                    : (!source.isUsable ? "不可用" : "可用")
                return "\(source.name)[\(reason)]"
            }.joined(separator: ", ")
            Log.info("音源解析", "音源状态：\(detail)")
        }
        return await thirdPartyURL(sources: enabled,
                                   song: song,
                                   quality: quality,
                                   excludedHosts: excludedHosts)
    }

    /// 用指定的音源列表解析，供「测试解析」在保存前验证草稿配置。
    static func thirdPartyURL(sources: [ThirdPartySource],
                              song: Song,
                              quality: MusicQuality,
                              excludedHosts: Set<String>) async -> ResolvedAudio? {
        let usable = sources.filter { canUse($0, song: song) }
        Log.info("音源解析", "「\(song.title)」共有 \(sources.count) 个音源，\(usable.count) 个可用于这首")
        if sources.count != usable.count {
            let skipped = sources.filter { !canUse($0, song: song) }.map(\.name)
            Log.warn("音源解析", "跳过：\(skipped.joined(separator: ", "))")
        }
        guard !usable.isEmpty else {
            Log.error("音源解析", "没有可用音源，「\(song.title)」无法解析播放地址")
            return nil
        }

        var seen = Set<String>()
        let candidates = usable.filter { seen.insert(fingerprint($0)).inserted }

        // 串行而不是并发：之前用 TaskGroup 同时跑所有音源，4 个 JavaScriptCore
        // 上下文一起解析同一首歌，内存和 CPU 峰值叠加，正是播放闪退的现场
        // （v1.4.4 日志停在「入口已识别」之后就断了）。
        // 串行后第一个成功的即返回，代价只是最坏情况多等几次超时。
        // 串行会叠加等待时间，所以再加一个总时限：超了就不再试后面的音源。
        let started = Date()
        let budget: TimeInterval = 20
        for (index, source) in candidates.enumerated() {
            if Task.isCancelled { return nil }
            if Date().timeIntervalSince(started) > budget {
                Log.warn("音源解析", "已用掉 \(Int(budget)) 秒解析预算，跳过剩余 \(candidates.count - index) 个音源")
                break
            }
            if let result = await resolve(source: source, song: song, quality: quality, excludedHosts: excludedHosts) {
                Log.info("音源解析", "「\(song.title)」由「\(result.sourceName)」解析成功")
                return result
            }
        }
        Log.error("音源解析", "\(candidates.count) 个音源都没能解析出「\(song.title)」的地址")
        return nil
    }

    private static func canUse(_ source: ThirdPartySource, song: Song) -> Bool {
        guard source.enabled, source.isUsable else { return false }
        if let code = source.providerCode, code != song.source.code { return false }
        return true
    }

    private static func resolve(source: ThirdPartySource,
                                song: Song,
                                quality: MusicQuality,
                                excludedHosts: Set<String>) async -> ResolvedAudio? {
        if source.isScript {
            return await ScriptSourceRunner.shared.resolve(source: source,
                                                            song: song,
                                                            quality: quality,
                                                            excludedHosts: excludedHosts)
        }
        return await resolveTemplate(source: source,
                                     song: song,
                                     quality: quality,
                                     excludedHosts: excludedHosts)
    }

    // MARK: 模板型

    private static func resolveTemplate(source: ThirdPartySource,
                                        song: Song,
                                        quality: MusicQuality,
                                        excludedHosts: Set<String>) async -> ResolvedAudio? {
        let keys = source.apiKeys
        let needsKey = source.requiresAPIKey
        guard !needsKey || !keys.isEmpty else { return nil }

        for level in qualityChain(for: source, preferred: quality) {
            let base = applyQualityPlaceholders(applyTemplate(source.template, song: song),
                                                quality: level.sourceValue)
            let candidates: [(url: String, key: String?)] = needsKey
                ? keys.map { (url: applyKeyPlaceholders(base, apiKey: $0), key: $0) }
                : [(url: base, key: nil)]

            for candidate in candidates {
                guard let url = URL(string: candidate.url) else { continue }
                if let audio = await fetch(url: url,
                                           source: source,
                                           apiKey: candidate.key,
                                           level: level,
                                           excludedHosts: excludedHosts) {
                    return audio
                }
            }
        }
        return nil
    }

    private static func fetch(url: URL,
                              source: ThirdPartySource,
                              apiKey: String?,
                              level: MusicQuality,
                              excludedHosts: Set<String>) async -> ResolvedAudio? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AuroraMusic/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(level.sourceValue, forHTTPHeaderField: "quality")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        let metaKeys: Set<String> = ["source", "quality", "qualities", "qualityOptions", "qualitys", "br", "level", "apiKey", "apiKeys", "apiKeyQuery"]
        for (key, value) in source.headers where !metaKeys.contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let code = responseCode(object), code != 0, code != 200 {
            return nil
        }
        // 有些服务直接返回纯文本的播放地址
        if let text = String(data: data, encoding: .utf8), text.hasPrefix("http") {
            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw = URL(string: candidate),
               let playable = playable(raw, excludedHosts: excludedHosts) {
                return ResolvedAudio(url: playable, sourceName: source.name, quality: level, isThirdParty: true)
            }
        }

        guard let raw = valueAtAnyPath(object, source.urlPath) as? String,
              !raw.isEmpty,
              let resolved = URL(string: raw) else { return nil }
        guard let playable = playable(resolved, excludedHosts: excludedHosts) else { return nil }

        return ResolvedAudio(url: playable, sourceName: source.name, quality: level, isThirdParty: true)
    }

    // MARK: - 模板变量

    private static func applyTemplate(_ template: String, song: Song) -> String {
        let songID = song.kugouHash.isEmpty ? song.id : song.kugouHash
        var result = template
        let replacements: [String: String] = [
            "{id}": songID,
            "{hash}": songID,
            "{songId}": songID,
            "{songid}": songID,
            "{songID}": songID,
            "{songmid}": songID,
            "{mid}": songID,
            "{copyrightId}": songID,
            "{album_id}": song.kugouAlbumID,
            "{albumId}": song.kugouAlbumID,
            "{audioid}": song.kugouAudioID,
            "{source}": song.source.code,
            "{name}": encode(song.title),
            "{keyword}": encode([song.title, song.artist].joined(separator: " ")),
            "{artist}": encode(song.artist),
            "{platform}": song.source.code,
        ]
        for (placeholder, value) in replacements {
            result = result.replacingOccurrences(of: placeholder, with: value)
        }
        return result
    }

    private static func applyKeyPlaceholders(_ template: String, apiKey: String) -> String {
        ["{apiKey}", "{apikey}", "{key}"].reduce(template) { result, placeholder in
            result.replacingOccurrences(of: placeholder, with: encode(apiKey))
        }
    }

    private static func applyQualityPlaceholders(_ template: String, quality: String) -> String {
        ["{quality}", "{br}", "{level}"].reduce(template) { result, placeholder in
            result.replacingOccurrences(of: placeholder, with: quality)
        }
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// 音质尝试顺序：用户偏好 → 音源默认 → 逐级降级。
    private static func qualityChain(for source: ThirdPartySource, preferred: MusicQuality) -> [MusicQuality] {
        var ordered: [MusicQuality] = []
        ordered.append(contentsOf: preferred.fallbackChain)
        if let declared = declaredQuality(source.quality) {
            ordered.append(contentsOf: declared.fallbackChain)
        }
        var seen = Set<String>()
        let filtered = ordered.filter { seen.insert($0.level).inserted }
        return filtered.isEmpty ? [.standard] : filtered
    }

    private static func declaredQuality(_ raw: String) -> MusicQuality? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "128k", "128", "standard": return .standard
        case "320k", "320", "higher", "exhigh": return .exHigh
        case "flac", "lossless": return .lossless
        default: return nil
        }
    }

    // MARK: - 响应处理

    private static func responseCode(_ object: [String: Any]) -> Int? {
        if let code = object["code"] as? Int { return code }
        if let code = object["code"] as? NSNumber { return code.intValue }
        if let code = object["code"] as? String { return Int(code) }
        return nil
    }

    private static func valueAtAnyPath(_ object: Any, _ paths: String) -> Any? {
        for path in paths.split(separator: "|") {
            if let value = valueAtPath(object, String(path)) { return value }
        }
        return nil
    }

    private static func valueAtPath(_ object: Any, _ path: String) -> Any? {
        var current: Any = object
        for key in path.split(separator: ".") {
            guard let dict = current as? [String: Any], let next = dict[String(key)] else { return nil }
            current = next
        }
        return current
    }

    /// 部分接口会返回不稳定的 QQ CDN 节点。这里按顺序返回候选节点，
    /// 跳过已失败的域名后取第一个——所以重试一次就会自动切到下一个节点。
    private static func playable(_ url: URL, excludedHosts: Set<String>) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        guard isQQHost(host) else { return excludedHosts.contains(host) ? nil : url }

        let alternates = [
            "isure6.ptqqmusic.gitv.tv",
            "isure.stream.qqmusic.qq.com",
            "dl.stream.qqmusic.qq.com",
            "ws.stream.qqmusic.qq.com",
            "streamoc.music.tc.qq.com",
        ]
        var seen = Set<String>()
        for candidate in ([host] + alternates) where seen.insert(candidate).inserted {
            if excludedHosts.contains(candidate) { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = candidate
            return components?.url ?? url
        }
        return nil
    }

    private static func isQQHost(_ host: String) -> Bool {
        host.contains("qq.com") || host.contains("qqmusic") || host.contains("ptqqmusic") || host.contains("gitv.tv")
    }

    /// 同一配置只留一个，避免并发请求同一个服务。指纹只在单次解析内使用。
    private static func fingerprint(_ source: ThirdPartySource) -> String {
        let headers = source.headers
            .filter { $0.key != "source" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "\(source.template)|\(source.urlPath)|\(headers)|\(source.quality)|\(source.script.count)|\(source.script.hashStable)"
    }
}

extension String {
    /// 与进程无关的稳定摘要（`hashValue` 每个进程加盐，不能用来标识配置）。
    var hashStable: String {
        var hash: UInt64 = 5381
        for byte in utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 16)
    }
}
