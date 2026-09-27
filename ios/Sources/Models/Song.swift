import Foundation

/// 歌曲来源平台。第三方音源解析按平台分派（wy / tx / kg）。
enum SongSource: String, Codable, CaseIterable, Identifiable, Hashable {
    case netease
    case local

    var id: String { rawValue }

    /// 供第三方音源脚本识别的平台代码。
    var code: String {
        switch self {
        case .netease: return "wy"
        case .local: return "local"
        }
    }

    var title: String {
        switch self {
        case .netease: return "网易云音乐"
        case .local: return "本地音频"
        }
    }
}

enum MusicQuality: String, Codable, CaseIterable, Identifiable {
    case standard, higher, exHigh, lossless, hires

    var id: String { rawValue }

    /// 网易云 level 参数。
    var level: String {
        switch self {
        case .standard: return "standard"
        case .higher: return "higher"
        case .exHigh: return "exhigh"
        case .lossless: return "lossless"
        case .hires: return "hires"
        }
    }

    /// 第三方音源模板的 {quality} 变量，用洛雪那套通用词汇。
    var sourceValue: String {
        switch self {
        case .standard: return "128k"
        case .higher: return "320k"
        case .exHigh: return "320k"
        case .lossless: return "flac"
        case .hires: return "flac24bit"
        }
    }

    /// 洛雪脚本在 musicInfo.types 里查自己支持哪些档位，这里给出候选全集。
    var lxTypes: [String] {
        switch self {
        case .standard: return ["128k"]
        case .higher: return ["128k", "320k"]
        case .exHigh: return ["128k", "320k", "flac"]
        case .lossless: return ["128k", "320k", "flac", "flac24bit"]
        case .hires: return ["128k", "320k", "flac", "flac24bit", "flac24bit_5_1", "aac", "ogg", "ape", "wav"]
        }
    }

    var title: String {
        switch self {
        case .standard: return "标准音质"
        case .higher: return "较高音质"
        case .exHigh: return "极高音质"
        case .lossless: return "无损音质"
        case .hires: return "Hi-Res"
        }
    }

    /// 降级链：高音质失败后依次向下尝试。
    var fallbackChain: [MusicQuality] {
        switch self {
        case .standard: return [.standard]
        case .higher: return [.higher, .standard]
        case .exHigh: return [.exHigh, .higher, .standard]
        case .lossless: return [.lossless, .exHigh, .higher, .standard]
        case .hires: return [.hires, .lossless, .exHigh, .higher, .standard]
        }
    }
}

struct Song: Identifiable, Hashable, Codable {
    /// 全局唯一：`wy:12345` / `local:文件名hash`
    var id: String
    var title: String
    var artist: String
    var album: String = ""
    /// 已解析好的播放地址（在线解析或本地文件）。
    var url: URL?
    var tags: [String] = []
    var isLocal: Bool = false
    var duration: Double = 0
    var artworkURL: URL?
    var source: SongSource = .netease
    /// 平台内 ID，第三方音源解析时使用。
    var neteaseID: Int?
    var playCount: Int = 0

    init(id: String? = nil,
         title: String,
         artist: String,
         album: String = "",
         url: URL? = nil,
         tags: [String] = [],
         isLocal: Bool = false,
         duration: Double = 0,
         artworkURL: URL? = nil,
         source: SongSource = .netease,
         neteaseID: Int? = nil,
         playCount: Int = 0) {
        self.id = id ?? (neteaseID.map { "\(source.code):\($0)" } ?? "\(source.code):\(UUID().uuidString)")
        self.title = title
        self.artist = artist
        self.album = album
        self.url = url
        self.tags = tags
        self.isLocal = isLocal
        self.duration = duration
        self.artworkURL = artworkURL
        self.source = source
        self.neteaseID = neteaseID
        self.playCount = playCount
    }

    static func == (lhs: Song, rhs: Song) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 是否可以交给在线接口解析（本地文件不走网络）。
    var isRemote: Bool { !isLocal && source != .local }

    /// 已下载到本地的文件位置（由 DownloadManager 维护）。
    static func localID(for path: String) -> String { "local:\(path)" }
}

enum PlaybackMode: Int, CaseIterable {
    case order, single, shuffle

    var title: String {
        switch self {
        case .order: return "列表循环"
        case .single: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }

    var icon: String {
        switch self {
        case .order: return "repeat"
        case .single: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }
}
