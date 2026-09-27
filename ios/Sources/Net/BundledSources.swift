import Foundation

/// 内置音源：随包发布的洛雪（lx-music）脚本。
///
/// 为什么内置：这两类脚本动辄几万字符、且高度混淆，走文件选择器导入既费劲又容易
/// 出各种幺蛾子（权限、编码、置灰），不如直接打进包里一键启用。
///
/// 只内置有明确开源许可的脚本（见 `ios/BundledSources/` 与 THIRD_PARTY_NOTICES.md）。
/// 没有 license 声明的第三方脚本请自行放到 `ios/BundledSources/*.js`，
/// 该目录已在 .gitignore 里排除，文件会打进 IPA 但不会进仓库。
enum BundledSources {
    struct Preset: Identifiable {
        var id: String { scriptName }
        /// 脚本文件名（不含扩展名）
        var scriptName: String
        var displayName: String
        var version: String
        var author: String?
        var license: String?
        var homepage: String?
        var notes: String?
    }

    /// 随包发布、已确认许可的脚本。
    private static let known: [Preset] = [
        Preset(scriptName: "molan",
               displayName: "墨澜聚合音源",
               version: "2.3.3",
               author: "白姬9527",
               license: "MIT",
               homepage: "https://github.com/baiji6/molanyinyueyuan",
               notes: "全平台支持 flac，wy / qq / kw / kg 支持母带")
    ]

    /// 包里所有能读到的音源脚本（含本地放的）。
    static var available: [Preset] {
        var result: [Preset] = []
        for url in scriptURLs() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if let preset = known.first(where: { $0.scriptName == name }) {
                result.append(preset)
            } else {
                result.append(fromHeader(text, fallbackName: name))
            }
        }
        return result
    }

    /// 读取脚本正文。
    static func script(named name: String) -> String? {
        guard let url = scriptURLs().first(where: { $0.deletingPathExtension().lastPathComponent == name })
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 把内置音源转成可用的配置。
    static func makeSource(_ preset: Preset) -> ThirdPartySource? {
        guard let script = script(named: preset.scriptName),
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ThirdPartySource(name: preset.displayName, kind: .script, script: script)
    }

    /// 首次启动时把内置音源写进列表。已经导入过的不重复添加。
    @discardableResult
    static func installMissing(into store: SourceStore = .shared) -> Int {
        let existing = Set(store.sources.map(\.name))
        var added = 0
        for preset in available {
            guard !existing.contains(preset.displayName),
                  let source = makeSource(preset) else { continue }
            store.upsert(source)
            added += 1
        }
        return added
    }

    // MARK: - 内部

    private static func scriptURLs() -> [URL] {
        guard let dir = Bundle.main.url(forResource: "BundledSources", withExtension: nil)
                ?? Bundle.main.url(forResource: "bundled", withExtension: nil) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.lowercased().hasSuffix(".js") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// 从 `/*! @name xxx */` 头注释里读元信息。
    private static func fromHeader(_ text: String, fallbackName: String) -> Preset {
        guard let end = text.range(of: "*/") else {
            return Preset(scriptName: fallbackName, displayName: fallbackName, version: "1.0",
                          author: nil, license: nil, homepage: nil, notes: nil)
        }
        // range(of:) 返回的 upperBound 已经是结束位置，不用再 lowerBound
        let header = String(text[..<end.upperBound])
        return Preset(scriptName: fallbackName,
                      displayName: field("name", in: header) ?? fallbackName,
                      version: field("version", in: header) ?? "1.0",
                      author: field("author", in: header),
                      license: field("license", in: header),
                      homepage: field("homepage", in: header),
                      notes: field("description", in: header))
    }

    private static func field(_ name: String, in header: String) -> String? {
        for line in header.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("*") else { continue }
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@\(name)"), body.count > name.count + 1 else { continue }
            return String(body.dropFirst(name.count + 1))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
