import Foundation

/// 下载歌曲的备份与恢复。
///
/// 备份目录结构（创建在用户选定的文件夹里）：
/// ```
/// Aurora Music 备份 2026-11-15 23-40-12/
///   audio/         ← Aurora Downloads 里的音频原文件
///   metadata/      ← Aurora Metadata 里的索引 json / 封面 / 歌词 / 写真
///   manifest.json  ← 备份时间、文件数、歌曲数、总字节
/// ```
/// 之所以连元数据一起备份：`DownloadManager.bootstrap()` 靠 metadata 里的
/// 索引 json 离线重建歌曲（歌名 / 歌手 / hash），只拷音频不拷索引，
/// 恢复后歌会「文件在但列表里看不到」。
enum DownloadBackup {
    struct Summary {
        var files = 0
        var songs = 0
        var bytes: Int64 = 0

        var isEmpty: Bool { files == 0 }

        mutating func add(_ other: Summary) {
            files += other.files
            songs += other.songs
            bytes += other.bytes
        }

        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    static let folderPrefix = "Aurora Music 备份"

    // MARK: - 备份

    /// 把当前全部下载（音频 + 元数据）备份到用户选定的文件夹。
    /// - Returns: 实际创建的备份子目录与统计。
    static func backup(to parent: URL) throws -> (folder: URL, summary: Summary) {
        let fm = FileManager.default
        let secured = parent.startAccessingSecurityScopedResource()
        defer { if secured { parent.stopAccessingSecurityScopedResource() } }

        let root = parent.appendingPathComponent("\(folderPrefix) \(stamp())", isDirectory: true)
        let audioDst = root.appendingPathComponent("audio", isDirectory: true)
        let metaDst = root.appendingPathComponent("metadata", isDirectory: true)
        try fm.createDirectory(at: audioDst, withIntermediateDirectories: true)
        try fm.createDirectory(at: metaDst, withIntermediateDirectories: true)

        var summary = copyContents(of: DownloadManager.directory(), to: audioDst,
                                   countSongs: true, overwrite: false, onlyAudio: false)
        summary.add(copyContents(of: DownloadManager.metadataDirectory(), to: metaDst,
                                 countSongs: false, overwrite: false, onlyAudio: false))

        let manifest: [String: Any] = [
            "format": 1,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "files": summary.files,
            "songs": summary.songs,
            "bytes": summary.bytes,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try? data.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        }
        return (root, summary)
    }

    // MARK: - 恢复

    /// 从备份目录把音频与元数据拷回 App，调用方随后需 `bootstrap()` 重建列表。
    ///
    /// 兼容三种选择方式：
    /// ① 选中备份根目录（含 `audio/`）；
    /// ② 选中 `audio/` 子目录本身；
    /// ③ 选中一个普通文件夹（里面直接放着音频），此时顺带尝试同级的 `metadata/`。
    static func restore(from picked: URL) throws -> Summary {
        let fm = FileManager.default
        let secured = picked.startAccessingSecurityScopedResource()
        defer { if secured { picked.stopAccessingSecurityScopedResource() } }

        let parent = picked.deletingLastPathComponent()
        let audioCandidates = [
            picked.appendingPathComponent("audio", isDirectory: true),
            parent.appendingPathComponent("audio", isDirectory: true),
        ]
        let audioSrc = audioCandidates.first { fm.fileExists(atPath: $0.path) } ?? picked

        let metaCandidates = [
            picked.appendingPathComponent("metadata", isDirectory: true),
            parent.appendingPathComponent("metadata", isDirectory: true),
        ]
        let metaSrc = metaCandidates.first { fm.fileExists(atPath: $0.path) }

        var summary = copyContents(of: audioSrc, to: DownloadManager.directory(),
                                  countSongs: true, overwrite: true, onlyAudio: true)
        if let metaSrc {
            summary.add(copyContents(of: metaSrc, to: DownloadManager.metadataDirectory(),
                                     countSongs: false, overwrite: true, onlyAudio: false))
        }
        return summary
    }

    // MARK: - 工具

    private static func copyContents(of source: URL,
                                     to destination: URL,
                                     countSongs: Bool,
                                     overwrite: Bool,
                                     onlyAudio: Bool) -> Summary {
        let fm = FileManager.default
        var summary = Summary()
        guard let names = try? fm.contentsOfDirectory(atPath: source.path) else { return summary }

        for name in names where !name.hasPrefix(".") {
            let from = source.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDir), !isDir.boolValue else { continue }

            let ext = (name as NSString).pathExtension.lowercased()
            let isAudio = DownloadManager.audioExtensions.contains(ext)
            if onlyAudio && !isAudio { continue }

            let to = destination.appendingPathComponent(name)
            if from.standardizedFileURL.path == to.standardizedFileURL.path { continue }

            do {
                if fm.fileExists(atPath: to.path) {
                    guard overwrite else { continue }
                    try fm.removeItem(at: to)
                }
                try fm.copyItem(at: from, to: to)
                summary.files += 1
                if let attrs = try? fm.attributesOfItem(atPath: to.path),
                   let size = (attrs[.size] as? NSNumber)?.int64Value {
                    summary.bytes += size
                }
                if countSongs && isAudio { summary.songs += 1 }
            } catch {
                continue
            }
        }
        return summary
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: Date())
    }
}
