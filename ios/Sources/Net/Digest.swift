import CommonCrypto
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

    /// MD5 摘要。
    ///
    /// CC_MD5 在 iOS 13 起被标记为已弃用，理由是它不适合安全场景。
    /// 但这里不是用来做安全防护的：
    /// - 酷狗接口的 signature / key 就是 MD5，协议规定死了，换算法请求就不成立
    /// - 洛雪音源脚本内部也用 MD5 做请求签名，需要我们提供实现
    /// 所以保留算法，只抑制这一条弃用警告。
    func md5Hex() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        withUnsafeBytes { buffer in
            // 这里绕过符号直接取函数指针调用：CC_MD5 的弃用标记是因为它不适合
            // 做安全防护，但酷狗接口签名和洛雪脚本都硬性要求 MD5，算法换不得。
            _ = withUnsafePointer(to: deprecatedMD5) { $0(buffer.baseAddress, CC_LONG(count), &digest) }
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private typealias MD5Function = @convention(c) (UnsafeRawPointer?, CC_LONG, UnsafeMutablePointer<UInt8>*) -> UInt32
    private static let deprecatedMD5: MD5Function = CC_MD5
}
