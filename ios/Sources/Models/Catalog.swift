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

/// 搜索结果聚合。
struct SearchResults {
    var songs: [Song] = []
    var playlists: [Playlist] = []
    var artists: [Artist] = []

    var isEmpty: Bool { songs.isEmpty && playlists.isEmpty && artists.isEmpty }
}

/// 首页聚合数据。
struct DiscoverFeed {
    var topLists: [Playlist] = []

    var isEmpty: Bool { topLists.isEmpty }
}

// MARK: - 酷狗 JSON 解析

extension Song {
    /// 解析酷狗歌曲节点。搜索、榜单共用同一套字段。
    ///
    /// 关键字段：`FileHash`（音频标识）、`FileName`（带 `<em>` 高亮标签，要剥掉）、
    /// `SingerName`、`AlbumName`、`Duration`（秒）、`Image` / `AlbumImage`（封面）。
    init?(kugouJSON json: [String: Any]) {
        let hash = KugouClient.string(json["FileHash"]) ?? KugouClient.string(json["hash"]) ?? ""
        guard !hash.isEmpty else { return nil }

        let rawName = KugouClient.string(json["FileName"])
            ?? KugouClient.string(json["SongName"])
            ?? ""
        let title = Self.stripHighlight(rawName)
        guard !title.isEmpty else { return nil }

        let artist = KugouClient.string(json["SingerName"])
            ?? KugouClient.string(json["Singer"])
            ?? "未知歌手"
        let album = KugouClient.string(json["AlbumName"]) ?? ""

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
        if let seconds = KugouClient.intValue(json["Duration"]) { duration = Double(seconds) }
        if duration == 0, let ms = KugouClient.intValue(json["duration"]) { duration = Double(ms) / 1000 }

        var tags: [String] = []
        if let payType = KugouClient.intValue(json["PayType"]), payType > 0 { tags.append("VIP") }
        if let ext = KugouClient.string(json["ExtName"]), !ext.isEmpty { tags.append(ext.uppercased()) }
        if let isOriginal = KugouClient.intValue(json["IsOriginal"]), isOriginal == 1 { tags.append("原唱") }

        self.init(id: "kg:\(hash)",
                  title: title,
                  artist: artist,
                  album: album,
                  tags: tags,
                  duration: duration,
                  artworkURL: cover,
                  source: .kugou,
                  kugouHash: hash,
                  kugouAudioID: KugouClient.string(json["Audioid"]) ?? KugouClient.string(json["audioid"]) ?? "",
                  kugouAlbumID: KugouClient.string(json["AlbumID"]) ?? KugouClient.string(json["album_id"]) ?? "")
    }

    /// 酷狗搜索结果的歌名带 `<em>` 高亮标签。
    static func stripHighlight(_ text: String) -> String {
        guard text.contains("<") else { return text }
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
