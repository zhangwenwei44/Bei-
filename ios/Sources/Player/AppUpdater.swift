import Combine
import Foundation
import UIKit

/// 应用内更新：查 GitHub Releases，发现新版本就把 IPA 下下来并唤起系统安装。
///
/// 越狱设备上由 AppSync / Zebra 接管 `open(.ipa)`，iOS 会弹「选取软件安装」；
/// 非越狱设备这一步会失败，所以同时提供浏览器下载的兜底入口。
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    struct Asset: Decodable, Equatable {
        var name: String
        var browser_download_url: String
        var size: Int
    }

    struct Release: Decodable, Equatable {
        var tag_name: String
        var name: String?
        var body: String?
        var html_url: String
        var assets: [Asset]
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case available(Release)
        case downloading(progress: Double)
        case ready(URL)
        case failed(String)

        var isBusy: Bool { self == .checking || isDownloading }

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheckedAt: Date?

    /// 仓库地址，和仓库 README 保持一致
    private let repo = "zhangwenwei44/Bei-"
    private let currentVersion: String
    private let currentBuild: String
    private var progressTask: Task<Void, Never>?

    private init() {
        let info = Bundle.main.infoDictionary
        currentVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        currentBuild = info?["CFBundleVersion"] as? String ?? "0"
    }

    // MARK: - 检查

    func check(force: Bool = false) async {
        if !force, let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < 300 { return }
        phase = .checking
        Log.info("更新", "开始检查更新，当前版本 \(versionText)")

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            phase = .failed("仓库地址无效")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AuroraMusic/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                Log.error("更新", "响应不是 HTTP：\(response)")
                phase = .failed("网络异常")
                return
            }
            // 403/404 多半是 API 限流。GitHub 未认证请求每 IP 每小时只有 60 次，
            // 移动网络下同 IP 共享，很容易撞上限。
            guard (200...299).contains(http.statusCode) else {
                let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
                Log.error("更新", "GitHub 返回 \(http.statusCode)，限流剩余 \(remaining ?? "未知")")
                phase = .failed(Self.rateLimitMessage(http))
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            lastCheckedAt = Date()
            Log.info("更新", "远端最新 \(release.tag_name)，附件 \(release.assets.map(\.name).joined(separator: ", "))")
            if isNewer(release.tag_name) {
                phase = .available(release)
            } else {
                Log.info("更新", "已是最新（远端 \(release.tag_name)）")
                phase = .upToDate(current: currentVersion)
            }
        } catch {
            Log.error("更新", "检查失败：\(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// 限流和 404 的说法不一样，不能一律报「稍后再试」。
    private static func rateLimitMessage(_ http: HTTPURLResponse) -> String {
        switch http.statusCode {
        case 403, 429:
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { TimeInterval($0) }
            if let reset {
                let minutes = max(1, Int((reset - Date().timeIntervalSince1970) / 60))
                return "GitHub 接口调用次数超限，约 \(minutes) 分钟后再试。也可以先用下面的「Releases 页面」下载"
            }
            return "GitHub 接口调用次数超限，请稍后再试，或用「Releases 页面」直接下载"
        case 404:
            return "找不到对应的 Release，检查仓库地址或版本号"
        default:
            return "GitHub 返回 \(http.statusCode)"
        }
    }

    /// 比较 v1.2.3 与 v1.10.0 这种段位号；非纯数字段（如 v1.0.0-beta）按字符串兜底。
    private func isNewer(_ tag: String) -> Bool {
        let remote = Self.parse(tag)
        let local = Self.parse(currentVersion)
        if remote.isEmpty || local.isEmpty { return tag != currentVersion }
        for (lhs, rhs) in zip(remote, local) {
            if lhs != rhs { return lhs > rhs }
        }
        return remote.count > local.count
    }

    private static func parse(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let head = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? trimmed
        return head.split(separator: ".").compactMap { Int($0) }
    }

    // MARK: - 下载并安装

    /// 下载 IPA 并交给系统安装。
    func install(_ release: Release) async {
        guard let asset = Self.pickIPA(from: release.assets) else {
            phase = .failed("这个版本没有 .ipa 附件")
            return
        }
        guard let url = URL(string: asset.browser_download_url) else {
            phase = .failed("下载地址无效")
            return
        }

        progressTask?.cancel()
        progressTask = Task { [weak self] in
            guard let self else { return }
            self.phase = .downloading(progress: 0)
            Log.info("更新", "开始下载 \(asset.name)（\(asset.size) 字节）")
            do {
                let localURL = try await Self.download(url: url, assetName: asset.name) { [weak self] ratio in
                    Task { @MainActor [weak self] in self?.phase = .downloading(progress: ratio) }
                }
                let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                Log.info("更新", "下载完成：\(localURL.lastPathComponent)，实际 \(size) 字节，期望 \(asset.size) 字节")
                if size > 0, asset.size > 0, size != Int64(asset.size) {
                    Log.warn("更新", "文件大小与 Release 声明不一致（\(size) vs \(asset.size)），包可能不完整")
                }
                self.phase = .ready(localURL)
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                Log.error("更新", "下载失败：\(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
            }
        }
        await progressTask?.value
    }

    func cancel() {
        progressTask?.cancel()
        progressTask = nil
        phase = .idle
    }

    /// 准备安装：把包拷到越狱安装器能读到的公共目录。
    ///
    /// SpringBoard 跑在 App 沙盒之外，读不到 App 自己的 Documents，所以必须先落到
    /// /var/mobile/Media 下——AppSync / Zebra / Filza 都是从那里找包的。
    func prepareInstall(_ fileURL: URL) -> URL {
        let shared = Self.shareToPublicDownloads(fileURL)
        if shared.path == fileURL.path {
            Log.warn("更新", "公共下载目录不可写，安装包仍留在沙盒内：\(fileURL.path)")
        } else {
            Log.info("更新", "安装包已拷到 \(shared.path)")
        }
        return shared
    }

    /// 直接唤起安装。新版 iOS 上系统没给 .ipa 注册 open 处理器，所以这个经常无效，
    /// 真正的可靠路径是分享面板让用户选 AppSync / Zebra / Filza。
    func tryOpenInstaller(_ fileURL: URL) {
        let shared = prepareInstall(fileURL)
        Log.info("更新", "尝试直接唤起安装 \(shared.lastPathComponent)")
        UIApplication.shared.open(shared) { [weak self] success in
            if success {
                Log.info("更新", "系统接管了安装请求")
            } else {
                Log.warn("更新", "系统没有接管安装请求，改用分享面板")
            }
            guard !success else { return }
            Task { @MainActor [weak self] in
                self?.installHint = "系统没有直接弹出安装界面。请在下面的分享面板里选 AppSync / Zebra / Filza 打开。"
            }
        }
    }

    /// 直唤失败时给用户的提示，不覆盖当前状态（包还在，用户还能用分享面板）。
    @Published var installHint: String?

    /// 拷贝到越狱常见的公共下载目录。AppSync / Zebra / Filza 都在这几个位置找包。
    private static func shareToPublicDownloads(_ fileURL: URL) -> URL {
        let candidates = [
            "/var/mobile/Media/Public/Downloads",
            "/var/mobile/Media/Downloads",
        ]
        for path in candidates {
            let dir = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                Log.warn("更新", "公共目录不存在：\(path)")
                continue
            }
            let target = dir.appendingPathComponent(fileURL.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: fileURL, to: target)
                return target
            } catch {
                Log.error("更新", "拷贝到 \(path) 失败：\(error.localizedDescription)")
                continue
            }
        }
        // 目录不存在或没权限时，退回沙盒路径，至少让分享面板能拿到
        return fileURL
    }

    /// 把 IPA 收进 Documents 下的 Updates 目录（Downloads 目录在安装后可能被清）。
    private static func download(url: URL,
                                assetName: String,
                                onProgress: @escaping (Double) -> Void) async throws -> URL {
        onProgress(0)
        // 用 data(from:) 而不是 bytes(from:)：后者要手写分块落盘，中途出错容易
        // 留下半截文件，而且拿不到最终内容做格式校验。
        let (data, response) = try await URLSession.shared.data(from: url)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            Log.error("更新", "下载返回 HTTP \(code)")
            throw UpdateError.http
        }
        // 撞到限流或登录页时，服务器会返回一小段 HTML/JSON 错误内容而不是 ipa。
        // 不校验的话会写出一个几百字节的假安装包，用户到安装那步才发现。
        guard dataStartsWithPK(data) else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            Log.error("更新", "下载到的不是 IPA（开头 \(preview.prefix(120))）")
            throw UpdateError.notIPA
        }
        Log.info("更新", "已取到 \(data.count) 字节，确认是 IPA 格式")

        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(assetName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try data.write(to: destination, options: .atomic)
        onProgress(1)
        return destination
    }

    /// IPA 本质是 zip，文件头是 PK\x03\x04。
    private static func dataStartsWithPK(_ data: Data) -> Bool {
        data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04
    }

    private static func pickIPA(from assets: [Asset]) -> Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".ipa") }
            ?? assets.first { $0.name.lowercased().hasSuffix(".tipa") }
    }

    // MARK: - UI 用

    var versionText: String { "v\(currentVersion) (\(currentBuild))" }

    /// Release note 转纯文本，GitHub 的 markdown 太长时只取前几行。
    static func notes(from body: String?, limit: Int = 6) -> [String] {
        guard let body, !body.isEmpty else { return [] }
        return body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<") }
            .prefix(limit)
            .map { $0.replacingOccurrences(of: "**", with: "") }
    }
}

enum UpdateError: LocalizedError {
    case http
    case notIPA

    var errorDescription: String? {
        switch self {
        case .http: return "下载失败，服务器没有返回安装包"
        case .notIPA: return "下载到的不是安装包（可能触发了 GitHub 限流），请稍后重试或用「Releases 页面」下载"
        }
    }
}
