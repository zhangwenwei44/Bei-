import Foundation

/// 歌单。酷狗这边在线的是榜单，本地的是用户自建歌单。
struct Playlist: Identifiable, Hashable {
    var id: String
    var name: String
    var coverURL: URL?
    var trackCount: Int
    var creatorName: String = ""
    var source: SongSource = .kugou
    /// 酷狗榜单 ID（`kg-rank:` 前缀的条目用）。
    var kugouRankID: String?
    var updateFrequency: String = ""

    init(id: String, name: String, coverURL: URL?, trackCount: Int,
         creatorName: String = "", source: SongSource = .kugou,
         kugouRankID: String? = nil, updateFrequency: String = "") {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.trackCount = trackCount
        self.creatorName = creatorName
        self.source = source
        self.kugouRankID = kugouRankID
        self.updateFrequency = updateFrequency
    }
}

/// 歌手。酷狗的搜索结果里没有独立歌手实体，歌手页用搜索代替。
struct Artist: Identifiable, Hashable {
    var id: String
    var name: String
    var coverURL: URL?
    var source: SongSource = .kugou

    init(id: String, name: String, coverURL: URL? = nil, source: SongSource = .kugou) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.source = source
    }
}

/// 专辑。酷狗搜索结果里没有独立专辑实体，从歌曲的专辑名聚合。
struct Album: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var artist: String
    var coverURL: URL?
    var albumID: String = ""

    init(id: String, name: String, artist: String, coverURL: URL? = nil, albumID: String = "") {
        self.id = id
        self.name = name
        self.artist = artist
        self.coverURL = coverURL
        self.albumID = albumID
    }
}

/// 搜索结果聚合。
struct SearchResults {
    var songs: [Song] = []
    var playlists: [Playlist] = []
    var artists: [Artist] = []
    var albums: [Album] = []

    var isEmpty: Bool { songs.isEmpty && playlists.isEmpty && artists.isEmpty && albums.isEmpty }
}

/// 首页聚合数据。
struct DiscoverFeed {
    var topLists: [Playlist] = []

    var isEmpty: Bool { topLists.isEmpty }
}

// MARK: - 酷狗 JSON 解析

extension Song {
    /// 封面回退键。`kg:<hash>` 命中详情页反查登记，`al:<专辑id>` 交给
    /// CoverResolver 联网按专辑补图（榜单歌曲节点不带图，只有专辑 id）。
    var coverFallbackKeys: [String] {
        var keys: [String] = []
        if !kugouHash.isEmpty { keys.append("kg:\(kugouHash)") }
        if !kugouAlbumID.isEmpty { keys.append("al:\(kugouAlbumID)") }
        return keys
    }

    /// 解析酷狗歌曲节点。搜索、榜单共用一套解析。
    ///
    /// 不同接口字段名不一样，都在这里兜住：
    /// - 搜索 / v3：`FileHash`、`Duration`(秒)、`SingerName`、`AlbumName`、`Image`
    /// - 榜单页 `global.features`：`Hash`、`timeLen`(秒)、`author_name`、`album_id`
    ///
    /// 另外搜索结果的歌名 / 歌手名带 `<em>` 高亮标签，必须剥掉，
    /// 否则播放页会直接显示 `<em>周杰伦</em>`。
    init?(kugouJSON json: [String: Any]) {
        let hash = KugouClient.string(json["FileHash"])
            ?? KugouClient.string(json["Hash"])
            ?? KugouClient.string(json["hash"])
            ?? ""
        guard !hash.isEmpty else { return nil }

        // 优先用 songname / singername（搜索接口直接分开），其次才用 FileName 或 filename（可能带歌手名拼接）
        let songName = KugouClient.string(json["songname"])
            ?? KugouClient.string(json["SongName"])
            ?? ""
        let rawName = KugouClient.string(json["FileName"])
            ?? KugouClient.string(json["filename"])
            ?? ""
        let titleRaw = !songName.isEmpty ? songName : rawName
        let title = Song.stripHighlight(titleRaw)
        guard !title.isEmpty else { return nil }

        let rawArtist = KugouClient.string(json["singername"])
            ?? KugouClient.string(json["SingerName"])
            ?? KugouClient.string(json["author_name"])
            ?? KugouClient.string(json["Singer"])
            ?? ""
        let artist = Song.stripHighlight(rawArtist)
        let album = Song.stripHighlight(
            KugouClient.string(json["album_name"])
                ?? KugouClient.string(json["AlbumName"])
                ?? ""
        )

        var cover: URL?
        // 酷狗各接口可能的封面字段
        let coverKeys = ["Image", "AlbumImage", "img", "Img", "album_img", "pic",
                    "cover", "image_url", "thumb", "icon", "album_image",
                    "album_pic", "pic_url", "pic_medium", "pic_small", "pic_big",
                    "pic_slarge", "pic_xlarge", "pic_xxlarge", "AlbumImg", "song_img",
                    "albumImg", "cover_url", "Cover", "coverImg",
                    "album_sizable_cover", "album_sizable_cover_1"]
        for key in coverKeys {
            if let raw = KugouClient.string(json[key]), !raw.isEmpty {
                let fixed = raw.replacingOccurrences(of: "{si}", with: "300")
                    .replacingOccurrences(of: "{size}", with: "300")
                    .replacingOccurrences(of: "{sizetype}", with: "4")
                let finalURL: String
                if fixed.hasPrefix("//") {
                    finalURL = "https:" + fixed
                } else if fixed.hasPrefix("http://") {
                    finalURL = fixed.replacingOccurrences(of: "http://", with: "https://")
                } else {
                    finalURL = fixed
                }
                if let u = URL(string: finalURL) {
                    cover = u
                    break
                }
            }
        }
        // special/song 等接口把封面塞在 trans_param.union_cover 里
        if cover == nil, let trans = json["trans_param"] as? [String: Any] {
            for key in ["union_cover", "union_cover_url"] {
                if let raw = KugouClient.string(trans[key]), !raw.isEmpty {
                    let fixed = raw.replacingOccurrences(of: "{size}", with: "300")
                    let finalURL = fixed.hasPrefix("http://")
                        ? fixed.replacingOccurrences(of: "http://", with: "https://")
                        : fixed
                    if let u = URL(string: finalURL) { cover = u; break }
                }
            }
        }
        // 如果还没命中，打印全部 key 帮助排查
        if cover == nil {
            Log.debug("Catalog", "封面未命中! 全部keys: \(json.keys.sorted())")
            // 尝试 album 嵌套
            if let album = json["album"] as? [String: Any] {
                Log.debug("Catalog", "album子keys: \(album.keys.sorted())")
                for key in coverKeys {
                    if let raw = KugouClient.string(album[key]), !raw.isEmpty {
                        let fixed = raw.replacingOccurrences(of: "{si}", with: "300")
                            .replacingOccurrences(of: "{size}", with: "300")
                        let finalURL = fixed.hasPrefix("//") ? "https:" + fixed : fixed
                        if let u = URL(string: finalURL) { cover = u; break }
                    }
                }
            }
        }

        var duration: Double = 0
        if let seconds = KugouClient.intValue(json["Duration"]) ?? KugouClient.intValue(json["timeLen"]) {
            duration = Double(seconds)
        }
        // 新搜索接口的 duration 是秒（如254），老接口可能是毫秒（如254000）
        if duration == 0, let raw = KugouClient.intValue(json["duration"]) {
            duration = raw > 10_000 ? Double(raw) / 1000.0 : Double(raw)
        }

        var tags: [String] = []
        let payType = KugouClient.intValue(json["PayType"])
            ?? KugouClient.intValue(json["pay_type"])
            ?? 0
        if payType > 0 { tags.append("VIP") }
        let ext = KugouClient.string(json["ExtName"])
            ?? KugouClient.string(json["extname"])
        if let ext, !ext.isEmpty { tags.append(ext.uppercased()) }
        let isOriginal = KugouClient.intValue(json["IsOriginal"])
            ?? KugouClient.intValue(json["isnew"])
            ?? 0
        if isOriginal == 1 { tags.append("原唱") }

        self.init(id: "kg:\(hash)",
                  title: title,
                  artist: artist.isEmpty ? "未知歌手" : artist,
                  album: album,
                  tags: tags,
                  duration: duration,
                  artworkURL: cover,
                  source: .kugou,
                  kugouHash: hash,
                  kugouAudioID: KugouClient.string(json["album_audio_id"])
                      ?? KugouClient.string(json["Audioid"])
                      ?? KugouClient.string(json["audioid"])
                      ?? "",
                  kugouAlbumID: KugouClient.string(json["album_id"])
                      ?? KugouClient.string(json["AlbumID"])
                      ?? KugouClient.string(json["albumId"])
                      ?? "")
    }

    /// 剥掉酷狗搜索结果里的 `<em>` 高亮标签。
    static func stripHighlight(_ text: String) -> String {
        guard text.contains("<") else { return text.trimmingCharacters(in: .whitespaces) }
        var out = ""
        var inside = false
        for ch in text {
            if ch == "<" { inside = true; continue }
            if ch == ">" { inside = false; continue }
            if !inside { out.append(ch) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

extension Playlist {
    init?(kugouJSON json: [String: Any]) {
        guard let rankID = KugouClient.string(json["rankid"]) ?? KugouClient.string(json["id"]),
              !rankID.isEmpty else { return nil }
        let name = KugouClient.string(json["rankname"]) ?? "榜单"
        var cover = KugouClient.string(json["img9"]) ?? KugouClient.string(json["imgurl"])
        if let raw = cover {
            cover = raw.replacingOccurrences(of: "{si}", with: "300")
                .replacingOccurrences(of: "{size}", with: "300")
        }
        self.init(id: "kg-rank:\(rankID)",
                  name: name,
                  coverURL: cover.flatMap { URL(string: $0) },
                  trackCount: KugouClient.intValue(json["songcount"]) ?? 0,
                  creatorName: "酷狗音乐",
                  source: .kugou,
                  kugouRankID: rankID,
                  updateFrequency: KugouClient.string(json["update_frequency"]) ?? "")
    }
}
