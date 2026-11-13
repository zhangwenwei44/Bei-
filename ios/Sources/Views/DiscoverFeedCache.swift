import Foundation

/// 🔴 2026-11-13：推荐页首屏数据的本地快照。
///
/// 用户反馈「App 每次启动都要先显示一下骨架屏画面才出内容」——根因是冷启动时
/// `feed` 为空，`isLoading && feed.isEmpty` 必然命中 `FeedSkeleton()`，要等网络
/// 回来才换成真内容。现在把上次成功加载的首屏数据落盘，启动时同步恢复，
/// **首帧就是真内容**，之后 `load(force: true)` 在后台静默刷新
/// （stale-while-revalidate），启动图淡出后不会再看到灰块扫光。
///
/// ⚠️ 只缓存展示用数据；歌曲的 `url` 可能是一次性 CDN 签名地址，
/// 播放时 PlayerStore 会重新解析，这里不做任何播放态持久化。
struct DiscoverSnapshot: Codable {
    var feed: DiscoverFeed
    var guessSongs: [Song]
    var guessPool: [Song]
    var dailySongs: [Song]
    var dailyPick: Song?
    var guessPick: Song?
    var hotArtists: [Artist]
    var recommendedPlaylists: [Playlist]
    var ktvSongs: [Song]
    var classicSongs: [Song]
    var djSongs: [Song]
    var newSongs: [Song]
    var hallSongs: [Song]
    var savedAt: TimeInterval
}

final class DiscoverFeedCache {
    static let shared = DiscoverFeedCache()

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("discover_feed_cache.json")
    }()
    private let ioQueue = DispatchQueue(label: "aurora.discover.cache", qos: .utility)
    private let lock = NSLock()

    /// 🔴 内存缓存必须要有：SwiftUI 每次父视图刷新都会重新构造 `DiscoverView`，
    /// 若 init 里每次都读磁盘 JSON，启动后会变成高频主线程 IO。
    /// 这里只在进程内第一次真正读盘，之后走内存。
    private var memory: DiscoverSnapshot?
    private var didLoad = false

    /// 启动首帧同步读（几十 KB）。文件不存在 / 损坏 / 老版本字段不兼容 → 返回 nil，
    /// 界面回退到「首次安装」的骨架路径，不会崩。
    func load() -> DiscoverSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        if didLoad { return memory }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(DiscoverSnapshot.self, from: data) else {
            memory = nil
            return nil
        }
        memory = snap
        return snap
    }

    /// 后台编码 + 原子写入，不占主线程。写之前先更新内存，保证同进程内立即生效。
    func save(_ snapshot: DiscoverSnapshot) {
        lock.lock()
        memory = snapshot
        didLoad = true
        lock.unlock()
        ioQueue.async { [fileURL] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
