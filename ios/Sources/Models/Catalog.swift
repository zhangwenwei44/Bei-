import Foundation

/// 歌单（网易云 playlist / toplist）。
struct Playlist: Identifiable, Hashable {
    var id: String
    var name: String
    var coverURL: URL?
    var trackCount: Int
    var creatorName: String = ""
    var source: SongSource = .netease
    var neteaseID: Int?
    /// 榜单的更新时间文案。
    var updateFrequency: String = ""

    init(id: String, name: String, coverURL: URL?, trackCount: Int,
         creatorName: String = "", source: SongSource = .netease,
         neteaseID: Int? = nil, updateFrequency: String = "") {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.trackCount = trackCount
        self.creatorName = creatorName
        self.source = source
        self.neteaseID = neteaseID
        self.updateFrequency = updateFrequency
    }
}

/// 歌手。
struct Artist: Identifiable, Hashable {
    var id: String
    var name: String
    var coverURL: URL?
    var source: SongSource = .netease
    var neteaseID: Int?
    var albumCount: Int?

    init(id: String, name: String, coverURL: URL? = nil,
         source: SongSource = .netease, neteaseID: Int? = nil,
         albumCount: Int? = nil) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.source = source
        self.neteaseID = neteaseID
        self.albumCount = albumCount
    }
}

/// 专辑。
struct Album: Identifiable, Hashable {
    var id: String
    var name: String
    var artistName: String
    var coverURL: URL?
    var source: SongSource = .netease
    var neteaseID: Int?
    var trackCount: Int?

    init(id: String, name: String, artistName: String, coverURL: URL? = nil,
         source: SongSource = .netease, neteaseID: Int? = nil, trackCount: Int? = nil) {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.coverURL = coverURL
        self.source = source
        self.neteaseID = neteaseID
        self.trackCount = trackCount
    }
}

/// 搜索结果聚合。
struct SearchResults {
    var songs: [Song] = []
    var playlists: [Playlist] = []
    var artists: [Artist] = []
    var albums: [Album] = []

    var isEmpty: Bool {
        songs.isEmpty && playlists.isEmpty && artists.isEmpty && albums.isEmpty
    }
}

/// 首页聚合数据。
struct DiscoverFeed {
    var hotSearch: [String] = []
    var recommendedPlaylists: [Playlist] = []
    var topLists: [Playlist] = []
    var newSongs: [Song] = []

    var isEmpty: Bool {
        hotSearch.isEmpty && recommendedPlaylists.isEmpty && topLists.isEmpty && newSongs.isEmpty
    }
}

// MARK: - JSON 解析

extension Song {
    /// 解析网易云歌曲节点。搜索、歌单、歌手、专辑共用同一套字段。
    init?(neteaseJSON json: [String: Any]) {
        guard let neteaseID = (json["id"] as? Int) ?? (json["id"] as? NSNumber)?.intValue,
              neteaseID > 0 else { return nil }

        let title = (json["name"] as? String) ?? "未知歌曲"
        let artists = ArtistName.parse(json["ar"] ?? json["artists"])
        let albumName = ((json["al"] as? [String: Any])?["name"] as? String)
            ?? ((json["album"] as? [String: Any])?["name"] as? String)
            ?? ""

        var cover: URL?
        if let pic = ((json["al"] as? [String: Any])?["picUrl"] as? String) ?? (json["album"] as? [String: Any])?["picUrl"] as? String,
           !pic.isEmpty {
            cover = URL(string: pic)
        }
        if cover == nil, let pic = json["picUrl"] as? String, !pic.isEmpty {
            cover = URL(string: pic)
        }

        let durationMS = (json["duration"] as? Int) ?? ((json["duration"] as? NSNumber)?.intValue) ?? 0
        let duration = durationMS > 0 ? Double(durationMS) / 1000 : 0

        self.init(id: "wy:\(neteaseID)",
                  title: title,
                  artist: artists.isEmpty ? "未知歌手" : artists,
                  album: albumName,
                  tags: Song.tagList(from: json),
                  duration: duration,
                  artworkURL: cover,
                  source: .netease,
                  neteaseID: neteaseID,
                  playCount: (json["playCount"] as? Int) ?? ((json["playCount"] as? NSNumber)?.intValue) ?? 0)
    }

    private static func tagList(from json: [String: Any]) -> [String] {
        var tags: [String] = []
        let privilege = json["privilege"] as? [String: Any]
        let fee = (privilege?["fee"] as? Int) ?? ((json["fee"] as? Int) ?? 0)
        if fee == 1 {
            tags.append("VIP")
        } else if (json["st"] as? Int) == -200 {
            tags.append("未开放")
        }
        if let modes = json["alia"] as? [String], !modes.isEmpty {
            tags.append("原唱")
        }
        if let publishTime = (json["publishTime"] as? NSNumber)?.intValue, publishTime > 1_600_000_000 {
            let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(publishTime / 1000)))
            tags.append("\(String(year))")
        }
        return tags
    }
}

extension Playlist {
    init?(neteaseJSON json: [String: Any]) {
        guard let neteaseID = (json["id"] as? Int) ?? ((json["id"] as? NSNumber)?.intValue), neteaseID > 0 else { return nil }
        let name = (json["name"] as? String) ?? "未命名歌单"
        var cover: URL?
        if let pic = json["coverImgUrl"] as? String, !pic.isEmpty {
            cover = URL(string: pic)
        } else if let pic = (json["picUrl"] as? String), !pic.isEmpty {
            cover = URL(string: pic)
        }
        self.init(id: "pl:\(neteaseID)",
                  name: name,
                  coverURL: cover,
                  trackCount: (json["trackCount"] as? Int) ?? ((json["trackCount"] as? NSNumber)?.intValue) ?? 0,
                  creatorName: (json["creator"] as? [String: Any])?["nickname"] as? String ?? "",
                  source: .netease,
                  neteaseID: neteaseID,
                  updateFrequency: (json["updateFrequency"] as? String) ?? "")
    }
}

extension Artist {
    init?(neteaseJSON json: [String: Any]) {
        guard let neteaseID = (json["id"] as? Int) ?? ((json["id"] as? NSNumber)?.intValue), neteaseID > 0 else { return nil }
        let pic = (json["picUrl"] as? String) ?? (json["img1v1Url"] as? String) ?? ""
        self.init(id: "ar:\(neteaseID)",
                  name: (json["name"] as? String) ?? "未知歌手",
                  coverURL: pic.isEmpty ? nil : URL(string: pic),
                  source: .netease,
                  neteaseID: neteaseID,
                  albumCount: (json["albumSize"] as? Int) ?? ((json["albumSize"] as? NSNumber)?.intValue))
    }
}

extension Album {
    init?(neteaseJSON json: [String: Any]) {
        guard let neteaseID = (json["id"] as? Int) ?? ((json["id"] as? NSNumber)?.intValue), neteaseID > 0 else { return nil }
        let pic = (json["picUrl"] as? String) ?? ""
        let artistName = ArtistName.parse(json["artist"] ?? json["artists"])
        self.init(id: "al:\(neteaseID)",
                  name: (json["name"] as? String) ?? "未知专辑",
                  artistName: artistName,
                  coverURL: pic.isEmpty ? nil : URL(string: pic),
                  source: .netease,
                  neteaseID: neteaseID,
                  trackCount: (json["size"] as? Int) ?? ((json["size"] as? NSNumber)?.intValue))
    }
}

/// `ar` / `artists` 节点解析成「歌手A、歌手B」。
enum ArtistName {
    static func parse(_ raw: Any?) -> String {
        guard let list = raw as? [[String: Any]] else {
            if let single = raw as? [String: Any] {
                return (single["name"] as? String) ?? ""
            }
            return ""
        }
        return list.compactMap { $0["name"] as? String }
            .filter { !$0.isEmpty }
            .joined(separator: "、")
    }
}
