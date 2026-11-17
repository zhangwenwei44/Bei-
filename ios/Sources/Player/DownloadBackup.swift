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
    enum BackupError: LocalizedError {
        case nothingToBackup

        var errorDescription: String? {
            switch self {
            case .nothingToBackup: return "当前没有可备份的歌曲。"
            }
        }
    }

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

    // MARK: - 打包 / 导出（🔴 2026-11-16：不再依赖「选择文件夹」）

    /// App 的 Documents/Backups。`UIFileSharingEnabled = true`，用户在「文件」App 里
    /// 能直接看到这里，哪怕取消导出，备份也已经在本机，绝不会「备份不了」。
    static func localBackupDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask)[0]
        return documents.appendingPathComponent("Backups", isDirectory: true)
    }

    /// 先在本机生成完整备份目录，再打包成**单个 zip**。
    /// 单文件才能用系统原生的「导出 / 存储到文件」让用户选目标文件夹，
    /// 这是绕开 `UTType.folder` 文档选择器在部分 iOS 版本上不回调的关键。
    /// 🔴 2026-11-17：打包前先补齐缺失的封面/歌词侧车，保证备份本身就带元数据；
    ///    并在 zip 根额外写一份 `sidecars.json`（base64），元数据目录丢失时也能还原。
    static func createArchive() async throws -> (archive: URL, summary: Summary) {
        await DownloadManager.shared.ensureSidecarsForDownloads()
        let fm = FileManager.default
        let local = localBackupDirectory()
        try fm.createDirectory(at: local, withIntermediateDirectories: true)

        let (folder, summary) = try backup(to: local)
        guard !summary.isEmpty else {
            try? fm.removeItem(at: folder)
            throw BackupError.nothingToBackup
        }

        // 🔴 2026-11-16：额外写一份完整歌曲清单。旧版备份只依赖 metadata 里的
        //    索引 json，一旦索引缺失或与音频文件名对不上，`bootstrap()` 会把整批
        //    歌过滤掉（提示恢复成功但列表显示「还没有下载」）。这份清单是权威兜底，
        //    恢复时能还原歌名 / 歌手 / hash / 封面，也能给每个音频补写索引。
        let songList = LibraryStore.shared.downloads
        if let data = try? JSONEncoder().encode(songList) {
            try? data.write(to: folder.appendingPathComponent("songs.json"), options: .atomic)
        }

        // 🔴 2026-11-17：封面 / 歌词 / 写真再以 base64 写一份到备份根。
        //    正常备份 metadata/ 里已经有这些文件；这一份是双保险 —— 旧版备份
        //    或用户手动整理过 zip 导致 metadata 丢失时，恢复端仍能把图/词写回去。
        var sidecars: [String: [String: String]] = [:]
        let metaDir = DownloadManager.metadataDirectory()
        for song in songList {
            let base = DownloadManager.sanitize(song.id)
            var entry: [String: String] = [:]
            for (key, ext) in [("art", "art.png"), ("lyrics", "lrc"), ("photo", "photo.png")] {
                if let data = try? Data(contentsOf: metaDir.appendingPathComponent("\(base).\(ext)")) {
                    entry[key] = data.base64EncodedString()
                }
            }
            if !entry.isEmpty { sidecars[base] = entry }
        }
        if let data = try? JSONSerialization.data(withJSONObject: sidecars) {
            try? data.write(to: folder.appendingPathComponent("sidecars.json"), options: .atomic)
        }

        var files: [(relativePath: String, url: URL)] = []
        if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                let prefix = folder.path + "/"
                let relative = file.path.hasPrefix(prefix)
                    ? String(file.path.dropFirst(prefix.count))
                    : file.lastPathComponent
                files.append((relativePath: relative, url: file))
            }
        }

        let archive = local.appendingPathComponent(folder.lastPathComponent + ".zip")
        try BackupArchive.create(files: files, to: archive)
        return (archive, summary)
    }

    /// 从 zip 备份恢复：解压到临时目录 → 复用目录恢复逻辑 → 清理临时目录。
    /// 调用方随后需 `DownloadManager.bootstrap()` 重建列表。
    static func restore(fromArchive archive: URL) throws -> Summary {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
            .appendingPathComponent("AuroraRestore-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        try BackupArchive.extract(archive, to: temp)

        // 兼容「zip 里再套一层备份文件夹」和「zip 直接是备份根」两种结构。
        var root = temp
        if let names = try? fm.contentsOfDirectory(atPath: temp.path), names.count == 1,
           let first = names.first {
            let candidate = temp.appendingPathComponent(first, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                root = candidate
            }
        }
        let summary = try restore(from: root)

        // 🔴 2026-11-17：先还原 base64 侧车双保险（只补缺失，不覆盖已有）；
        //    这样即使备份里的 metadata/ 不完整，下面的 rebuildIndexes 也能
        //    按 songID 找到对应的封面 / 歌词 / 写真。
        for candidate in [root.appendingPathComponent("sidecars.json"),
                          temp.appendingPathComponent("sidecars.json")] {
            guard let data = try? Data(contentsOf: candidate),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
            else { continue }
            let targetDir = DownloadManager.metadataDirectory()
            for (base, entry) in map {
                for (key, ext) in [("art", "art.png"), ("lyrics", "lrc"), ("photo", "photo.png")] {
                    guard let encoded = entry[key], let payload = Data(base64Encoded: encoded) else { continue }
                    let target = targetDir.appendingPathComponent("\(base).\(ext)")
                    if !fm.fileExists(atPath: target.path) {
                        try? payload.write(to: target, options: .atomic)
                    }
                }
            }
            break
        }

        // 🔴 2026-11-16：音频与元数据已拷回，但 `bootstrap()` 只认索引 json。
        //    这里读备份清单，以磁盘上的音频文件为准把缺失索引全部补齐；
        //    旧备份没有 songs.json 时清单为空，仍会按文件名兜底生成索引。
        //    纯文件 IO，@Published 一律留给调用方在主线程 `bootstrap()` 里写。
        var manifest: [Song] = []
        for candidate in [root.appendingPathComponent("songs.json"),
                          temp.appendingPathComponent("songs.json")] {
            if let data = try? Data(contentsOf: candidate),
               let songs = try? JSONDecoder().decode([Song].self, from: data) {
                manifest = songs
                break
            }
        }
        DownloadManager.shared.rebuildIndexes(manifest: manifest)
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
