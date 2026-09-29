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
struct Album: Identifiable, Hashable {
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
            ?? ""
        guard !hash.isEmpty else { return nil }

        let rawName = KugouClient.string(json["FileName"]) ?? ""
        let title = Song.stripHighlight(rawName)
        guard !title.isEmpty else { return nil }

        let artist = Song.stripHighlight(
            KugouClient.string(json["SingerName"])
                ?? KugouClient.string(json["author_name"])
                ?? KugouClient.string(json["Singer"])
                ?? ""
        )
        let album = Song.stripHighlight(KugouClient.string(json["AlbumName"]) ?? "")

        var cover: URL?
        for key in ["Image", "AlbumImage", "img", "Img"] {
            if let raw = KugouClient.string(json[key]), !raw.isEmpty {
                // 酷狗封面地址里有 {size} 占位
                let fixed = raw.replacingOccurrences(of: "{si}", with: "300")
                    .replacingOccurrences(of: "{size}", with: "300")
                cover = URL(string: fixed)
                if cover != nil { break }
            }
        }

        var duration: Double = 0
        if let seconds = KugouClient.intValue(json["Duration"]) ?? KugouClient.intValue(json["timeLen"]) {
            duration = Double(seconds)
        }
        if duration == 0, let ms = KugouClient.intValue(json["duration"]) { duration = Double(ms) / 1000 }

        var tags: [String] = []
        if let payType = KugouClient.intValue(json["PayType"]), payType > 0 { tags.append("VIP") }
        if let ext = KugouClient.string(json["ExtName"]), !ext.isEmpty { tags.append(ext.uppercased()) }
        if let isOriginal = KugouClient.intValue(json["IsOriginal"]), isOriginal == 1 { tags.append("原唱") }

        self.init(id: "kg:\(hash)",
                  title: title,
                  artist: artist.isEmpty ? "未知歌手" : artist,
                  album: album,
                  tags: tags,
                  duration: duration,
                  artworkURL: cover,
                  source: .kugou,
                  kugouHash: hash,
                  kugouAudioID: KugouClient.string(json["Audioid"])
                      ?? KugouClient.string(json["audioid"])
                      ?? "",
                  kugouAlbumID: KugouClient.string(json["AlbumID"])
                      ?? KugouClient.string(json["album_id"])
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
