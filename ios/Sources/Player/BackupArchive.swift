import Foundation

/// 极简 ZIP 读写（store 模式、不压缩），用于把「下载歌曲备份」打成单个文件。
///
/// 为什么自己写：App 不想为一个备份功能引入第三方依赖；音频文件本身已是压缩格式，
/// store 模式不额外耗 CPU，且解压端只需按中央目录取出原始字节，不需要 Compression 框架。
/// 生成的是标准 ZIP，用户也能在「文件」App 里直接解压查看。
enum BackupArchive {
    enum ArchiveError: LocalizedError {
        case badZip
        case unsupportedCompression
        case invalidName

        var errorDescription: String? {
            switch self {
            case .badZip: return "备份文件已损坏或不是有效的 zip。"
            case .unsupportedCompression: return "这个备份的压缩格式不支持。"
            case .invalidName: return "备份里包含非法文件名。"
            }
        }
    }

    // MARK: - 打包

    /// - Parameter files: `(压缩包内相对路径, 本机文件 URL)`。
    static func create(files: [(relativePath: String, url: URL)],
                       to destination: URL) throws {
        var body = Data()
        var central = Data()
        var count: UInt16 = 0

        for entry in files {
            guard !entry.relativePath.isEmpty else { continue }
            let payload = try Data(contentsOf: entry.url)
            let nameData = Data(entry.relativePath.utf8)
            guard nameData.count < Int(UInt16.max) else { continue }
            let checksum = crc32(payload)
            let size = UInt32(payload.count)
            let offset = UInt32(body.count)

            // Local file header
            append32(0x04034b50, &body)
            append16(20, &body)        // version needed
            append16(0x0800, &body)    // UTF-8 文件名
            append16(0, &body)         // method 0 = store
            append16(0, &body)         // DOS time
            append16(0x0021, &body)    // DOS date 1980-01-01
            append32(checksum, &body)
            append32(size, &body)
            append32(size, &body)
            append16(UInt16(nameData.count), &body)
            append16(0, &body)         // extra len
            body.append(nameData)
            body.append(payload)

            // Central directory header
            append32(0x02014b50, &central)
            append16(20, &central)     // version made by
            append16(20, &central)     // version needed
            append16(0x0800, &central)
            append16(0, &central)
            append16(0, &central)
            append16(0x0021, &central)
            append32(checksum, &central)
            append32(size, &central)
            append32(size, &central)
            append16(UInt16(nameData.count), &central)
            append16(0, &central)      // extra len
            append16(0, &central)      // comment len
            append16(0, &central)      // disk number
            append16(0, &central)      // internal attrs
            append32(0, &central)      // external attrs
            append32(offset, &central)
            central.append(nameData)
            count += 1
        }

        let centralOffset = UInt32(body.count)
        let centralSize = UInt32(central.count)
        body.append(central)

        // End of central directory
        append32(0x06054b50, &body)
        append16(0, &body)
        append16(0, &body)
        append16(count, &body)
        append16(count, &body)
        append32(centralSize, &body)
        append32(centralOffset, &body)
        append16(0, &body)

        try body.write(to: destination, options: .atomic)
    }

    // MARK: - 解包

    static func extract(_ archive: URL, to directory: URL) throws {
        let data = try Data(contentsOf: archive)
        guard data.count >= 22 else { throw ArchiveError.badZip }

        // EOCD 可能带注释，从尾部往回找签名
        var eocd: Int?
        let floor = max(0, data.count - 65558)
        var i = data.count - 22
        while i >= floor {
            if read32(data, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard let end = eocd else { throw ArchiveError.badZip }

        let entries = Int(read16(data, end + 10))
        var cursor = Int(read32(data, end + 16))
        let fm = FileManager.default

        for _ in 0..<entries {
            guard cursor + 46 <= data.count, read32(data, cursor) == 0x02014b50 else {
                throw ArchiveError.badZip
            }
            let method = read16(data, cursor + 10)
            let size = Int(read32(data, cursor + 20))
            let nameLength = Int(read16(data, cursor + 28))
            let extraLength = Int(read16(data, cursor + 30))
            let commentLength = Int(read16(data, cursor + 32))
            let localOffset = Int(read32(data, cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count,
                  let name = String(data: data.subdata(in: nameStart..<nameEnd),
                                    encoding: .utf8) else {
                throw ArchiveError.badZip
            }
            cursor = nameEnd + extraLength + commentLength

            guard method == 0 else { throw ArchiveError.unsupportedCompression }
            guard localOffset + 30 <= data.count,
                  read32(data, localOffset) == 0x04034b50 else {
                throw ArchiveError.badZip
            }
            let localNameLength = Int(read16(data, localOffset + 26))
            let localExtraLength = Int(read16(data, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + size <= data.count else { throw ArchiveError.badZip }

            // Zip Slip 防护：只允许相对路径、禁止 .. / 绝对路径
            let parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty, !name.hasPrefix("/"),
                  !parts.contains(where: { $0 == ".." || $0 == "." }) else {
                throw ArchiveError.invalidName
            }

            var parent = directory
            for part in parts.dropLast() {
                parent.appendPathComponent(part, isDirectory: true)
            }
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let target = parent.appendingPathComponent(parts[parts.count - 1])
            try data.subdata(in: dataStart..<(dataStart + size))
                .write(to: target, options: .atomic)
        }
    }

    // MARK: - 字节工具

    private static func append16(_ value: UInt16, _ data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func append32(_ value: UInt32, _ data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func read16(_ data: Data, _ index: Int) -> UInt16 {
        UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }

    private static func read32(_ data: Data, _ index: Int) -> UInt32 {
        UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[n] = c
        }
        return table
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
