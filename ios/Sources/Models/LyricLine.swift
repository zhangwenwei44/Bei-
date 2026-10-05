import Foundation

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let time: Double
    let text: String
    /// 翻译歌词（部分音源会带），没有时为 nil。
    var translation: String?
}

enum LRCParser {
    private static let pattern: NSRegularExpression? = {
        let p = #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
        return try? NSRegularExpression(pattern: p)
    }()

    /// 词曲元数据关键词——这些行出现在歌词时间戳后面，但不是歌词正文。
    private static let metadataKeywords: Set<String> = [
        "词", "曲", "作曲", "编曲", "制作", "制作人", "演奏", "混音",
        "母带", "母", "监制", "出品", "发行", "和声", "配唱", "录音",
        "吉他", "钢琴", "贝斯", "鼓", "弦乐", "中阮", "编曲",
        "改编", "cover", "Cover", "词：", "曲：", "编曲：",
        "制作人：", "监制：", "录音：", "混音："
    ]

    static func parse(_ text: String) -> [LyricLine] {
        guard let pattern else { return [] }
        var result: [LyricLine] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // 时间戳与正文都要在「当前行」里取，不能用整篇文本的偏移。
            let ns = line as NSString
            let stamps = pattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let first = stamps.first else {
                // [ar:xxx] [ti:xxx] [hash:xxx] 这类 LRC 头部元数据不是歌词，
                // 跳过，不然播放页/歌词页会显示一排 [ar:...] 标签
                if line.hasPrefix("["), line.hasSuffix("]"),
                   let key = line.dropFirst().dropLast().split(separator: ":", maxSplits: 1).first,
                   !key.isEmpty, key.allSatisfy({ $0.isLetter }) {
                    continue
                }
                result.append(LyricLine(time: 0, text: line))
                continue
            }

            let contentStart = first.range.upperBound
            let content = ns.substring(from: contentStart).trimmingCharacters(in: .whitespaces)

            // time≈0 的行：正文如果以词曲元数据关键词开头，跳过——
            // 这些是创作人员信息（词：郑国江 / 曲：陈百强 等），不是歌词正文。
            let firstMin = Double(ns.substring(with: first.range(at: 1))) ?? 0
            let firstSec = Double(ns.substring(with: first.range(at: 2))) ?? 0
            if firstMin == 0, firstSec <= 1.5 {
                let lower = content.lowercased()
                if Self.metadataKeywords.contains(where: { kw in
                    let k = kw.lowercased()
                    return lower.hasPrefix(k + ":") || lower.hasPrefix(k + "：") || lower == k
                }) {
                    continue
                }
            }

            for stamp in stamps {
                let m = ns.substring(with: stamp.range(at: 1))
                let s = ns.substring(with: stamp.range(at: 2))
                var fraction = "0"
                if stamp.range(at: 3).location != NSNotFound,
                   let msRange = Range(stamp.range(at: 3), in: line) {
                    fraction = String(line[msRange])
                }

                let minutes = Double(m) ?? 0
                let seconds = Double(s) ?? 0
                let millis = Double(fraction.prefix(2).padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
                result.append(LyricLine(time: minutes * 60 + seconds + millis / 100,
                                        text: content.isEmpty ? "♪" : content))
            }
        }

        return result.sorted { $0.time < $1.time }
    }

    static func index(at time: Double, in lines: [LyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        var found: Int?
        for (index, line) in lines.enumerated() where line.time <= time + 0.25 {
            found = index
        }
        return found
    }

    /// 解析原文 + 翻译，按时间戳合并成一份歌词。
    static func parse(_ lrc: String, translation tlyric: String?) -> [LyricLine] {
        let base = parse(lrc)
        guard let tlyric, !tlyric.isEmpty else { return base }
        let translated = parse(tlyric)
        guard !translated.isEmpty else { return base }

        var result: [LyricLine] = []
        var cursor = 0
        for line in base {
            while cursor < translated.count, abs(translated[cursor].time - line.time) > 0.35 {
                cursor += 1
            }
            let match = cursor < translated.count && abs(translated[cursor].time - line.time) <= 0.35
                ? translated[cursor]
                : nil
            result.append(LyricLine(time: line.time,
                                    text: line.text,
                                    translation: match?.text))
        }
        return result
    }
}

extension Double {
    var clockString: String {
        guard isFinite, self >= 0 else { return "00:00" }
        let total = Int(self.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
