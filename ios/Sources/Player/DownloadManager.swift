import Combine
import Foundation

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

    @Published private(set) var items: [DownloadItem] = []

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
        // ATS 默认拦 http，但很多音源的 CDN 只有 http 出口（酷狗/qqmusic 的 bdycdn.cn
        // 在国内网络下 http 经常能通但 https 探测失败）。给下载 session 放开 http 限制。
        // allowsConstrainedDownloads 是 iOS 17+ 的 API，iOS 16 靠 Info.plist 里的
        // NSAllowsArbitraryLoads 已经放开了整个 App 的 http。
        if #available(iOS 17.0, *) {
            config.allowsConstrainedDownloads = true
        }
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

    static func directory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Aurora Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private static func indexName(for songID: String) -> String {
        "\(sanitize(songID)).json"
    }

    /// 扫描目录，重建「歌曲 ID → 文件名」索引。
    private func loadIndex() {
        var result: [String: String] = [:]
        let folder = DownloadManager.directory()
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
        let object: [String: Any] = ["id": song.id, "title": song.title, "artist": song.artist, "file": file]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: DownloadManager.directory()
            .appendingPathComponent(DownloadManager.indexName(for: song.id)), options: .atomic)
    }

    /// 启动时调用：重建下载列表，清掉磁盘上已不存在的记录。
    func bootstrap() {
        loadIndex()
        let alive = LibraryStore.shared.downloads.filter { fileName(for: $0.id) != nil }
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
    func download(_ song: Song) async throws -> URL {
        if let local = localURL(for: song) { return local }

        let resolved = await SourceResolver.resolve(song: song, quality: SourceStore.shared.quality)
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
        return destination
    }

    /// 删除下载文件，同时取消在途任务。
    func delete(_ song: Song) {
        cancelTask(for: song.id)
        if let name = fileName(for: song.id) {
            try? FileManager.default.removeItem(at: DownloadManager.directory().appendingPathComponent(name))
            try? FileManager.default.removeItem(at: DownloadManager.directory()
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
