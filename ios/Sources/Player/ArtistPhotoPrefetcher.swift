import UIKit

/// 🔴 v2.7.6：歌手写真预取器。
///
/// ## 为什么需要它
/// 用户反馈「歌词页歌手写真加载慢，老是先显示一会专辑取色背景」。
/// 原因：写真是在**打开歌词页那一刻**才开始取的，串行三段网络：
///   ① song/info 反查 singerid → ② author/extend 拿写真图址 → ③ 下载 750×1334 大图
/// 就算一切顺利也是 1~3 秒，这期间歌词页只能是专辑取色渐变。
///
/// ## 做法
/// 在**歌曲开始播放时**（PlayerStore.prepare）就后台把写真抓下来放进
/// `ArtistPhotoCache`。等用户切到歌词页，`ArtistPhotoBackdrop` 一上来就命中缓存，
/// 照片立刻出现（基本不再有取色背景的阶段）。
///
/// 两层兜底保证不会白费流量：
/// · 图址有磁盘缓存（KugouClient.photoURLs），①② 两步通常是 0 网络开销；
/// · 图片下载走 CoverLoader，同一 URL 的在途请求会合并 ——
///   预取还没跑完就打开歌词页时，歌词页不会重复下载，而是等同一份数据回来。
final class ArtistPhotoPrefetcher {
    static let shared = ArtistPhotoPrefetcher()

    private let pending = PendingKeys()

    /// 一次预取最多抓几张（和 ArtistPhotoBackdrop.maxPhotos 保持一致）
    private static let maxPhotos = 6
    /// 解码上限：酷狗写真原图 750×1334，按 1600 解码不缩不放
    private static let decodeMaxPixel: CGFloat = 1600

    /// 预取某个歌手的写真。已有成品 / 正在抓 / 歌手名为空 → 直接跳过。
    func prefetch(artist: String, title: String = "", hash: String = "") {
        let key = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if !ArtistPhotoCache.shared.images(for: key).isEmpty { return }
        guard pending.insert(key) else { return }

        let keys = pending
        Task.detached(priority: .utility) {
            await Self.fetch(key: key, title: title, hash: hash)
            keys.remove(key)
        }
    }

    private static func fetch(key: String, title: String, hash: String) async {
        var picked: [URL] = []
        let gallery = await KugouClient.shared.singerPhotoURLs(name: key, title: title, hash: hash)
        if !gallery.isEmpty {
            picked = spread(gallery, count: maxPhotos)
        }
        if picked.isEmpty,
           let fallback = await KugouClient.shared.artistPhotoStrict(name: key, title: title) {
            picked = [fallback]
        }
        guard !picked.isEmpty else {
            Log.info("歌词写真", "预取：没取到 \(key) 的写真")
            return
        }

        var loaded: [UIImage] = []
        for url in picked {
            guard let image = await CoverLoader.downloadPhoto(url, maxPixelSize: decodeMaxPixel) else { continue }
            loaded.append(image)
        }
        // 只在**全部**抓完后才写缓存 —— 写半成品会让歌词页只轮播 1 张，再也补不齐。
        ArtistPhotoCache.shared.store(loaded, for: key)
        Log.info("歌词写真", "预取完成：\(key) \(loaded.count)/\(picked.count) 张")
    }

    /// 从图库里均匀抽 count 张（首尾都覆盖，风格差异大一点）
    private static func spread(_ urls: [URL], count: Int) -> [URL] {
        guard urls.count > count else { return urls }
        var result: [URL] = []
        let step = Double(urls.count) / Double(count)
        for i in 0..<count {
            let idx = min(urls.count - 1, Int((Double(i) * step).rounded()))
            let url = urls[idx]
            if !result.contains(url) { result.append(url) }
        }
        return result
    }
}

/// 正在预取的歌手名登记表（锁全部收在这个同步类内部，不暴露到 async 上下文）。
private final class PendingKeys: @unchecked Sendable {
    private var keys = Set<String>()
    private let lock = NSLock()

    /// 返回 true = 刚登记成功（可以开始抓）；false = 已经在抓了
    func insert(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if keys.contains(key) { return false }
        keys.insert(key)
        return true
    }

    func remove(_ key: String) {
        lock.lock(); keys.remove(key); lock.unlock()
    }
}
