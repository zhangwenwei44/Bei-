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

    func md5Hex() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
