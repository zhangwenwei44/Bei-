import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// 封面回退：拿到真实图片之前，先用能拿到的最相关的一张顶上。
///
/// 数据链路经常缺图，规则是「就近取」：
/// - 歌单 → 歌单里第一首歌的专辑图
/// - 歌手 → 该歌手热门歌里的第一张专辑图
/// - 专辑 → 歌手的一张图
/// - 歌曲 → 专辑图 → 歌手图 → 按歌名哈希的渐变
///
/// 详情页加载完曲目后调用 `register`，列表里的小图就会自动跟着变。
final class CoverResolver {
    static let shared = CoverResolver()

    private let lock = NSLock()
    private var overrides: [String: URL] = [:]

    private init() {}

    /// key 用实体的稳定 id：`kg-rank:381` / `kg:B3A5...`
    func register(_ url: URL?, for key: String) {
        guard let url else { return }
        lock.lock()
        overrides[key] = url
        lock.unlock()
    }

    func register(_ url: URL?, for keys: [String]) {
        for key in keys { register(url, for: key) }
    }

    func url(for key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return overrides[key]
    }

    /// 依次尝试每个 key 的覆盖图，返回第一个存在的。
    func firstAvailable(_ keys: [String]) -> URL? {
        for key in keys {
            if let url = url(for: key) { return url }
        }
        return nil
    }

    func reset() {
        lock.lock()
        overrides.removeAll()
        lock.unlock()
    }

    /// 按需联网解析封面。列表里的歌曲没有图时按 key 补：
    /// `al:<专辑id>` → 专辑接口的 imgurl（榜单歌曲的节点不带图，只有专辑 id）；
    /// `kg:<歌曲hash>` → `song/info` 的 imgurl（本地收藏里 artworkURL 失效的条目）。
    /// 解析成功后登记进 overrides，下次同步查表就能命中。
    /// 🔴 2026-11-13：CoverImage 现在在「首选 URL 下载失败」时也会调这里，
    ///    所以坏链接不会再让卡片永久停在灰白占位。
    func resolveCover(for keys: [String]) async -> URL? {
        if let url = firstAvailable(keys) { return url }
        for key in keys where key.hasPrefix("al:") {
            let albumID = String(key.dropFirst(3))
            guard !albumID.isEmpty else { continue }
            if let url = await CoverFetchCoordinator.shared.albumCover(albumID: albumID, key: key) {
                return url
            }
        }
        for key in keys where key.hasPrefix("kg:") {
            let hash = String(key.dropFirst(3))
            guard !hash.isEmpty else { continue }
            if let url = await CoverFetchCoordinator.shared.hashCover(hash: hash, key: key) {
                return url
            }
        }
        return nil
    }

    /// 🔴 2026-11-18：resolveCover 全部失败后的最后兜底——按歌名搜索补封面。
    ///    key 用歌名+歌手拼成稳定字符串，命中缓存/负缓存后不再重复搜索。
    func resolveCoverByTitle(artist: String, title: String) async -> URL? {
        let key = "title:\(artist)|\(title)"
        return await CoverFetchCoordinator.shared.coverByTitle(artist: artist, title: title, key: key)
    }

    // MARK: - 从歌曲反查

    /// 绑定时把实体 key 登记上（列表里的小图能直接命中）。
    /// 注意只登记实体本身的 key：不同歌曲的封面不一样，
    /// 不能把第一首歌的图挂到所有歌曲的 key 上（以前就是这么错的）。
    func bind(from songs: [Song], to entities: [String]) {
        guard let cover = songs.compactMap({ $0.artworkURL }).first else { return }
        register(cover, for: entities)
    }

    /// 歌手页：热门歌之外的专辑也用第一张图兜住。
    func bindArtist(_ artistID: String, from songs: [Song]) {
        bind(from: songs, to: [artistID])
    }
}

/// 专辑封面的联网解析与去重。同一专辑并发请求只发一次网络。
/// 用 actor 而不是 NSLock：NSLock 在 async 上下文里会被严格并发检查
/// 标记成警告，CI 的「Fail on compiler warnings」步骤会把警告当错误。
actor CoverFetchCoordinator {
    static let shared = CoverFetchCoordinator()

    private var inFlight: [String: Task<URL?, Never>] = [:]
    /// 反查失败过的 key：列表来回滚动时不重复打同样的失败请求。
    private var failed: Set<String> = []

    func albumCover(albumID: String, key: String) async -> URL? {
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task<URL?, Never> {
            await KugouClient.shared.albumCover(albumID: albumID)
        }
        inFlight[key] = task
        let url = await task.value
        inFlight[key] = nil
        if let url {
            CoverResolver.shared.register(url, for: [key])
        }
        return url
    }

    /// 按歌曲 hash 反查封面（同一 hash 并发只发一次；失败做负缓存）。
    func hashCover(hash: String, key: String) async -> URL? {
        if let url = CoverResolver.shared.url(for: key) { return url }
        if failed.contains(key) { return nil }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task<URL?, Never> {
            await KugouClient.shared.coverForHash(hash)
        }
        inFlight[key] = task
        let url = await task.value
        inFlight[key] = nil
        if let url {
            CoverResolver.shared.register(url, for: [key])
        } else {
            failed.insert(key)
        }
        return url
    }

    /// 🔴 2026-11-18：按「歌手 + 歌名」搜索补封面。
    ///    第三方音源 / 搜索歌曲常既无 artworkURL、hash 也不合规（<16 位反查不了），
    ///    resolveCover 三路全失败后只剩取色渐变。这里最后按歌名搜一次，
    ///    用搜索结果里带真实图片的那首补图。结果与失败都做去重/负缓存，
    ///    避免切歌来回时反复搜索。
    func coverByTitle(artist: String, title: String, key: String) async -> URL? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        if let url = CoverResolver.shared.url(for: key) { return url }
        if failed.contains(key) { return nil }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task<URL?, Never> {
            let keyword = artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? cleanTitle
                : "\(artist) \(cleanTitle)"
            guard let results = try? await KugouClient.shared.searchSongs(keyword: keyword, limit: 10) else {
                return nil
            }
            // 优先标题包含目标歌名的，其次直接第一首；只取带真实封面的。
            let best = results.first(where: { $0.cleanTitle.localizedCaseInsensitiveContains(cleanTitle) && $0.artworkURL != nil })
                ?? results.first(where: { $0.artworkURL != nil })
            return best?.artworkURL
        }
        inFlight[key] = task
        let url = await task.value
        inFlight[key] = nil
        if let url {
            CoverResolver.shared.register(url, for: [key])
        } else {
            failed.insert(key)
        }
        return url
    }
}

/// 本地导入音频时把内嵌封面抽出来存到 Caches，返回可长期引用的文件地址。
enum LocalArtwork {
    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("Artwork", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }()

    /// 读音频文件的内嵌封面；没有就用用户指定的「蓝色唱片」兜底图。
    /// - Parameter forceRefresh: true = 忽略 Caches 里的旧图重新生成
    ///   （用于把旧版「歌名首字渐变」兜底一次性换成新图）。
    static func cover(for fileURL: URL, title: String, forceRefresh: Bool = false) async -> URL? {
        let destination = directory.appendingPathComponent("\(stableKey(for: fileURL)).jpg")
        if !forceRefresh, FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let image = await extract(from: fileURL) ?? fallbackImage()
        guard let data = image?.jpegData(compressionQuality: 0.85) else { return nil }
        try? data.write(to: destination, options: .atomic)
        return destination
    }

    /// 🔴 2026-11-17：用户指定的本地导入兜底图（Assets.xcassets/LocalImportFallback）。
    static func fallbackImage() -> UIImage? { UIImage(named: "LocalImportFallback") }

    private static func stableKey(for url: URL) -> String {
        var hash: UInt64 = 5381
        for byte in url.path.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 16)
    }

    /// 读音频文件里内嵌的封面（备份恢复后没有图时优先从音频本身捞）。
    static func extractEmbeddedArtwork(from fileURL: URL) async -> UIImage? {
        await extract(from: fileURL)
    }

    private static func extract(from fileURL: URL) async -> UIImage? {
        let asset = AVURLAsset(url: fileURL)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            guard let value = try? await item.load(.value) else { continue }
            if let image = value as? UIImage { return image }
            if let data = value as? Data { return UIImage(data: data) }
        }
        return nil
    }

    /// 没有内嵌图时画一张：取色渐变 + 歌名首字，避免列表里全是同一个占位图。
    private static func render(title: String) -> UIImage {
        let size = CGSize(width: 300, height: 300)
        let initial = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
        return UIGraphicsImageRenderer(size: size).image { context in
            let palette = ArtworkPaletteEngine.palette(for: nil, seed: title)
            let cgColors = palette.gradient.map { UIColor($0).cgColor } as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: cgColors,
                                         locations: [0, 0.4, 0.75, 1]) {
                context.cgContext.drawLinearGradient(gradient,
                                                     start: CGPoint(x: 0, y: 0),
                                                     end: CGPoint(x: size.width, y: size.height),
                                                     options: [])
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 130, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                .paragraphStyle: paragraph,
            ]
            let text = initial as NSString
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                                  y: (size.height - bounds.height) / 2),
                      withAttributes: attributes)
        }
    }
}
