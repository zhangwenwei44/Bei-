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

    /// 解析结果：歌词正文 + 词曲编曲等元数据（从正文剥离出来的）。
    struct ParseResult {
        let lines: [LyricLine]
        /// 词曲/编曲/制作人等简介信息，key=标签（如"词"、"曲"），value=内容。
        let metadata: [String: String]
    }

    static func parse(_ text: String) -> ParseResult {
        guard let pattern else { return ParseResult(lines: [], metadata: [:]) }
        var result: [LyricLine] = []
        var meta: [String: String] = [:]

        // LRC 元数据头关键词（必须全字母，如 id, ar, ti, al, by, offset, length, ve）
        let lrcMetaKeys: Set<String> = ["id", "ar", "ti", "al", "au", "by", "offset",
                                         "length", "ve", "tool", "version", "editor",
                                         "pye", "tlyric", "lyric"]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let ns = line as NSString
            let stamps = pattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let first = stamps.first else {
                // 无时间戳行：过滤 [id:xxx] / [ar:xxx] 等元数据行
                if line.hasPrefix("["), line.hasSuffix("]") {
                    let inside = String(line.dropFirst().dropLast())
                    let key = inside.split(separator: ":", maxSplits: 1).first.map(String.init) ?? inside
                    if lrcMetaKeys.contains(key.lowercased()) { continue }
                    // 如果 key 全字母但不在已知集合里，也跳过（保险）
                    if !key.isEmpty, key.allSatisfy({ $0.isLetter }) { continue }
                }
                result.append(LyricLine(time: 0, text: line))
                continue
            }

            let contentStart = first.range.upperBound
            var content = ns.substring(from: contentStart).trimmingCharacters(in: .whitespaces)

            // 清除酷狗/QQ音乐的 [d:$00000000] / [d:0] / [v:1] 等内嵌标签
            // 这些标签跟时间戳同行，如 [00:01.23][d:$00000000]童话
            content = stripEmbeddedTags(content)

            // 有时间戳但正文是 id00000000 / ar 许嵩这类也跳过
            let contentLower = content.lowercased()
            if contentLower.hasPrefix("id") && contentLower.dropFirst(2).allSatisfy({ $0.isNumber }) { continue }
            if lrcMetaKeys.contains(contentLower) { continue }
            // 颜色标签清除后可能为空
            if content.isEmpty { continue }

            let firstMin = Double(ns.substring(with: first.range(at: 1))) ?? 0
            let firstSec = Double(ns.substring(with: first.range(at: 2))) ?? 0
            if firstMin == 0, firstSec <= 1.5 {
                let lower = content.lowercased()
                if let hit = Self.metadataKeywords.first(where: { kw in
                    let k = kw.lowercased()
                    return lower.hasPrefix(k + ":") || lower.hasPrefix(k + "：") || lower == k
                }) {
                    // 提取 "词" / "曲" 等短标签 + 值
                    let cleaned = content.replacingOccurrences(of: "\(hit)：", with: "")
                                         .replacingOccurrences(of: "\(hit):", with: "")
                                         .trimmingCharacters(in: .whitespaces)
                    let key = hit.replacingOccurrences(of: "：", with: "")
                                 .replacingOccurrences(of: ":", with: "")
                    if meta[key] == nil, !cleaned.isEmpty {
                        meta[key] = cleaned
                    }
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

        return ParseResult(lines: result.sorted { $0.time < $1.time }, metadata: meta)
    }

    /// 清除酷狗/QQ音乐 LRC 内嵌标签：[d:$00000000] / [d:0] / [v:1] / [t:xxx]
    /// 这些跟时间戳同行，如 [00:01.23][d:$00000000]童话 → 童话
    static func stripEmbeddedTags(_ s: String) -> String {
        // [字母开头 任意内容]  非贪婪匹配
        // 酷狗颜色标签格式：[d:$AARRGGBB] 或 [d:$RRGGBB] 或 [d:0]
        // QQ：[v:1] [t:xxx] [c:xxx]
        guard let regex = try? NSRegularExpression(pattern: #"\[[a-zA-Z][^\]]*\]"#) else { return s }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        var result = s
        for m in matches.reversed() {
            if let range = Range(m.range, in: result) {
                result.removeSubrange(range)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 兼容旧调用方，只返回歌词行。
    static func parseLines(_ text: String) -> [LyricLine] {
        parse(text).lines
    }

    /// 找到时间戳 ≤ `time + 0.25s` 的最后一行 —— 即「当前应该高亮的歌词行」。
    ///
    /// ⚠️ 性能关键：二分搜索 O(log n)，之前是 O(n) 全量扫描。
    /// 0.05s × 每秒 20 次调用 × 100 行歌词 = 2000 次比较/秒，和 ScrollGesture 抢 CPU 导致滑动卡顿。
    /// 改成二分后每次只需 7 次比较（2^7 = 128），加上 time observer interval 也从 0.05s 降到 0.25s，
    /// 主线程工作量直接砍到之前的 1/8。
    static func index(at time: Double, in lines: [LyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        // 二分找最后一个 timeStamp <= time + 0.25 的行（0.25s 提前高亮容差）
        let target = time + 0.25
        var lo = 0, hi = lines.count - 1, result: Int?
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if lines[mid].time <= target {
                result = mid       // mid 可能是答案，先记下来
                lo = mid + 1       // 继续往右找更晚的行
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    /// 解析原文 + 翻译，按时间戳合并成一份歌词。
    static func parse(_ lrc: String, translation tlyric: String?) -> ParseResult {
        let base = parse(lrc)
        guard let tlyric, !tlyric.isEmpty else { return base }
        let translated = parseLines(tlyric)
        guard !translated.isEmpty else { return base }

        var result: [LyricLine] = []
        var cursor = 0
        for line in base.lines {
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
        return ParseResult(lines: result, metadata: base.metadata)
    }
}

extension Double {
    var clockString: String {
        guard isFinite, self >= 0 else { return "00:00" }
        let total = Int(self.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
