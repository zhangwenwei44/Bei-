import Foundation

/// 签名和脚本要用到的几个基础摘要。
enum Digest {
    static func md5Hex(_ text: String) -> String {
        Data(text.utf8).md5Hex()
    }
}

extension Data {
    init(hexString: String) {
        var hex = hexString
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        if !hex.count.isMultiple(of: 2) { hex = "0" + hex }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        self.init(bytes)
    }

    /// MD5 摘要（小端序输出）。
    ///
    /// 自己实现而不用 CommonCrypto 的 CC_MD5：后者在 iOS 13 起被标记为已弃用，
    /// 每次调用都会产生一条编译警告，而 CI 现在把警告当失败。
    /// 算法本身是 RFC 1321 的标准实现，行为与 CC_MD5 完全一致。
    ///
    /// 这里的 MD5 不是拿来做安全防护的：酷狗接口的 signature / key 协议规定死了
    /// 用 MD5，洛雪音源脚本内部也用 MD5 做请求签名。
    func md5Hex() -> String {
        var digest = MD5.hash(Array(self))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 纯 Swift 的 MD5 实现。
enum MD5 {
    /// 每轮循环用的移位量。
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    /// 每轮用的加法常数：floor(abs(sin(i + 1)) * 2^32)。
    private static let table: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        // 填充到 448 mod 64，再追加 64 位长度（小端）
        var padded = message
        let bitLength = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for i in 0..<8 {
            padded.append(UInt8truncating(bitLength: bitLength, index: i))
        }

        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for j in 0..<16 {
                let base = chunkStart + j * 4
                m[j] = UInt32(padded[base])
                    | (UInt32(padded[base + 1]) << 8)
                    | (UInt32(padded[base + 2]) << 16)
                    | (UInt32(padded[base + 3]) << 24)
            }

            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16:
                    f = (b & c) | (~b & d)
                    g = i
                case 16..<32:
                    f = (d & b) | (~d & c)
                    g = (5 * i + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * i) % 16
                }
                f = f &+ a &+ table[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ rotateLeft(f, by: shifts[i])
            }

            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        var out = [UInt8]()
        out.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            for shift in stride(from: 0, to: 32, by: 8) {
                out.append(UInt8truncating(word: word, shift: shift))
            }
        }
        return out
    }

    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }

    private static func UInt8truncating(bitLength: UInt64, index: Int) -> UInt8 {
        UInt8((bitLength >> UInt64(index * 8)) & 0xFF)
    }

    private static func UInt8truncating(word: UInt32, shift: Int) -> UInt8 {
        UInt8((word >> UInt32(shift)) & 0xFF)
    }
}
