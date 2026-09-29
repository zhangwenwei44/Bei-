import Foundation
import SwiftUI
import UIKit

/// 运行日志。
///
/// 之前排查歌单空白和音源导入特别费劲：代码里大量 `try?` / `guard ... else { return [] }`，
/// 出错和「本来就空」在界面上长得一模一样。这里把所有这些静默点记下来，
/// 界面上能看、能导出，出问题把文件发出来就能定位。
enum Log {
    enum Level: String, Codable, Comparable, CaseIterable {
        case debug, info, warn, error

        var order: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            }
        }

        var label: String {
            switch self {
            case .debug: return "调试"
            case .info: return "信息"
            case .warn: return "警告"
            case .error: return "错误"
            }
        }

        var symbol: String {
            switch self {
            case .debug: return "ladybug"
            case .info: return "info.circle"
            case .warn: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.order < rhs.order }
    }

    struct Entry: Identifiable, Codable {
        // Codable 时用日期做主键：id 带初值时不会被解码还原，
        // 每次读回日志都会生成新 UUID，SwiftUI 的 diff 会把整列表当成全新内容重建。
        var id: Date { date }
        let date: Date
        let level: Level
        let category: String
        let message: String

        var timeText: String {
            Entry.formatter.string(from: date)
        }

        static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    static func debug(_ category: String, _ message: @autoclosure () -> String) {
        append(.debug, category, message())
    }

    static func info(_ category: String, _ message: @autoclosure () -> String) {
        append(.info, category, message())
    }

    static func warn(_ category: String, _ message: @autoclosure () -> String) {
        append(.warn, category, message())
    }

    static func error(_ category: String, _ message: @autoclosure () -> String) {
        append(.error, category, message())
    }

    private static func append(_ level: Level, _ category: String, _ message: String) {
        LogStore.shared.append(level: level, category: category, message: message)
    }
}

/// 日志仓库：内存环形缓冲 + 落盘。
///
/// 落盘用滚动文件，超过单个文件上限就换新文件，避免把设备存储写满。
///
/// 刻意不标 @MainActor：网络层是非隔离的，标了连单例都初始化不了。
/// 需要动 @Published 的方法单独标 @MainActor。
final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// 内存里最多留这么多条，太老的丢掉。
    private let memoryLimit = 2000
    /// 单个日志文件上限，超过就滚动。
    private let fileSizeLimit = 2 * 1024 * 1024
    /// 最多留几个日志文件。
    private let fileLimit = 5

    @Published private(set) var entries: [Log.Entry] = []
    @Published private(set) var logFileURLs: [URL] = []

    /// 低于这个级别的不记，调试时可以在设置里放开。
    @Published var minLevel: Log.Level = .debug

    /// 落盘专用串行队列。见 append 里的说明。
    private let diskQueue = DispatchQueue(label: "Aurora.LogStore.disk")

    private var currentFile: URL?
    private var currentHandle: FileHandle?
    private var currentBytes = 0
    private let iso = ISO8601DateFormatter()
    /// 带小数秒的变体。默认的 iso 不产出小数秒，但别处（比如手工复制的日志）
    /// 可能带，两种都要能读回来。
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 单例可能被非主线程首次访问，所以 init 里只碰非隔离状态；
    /// @Published 的 logFileURLs 留给主线程刷新（见 reloadFromDisk / pruneOldFiles）。
    private init() {
        let dir = Self.logDirectoryURL()
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
        if let latest = files.max(by: { Self.modified($0) < Self.modified($1) }) {
            currentFile = latest
            currentHandle = try? FileHandle(forWritingTo: latest)
            currentBytes = (try? latest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func logDirectoryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Logs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: 写入

    nonisolated func append(level: Log.Level, category: String, message: String) {
        guard level >= minLevel else { return }
        // 时间戳在调用点取：之前是主线程真正写入时才取，主线程一忙
        // 日志时间整体漂移，事件顺序看着都对不上。
        let entry = Log.Entry(date: Date(), level: level, category: category, message: message)
        // 落盘走专用串行队列，不等主线程：之前整个写入都在
        // Task { @MainActor } 里，进程崩溃/冻结时排在队列里的日志全部丢失
        // ——恰恰是排查问题最需要的那几行。
        diskQueue.async { [weak self] in
            self?.appendToDisk(entry)
        }
        // 内存里的条目给界面看，仍然回主线程更新
        Task { @MainActor [weak self] in
            self?.write(entry)
        }
    }

    @MainActor
    private func write(_ entry: Log.Entry) {
        entries.append(entry)
        if entries.count > memoryLimit {
            entries.removeFirst(entries.count - memoryLimit)
        }
    }

    /// 只在 diskQueue 上跑。
    private func appendToDisk(_ entry: Log.Entry) {
        // 用 | 分隔而不是 "] "：原来用 "] " 会把级别后面的右方括号当成分隔符吃掉，
        // 解析时 head 里就找不到配对的 "]"，导致每一行都解析失败、整份日志被清空。
        let line = "\(iso.string(from: entry.date))|\(entry.level.rawValue)|\(entry.category)|\(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            if currentHandle == nil { openNewFile() }
            try currentHandle?.write(contentsOf: data)
            currentBytes += data.count
            if currentBytes > fileSizeLimit { rotate() }
        } catch {
            // 日志写失败不能影响主流程
        }
    }

    /// 只在 diskQueue 上跑。
    private func openNewFile() {
        closeHandle()
        let name = "aurora-\(fileStamp()).log"
        let url = Self.logDirectoryURL().appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        currentFile = url
        currentHandle = try? FileHandle(forWritingTo: url)
        currentBytes = 0
        pruneOldFiles()
    }

    /// 只在 diskQueue 上跑。
    private func closeHandle() {
        try? currentHandle?.close()
        currentHandle = nil
        currentFile = nil
        currentBytes = 0
    }

    /// 只在 diskQueue 上跑。
    private func rotate() {
        closeHandle()
        openNewFile()
    }

    private func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// 只在 diskQueue 上跑。
    private func pruneOldFiles() {
        let dir = Self.logDirectoryURL()
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { Self.modified($0) > Self.modified($1) }
        // logFileURLs 是 @Published，回主线程更新
        Task { @MainActor in
            self.logFileURLs = files
        }
        // 自己刚建的那个不能删，从最旧的开始清
        for file in files.dropFirst(fileLimit) {
            if file != currentFile { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: 读回

    /// 把磁盘上的历史日志读进内存，方便界面上直接看。
    @MainActor
    func reloadFromDisk() {
        if logFileURLs.isEmpty {
            logFileURLs = ((try? FileManager.default.contentsOfDirectory(at: Self.logDirectoryURL(),
                                                                           includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "log" }
                .sorted { Self.modified($0) > Self.modified($1) }
        }
        var loaded: [Log.Entry] = []
        var unparsed = 0
        for file in logFileURLs.reversed() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where !line.isEmpty {
                if let entry = parse(line: String(line)) {
                    loaded.append(entry)
                } else {
                    unparsed += 1
                }
            }
        }
        // 一条都解析不出来时绝不能覆盖内存里的条目：
        // 之前就是这么把已有日志全清空的，结果导出出来是 0 条，等于白记。
        if loaded.isEmpty && !entries.isEmpty {
            NSLog("[LogStore] 磁盘有 \(logFileURLs.count) 个文件、\(unparsed) 行没能解析，保留内存里的 \(entries.count) 条")
            return
        }
        if unparsed > 0 {
            NSLog("[LogStore] 有 \(unparsed) 行没解析出来（日志格式可能来自更早的版本）")
        }
        entries = Array(loaded.suffix(memoryLimit))
    }

    private func parse(line: String) -> Log.Entry? {
        // 格式：<ISO8601>|<level>|<category>|<message>
        // maxSplits: 3 —— 消息正文里可能有 |，不能继续切
        let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let raw = String(parts[0])
        guard let level = Log.Level(rawValue: parts[1].lowercased()),
              let date = iso.date(from: raw) ?? isoFractional.date(from: raw) else { return nil }
        return Log.Entry(date: date, level: level, category: String(parts[2]), message: String(parts[3]))
    }

    // MARK: 导出

    /// 导出一份带环境信息的完整报告，方便直接发出来分析。
    @MainActor
    func exportReport() -> URL? {
        reloadFromDisk()
        var out = ""
        out += "==== Aurora Music 运行日志 ====\n"
        out += "导出时间：\(iso.string(from: Date()))\n"
        out += "App 版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")\n"
        out += "构建号：\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知")\n"
        out += "系统：iOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "设备：\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)\n"
        out += "条目数：\(entries.count)\n"
        out += String(repeating: "=", count: 40) + "\n\n"
        for entry in entries {
            out += "\(iso.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)\n"
        }

        // 最后附上原始文件内容。解析器万一再出问题，也不会把证据弄丢。
        out += "\n" + String(repeating: "=", count: 40) + "\n"
        out += "以下为原始日志文件内容（未经解析）\n"
        out += String(repeating: "=", count: 40) + "\n"
        for file in logFileURLs {
            out += "\n---- \(file.lastPathComponent) ----\n"
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                out += text
            } else {
                out += "(读取失败)\n"
            }
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aurora-log-\(fileStamp()).txt")
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.error("日志", "导出报告失败：\(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    func clear() {
        entries = []
        let files = logFileURLs
        logFileURLs = []
        // 句柄和文件操作都在 diskQueue 上做，和正常写入保持串行
        diskQueue.async { [weak self] in
            self?.closeHandle()
            for file in files { try? FileManager.default.removeItem(at: file) }
            self?.openNewFile()
        }
    }

    /// 崩溃现场用的同步写入。
    ///
    /// 信号处理器和未捕获异常处理器里不能靠 `Task { @MainActor }`——进程马上就要死了，
    /// 那个 Task 根本来不及执行。这条路径直接同步落盘。
    nonisolated static func emergencyWrite(_ text: String) {
        emergencyLock.lock()
        defer { emergencyLock.unlock() }
        let dir = logDirectoryURL()
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date()))|error|崩溃|\(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        // 每次现场新建一个文件，避开和其他线程抢同一个句柄
        let name = "crash-\(Int(Date().timeIntervalSince1970)).log"
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.write(contentsOf: data)
    }

    private nonisolated static let emergencyLock = NSLock()
}
