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

    struct Asset: Decodable {
        var name: String
        var browser_download_url: String
        var size: Int
    }

    struct Release: Decodable {
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
    private let repo = "zhangwenwei44/KUgou"
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

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AuroraMusic/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                phase = .failed("网络异常")
                return
            }
            // 403/404 多半是 API 限流
            guard (200...299).contains(http.statusCode) else {
                phase = .failed("GitHub 返回 \(http.statusCode)，稍后再试")
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            lastCheckedAt = Date()
            if isNewer(release.tag_name) {
                phase = .available(release)
            } else {
                phase = .upToDate(current: currentVersion)
            }
        } catch {
            phase = .failed(error.localizedDescription)
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
            do {
                let localURL = try await Self.download(url: url, assetName: asset.name) { [weak self] ratio in
                    Task { @MainActor [weak self] in self?.phase = .downloading(progress: ratio) }
                }
                self.phase = .ready(localURL)
            } catch is CancellationError {
                self.phase = .idle
            } catch {
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

    /// 调起安装：越狱机由 AppSync 弹「选取软件安装」。
    func openInstaller(_ fileURL: URL) {
        UIApplication.shared.open(fileURL, options: [:]) { [weak self] success in
            guard !success else { return }
            Task { @MainActor [weak self] in
                self?.phase = .failed("系统没接住这个安装包。越狱设备请确认已安装 AppSync / Zebra，然后重试或用浏览器下载")
            }
        }
    }

    /// 把 IPA 收进 Documents 下的 Updates 目录（Downloads 目录在安装后可能被清）。
    private static func download(url: URL,
                                assetName: String,
                                onProgress: @escaping (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.http
        }
        let total = http.expectedContentLength

        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(assetName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { onProgress(min(1, Double(written) / Double(total))) }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        guard written > 0 else { throw UpdateError.empty }
        onProgress(1)
        return destination
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
    case empty

    var errorDescription: String? {
        switch self {
        case .http: return "下载失败，服务器没有返回安装包"
        case .empty: return "下载到的文件是空的"
        }
    }
}
