import CryptoKit
import Foundation
import Security
import SwiftUI

/// 🔴 v2.9.0：一机一码离线授权。
///
/// 每台设备有一个稳定的设备 ID（优先存 Keychain，重装 / 覆盖安装都不变），
/// 授权码 = SHA256("密钥|设备ID") 的十六进制前 16 位。
/// App 自己重算一遍比对即可，**完全离线、不要服务器、激活后永久有效**。
///
/// 一个设备码只能对应一个授权码；换手机（或抹掉重装系统）设备 ID 会变，需要重新授权。
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published private(set) var isActivated: Bool = false

    /// 设备 ID（大写 UUID）。锁屏展示给用户，用来换取授权码。
    private(set) var deviceID: String = ""

    private let activatedKey = "aurora.license.activated"
    private let savedCodeKey = "aurora.license.code"
    private let deviceIDDefaultsKey = "aurora.license.deviceID"
    private let keychainService = "com.auroramusic.license"
    private let keychainAccount = "deviceID"

    private init() {
        deviceID = Self.loadOrCreateDeviceID(
            service: keychainService,
            account: keychainAccount,
            defaultsKey: deviceIDDefaultsKey
        )
        let d = UserDefaults.standard
        // 🔴 只认标志位不够 —— 手改 UserDefaults 就能绕过；
        // 存下来的授权码必须和当前设备 ID 重新算出来的结果对得上。
        if d.bool(forKey: activatedKey) {
            let saved = d.string(forKey: savedCodeKey) ?? ""
            isActivated = !saved.isEmpty && saved == Self.expectedCode(for: deviceID)
        }
        Log.info("授权", "设备ID=\(deviceID) 已激活=\(isActivated)")
    }

    // MARK: - 授权码

    /// 输入归一化：忽略大小写、空格、连字符（用户粘贴 `xxxx-xxxx-xxxx-xxxx` 也能用）
    static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 某台设备「应该」对应的授权码（生成器用同样算法离线算出）
    /// 算法：SHA256("<密钥>|<设备ID>") 的十六进制前 16 位大写。
    static func expectedCode(for deviceID: String) -> String {
        let raw = "\(LicenseSecret.value)|\(deviceID.uppercased())"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).uppercased()
    }

    /// 展示用：`XXXX-XXXX-XXXX-XXXX`
    static func pretty(_ code: String) -> String {
        let s = normalize(code)
        guard !s.isEmpty else { return "" }
        return stride(from: 0, to: s.count, by: 4)
            .map { i -> String in
                let start = s.index(s.startIndex, offsetBy: i)
                let end = s.index(start, offsetBy: min(4, s.distance(from: start, to: s.endIndex)))
                return String(s[start..<end])
            }
            .joined(separator: "-")
    }

    @discardableResult
    func activate(code: String) -> Bool {
        let normalized = Self.normalize(code)
        guard !normalized.isEmpty else { return false }
        guard normalized == Self.expectedCode(for: deviceID) else {
            Log.info("授权", "授权码校验失败：\(normalized)")
            return false
        }
        let d = UserDefaults.standard
        d.set(true, forKey: activatedKey)
        d.set(normalized, forKey: savedCodeKey)
        isActivated = true
        Haptics.success()
        Log.info("授权", "激活成功 \(Self.pretty(normalized))")
        return true
    }

    // MARK: - 设备 ID（Keychain 优先，失败回落 UserDefaults）

    private static func loadOrCreateDeviceID(service: String,
                                             account: String,
                                             defaultsKey: String) -> String {
        let d = UserDefaults.standard
        // ① Keychain：重装 App 也还在
        if let kc = LicenseKeychain.read(service: service, account: account), !kc.isEmpty {
            d.set(kc, forKey: defaultsKey)   // 同步一份做兜底
            return kc
        }
        // ② UserDefaults：Keychain 写不进去（极少数沙箱异常）时的兜底
        if let ud = d.string(forKey: defaultsKey), !ud.isEmpty {
            LicenseKeychain.write(ud, service: service, account: account)
            return ud
        }
        // ③ 全新设备
        let newID = UUID().uuidString.uppercased()
        LicenseKeychain.write(newID, service: service, account: account)
        d.set(newID, forKey: defaultsKey)
        Log.info("授权", "生成新设备ID \(newID)")
        return newID
    }
}

// MARK: - 极简 Keychain 读写

private enum LicenseKeychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess, let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }
}
