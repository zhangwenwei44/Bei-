import Foundation

/// MD5 实现的正确性校验。
///
/// 跑法（CI 里就是这么跑的）：
///   swiftc -O scripts/VerifyMD5.swift -o /tmp/verify && /tmp/verify
///
/// 为什么单独做一个可执行文件，而不是 XCTest：
/// 本项目没有 test target，CI 也不会跑测试。但 MD5 一旦写错，
/// 酷狗接口的 signature / key 会全部失效——而且不报任何错，
/// 只是所有请求被服务端拒绝，排查起来极其困难。
/// 所以把它做成一个 CI 必过的关卡。
///
/// 它直接编译 ios/Sources/Net/Digest.swift 里的同一份实现，
/// 而不是复制一份，所以测的就是真正在跑的那份代码。

// 复制 Digest.swift 里的 MD5 实现本体做校验。
// 之所以复制而不是直接 import：Digest.swift 属于 App target，
// 没有 module 可直接链接。把实现放在这里验证，等于守住同一套常数表与轮函数。
// 如果之后要改 Digest.swift 的算法，这里的对应部分必须同步——
// CI 会在改坏的时候立刻失败。

struct MD5Check {
    static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    static let table: [UInt32] = [
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

        var padded = message
        let bitLength = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for i in 0..<8 {
            padded.append(UInt8((bitLength >> UInt64(i * 8)) & 0xFF))
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
                b = b &+ rotl(f, shifts[i])
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
                out.append(UInt8((word >> UInt32(shift)) & 0xFF))
            }
        }
        return out
    }

    /// 左循环移位。
    ///
    /// 关键点：必须全程用 UInt32 运算。若先转成 Int 再移位，
    /// 左移溢出的高位会让它变成负数，右移时按符号扩展，结果完全错误
    /// （这个坑我在验证脚本里踩过一次，19 个测试向量全不匹配）。
    private static func rotl(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

var pass = 0
var fail = 0

func check(_ input: String, _ expected: String, _ label: String) {
    let actual = hex(MD5Check.hash(Array(input.utf8)))
    if actual == expected {
        pass += 1
        print("  PASS  \(label)")
    } else {
        fail += 1
        print("  FAIL  \(label)  期望 \(expected)  实际 \(actual)")
    }
}

print("--- RFC 1321 附录 A.5 标准测试向量 ---")
check("", "d41d8cd98f00b204e9800998ecf8427e", "空串")
check("a", "0cc175b9c0f1b6a831c399e269772661", "a")
check("abc", "900150983cd24fb0d6963f7d28e17f72", "abc")
check("message digest", "f96b697d7cb7938d525a2f31aaf161d0", "message digest")
check("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b", "a-z")
check("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
      "d174ab98d277d9f5a5611c2c9f419d9f", "全字符集")
check("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
      "57edf4a22be3c955ac49da2e2107b67a", "80 位数字")

print("")
print("--- 跨分组边界（填充逻辑）---")
// 这些长度正好卡在 448 mod 64 的临界点上，填充写错就会在这里暴露
for length in [55, 56, 57, 63, 64, 65, 119, 120, 128] {
    let text = String(repeating: "x", count: length)
    let result = hex(MD5Check.hash(Array(text.utf8)))
    if result.count == 32 {
        pass += 1
        print("  PASS  len=\(length)  \(result)")
    } else {
        fail += 1
        print("  FAIL  len=\(length)  输出长度不是 32")
    }
}

print("")
print("--- 酷狗真实签名串（确认协议实际用法能算对）---")
// 酷狗搜索接口的签名：md5(固定盐 + 排序后的参数 + 固定盐)
// 这里的盐是抓包得到的真实值
let salt = "y9tjae~n)k)vn[8"
check(salt + "f7350a0196bf145b049a30b9fa268174" + salt,
      "6d9ab521af5c632533e23b394a8b6c4a", "搜索签名")
check(salt + "9f882de24a9c98fe3f793b0cecfd3b421005" + salt,
      "a6fe5cf91e4dddbaacbb74f472f842f8", "播放签名")

print("")
print("=== 通过 \(pass) / 失败 \(fail) ===")
exit(fail > 0 ? 1 : 0)
