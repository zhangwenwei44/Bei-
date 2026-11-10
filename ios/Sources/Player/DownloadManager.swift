import Combine
import Foundation
import UIKit

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
        let continuation: CheckedContinuation<URL, Error>
        var destination: URL?

        init(song: Song, continuation: CheckedContinuation<URL, Error>) {
            self.song = song
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

    private func writeIndex(song: Song, file: String) {
        // 🔴 v2.9.3：多存 hash / albumID —— 离线重建歌曲时仍能走歌词/写真兜底逻辑。
        let object: [String: Any] = ["id": song.id, "title": song.title, "artist": song.artist,
                                     "file": file, "hash": song.kugouHash, "albumID": song.kugouAlbumID]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: DownloadManager.metadataDirectory()
            .appendingPathComponent(DownloadManager.indexName(for: song.id)), options: .atomic)
    }

    // MARK: - 离线元数据侧车文件（🔴 v2.9.3）

    /// 下载时把「封面 / 歌词 / 歌手写真」一并落盘，保证断网后已下载歌曲仍能展示。
    /// 命名规则：`<songID>.art.png` / `<songID>.lrc` / `<songID>.photo.png`。
    /// 全部尽力而为，失败静默跳过（不影响音频本身）。
    private func saveSidecars(for song: Song) async {
        let folder = DownloadManager.metadataDirectory()
        let base = DownloadManager.sanitize(song.id)

        // ① 封面：歌曲本身带 artworkURL 时直接下载存盘（榜单类无地址的跳过，靠兜底）。
        if let url = song.artworkURL,
           let image = await CoverLoader.download(url) {
            let dest = folder.appendingPathComponent("\(base).art.png")
            _ = try? image.pngData()?.write(to: dest, options: .atomic)
        }

        // ② 歌词：有酷狗 hash 才能取到 LRC。
        if !song.kugouHash.isEmpty,
           let lrc = await KugouClient.shared.lyric(hash: song.kugouHash, duration: song.duration),
           !lrc.isEmpty {
            let dest = folder.appendingPathComponent("\(base).lrc")
            _ = try? Data(lrc.utf8).write(to: dest, options: .atomic)
        }

        // ③ 歌手写真：取主歌手精确匹配。
        let lead = song.artist.components(separatedBy: CharacterSet(charactersIn: "、/&，,"))
            .first?.trimmingCharacters(in: .whitespaces) ?? song.artist
        if !lead.isEmpty,
           let photoURL = await KugouClient.shared.artistPhoto(name: lead, title: song.title),
           let image = await CoverLoader.download(photoURL) {
            let dest = folder.appendingPathComponent("\(base).photo.png")
            _ = try? image.pngData()?.write(to: dest, options: .atomic)
        }
    }

    /// 侧车文件地址（存在才返回），供 PlayerStore 离线加载用。
    private func sidecarURL(_ ext: String, for songID: String) -> URL? {
        let url = DownloadManager.metadataDirectory().appendingPathComponent("\(DownloadManager.sanitize(songID)).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func localArtworkURL(for song: Song) -> URL? { sidecarURL("art.png", for: song.id) }
    func localLyricsURL(for song: Song) -> URL? { sidecarURL("lrc", for: song.id) }
    func localArtistPhotoURL(for song: Song) -> URL? { sidecarURL("photo.png", for: song.id) }

    /// 启动时调用：重建下载列表。
    /// 优先从磁盘 .json 索引直接重建 Song 列表（绕过 LibraryStore 持久化可能不一致的问题），
    /// 再与 LibraryStore.downloads 合并取并集，确保不会丢失。
    func bootstrap() {
        migrateIfNeeded()
        loadIndex()
        // 🔴 v2.9.14：恢复上次选的默认下载音质
        if let raw = UserDefaults.standard.string(forKey: Self.downloadQualityKey),
           let q = MusicQuality(rawValue: raw) {
            defaultDownloadQuality = q
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
    func download(_ song: Song, quality: MusicQuality? = nil) async throws -> URL {
        if let local = localURL(for: song) { return local }

        let targetQuality = quality ?? effectiveDownloadQuality
        let resolved = await SourceResolver.resolve(song: song, quality: targetQuality)
        guard let resolved else { throw DownloadError.unresolved }

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
            setPending(Pending(song: song, continuation: continuation), for: task.taskIdentifier)
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

    private static func sanitize(_ name: String) -> String {
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
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            item.destination = destination
            writeIndex(song: item.song, file: name)
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
