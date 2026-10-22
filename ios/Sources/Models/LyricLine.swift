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
    /// 🔴 不再限制时间戳位置逐行前缀匹配（旧版只在 ≤1.5s 时识别，部分源的
    /// 元数据行时间戳靠后，导致歌词页首屏全是「演唱：xxx」）。
    private static let metadataKeywords: Set<String> = [
        "词", "曲", "作词", "作曲", "编曲", "填词", "谱曲",
        "制作", "制作人", "联合制作", "监制", "出品", "出品人", "发行",
        "演奏", "演唱", "原唱", "主唱", "和声", "和音", "伴唱", "合唱",
        "混音", "缩混", "母带", "录音", "录音师", "音效", "配唱",
        "统筹", "艺人统筹", "企划", "策划", "宣传", "宣发", "推广", "推广营销", "营销",
        "文案", "编辑", "顾问", "指导", "总监", "音乐总监",
        "改编词", "改编曲", "改编", "cover",
        "吉他", "钢琴", "贝斯", "鼓", "弦乐", "中阮", "键盘", "萨克斯",
        "小提琴", "大提琴", "二胡", "琵琶", "古筝", "笛子", "唢呐", "长笛",
        "版权", "厂牌", "唱片", "op", "sp", "isrc"
    ]

    /// 英文词曲元数据关键词（酷狗/QQ 英文歌 LRC 常见，如 "Lyrics by: …"、"Composed by: …"）。
    /// 🔴 这些行常带时间戳（[00:00.00]Lyrics by: xxx），绕过无时间戳分支，之前的
    /// 中文关键词过滤漏掉它们 → 歌词页首屏混入英文制作信息（用户截图实测）。
    private static let englishMetaKeywords: [String] = [
        "lyrics by", "lyric by", "lyricist", "words by",
        "composed by", "composer", "written by", "writer",
        "produced by", "producer", "arranged by", "arranger", "arrangement",
        "vocals by", "vocal by", "vocal", "sung by", "performed by", "performer",
        "mixed by", "mastered by", "engineered by", "recorded by", "recording",
        "music by", "melody by", "translated by", "translation"
    ]

    /// 兜底元数据行判定：整行仍是「[key:value]」括号元数据（如残留的 [id:$00000000]、[ar:…]），
    /// 或以英文元数据关键词开头（Lyrics by: … / Composed by: …）。命中即不进正文歌词。
    private static func isMetadataLine(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        // 整行是 [key:value] 且 key 为字母数字 → 元数据（时间戳已在前面剥掉，正文不会长这样）
        if t.hasPrefix("["), t.hasSuffix("]") {
            let inside = String(t.dropFirst().dropLast())
            if let key = inside.split(separator: ":", maxSplits: 1).first {
                let k = String(key)
                if !k.isEmpty, k.allSatisfy({ $0.isLetter || $0.isNumber }) { return true }
            }
        }
        // 英文元数据关键词（大小写不敏感，支持中英文冒号）
        let lower = t.lowercased()
        for kw in englishMetaKeywords
            where lower.hasPrefix(kw + ":") || lower.hasPrefix(kw + "：") {
            return true
        }
        return false
    }

    /// 🔴 v2.6.6：版权声明 / 免责声明类整行。
    /// 酷狗 LRC 开头常带「【未经著作权人许可不得转载或使用】」这类声明行，
    /// 之前没有任何过滤，会被当成歌词正文显示（用户截图实测）。
    private static let copyrightNotices: [String] = [
        "未经著作权人许可", "未经版权方许可", "未经版权所有人许可", "未经出版方许可",
        "版权所有", "版权归", "本作品未经", "仅供试听", "仅供试听使用",
        "请购买正版", "请支持正版", "不得用于商业", "仅供学习交流", "禁止转载",
        "更多歌曲请访问", "更多歌曲下载", "更多音乐请", "本歌词由", "本翻译由",
        "歌词贡献", "歌词整理", "未经授权", "侵权必究", "违者必究", "保留所有权利",
    ]

    /// 🔴 v2.6.6：判定整行是不是版权/声明行（含「【…】」包裹的也要命中）。
    private static func isCopyrightNotice(_ content: String) -> Bool {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return copyrightNotices.contains { t.contains($0) }
    }

    /// 解析结果：歌词正文 + 词曲编曲等元数据（从正文剥离出来的）。
    struct ParseResult {
        let lines: [LyricLine]
        /// 词曲/编曲/制作人等简介信息，key=标签（如"词"、"曲"），value=内容。
        let metadata: [String: String]
    }

    static func parse(_ text: String,
                      songTitle: String = "",
                      songArtist: String = "") -> ParseResult {
        guard let pattern else { return ParseResult(lines: [], metadata: [:]) }
        // 🔴 LRC 全局时间校准 [offset:±毫秒]（v2.5.39）：
        // 标准约定「正值 = 歌词整体提前」，故实际生效时间 = 行时间 − offset/1000。
        // 酷狗多数 LRC 是 [offset:0]，此前该标签被整行丢弃、从未生效 —— 一旦音源
        // 下发了非零 offset，整首歌词就会恒定偏早/偏晚（"歌词对不上"的隐藏来源之一）。
        var offsetMilliseconds: Double = 0
        // 🔴 必须剥掉 UTF-8 BOM(\u{feff})：酷狗 LRC 首行常是 "\u{feff}[id:$00000000]"，
        // BOM 不在 .whitespacesAndNewlines 里、trim 不掉 → hasPrefix("[") 失配 →
        // 元数据过滤被绕过，[id:$00000000] 当成歌词正文显示（用户截图实测）。
        let text = text.replacingOccurrences(of: "\u{feff}", with: "")
        var result: [LyricLine] = []
        var meta: [String: String] = [:]

        // LRC 元数据头关键词（必须全字母，如 id, ar, ti, al, by, offset, length, ve）
        let lrcMetaKeys: Set<String> = ["id", "ar", "ti", "al", "au", "by", "offset",
                                         "length", "ve", "tool", "version", "editor",
                                         "pye", "tlyric", "lyric"]

        for rawLine in text.components(separatedBy: .newlines) {
            // 🔴 必须 trim 换行符：酷狗 LRC 是 \r\n 换行，[id:xxx] 行结尾会带 \r，
            // 只 trim 空格的话 hasSuffix("]") 失配，元数据行（如 [id:$00000000]）
            // 会被当成歌词正文显示出来。
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let ns = line as NSString
            let stamps = pattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let first = stamps.first else {
                // 无时间戳行：过滤 [id:xxx] / [ar:xxx] 等元数据行
                if line.hasPrefix("["), line.hasSuffix("]") {
                    let inside = String(line.dropFirst().dropLast())
                    let key = inside.split(separator: ":", maxSplits: 1).first.map(String.init) ?? inside
                    if lrcMetaKeys.contains(key.lowercased()) {
                        // [offset:±毫秒]：全局时间校准（详见 parse 顶部注释）
                        if key.lowercased() == "offset" {
                            let raw = inside.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                            if let ms = Double(raw.trimmingCharacters(in: .whitespaces)),
                               abs(ms) <= 5000 {
                                offsetMilliseconds += ms
                            }
                        }
                        // 顺带把 [ti:歌名] / [ar:歌手] / [al:专辑] 存进 meta ——
                        // 供下面剔除酷狗首句「[00:00.02]青花瓷 - 周杰伦」（歌名 - 歌手）。
                        Self.storeHeaderMeta(key: key.lowercased(), inside: inside, into: &meta)
                        continue
                    }
                    // 如果 key 全字母但不在已知集合里，也跳过（保险）
                    if !key.isEmpty, key.allSatisfy({ $0.isLetter }) { continue }
                }
                // 裸元数据行（无方括号也无时间戳）：如 id:00000000 / id$00000000
                if Self.isKugouMetadata(line) { continue }
                // 无时间戳的词曲信息行（演唱：xxx / 作词：xxx）也归入 metadata，不进正文
                if let hit = Self.metadataKeyword(for: line) {
                    Self.storeMeta(hit, content: line, into: &meta)
                    continue
                }
                // 🔴 v2.6.6：无时间戳的版权声明行同样不进正文
                if Self.isCopyrightNotice(line) { continue }
                result.append(LyricLine(time: 0, text: line))
                continue
            }

            let contentStart = first.range.upperBound
            var content = ns.substring(from: contentStart).trimmingCharacters(in: .whitespacesAndNewlines)

            // 清除酷狗/QQ音乐的 [d:$00000000] / [d:0] / [v:1] 等内嵌标签
            // 这些标签跟时间戳同行，如 [00:01.23][d:$00000000]童话
            content = stripEmbeddedTags(content)

            // 有时间戳但正文是酷狗元数据也跳过：id:00000000 / id$00000000 / id$AARRGGBB
            let contentLower = content.lowercased()
            if Self.isKugouMetadata(content) { continue }
            if lrcMetaKeys.contains(contentLower) { continue }
            // 颜色标签清除后可能为空
            if content.isEmpty { continue }

            // 🔴 词曲元数据行（演唱：/作词：/制作人：…）不再限制时间戳位置：
            // 旧版只在 ≤1.5s 时识别，部分源的元数据行时间戳靠后，全被当成歌词
            // 正文滚出来。现在逐行前缀匹配，命中即归入 metadata（歌词页顶部折叠简介）。
            if let hit = Self.metadataKeyword(for: content) {
                Self.storeMeta(hit, content: content, into: &meta)
                continue
            }

            // 🔴 v2.6.6：版权声明整行不进正文（【未经著作权人许可不得转载或使用】等）
            if Self.isCopyrightNotice(content) { continue }

            // 🔴 歌名行：酷狗 LRC 首句常是「[00:00.02]青花瓷 - 周杰伦」（歌名 - 歌手），
            // 带时间戳、绕过头信息过滤，会被当成歌词正文显示在歌词页/播放条首屏。
            // 🔴 v2.6.6：判定放宽 —— 之前只在 LRC 头信息有 [ti:]/[ar:] 时才判，
            // 而酷狗大量 LRC 根本没有头信息 → 标题行全部漏网，还被当成"当前行"
            // 用 26pt 大字高亮（用户三张截图实测）。现在同时用【歌曲本身的歌名/歌手】
            // 做匹配，并允许「歌名带副标题」「歌手带英文别名」等常见变形。
            let firstTime = Self.timeValue(of: first, in: line)
            if Self.isTitleLine(content,
                                meta: meta,
                                songTitle: songTitle,
                                songArtist: songArtist,
                                time: firstTime) { continue }

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

        // 🔴 兜底过滤：酷狗英文歌 LRC 常把 [id:$00000000]、Lyrics by: …、Composed by: …
        // 写成带时间戳的行，绕过上面的关键词分支混进正文。这里对成品再做一遍元数据剔除。
        result.removeAll { Self.isMetadataLine($0.text) }

        var lines = result.sorted { $0.time < $1.time }
        // 应用 [offset:] 全局校准（正值 = 歌词提前 → 行时间减小），并裁剪掉负值时间戳
        if offsetMilliseconds != 0 {
            let delta = offsetMilliseconds / 1000.0
            lines = lines.map { LyricLine(time: max(0, $0.time - delta),
                                          text: $0.text,
                                          translation: $0.translation) }
        }

        return ParseResult(lines: lines, metadata: meta)
    }

    /// 识别词曲元数据行前缀：返回命中的关键词。
    /// 🔴 长词优先（「作词」不能被「词」抢走、「制作人」不能被「制作」抢走）；
    /// 单字关键词只匹配 "词：" 形式，不匹配整行等于单字（避免误伤正常歌词）。
    private static func metadataKeyword(for content: String) -> String? {
        let lower = content.lowercased()
        for kw in metadataKeywords.sorted(by: { $0.count > $1.count }) {
            let k = kw.lowercased()
            if lower.hasPrefix(k + ":") || lower.hasPrefix(k + "：") { return kw }
            if k.count >= 2, lower == k { return kw }
        }
        return nil
    }

    /// 从 "制作人：欧华成" 剥出 key="制作人"、value="欧华成"，塞进 metadata（同名只取第一条）。
    private static func storeMeta(_ hit: String, content: String, into meta: inout [String: String]) {
        let cleaned = content.replacingOccurrences(of: "\(hit)：", with: "")
                             .replacingOccurrences(of: "\(hit):", with: "")
                             .trimmingCharacters(in: .whitespaces)
        let key = hit.replacingOccurrences(of: "：", with: "")
                     .replacingOccurrences(of: ":", with: "")
        if meta[key] == nil, !cleaned.isEmpty {
            meta[key] = cleaned
        }
    }

    /// 把头信息 [ti:歌名] / [ar:歌手] / [al:专辑] / [by:…] 的值存进 metadata，
    /// 供 isTitleLine 剔除「歌名 - 歌手」首句用。key 统一小写。
    private static func storeHeaderMeta(key: String, inside: String, into meta: inout [String: String]) {
        guard ["ti", "ar", "al", "by"].contains(key) else { return }
        let value = inside.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty, meta[key] == nil { meta[key] = v }
    }

    /// 判定「歌名行」—— 酷狗 LRC 的第一句常常是标题而不是歌词。
    ///
    /// 🔴 v2.6.6：判定放宽，覆盖三种真实形态（用户三张截图实测）：
    /// ①「青花瓷 - 周杰伦」      → 歌名 + " - " + 歌手
    /// ②「大梦归（《兰香如故》电视剧主题曲）- 周深」→ 歌名带副标题
    /// ③「茶汤 - 都可唯 (Yisa Yu)」→ 歌手带英文别名
    /// 另外还有「时过境迁」这种只有歌名、没有分隔符的形态。
    ///
    /// 判定依据有两个来源：LRC 头信息 [ti:]/[ar:]（有就用），
    /// 以及**歌曲本身的歌名/歌手**（App 里就有，最可靠）。
    /// 两者都缺才判不了 —— 这正是之前大量 LRC 标题行漏网的原因。
    ///
    /// 为了不误伤真歌词，「整行就是歌名」这条规则只在前 10 秒内生效。
    private static func isTitleLine(_ content: String,
                                    meta: [String: String],
                                    songTitle: String,
                                    songArtist: String,
                                    time: Double) -> Bool {
        let norm = Self.normalize(content)
        guard !norm.isEmpty else { return false }

        var titles: [String] = []
        var artists: [String] = []
        if let ti = meta["ti"], !ti.isEmpty { titles.append(ti) }
        if let ar = meta["ar"], !ar.isEmpty { artists.append(ar) }
        if !songTitle.isEmpty { titles.append(songTitle) }
        if !songArtist.isEmpty { artists.append(songArtist) }

        let normTitles = titles.map { Self.normalize($0) }.filter { !$0.isEmpty }
        let normArtists = artists.map { Self.normalize($0) }.filter { !$0.isEmpty }

        // ① 整行就是歌名（只在开头几秒判定，避免误伤同名真歌词）
        if time <= 10, normTitles.contains(where: { $0 == norm }) { return true }

        // ② 「歌名 - 歌手」形态：任一侧带上常见的附加说明也算命中
        for sep in [" - ", " – ", "—", "－", "-"] {
            guard let range = content.range(of: sep) else { continue }
            let left = Self.normalize(String(content[content.startIndex..<range.lowerBound]))
            let right = Self.normalize(String(content[range.upperBound...]))
            guard !left.isEmpty, !right.isEmpty else { continue }
            let leftHit = normTitles.contains { left.hasPrefix($0) || $0.hasPrefix(left) }
            let rightHit = normArtists.contains { right == $0 || right.hasPrefix($0) || $0.hasPrefix(right) }
            if leftHit && rightHit { return true }
        }
        return false
    }

    /// 归一化：去空白、去尾部括号补充说明（"都可唯 (Yisa Yu)" → "都可唯"），
    /// 括号里的内容在标题里也可能是副标题（"大梦归（《兰香如故》电视剧主题曲）"）。
    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 反复剥掉尾部的（中英文）括号补充说明
        while let r = t.range(of: "\\s*[（(][^（()）]*[)）]\\s*$", options: .regularExpression) {
            let stripped = String(t[t.startIndex..<r.lowerBound])
            if stripped.isEmpty { break }
            t = stripped
        }
        return t.replacingOccurrences(of: " ", with: "")
               .replacingOccurrences(of: "\t", with: "")
               .replacingOccurrences(of: "\u{3000}", with: "")
    }

    /// 时间戳 → 秒（用于判定"是不是开头那行"）。
    private static func timeValue(of stamp: NSTextCheckingResult, in line: String) -> Double {
        let ns = line as NSString
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
        return minutes * 60 + seconds + millis / 100
    }

    /// 判断是否为酷狗内嵌元数据（如 id:00000000 / id$00000000 / id$AARRGGBB / 纯 "id"）。
    /// 这些可能出现在时间戳行正文、或作为裸行，不能当成歌词显示。
    /// 注意：带 `:` 或 `$` 前缀才判定为元数据，避免误伤普通歌词（如 "idea"、"identity"）。
    private static func isKugouMetadata(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard lower.hasPrefix("id") else { return false }
        let rest = String(lower.dropFirst(2))   // 去掉 "id"
        if rest.isEmpty { return true }         // 纯 "id"
        if rest.first == ":" || rest.first == "$" {
            let tail = String(rest.dropFirst())
            // 后面是数字或十六进制（酷狗 id 多为长串数字/十六进制）
            return !tail.isEmpty && tail.allSatisfy { $0.isNumber || ($0 >= "a" && $0 <= "f") }
        }
        return false
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
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 兼容旧调用方，只返回歌词行。
    static func parseLines(_ text: String) -> [LyricLine] {
        parse(text).lines
    }

    /// 找到时间戳 ≤ `time + 0.05s` 的最后一行 —— 即「当前应该高亮的歌词行」。
    ///
    /// 🔴 v2.5.39：提前高亮容差从 0.25s 收到 0.05s。旧的 0.25s 会让下一句在真正唱到
    /// 之前 250ms 就翻上去，与逐字填充（按真实播放头走）明显错位 —— 这是「歌词对不上」
    /// 最直观的来源。观察器已提到 10fps（±50ms），0.05s 容差正好把误差居中。
    ///
    /// ⚠️ 性能关键：二分搜索 O(log n)，之前是 O(n) 全量扫描。
    /// 改成二分后每次只需 7 次比较（2^7 = 128），10fps 下开销可忽略。
    static func index(at time: Double, in lines: [LyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        // 二分找最后一个 timeStamp <= time + 0.05 的行（50ms 提前高亮容差）
        let target = time + 0.05
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
    static func parse(_ lrc: String,
                      translation tlyric: String?,
                      songTitle: String = "",
                      songArtist: String = "") -> ParseResult {
        let base = parse(lrc, songTitle: songTitle, songArtist: songArtist)
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
