import SwiftUI

struct Song: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var artist: String
    var url: URL?
    var duration: Double = 0
    var tags: [String] = ["原唱", "高音质", "标准"]
    var isLocal: Bool = false
    var artworkURL: URL?

    var subtitle: String { artist }

    static func == (lhs: Song, rhs: Song) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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

enum DemoLibrary {
    static let songs: [Song] = [
        Song(
            title: "有风无风皆自由",
            artist: "王一佳",
            url: URL(string: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3"),
            tags: ["原唱", "高音质", "标准", "音效"],
            duration: 372
        ),
        Song(
            title: "Cloud Nine",
            artist: "Aurora Fields",
            url: URL(string: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3"),
            tags: ["Hi-Res", "纯音乐"],
            duration: 402
        ),
        Song(
            title: "Night Drive",
            artist: "Retro Lane",
            url: URL(string: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3"),
            tags: ["标准", "伴唱"],
            duration: 331
        ),
        Song(
            title: "山海之间",
            artist: "云上乐队",
            url: URL(string: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-8.mp3"),
            tags: ["原唱", "视频"],
            duration: 289
        )
    ]

    static func lyrics(for song: Song) -> [LyricLine] {
        switch song.title {
        case "有风无风皆自由":
            return [
                LyricLine(time: 0, text: "有风 无风 皆自由"),
                LyricLine(time: 8, text: "行走人海中 做个某某某"),
                LyricLine(time: 15, text: "心若无所求"),
                LyricLine(time: 21, text: "有风无风皆自由"),
                LyricLine(time: 30, text: "路太长 弯太多"),
                LyricLine(time: 38, text: "尽头总会有出口"),
                LyricLine(time: 46, text: "把日子唱成歌"),
                LyricLine(time: 54, text: "走到哪 唱到哪"),
                LyricLine(time: 66, text: "有过 mist 也有过回头"),
                LyricLine(time: 74, text: "不为谁停留"),
                LyricLine(time: 82, text: "有风 无风 皆自由")
            ]
        case "Cloud Nine":
            return [
                LyricLine(time: 0, text: "轻快的云 落在耳畔"),
                LyricLine(time: 10, text: "风穿过 蓝色的晚"),
                LyricLine(time: 20, text: "Cloud nine, 慢慢飘"),
                LyricLine(time: 32, text: "灯亮着 等你回来")
            ]
        case "Night Drive":
            return [
                LyricLine(time: 0, text: "路灯拉长影子"),
                LyricLine(time: 9, text: "霓虹在雨里游泳"),
                LyricLine(time: 18, text: "Night drive 一直到天亮"),
                LyricLine(time: 30, text: "你说 明天见")
            ]
        default:
            return [
                LyricLine(time: 0, text: "越过山海 遇见你"),
                LyricLine(time: 10, text: "风里都是 你的呼吸"),
                LyricLine(time: 20, text: "不必言语"),
                LyricLine(time: 26, text: "有你在 就是的意义")
            ]
        }
    }
}
