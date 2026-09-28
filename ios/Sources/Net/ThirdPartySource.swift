import Foundation
import SwiftUI

/// 一条第三方音源配置。
///
/// 两种形态：
/// - `template`：URL 模板。`{id}` 歌名搜索型、`{songmid}` 平台 ID 型。
/// - `script`：LX / MusicPlugin 风格 JS 脚本，走 `ScriptSourceRunner`。
struct ThirdPartySource: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case template
        case script

        var title: String {
            switch self {
            case .template: return "接口模板"
            case .script: return "JS 脚本"
            }
        }
    }

    var id: String = UUID().uuidString
    var name: String
    var kind: Kind = .template
    /// 模板型音源的请求地址，支持占位符替换。
    var template: String = ""
    /// 从响应里取播放地址的字段路径，多个用 `|` 分隔，例如 `data.url|url`。
    var urlPath: String = "url"
    /// 附加请求头。同时支持 `apiKey`（逗号分隔多个）与 `source`（限定平台）。
    var headers: [String: String] = [:]
    /// 模板默认音质，会作为 `{quality}` 变量。
    var quality: String = MusicQuality.exHigh.sourceValue
    /// 脚本内容。
    var script: String = ""
    var enabled: Bool = true

    init(id: String = UUID().uuidString,
         name: String,
         kind: Kind = .template,
         template: String = "",
         urlPath: String = "url",
         headers: [String: String] = [:],
         quality: String = MusicQuality.exHigh.sourceValue,
         script: String = "",
         enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
        self.urlPath = urlPath
        self.headers = headers
        self.quality = quality
        self.script = script
        self.enabled = enabled
    }

    /// 是否是脚本型（含 script 内容或 kind 标记）。
    var isScript: Bool { kind == .script || !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 平台限定（`headers["source"]`），为空表示不限平台。
    var providerCode: String? {
        let value = headers["source"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value.lowercased()
    }

    var apiKeys: [String] {
        var keys: [String] = []
        if let raw = headers["apiKeys"] {
            keys.append(contentsOf: raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        if let single = headers["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            keys.append(single)
        }
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var requiresAPIKey: Bool {
        ["{apiKey}", "{apikey}", "{key}"].contains { template.contains($0) }
    }

    /// 配置是否可用于在线解析。
    var isUsable: Bool {
        if isScript { return !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !template.isEmpty, URL(string: template) != nil else { return false }
        return !(requiresAPIKey && apiKeys.isEmpty)
    }

    static func == (lhs: ThirdPartySource, rhs: ThirdPartySource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, template, url, urlPath, headers, quality, script, enabled
    }

    /// 导入的 JSON 常常缺字段（甚至用 url 代替 template），全部走默认值兜住。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = (try container.decodeIfPresent(String.self, forKey: .name))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "未命名音源"

        let rawKind = (try container.decodeIfPresent(String.self, forKey: .kind))?.lowercased() ?? ""
        kind = rawKind.contains("script") || rawKind.contains("lx") || rawKind.contains("plugin")
            ? .script
            : .template

        // try 不能横跨 ?? 运算符，整条链只抛一次
        let rawTemplate = try container.decodeIfPresent(String.self, forKey: .template)
        let rawURL = try container.decodeIfPresent(String.self, forKey: .url)
        template = rawTemplate ?? rawURL ?? ""
        urlPath = (try container.decodeIfPresent(String.self, forKey: .urlPath))?.nilIfEmpty ?? "url"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        quality = (try container.decodeIfPresent(String.self, forKey: .quality))
            ?? headers["quality"]
            ?? MusicQuality.exHigh.sourceValue
        script = try container.decodeIfPresent(String.self, forKey: .script) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true

        // 有脚本内容就按脚本处理，和 isScript 的判断保持一致
        if !script.isEmpty { kind = .script }
    }

    /// 导出时用 template，避免和导入端的兼容字段混在一起。
    func encode(to encoder: Encoder) throws {
        // KeyedEncodingContainer 的 encode 是 mutating，必须用 var
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(template, forKey: .template)
        try container.encode(urlPath, forKey: .urlPath)
        try container.encode(headers, forKey: .headers)
        try container.encode(quality, forKey: .quality)
        if !script.isEmpty { try container.encode(script, forKey: .script) }
        try container.encode(enabled, forKey: .enabled)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - 存储

/// 第三方音源管理：只保存用户自己添加的配置，不内置任何服务。
final class SourceStore: ObservableObject {
    static let shared = SourceStore()

    @Published private(set) var sources: [ThirdPartySource] = []

    private let defaults = UserDefaults.standard
    private let storeKey = "aurora.sources.v1"
    private let qualityKey = "aurora.playbackQuality"

    /// 播放音质偏好。
    @Published var quality: MusicQuality {
        didSet { defaults.set(quality.rawValue, forKey: qualityKey) }
    }

    var enabledSources: [ThirdPartySource] {
        sources.filter { $0.enabled && $0.isUsable }
    }

    private init() {
        if let data = defaults.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([ThirdPartySource].self, from: data) {
            sources = list
        }
        if let raw = defaults.string(forKey: qualityKey),
           let value = MusicQuality(rawValue: raw) {
            quality = value
        } else {
            quality = .exHigh
        }
    }

    private func persist() {
        // 之前这里是 try? 静默丢弃：编码失败时音源只留在内存里，重启就没了，
        // 表现为「导入了但列表里没有」。
        do {
            let data = try JSONEncoder().encode(sources)
            defaults.set(data, forKey: storeKey)
            Log.debug("音源", "已落盘 \(sources.count) 条音源，\(data.count) 字节")
        } catch {
            Log.error("音源", "落盘失败：\(error.localizedDescription)（\(sources.count) 条音源只在内存里，重启会丢）")
        }
    }

    // MARK: 增删改

    func upsert(_ source: ThirdPartySource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        persist()
    }

    /// 按名字覆盖导入。
    ///
    /// `upsert` 是按 id 匹配的，而 id 每次都是新 UUID，所以重新导入同一个音源
    /// 会不断堆出重复条目——用户看着就像「导了好几次都没生效」。
    func upsertReplacingByName(_ source: ThirdPartySource) {
        if let index = sources.firstIndex(where: { $0.name == source.name }) {
            // 保留原来的 id，避免覆盖后变成另一条
            var replaced = source
            replaced.id = sources[index].id
            sources[index] = replaced
        } else {
            sources.append(source)
        }
        persist()
    }

    @discardableResult
    func remove(id: String) -> Bool {
        let before = sources.count
        sources.removeAll { $0.id == id }
        persist()
        return sources.count != before
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled = enabled
        persist()
    }

    /// 按给定顺序整体重排。
    func reorder(_ ordered: [ThirdPartySource]) {
        let existingIDs = Set(sources.map(\.id))
        let incomingIDs = Set(ordered.map(\.id))
        guard incomingIDs == existingIDs, ordered.count == sources.count else { return }
        sources = ordered
        persist()
    }

    // MARK: 导入导出

    /// 解析粘贴的 JSON：支持单条对象、数组、或带 `sources` 字段的包装对象。
    static func parseImport(_ text: String) -> [ThirdPartySource] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        func decodeArray(_ raw: Any) -> [ThirdPartySource] {
            if let dict = raw as? [String: Any] {
                guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return [] }
                return [(try? JSONDecoder().decode(ThirdPartySource.self, from: data))].compactMap { $0 }
            }
            if let list = raw as? [Any] {
                return list.flatMap { decodeArray($0) }
            }
            return []
        }

        if let wrapper = object as? [String: Any], let inner = wrapper["sources"] {
            return decodeArray(inner)
        }
        return decodeArray(object)
    }

    /// 导出为可分享的 JSON 字符串。
    func exportJSON(ids: [String]? = nil) -> String? {
        let list = ids.map { wanted in sources.filter { wanted.contains($0.id) } } ?? sources
        guard !list.isEmpty,
              let data = try? JSONEncoder().encode(list),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

// MARK: - 内置表单模板（只是空表单，不含任何服务地址）

enum SourceFormTemplate {
    static let templateForm = ThirdPartySource(
        name: "新接口音源",
        kind: .template,
        template: "",
        urlPath: "data.url|url",
        quality: MusicQuality.exHigh.sourceValue
    )

    static let scriptForm = ThirdPartySource(
        name: "新脚本音源",
        kind: .script,
        script: ""
    )
}
