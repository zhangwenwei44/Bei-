import Combine
import Foundation
import UIKit
import AVFoundation

struct DownloadItem: Identifiable, Equatable {
    var id: String { song.id }
    var song: Song
    var progress: Double = 0
    var state: DownloadState = .waiting
    var fileName: String?

    var isDone: Bool { state == .done }
}

/// 音频下载：解析地址 → 下载到 Documents/Aurora Downloads → 登记到曲库。
///
/// 用 `URLSessionDownloadTask` + 委托拿进度；一次只允许同一首歌一个任务。
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = [] {
        didSet {
            // 🔴 v2.8.3：有下载任务进行中就保持屏幕常亮（熄屏会把下载挂起）
            IdleTimerKeeper.shared.set("song-downloads", !items.isEmpty)
        }
    }

    /// 🔴 v2.9.14：默认下载音质。nil = 每次点下载都弹窗让用户选；
    /// 设成具体档位后，下载按钮直接按该档位下载，不再打扰。
    @Published var defaultDownloadQuality: MusicQuality? {
        didSet {
            UserDefaults.standard.set(defaultDownloadQuality?.rawValue, forKey: Self.downloadQualityKey)
        }
    }
    private static let downloadQualityKey = "aurora.downloadQuality"

    /// 实际用于下载的音质：默认设置优先，没设置就跟随播放音质。
    var effectiveDownloadQuality: MusicQuality {
        defaultDownloadQuality ?? SourceStore.shared.quality
    }

    private final class Pending {
        let song: Song
        /// 🔴 2026-11-17：本次**请求**的档位，落盘时写进索引供「换音质是否重下」判定。
        ///    这里必须用请求档位而不是音源实际给的档位：第三方音源经常静默降级
        ///    （选至臻2.0 只给 128k），若把实际档位写进索引，用户每次点下载都会
        ///    发现「档位不符」而无限重下。实际档位只用于 UI 显示与日志。
        let requestedQuality: MusicQuality
        let continuation: CheckedContinuation<URL, Error>
        var destination: URL?

        init(song: Song, requestedQuality: MusicQuality, continuation: CheckedContinuation<URL, Error>) {
            self.song = song
            self.requestedQuality = requestedQuality
            self.continuation = continuation
        }
    }

    /// 委托队列是串行队列，回调之间不需要额外加锁。
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60 * 60
        // Info.plist 里已经设了 NSAllowsArbitraryLoads=true，
        // 整个 App 的 http 请求都不被 ATS 拦，不需要额外配。
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// 委托回调跑在 URLSession 自建的串行队列上，而 `download()` 在 await 之后
    /// 已经在通用执行器上，两边会并发访问 pending / fileIndex，统一用锁保护。
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var fileIndex: [String: String] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]

    // MARK: - 加锁访问

    private func setPending(_ value: Pending, for id: Int) {
        lock.lock()
        pending[id] = value
        lock.unlock()
    }

    private func takePending(_ id: Int) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func peekPending(_ id: Int) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        return pending[id]
    }

    private func putFile(_ name: String, for songID: String) {
        lock.lock()
        fileIndex[songID] = name
        lock.unlock()
    }

    /// 记住在途任务，删除时先取消，否则任务跑完会把歌「复活」回下载列表。
    private func putTask(_ task: URLSessionDownloadTask, for songID: String) {
        lock.lock()
        tasks[songID] = task
        lock.unlock()
    }

    private func cancelTask(for songID: String) {
        lock.lock()
        let task = tasks[songID]
        tasks[songID] = nil
        lock.unlock()
        task?.cancel()
    }

    private func dropTask(for songID: String) {
        lock.lock()
        tasks[songID] = nil
        lock.unlock()
    }

    private func dropFile(for songID: String) {
        lock.lock()
        fileIndex[songID] = nil
        lock.unlock()
    }

    private func fileName(for songID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return fileIndex[songID]
    }

    // MARK: - 目录与索引

    /// 🔴 2026-11-10：下载目录改回 `Documents/Aurora Downloads`。
    ///    Info.plist 已开 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`，
    ///    所以用户能在「文件」App → 我的 iPhone → Aurora Music 里直接看到/复制/分享
    ///    这些「歌名-歌手.mp3」文件（v2.9.11 特意挪到 Application Support 是反需求）。
    ///    只放音频；索引 json / 封面 / 歌词 / 写真这些杂项放 `metadataDirectory()`，
    ///    免得文件 App 里混进一堆看不懂的 .json / .png。
    static func directory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Aurora Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    /// 私有元数据目录：索引与侧车文件，不暴露给「文件」App。
    static func metadataDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("Aurora Metadata", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    /// 可导入 / 可播放的音频扩展名（含无损与常见容器）。
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "caf",
        "ogg", "opus", "ape", "wma", "alac",
    ]

    /// 🔴 2026-11-10：把 v2.9.11~3.0.0 存在 Application Support 的旧下载搬回 Documents。
    ///    音频 → 共享下载目录；索引 / 侧车 → 私有元数据目录。同名不覆盖，搬完才删空壳。
    private func migrateIfNeeded() {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aurora Downloads", isDirectory: true)
        let audioDir = DownloadManager.directory()
        let metaDir = DownloadManager.metadataDirectory()
        guard fm.fileExists(atPath: legacy.path), legacy.path != audioDir.path,
              let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { return }
        for name in names where !name.hasPrefix(".") {
            let from = legacy.appendingPathComponent(name)
            let isAudio = DownloadManager.audioExtensions.contains((name as NSString).pathExtension.lowercased())
            let to = (isAudio ? audioDir : metaDir).appendingPathComponent(name)
            guard !fm.fileExists(atPath: to.path) else { continue }
            try? fm.moveItem(at: from, to: to)
        }
        if let left = try? fm.contentsOfDirectory(atPath: legacy.path), left.isEmpty {
            try? fm.removeItem(at: legacy)
        }
    }

    private static func indexName(for songID: String) -> String {
        "\(sanitize(songID)).json"
    }

    /// 扫描目录，重建「歌曲 ID → 文件名」索引。
    private func loadIndex() {
        var result: [String: String] = [:]
        let folder = DownloadManager.metadataDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songID = object["id"] as? String,
                  let file = object["file"] as? String else { continue }
            result[songID] = file
        }
        lock.lock()
        fileIndex = result
        lock.unlock()
    }

    private func writeIndex(song: Song, file: String, quality: MusicQuality? = nil) {
        // 🔴 v2.9.3：多存 hash / albumID —— 离线重建歌曲时仍能走歌词/写真兜底逻辑。
        var object: [String: Any] = ["id": song.id, "title": song.title, "artist": song.artist,
                                     "file": file, "hash": song.kugouHash, "albumID": song.kugouAlbumID]
        // 🔴 2026-11-17：记下这首文件实际是按哪一档下的。用户换音质再点下载时，
        //    download() 靠这个字段判断「要不要真重下」，而不是无脑短路返回旧的 1.3MB 文件。
        //    恢复/导入场景没有档位信息，传 nil 表示未知（保持旧行为）。
        if let quality { object["quality"] = quality.rawValue }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: DownloadManager.metadataDirectory()
            .appendingPathComponent(DownloadManager.indexName(for: song.id)), options: .atomic)
    }

    /// 读索引里记录的下载档位；nil = 旧索引/恢复/导入，档位未知。
    private func recordedQuality(for songID: String) -> MusicQuality? {
        let url = DownloadManager.metadataDirectory()
            .appendingPathComponent(DownloadManager.indexName(for: songID))
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["quality"] as? String else { return nil }
        return MusicQuality(rawValue: raw)
    }

    /// 🔴 2026-11-16：备份恢复后重建索引，修「提示已恢复 N 首，列表却还是空的」。
    ///
    /// `bootstrap()` 从 metadata 目录的 `<id>.json` 建 `fileIndex`，再用
    /// `alive = merged.filter { fileName(for: $0.id) != nil }` 过滤。
    /// 只要备份里缺索引（旧版本备份、用户先删歌再恢复导致 metadata 被清空、
    /// 或索引与音频文件名对不上），音频文件虽然成功拷回来了，却没有 songID
    /// 能进 `fileIndex`，于是整批被过滤掉 —— 页面就是「还没有下载」。
    ///
    /// 这里以**磁盘上的音频文件为准**：凡是没有索引指向它的，都补写一份。
    /// 有备份清单时用清单里的歌名 / 歌手 / hash / albumID，没有就按文件名兜底解析，
    /// 保证任何备份恢复完都能在列表里看到歌曲。纯文件 IO，不碰 @Published。
    /// - Parameter manifest: 备份里带的完整歌曲清单，可为空（兼容旧备份）。
    func rebuildIndexes(manifest: [Song]) {
        let fm = FileManager.default
        let audioDir = DownloadManager.directory()
        let metaDir = DownloadManager.metadataDirectory()

        // ① 备份清单：按音频文件名建立 Song 映射，恢复出真实歌名 / 歌手 / hash / albumID。
        //    🔴 2026-11-16：歌曲存进 LibraryStore 后 url 多半还是在线地址（甚至 nil），
        //    `song.url?.lastPathComponent` 和磁盘上的「歌名-歌手.mp3」根本对不上，
        //    于是旧版这里几乎总是落到 ③ 的 `local:import:` 兜底：hash / albumID 全丢。
        //    没有 hash 就没有 kg:<hash> / al:<id> 封面回退键，也拿不到歌词 ——
        //    用户看到的就是「恢复后歌在、但没图片没歌词」。
        //    下载落盘名就是 sanitize("歌名-歌手.ext")（见 didFinishDownloadingTo），
        //    这里按同一规则再建一组键，确保恢复出原始 Song 的 hash / albumID。
        var byFile: [String: Song] = [:]
        var byID: [String: Song] = [:]
        for song in manifest {
            byID[DownloadManager.sanitize(song.id)] = song
            if let file = song.url?.lastPathComponent, !file.isEmpty {
                byFile[file] = song
            }
            for ext in DownloadManager.audioExtensions {
                let expected = DownloadManager.sanitize("\(song.title)-\(song.artist).\(ext)")
                byFile[expected] = song
            }
        }

        // ② 扫现有索引 json，按「指向的音频文件名」分组记下 (索引文件, songID)。
        //    🔴 2026-11-16：以前只用 `covered` 集合判断「有索引就跳过」，于是备份里
        //    若带着旧版 / 兜底的 `local:import:` 索引（没 hash / albumID），它会被当成
        //    「已覆盖」保留下来，压过 songs.json 里的真实 Song —— 恢复后依旧没图没词。
        //    现在改成：清单命中就用真实 Song 重写索引，并删掉指向同一音频的旧 id 索引，
        //    既能补回 hash，也避免同一首歌出现两个 id（列表里变成重复两首）。
        var indexesByFile: [String: [(url: URL, songID: String)]] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: metaDir.path)) ?? []
            where name.hasSuffix(".json") {
            let url = metaDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let file = object["file"] as? String,
                  let songID = object["id"] as? String else { continue }
            indexesByFile[file, default: []].append((url: url, songID: songID))
        }

        // ③ 以磁盘上的音频文件为准：补写缺失索引 / 用权威清单纠正过时索引。
        guard let names = try? fm.contentsOfDirectory(atPath: audioDir.path) else { return }
        for name in names where !name.hasPrefix(".") {
            let ext = (name as NSString).pathExtension.lowercased()
            guard DownloadManager.audioExtensions.contains(ext) else { continue }

            // 文件名对不上时（改名 / 带 -2 后缀）再用旧索引的 songID 找清单，
            // 否则真实 Song 的 hash / albumID 会丢，恢复后没封面没歌词。
            let existing = indexesByFile[name] ?? []
            let real = byFile[name]
                ?? existing.compactMap { byID[DownloadManager.sanitize($0.songID)] }.first
            if let real {
                // 清单命中：先把旧 id 名下的封面 / 歌词 / 写真侧车迁到真实 id，
                // 再删掉指向同一音频、id 不同的旧索引，最后写带真实 hash 的索引。
                // 🔴 不迁侧车的话，索引换成真实 id 后 sidecarURL 找不到旧文件，
                //    用户看到的就是「歌回来了但没图没词」。
                for old in existing where old.songID != real.id {
                    Self.copySidecars(from: old.songID, to: real.id, in: metaDir)
                    try? fm.removeItem(at: old.url)
                }
                writeIndex(song: real, file: name)
                continue
            }

            // 清单未命中（旧备份没有 songs.json）：已有任意索引指向它就不动，否则按文件名兜底。
            if !existing.isEmpty { continue }
            let base = (name as NSString).deletingPathExtension
            var title = base
            var artist = "本地文件"
            for sep in [" - ", " – ", " — ", "_-_"] {
                guard let range = base.range(of: sep) else { continue }
                let a = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let t = String(base[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !a.isEmpty && !t.isEmpty { artist = a; title = t }
                break
            }
            let song = Song(id: "local:import:\(name)", title: title, artist: artist,
                            url: audioDir.appendingPathComponent(name),
                            isLocal: true, source: .local)
            writeIndex(song: song, file: name)
        }
    }

    /// 备份恢复时把旧 id 名下的侧车迁到新 id（纯 IO，不碰 @Published）。
    private static func copySidecars(from oldID: String, to newID: String, in folder: URL) {
        let fm = FileManager.default
        let fromBase = sanitize(oldID)
        let toBase = sanitize(newID)
        guard fromBase != toBase else { return }
        for ext in ["art.png", "lrc", "photo.png"] {
            let from = folder.appendingPathComponent("\(fromBase).\(ext)")
            let to = folder.appendingPathComponent("\(toBase).\(ext)")
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try? fm.copyItem(at: from, to: to)
        }
    }

    // MARK: - 离线元数据侧车文件（🔴 v2.9.3）

    /// 下载时把「封面 / 歌词 / 歌手写真」一并落盘，保证断网后已下载歌曲仍能展示。
    /// 命名规则：`<songID>.art.png` / `<songID>.lrc` / `<songID>.photo.png`。
    /// 全部尽力而为，失败静默跳过（不影响音频本身）。
    ///
    /// - Parameter onlyIfMissing: >true 只补缺失的侧车（恢复后回填用），已存在的
    ///   不重新下载，避免每次恢复都把整批封面/歌词重拉一遍。
    private func saveSidecars(for song: Song, onlyIfMissing: Bool = false) async {
        let fm = FileManager.default
        let folder = DownloadManager.metadataDirectory()
        let base = DownloadManager.sanitize(song.id)
        let artDest = folder.appendingPathComponent("\(base).art.png")
        let lrcDest = folder.appendingPathComponent("\(base).lrc")
        let photoDest = folder.appendingPathComponent("\(base).photo.png")

        // ① 封面：优先用歌曲自带 artworkURL；榜单歌曲没有地址时按
        //    kg:<hash> / al:<albumID> 反查一张再存盘（以前整类榜单歌都缺封面侧车）。
        if !onlyIfMissing || !fm.fileExists(atPath: artDest.path) {
            var coverURL = song.artworkURL
            if coverURL == nil {
                coverURL = await CoverResolver.shared.resolveCover(for: song.coverFallbackKeys)
            }
            if let url = coverURL, let image = await CoverLoader.download(url) {
                try? image.pngData()?.write(to: artDest, options: .atomic)
            }
        }

        // ② 歌词：有酷狗 hash 才能取到 LRC。
        if (!onlyIfMissing || !fm.fileExists(atPath: lrcDest.path)),
           !song.kugouHash.isEmpty,
           let lrc = await KugouClient.shared.lyric(hash: song.kugouHash, duration: song.duration),
           !lrc.isEmpty {
            try? Data(lrc.utf8).write(to: lrcDest, options: .atomic)
        }

        // ③ 歌手写真：取主歌手精确匹配。
        if !onlyIfMissing || !fm.fileExists(atPath: photoDest.path) {
            let lead = song.artist.components(separatedBy: CharacterSet(charactersIn: "、/&，,"))
                .first?.trimmingCharacters(in: .whitespaces) ?? song.artist
            if !lead.isEmpty,
               let photoURL = await KugouClient.shared.artistPhoto(name: lead, title: song.title),
               let image = await CoverLoader.download(photoURL) {
                try? image.pngData()?.write(to: photoDest, options: .atomic)
            }
        }
    }

    /// 🔴 2026-11-16：恢复后回填侧车。备份可能来自旧版本（metadata 里没有
    /// 封面/歌词），或用户当初下载的是榜单歌（无 artworkURL → 没存封面侧车）。
    /// 这里只补缺失的，不覆盖已有文件；纯 IO + 网络，成功后由调用方 bootstrap
    /// 让 `artworkURL` 指向新落盘的封面，播放页/列表就能离线显示图片与歌词。
    func ensureSidecarsForDownloads() async {
        let songs = LibraryStore.shared.downloads
        for song in songs {
            // 🔴 2026-11-17：备份恢复后「有歌没图没词」的补强。
            //    旧备份 / 索引丢失时 Song 没有 hash，单靠 saveSidecars 的
            //    kg:<hash> 反查永远拿不到封面和歌词；这里先做两件事：
            //    ① 从本地音频里直接抽内嵌封面（下载来的 mp3 大多带 ID3 图）；
            //    ② 没有 hash 时按「歌手 + 歌名」搜一次酷狗，把 hash / 专辑 id
            //       补回索引，后续歌词 / 封面 / 写真就都能正常反查。
            var resolved = song
            let folder = DownloadManager.metadataDirectory()
            let base = DownloadManager.sanitize(song.id)
            let artDest = folder.appendingPathComponent("\(base).art.png")
            let lrcDest = folder.appendingPathComponent("\(base).lrc")

            // 恢复的歌 duration 常为 0，酷狗歌词按 duration 匹配候选；先读真实时长。
            if resolved.duration <= 0, let file = localURL(for: song) {
                resolved.duration = await Self.duration(of: file)
            }

            // ① 内嵌封面兜底（不需要网络）
            if !FileManager.default.fileExists(atPath: artDest.path),
               let file = localURL(for: song),
               let embedded = await LocalArtwork.extractEmbeddedArtwork(from: file),
               let data = embedded.pngData() {
                try? data.write(to: artDest, options: .atomic)
            }

            // ② hash 缺失时按歌名搜一次，补回索引
            if resolved.kugouHash.isEmpty, !resolved.cleanTitle.isEmpty,
               (!FileManager.default.fileExists(atPath: artDest.path)
                || !FileManager.default.fileExists(atPath: lrcDest.path)) {
                let keyword = resolved.artist.isEmpty
                    ? resolved.cleanTitle
                    : "\(resolved.artist) \(resolved.cleanTitle)"
                if let found = try? await KugouClient.shared.searchSongs(keyword: keyword, limit: 10),
                   let best = found.first(where: { $0.cleanTitle.localizedCaseInsensitiveContains(resolved.cleanTitle) })
                        ?? found.first {
                    resolved.kugouHash = best.kugouHash
                    resolved.kugouAlbumID = best.kugouAlbumID
                    if resolved.artworkURL == nil { resolved.artworkURL = best.artworkURL }
                    if let name = fileName(for: song.id) {
                        writeIndex(song: resolved, file: name)
                    }
                }
            }

            await saveSidecars(for: resolved, onlyIfMissing: true)
        }
    }

    private static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds,
              seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    /// 侧车文件地址（存在才返回），供 PlayerStore 离线加载用。
    private func sidecarURL(_ ext: String, for songID: String) -> URL? {
        let url = DownloadManager.metadataDirectory().appendingPathComponent("\(DownloadManager.sanitize(songID)).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func localArtworkURL(for song: Song) -> URL? { sidecarURL("art.png", for: song.id) }
    func localLyricsURL(for song: Song) -> URL? { sidecarURL("lrc", for: song.id) }
    func localArtistPhotoURL(for song: Song) -> URL? { sidecarURL("photo.png", for: song.id) }

    /// 🔴 2026-11-17：一次性把旧版「歌名首字渐变」本地导入兜底换成用户指定的唱片图。
    private static let localFallbackMigrationKey = "aurora.localImportFallback.v1"

    private func migrateLocalImportArtworkIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.localFallbackMigrationKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.localFallbackMigrationKey)
        let targets = LibraryStore.shared.downloads.filter { $0.id.hasPrefix("local:import:") }
        guard !targets.isEmpty else { return }
        Task { @MainActor in
            for song in targets {
                guard let file = self.localURL(for: song) else { continue }
                guard let art = await LocalArtwork.cover(for: file, title: song.title, forceRefresh: true),
                      let data = try? Data(contentsOf: art) else { continue }
                let sidecar = DownloadManager.metadataDirectory()
                    .appendingPathComponent("\(DownloadManager.sanitize(song.id)).art.png")
                try? data.write(to: sidecar, options: .atomic)
            }
            self.bootstrap()
        }
    }

    /// 启动时调用：重建下载列表。
    /// 优先从磁盘 .json 索引直接重建 Song 列表（绕过 LibraryStore 持久化可能不一致的问题），
    /// 再与 LibraryStore.downloads 合并取并集，确保不会丢失。
    func bootstrap() {
        migrateIfNeeded()
        loadIndex()
        // 🔴 v2.9.14：恢复上次选的默认下载音质
        if let raw = UserDefaults.standard.string(forKey: Self.downloadQualityKey),
           let q = MusicQuality(rawValue: raw) {
            // 🔴 2026-11-18：「至臻母带/至臻2.0」已从选择 UI 移除，老偏好若仍停在
            //    这两档，静默降级到「无损」，避免界面显示已移除的档位名。
            defaultDownloadQuality = MusicQuality.selectableCases.contains(q) ? q : .exHigh
        }
        // 从磁盘索引文件直接重建 Song（兜底方案）
        let fromDisk = fileIndex.compactMap { songID, fileName -> Song? in
            let folder = DownloadManager.directory()
            let indexFile = DownloadManager.metadataDirectory()
                .appendingPathComponent(DownloadManager.indexName(for: songID))
            guard let data = try? Data(contentsOf: indexFile),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = object["title"] as? String,
                  let artist = object["artist"] as? String else { return nil }
            // 给 Song 加 local URL 和 isLocal 标记
            let localURL = folder.appendingPathComponent(fileName)
            let song = Song(id: songID, title: title, artist: artist,
                            url: localURL, isLocal: true,
                            artworkURL: sidecarURL("art.png", for: songID),
                            source: .local,
                            kugouHash: (object["hash"] as? String) ?? "",
                            kugouAlbumID: (object["albumID"] as? String) ?? "")
            return song
        }
        // LibraryStore 里可能也有持久化的下载列表（UserDefaults），取并集。
        // 🔴 v2.9.3：优先用磁盘重建的 Song（带本地封面 / hash / albumID），
        // 因此 fromDisk 排在前，同 id 时它胜出。
        let fromLib = LibraryStore.shared.downloads
        var merged: [Song] = []
        var seen = Set<String>()
        for s in fromDisk + fromLib where !seen.contains(s.id) {
            seen.insert(s.id)
            merged.append(s)
        }
        // 过滤：磁盘上文件还在的才算活的
        let alive = merged.filter { fileName(for: $0.id) != nil }
        LibraryStore.shared.setDownloads(alive)
        var restored = alive.map { DownloadItem(song: $0, progress: 1, state: .done, fileName: fileName(for: $0.id)) }
        restored.append(contentsOf: items.filter { $0.state.isActive })
        items = restored
        // 🔴 2026-11-17：旧版本地导入歌的渐变兜底图一次性换成唱片图。
        migrateLocalImportArtworkIfNeeded()
        // 🔴 2026-11-18：已在列表里的本地导入歌一次性补真实歌手 + 网络封面。
        migrateLocalImportsOnlineIfNeeded()
    }

    // MARK: - 查询

    func item(for song: Song) -> DownloadItem? {
        items.first { $0.id == song.id }
    }

    func isDownloaded(_ song: Song) -> Bool { localURL(for: song) != nil }

    /// 已下载歌曲的本地播放地址。
    func localURL(for song: Song) -> URL? {
        guard let name = fileName(for: song.id) ?? item(for: song)?.fileName else { return nil }
        let url = DownloadManager.directory().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 下载

    /// 下载一首歌；已下载直接返回本地地址。
    /// - Parameter quality: 指定音质；nil = 用「默认下载音质」（未设置时跟随播放音质）。
    /// - Parameter force: true = 忽略「已下载」短路、强制按新音质重新拉取。
    ///   🔴 2026-11-16：以前用户在音质弹窗里选更高档再点下载，
    ///   `if let local = localURL(...)` 直接把旧的低码率文件返回，看起来就是
    ///   「换音质下载还是 1MB」。显式选音质时必须走这条 force 通道真重下。
    ///   注意：这里**不预先删旧文件** —— 让 `didFinishDownloadingTo` 只在
    ///   新文件成功后才覆盖，重下失败也还有旧的能播。
    func download(_ song: Song, quality: MusicQuality? = nil, force: Bool = false) async throws -> URL {
        let targetQuality = quality ?? effectiveDownloadQuality
        if !force, let local = localURL(for: song) {
            // 🔴 2026-11-17：以前只看「文件在不在」，换音质点下载一律返回旧的
            //    低码率文件（用户看到的就是「换音质下载还是 1MB」）。现在比对索引档位：
            //    · 老版本下的歌 / 恢复导入的歌没有档位字段 → 一律视为「高品音质(128k)」，
            //      这样用户把音质切到更高档再点下载时，这些旧的 1.3MB 文件会真重下；
            //      若目标档位本来就是 128k，则仍然复用，不会无故重下。
            //    · 记了档位且 != 目标档位 → 按新档位真重下。
            //    · 记了档位且 == 目标档位 → 复用。
            let recorded = recordedQuality(for: song.id) ?? .standard
            if recorded != targetQuality {
                Log.info("下载", "「\(song.title)」已存 \(recorded.title)，改按 \(targetQuality.title) 重新下载")
            } else {
                return local
            }
        }

        let resolved = await SourceResolver.resolve(song: song, quality: targetQuality)
        guard let resolved else { throw DownloadError.unresolved }
        // 🔴 脚本内部有 QUALITY_FALLBACK 静默降级链（选 flac24bit 可能只给 128k）。
        //    resolved.quality 现在是脚本回传的真实档位，这里只用于如实提示，
        //    **不写进索引** —— 否则用户选高档位、音源降级，每次点下载都会判定
        //    「档位不符」陷入无限重下。索引记的是「用户要的档位」。
        if resolved.quality != targetQuality {
            Log.warn("下载", "「\(song.title)」请求 \(targetQuality.title)，音源实际只提供 \(resolved.quality.title)")
        }

        // http→https 升级（和 PlayerStore 一样的逻辑）。
        // 下载用 URLSession 走 ATS 的策略如果是 Default，http 会被拦截。
        let target: URL
        if resolved.url.scheme?.lowercased() == "http",
           let secure = URL(string: resolved.url.absoluteString.replacingOccurrences(of: "http://", with: "https://")) {
            var probe = URLRequest(url: secure)
            probe.httpMethod = "GET"
            probe.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            probe.timeoutInterval = 6
            if let (_, resp) = try? await URLSession.shared.data(for: probe),
               let code = (resp as? HTTPURLResponse)?.statusCode,
               code == 200 || code == 206 {
                target = secure
            } else {
                target = resolved.url
            }
        } else {
            target = resolved.url
        }

        var request = URLRequest(url: target)
        request.setValue("AuroraMusic/1.0", forHTTPHeaderField: "User-Agent")
        // Referer 设网易云对酷狗/qqmusic CDN 是无效的，可能还会触发反爬。
        // 改成设酷狗首页 Referer — 或者干脆不设，让 CDN 自己判断。
        if target.host?.contains("kugou") == true || target.host?.contains("qqmusic") == true {
            request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        }

        let task = session.downloadTask(with: request)
        let destination: URL = try await withCheckedThrowingContinuation { continuation in
            setPending(Pending(song: song, requestedQuality: targetQuality, continuation: continuation),
                       for: task.taskIdentifier)
            putTask(task, for: song.id)
            apply(DownloadItem(song: song, progress: 0, state: .downloading))
            task.resume()
        }
        // 🔴 v2.9.3：音频落盘后顺手把封面/歌词/写真存好，断网也能看。
        await saveSidecars(for: song)
        return destination
    }

    /// 删除下载文件，同时取消在途任务。
    func delete(_ song: Song) {
        cancelTask(for: song.id)
        if let name = fileName(for: song.id) {
            try? FileManager.default.removeItem(at: DownloadManager.directory().appendingPathComponent(name))
            try? FileManager.default.removeItem(at: DownloadManager.metadataDirectory()
                .appendingPathComponent(DownloadManager.indexName(for: song.id)))
        }
        dropFile(for: song.id)
        removeIDs(Set([song.id]))
        LibraryStore.shared.removeDownload(song)
    }

    func clearAll() {
        // 遍历的是快照：delete() 会同步改动 LibraryStore.downloads
        for song in Array(LibraryStore.shared.downloads) { delete(song) }
        removeIDs(Set(items.map(\.id)))
    }

    // MARK: - 🔴 2026-11-18 本地导入歌联网补全（真实歌手 + 网络封面 + 歌词）

    /// 本地导入歌的文件名常常是「歌名-歌手」这类无空格写法，离线解析拆不开、
    /// 也没有网络封面。这里用文件名（及按 `-`/`_` 拆出的片段）搜索酷狗，命中后
    /// 把真实的歌名 / 歌手 / hash / 专辑 id 回填索引，并下载网络封面 + 歌词到侧车。
    /// 结果：歌手名显示在歌名下方（不再是「本地文件」），列表/播放页用上网络封面。
    /// 纯 IO + 网络，不碰 @Published；调用方负责回主线程 bootstrap。
    private func enrichLocalImportFromNetwork(_ song: Song, file: String) async -> Song? {
        guard song.id.hasPrefix("local:import:") else { return nil }
        let base = (file as NSString).deletingPathExtension

        var keywords: [String] = [song.cleanTitle, base]
        for sep in [" - ", "-", " – ", "–", " — ", "—", "_-_", "_"] {
            let parts = base.components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for part in parts where !keywords.contains(part) { keywords.append(part) }
        }
        keywords = keywords.filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return nil }

        let blob = base.lowercased()
        var best: Song?
        var bestScore = 0
        for kw in keywords.prefix(6) {
            guard let results = try? await KugouClient.shared.searchSongs(keyword: kw, limit: 10) else { continue }
            for cand in results {
                var score = 0
                let ct = cand.cleanTitle.lowercased()
                let ca = cand.artist.lowercased()
                if !ct.isEmpty && blob.contains(ct) { score += 3 }
                if !ca.isEmpty && blob.contains(ca) { score += 2 }
                if !kw.isEmpty && ct.contains(kw.lowercased()) { score += 1 }
                if score > bestScore { bestScore = score; best = cand }
            }
            if bestScore >= 4 { break }
        }
        guard let hit = best, bestScore >= 3 else { return nil }

        // 保留本地身份（id / url / 本地标记），只回填网络元数据。
        var resolved = song
        resolved.title = hit.cleanTitle.isEmpty ? song.title : hit.cleanTitle
        resolved.artist = hit.artist.isEmpty ? song.artist : hit.artist
        resolved.kugouHash = hit.kugouHash
        resolved.kugouAlbumID = hit.kugouAlbumID

        // 网络封面覆盖兜底/内嵌图；下载失败则保留原侧车（唱片兜底图）。
        let artDest = DownloadManager.metadataDirectory()
            .appendingPathComponent("\(DownloadManager.sanitize(song.id)).art.png")
        if let coverURL = hit.artworkURL,
           let image = await CoverLoader.download(coverURL),
           let data = image.pngData() {
            try? data.write(to: artDest, options: .atomic)
        }

        // 歌词 / 歌手写真（只补缺失，不重复下载已有封面）。
        await saveSidecars(for: resolved, onlyIfMissing: true)
        writeIndex(song: resolved, file: file)
        return resolved
    }

    /// 一次性迁移：给已经在列表里的本地导入歌补真实歌手 + 网络封面。
    private static let localImportOnlineEnrichKey = "aurora.localImportOnlineEnrich.v1"

    private func migrateLocalImportsOnlineIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.localImportOnlineEnrichKey) else { return }
        let targets = LibraryStore.shared.downloads.filter { $0.id.hasPrefix("local:import:") }
        guard !targets.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: Self.localImportOnlineEnrichKey)
        Task { @MainActor in
            for song in targets {
                guard let file = self.fileName(for: song.id) else { continue }
                _ = await self.enrichLocalImportFromNetwork(song, file: file)
            }
            self.bootstrap()
        }
    }

    // MARK: - 🔴 2026-11-10 从「文件」App 导入

    /// 把用户在「文件」App 里选中的音频复制进共享下载目录，并登记成已下载歌曲。
    /// 返回 nil = 不是支持的音频格式或复制失败。
    /// 🔴 fileImporter 给的是安全作用域 URL，必须 start/stopAccessingSecurityScopedResource。
    /// 🔴 写一份索引 json，这样重启后 `bootstrap()` 能从磁盘重建，导入的歌不会丢。
    @discardableResult
    func importFile(_ source: URL) -> Song? {
        let fm = FileManager.default
        let secured = source.startAccessingSecurityScopedResource()
        defer { if secured { source.stopAccessingSecurityScopedResource() } }

        let ext = source.pathExtension.lowercased()
        guard DownloadManager.audioExtensions.contains(ext) else { return nil }

        let raw = source.deletingPathExtension().lastPathComponent
        let base = DownloadManager.sanitize(raw.isEmpty ? "导入歌曲" : raw)
        var name = "\(base).\(ext)"
        var suffix = 2
        while fm.fileExists(atPath: DownloadManager.directory().appendingPathComponent(name).path) {
            name = "\(base)-\(suffix).\(ext)"
            suffix += 1
        }
        let destination = DownloadManager.directory().appendingPathComponent(name)
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            return nil
        }

        // 「歌手 - 歌名」这类文件名尽量拆开；拆不了就整串当歌名。
        // 🔴 2026-11-18：无空格 `-` 无法可靠判断「歌名-歌手」还是「歌手-歌名」
        //    （如「你的抱抱-罗百吉」是前者，离线拆会拆反），所以只认带空格分隔符；
        //    真实歌名 / 歌手统一交给 enrichLocalImportFromNetwork 联网校正。
        var title = base
        var artist = "本地文件"
        for sep in [" - ", " – ", " — ", "_-_"] {
            guard let range = base.range(of: sep) else { continue }
            let a = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let t = String(base[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !a.isEmpty && !t.isEmpty { artist = a; title = t }
            break
        }

        let song = Song(id: "local:import:\(name)",
                        title: title, artist: artist,
                        url: destination, isLocal: true, source: .local)
        writeIndex(song: song, file: name)
        putFile(name, for: song.id)
        apply(DownloadItem(song: song, progress: 1, state: .done, fileName: name))
        let register = { LibraryStore.shared.registerDownload(song) }
        if Thread.isMainThread { register() } else { DispatchQueue.main.async(execute: register) }

        // 🔴 2026-11-17：导入时顺手抽内嵌封面（没有就按歌名生成），存成和下载歌
        //    同名的侧车。以前导入歌完全没有封面，重启也补不回来。
        // 🔴 2026-11-18：紧接着联网补全真实歌手 / 网络封面 / 歌词（离线失败则保留兜底图）。
        let songID = song.id
        Task { @MainActor in
            guard let art = await LocalArtwork.cover(for: destination, title: title),
                  let data = try? Data(contentsOf: art) else { return }
            let sidecar = DownloadManager.metadataDirectory()
                .appendingPathComponent("\(DownloadManager.sanitize(songID)).art.png")
            try? data.write(to: sidecar, options: .atomic)
            _ = await self.enrichLocalImportFromNetwork(song, file: name)
            // bootstrap 会用侧车重建 Song.artworkURL，列表 / 播放器立即有图。
            DownloadManager.shared.bootstrap()
        }
        return song
    }

    // MARK: - 内部

    /// items 只在主线程上改。
    private func apply(_ item: DownloadItem) {
        if Thread.isMainThread {
            upsert(item)
        } else {
            DispatchQueue.main.async { [weak self] in self?.upsert(item) }
        }
    }

    private func upsert(_ item: DownloadItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    private func removeIDs(_ ids: Set<String>) {
        let remove = { self.items.removeAll { ids.contains($0.id) } }
        if Thread.isMainThread { remove() } else { DispatchQueue.main.async(execute: remove) }
    }

    private static func fileExtension(for response: URLResponse?, url: URL) -> String {
        let fromPath = url.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "flac", "wav", "aiff", "caf", "ogg"].contains(fromPath) { return fromPath }
        if let mime = (response as? HTTPURLResponse)?.mimeType {
            switch mime {
            case "audio/mpeg", "audio/mp3": return "mp3"
            case "audio/mp4", "audio/x-m4a": return "m4a"
            case "audio/aac": return "aac"
            case "audio/flac", "audio/x-flac": return "flac"
            case "audio/wav", "audio/x-wav": return "wav"
            case "audio/ogg": return "ogg"
            default: break
            }
        }
        return fromPath.isEmpty ? "mp3" : fromPath
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let item = peekPending(downloadTask.taskIdentifier) else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        apply(DownloadItem(song: item.song,
                           progress: max(0, min(1, fraction)),
                           state: .downloading))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let item = peekPending(downloadTask.taskIdentifier) else { return }

        // 403/404 的错误页不能当成音频存下来
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            apply(DownloadItem(song: item.song, progress: 0, state: .failed("HTTP \(http.statusCode)")))
            item.continuation.resume(throwing: DownloadError.http)
            _ = takePending(downloadTask.taskIdentifier)
            return
        }

        let ext = DownloadManager.fileExtension(for: downloadTask.response,
                                                url: downloadTask.response?.url ?? location)
        let name = DownloadManager.sanitize("\(item.song.title)-\(item.song.artist).\(ext)")
        let destination = DownloadManager.directory().appendingPathComponent(name)
        // 🔴 2026-11-17：换音质重下时扩展名可能变（.mp3 → .flac），新旧文件名不同，
        //    只覆盖同名文件会让旧的 1.3MB 低码率文件残留成孤儿 —— 用户在「文件」App
        //    里看到的还是那个小文件，以为换了音质没生效。成功后把旧文件删掉。
        let previousName = fileName(for: item.song.id)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            if let previousName, previousName != name {
                let old = DownloadManager.directory().appendingPathComponent(previousName)
                if FileManager.default.fileExists(atPath: old.path) {
                    try? FileManager.default.removeItem(at: old)
                    Log.info("下载", "换音质重下：移除旧文件 \(previousName)")
                }
            }
            item.destination = destination
            writeIndex(song: item.song, file: name, quality: item.requestedQuality)
            putFile(name, for: item.song.id)
        } catch {
            _ = takePending(downloadTask.taskIdentifier)
            apply(DownloadItem(song: item.song, progress: 0, state: .failed("保存失败")))
            item.continuation.resume(throwing: DownloadError.move)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let item = takePending(task.taskIdentifier) else { return }
        dropTask(for: item.song.id)
        if let error {
            apply(DownloadItem(song: item.song, progress: 0, state: .failed(error.localizedDescription)))
            item.continuation.resume(throwing: error)
            return
        }
        guard let destination = item.destination else {
            apply(DownloadItem(song: item.song, progress: 0, state: .failed("没有收到音频数据")))
            item.continuation.resume(throwing: DownloadError.http)
            return
        }
        let name = destination.lastPathComponent
        apply(DownloadItem(song: item.song, progress: 1, state: .done, fileName: name))
        // LibraryStore 的 @Published 只能在主线程改
        DispatchQueue.main.async {
            LibraryStore.shared.registerDownload(item.song)
            item.continuation.resume(returning: destination)
        }
    }
}

enum DownloadError: LocalizedError {
    case unresolved
    case http
    case move

    var errorDescription: String? {
        switch self {
        case .unresolved: return "解析不到播放地址，请检查音源配置"
        case .http: return "下载失败，服务器未返回音频"
        case .move: return "保存到本地失败"
        }
    }
}
