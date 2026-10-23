import Foundation

/// 🔴 v2.7.3：更新包下载器 —— 修「有时候下载不了」。
///
/// ## 旧实现的毛病（AppUpdater.download）
/// 1. `URLSession.shared.data(from:)` **一次性把 5.7MB 读进内存**，
///    默认资源超时 60s —— 慢网/地铁里直接超时失败，且**没有任何重试**。
/// 2. 进度是假的：`onProgress(0)` 之后直接跳 `onProgress(1)`，用户看到进度条卡住不动。
/// 3. 没有 User-Agent —— GitHub 的 release 资产 CDN 偶尔会直接拒绝。
/// 4. 下载跑在普通 `Task` 里 —— App 切后台会被系统挂起，下载中断后不会恢复。
///
/// ## 现在
/// · 用 `URLSessionDownloadTask`（走 delegate）→ **真实进度** + 临时文件自动落盘；
/// · 资源超时 600s + `waitsForConnectivity`（等网络回来而不是立刻失败）；
/// · 带 User-Agent；
/// · **失败自动重试 2 次**（每次重新发起下载，不是续传）；
/// · 校验文件大小（与 Release 声明不符 → 视为失败并重试）。
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = UpdateDownloader()

    /// 正在进行的下载的回调
    private var completion: ((Result<URL, Error>) -> Void)?
    private var progressHandler: ((Double) -> Void)?
    private var session: URLSession?
    /// 本次期望的字节数（Release 里声明的 asset.size）
    private var expectedSize: Int64 = 0
    /// 是否已经回调过结果（避免 didFinish 与 didComplete 重复回调）
    private var settled = false

    /// 私有初始化：整个 App 只用 shared 单例。    /// ⚠️ 不能写成 `private override init()` —— NSObject.init() 是 public，
    /// override 的访问级别不能比父类更严，编译器会直接报错。
    override init() {
        super.init()
    }

    /// 下载 IPA 到沙盒 Documents/Updates/，返回落盘后的文件地址。
    func download(from url: URL,
                  assetName: String,
                  expectedSize: Int64,
                  maxRetries: Int = 2,
                  onProgress: @escaping (Double) -> Void) async throws -> URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(assetName)

        var lastError: Error = UpdateError.http
        for attempt in 0...maxRetries {
            do {
                let temp = try await runTask(url: url,
                                            expectedSize: expectedSize,
                                            onProgress: onProgress)
                // 大小校验：下到一半的包也要重试，不能拿给用户装
                let attrs = try? FileManager.default.attributesOfItem(atPath: temp.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                if expectedSize > 0, size != expectedSize {
                    try? FileManager.default.removeItem(at: temp)
                    throw UpdateError.sizeMismatch(expected: expectedSize, actual: size)
                }
                // 🔴 格式校验：IPA 本质是 zip，文件头必须是 PK\x03\x04。
                // 撞到 GitHub 限流/登录页时服务器会返回一小段 HTML/JSON，
                // 大小可能刚好凑巧接近，不校验就会装出一个假包。
                guard Self.isIPAFile(temp) else {
                    try? FileManager.default.removeItem(at: temp)
                    Log.error("更新", "下载到的文件不是 IPA（大小 \(size) 字节）")
                    throw UpdateError.notIPA
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temp, to: destination)
                Log.info("更新", "下载完成：\(destination.lastPathComponent)（\(size) 字节）")
                onProgress(1)
                return destination
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < maxRetries {
                    Log.warn("更新", "下载失败（第 \(attempt + 1) 次）：\(error.localizedDescription)，1.5 秒后重试")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        throw lastError
    }

    /// IPA 本质是 zip，文件头是 PK\x03\x04
    private static func isIPAFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        return head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04
    }

    /// 发起一次下载任务，用 continuation 把 delegate 回调转成 async
    private func runTask(url: URL,
                         expectedSize: Int64,
                         onProgress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.settled = false
            self.expectedSize = expectedSize
            self.progressHandler = onProgress
            self.completion = { result in
                switch result {
                case .success(let url): continuation.resume(returning: url)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            // 🔴 关键：资源超时从默认 60s 放宽到 600s —— 5.7MB 在慢网下很容易超
            config.timeoutIntervalForResource = 600
            // 🔴 等网络恢复，而不是立刻失败
            config.waitsForConnectivity = true
            config.httpAdditionalHeaders = ["User-Agent": "AuroraMusic/OTA"]
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !settled else { return }
        settled = true
        session?.finishTasksAndInvalidate()
        session = nil
        let handler = completion
        completion = nil
        progressHandler = nil
        handler?(result)
    }

    // MARK: - URLSessionDownloadDelegate

    /// 真实进度
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        guard total > 0 else { return }
        let ratio = min(1, Double(totalBytesWritten) / Double(total))
        progressHandler?(ratio)
    }

    /// 下载完成：location 是临时文件（会被系统立刻删除），必须马上移走
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-update-\(UUID().uuidString).ipa")
        do {
            try FileManager.default.moveItem(at: location, to: temp)
            finish(.success(temp))
        } catch {
            Log.error("更新", "保存下载文件失败：\(error.localizedDescription)")
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            Log.error("更新", "下载任务失败：\(error.localizedDescription)")
            finish(.failure(error))
        }
        // 成功路径已在 didFinishDownloadingTo 里回调
    }
}
