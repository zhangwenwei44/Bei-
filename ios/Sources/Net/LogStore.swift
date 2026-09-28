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
        let id = UUID()
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

    private var currentFile: URL?
    private var currentHandle: FileHandle?
    private var currentBytes = 0
    private let iso = ISO8601DateFormatter()

    private init() {
        loadExisting()
    }

    // MARK: 写入

    nonisolated func append(level: Log.Level, category: String, message: String) {
        // 静态入口可能被非主线程调用，这里统一切回主线程
        Task { @MainActor [weak self] in
            self?.write(level: level, category: category, message: message)
        }
    }

    @MainActor
    private func write(level: Log.Level, category: String, message: String) {
        guard level >= minLevel else { return }
        let entry = Log.Entry(date: Date(), level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > memoryLimit {
            entries.removeFirst(entries.count - memoryLimit)
        }
        appendToDisk(entry)
    }

    @MainActor
    private func appendToDisk(_ entry: Log.Entry) {
        let line = "\(iso.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)\n"
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

    private func logDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Logs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    @MainActor
    private func openNewFile() {
        closeHandle()
        let name = "aurora-\(fileStamp()).log"
        let url = logDirectory().appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        currentFile = url
        currentHandle = try? FileHandle(forWritingTo: url)
        currentBytes = 0
        pruneOldFiles()
    }

    @MainActor
    private func closeHandle() {
        try? currentHandle?.close()
        currentHandle = nil
        currentFile = nil
        currentBytes = 0
    }

    @MainActor
    private func rotate() {
        closeHandle()
        openNewFile()
    }

    private func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    @MainActor
    private func pruneOldFiles() {
        let dir = logDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let a = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            } ?? []
        logFileURLs = files
        // 自己刚建的那个不能删，从最旧的开始清
        for file in files.dropFirst(fileLimit) {
            if file != currentFile { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: 读回

    @MainActor
    private func loadExisting() {
        let dir = logDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "log" } ?? []
        logFileURLs = files
        // 当前会话接在最新文件后面
        if let latest = files.max(by: {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }) {
            currentFile = latest
            currentHandle = try? FileHandle(forWritingTo: latest)
            currentBytes = (try? latest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        }
    }

    /// 把磁盘上的历史日志读进内存，方便界面上直接看。
    @MainActor
    func reloadFromDisk() {
        var loaded: [Log.Entry] = []
        for file in logFileURLs.reversed() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let entry = parse(line: String(line)) { loaded.append(entry) }
            }
        }
        entries = Array(loaded.suffix(memoryLimit))
    }

    private func parse(line: String) -> Log.Entry? {
        // 2026-01-01T00:00:00Z [WARN] [网络] 内容
        let parts = line.components(separatedBy: "] ")
        guard parts.count >= 3 else { return nil }
        let head = parts[0]
        guard let datePart = head.split(separator: " ").first,
              let date = iso.date(from: String(datePart)),
              let openIndex = head.firstIndex(of: "["),
              let closeIndex = head[head.index(after: openIndex)...].firstIndex(of: "]")
        else { return nil }
        let levelRaw = head[head.index(after: openIndex)..<closeIndex].lowercased()
        guard let level = Log.Level(rawValue: levelRaw) else { return nil }
        let catPart = parts[1]
        guard let catOpen = catPart.firstIndex(of: "["),
              let catClose = catPart.lastIndex(of: "]") else { return nil }
        let category = String(catPart[catPart.index(after: catOpen)..<catClose])
        let message = parts[2...].joined(separator: "] ")
        return Log.Entry(date: date, level: level, category: category, message: message)
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
        if let device = UIDevice.current.model, let ver = UIDevice.current.systemVersion {
            out += "设备：\(device) iOS \(ver)\n"
        }
        out += "条目数：\(entries.count)\n"
        out += String(repeating: "=", count: 40) + "\n\n"
        for entry in entries {
            out += "\(iso.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)\n"
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
        closeHandle()
        for file in logFileURLs { try? FileManager.default.removeItem(at: file) }
        logFileURLs = []
        openNewFile()
    }
}
