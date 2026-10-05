import Foundation
import Security
import Combine
import CryptoKit

/// 本地账号系统：用户名 + 密码（Keychain 存哈希）。
///
/// 数据隔离策略：
/// - 曲库（收藏/歌单/历史/下载记录/本地歌曲记录）按 userId 加前缀存 UserDefaults
/// - 下载的音频文件（Documents/Aurora Downloads/）和音源脚本（Documents/Sources/）是共享资源，所有用户共用
/// - 密码不存明文，SHA256(password + salt) 存 Keychain
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    /// 当前登录的用户名；nil = 游客模式
    @Published private(set) var currentUser: String?

    private let defaults = UserDefaults.standard
    private enum K {
        static let currentUser = "aurora.auth.currentUser"
        static let registeredUsers = "aurora.auth.registeredUsers" // [String]
    }

    private init() {
        currentUser = defaults.string(forKey: K.currentUser)
    }

    // MARK: - 公开 API

    var isLoggedIn: Bool { currentUser != nil }

    /// 注册新账号。首次注册会把游客数据（无前缀 key）迁移到新用户的命名空间下。
    func register(username: String, password: String) throws {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw AuthError.emptyUsername }
        guard password.count >= 4 else { throw AuthError.passwordTooShort }
        let name = trimmed.lowercased()

        var users = defaults.stringArray(forKey: K.registeredUsers) ?? []
        guard !users.contains(name) else { throw AuthError.userExists }

        // Keychain 存 hash
        try savePassword(password, for: name)
        users.append(name)
        defaults.set(users, forKey: K.registeredUsers)

        // 数据迁移：把游客的未前缀 key 复制到 aurora.user.<name>.*
        migrateGuestData(to: name)

        currentUser = name
        defaults.set(name, forKey: K.currentUser)
        LibraryStore.shared.switchUser(userId: name)
        Log.info("账号", "注册并登录 \(name)")
    }

    func login(username: String, password: String) throws {
        let name = username.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { throw AuthError.emptyUsername }
        guard verifyPassword(password, for: name) else { throw AuthError.wrongPassword }

        currentUser = name
        defaults.set(name, forKey: K.currentUser)
        LibraryStore.shared.switchUser(userId: name)
        Log.info("账号", "登录 \(name)")
    }

    func logout() {
        currentUser = nil
        defaults.removeObject(forKey: K.currentUser)
        LibraryStore.shared.switchUser(userId: nil) // nil = 游客，用无前缀 key
        Log.info("账号", "退出登录")
    }

    func deleteAccount(username: String, password: String) throws {
        let name = username.lowercased()
        guard verifyPassword(password, for: name) else { throw AuthError.wrongPassword }

        // 删 Keychain
        deletePassword(for: name)

        // 删用户数据（UserDefaults）
        let prefix = userKeyPrefix(for: name)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }

        // 从注册列表移除
        var users = defaults.stringArray(forKey: K.registeredUsers) ?? []
        users.removeAll { $0 == name }
        defaults.set(users, forKey: K.registeredUsers)

        // 如果删的是当前登录用户 → 退出到游客
        if currentUser == name {
            logout()
        }
        Log.info("账号", "删除账号 \(name)")
    }

    // MARK: - Keychain 密码

    private struct Account {
        static let service = "com.aurora.music"
        static func query(account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: account]
        }
    }

    private func savePassword(_ password: String, for account: String) throws {
        // 先删旧的（如果有）
        SecItemDelete(Account.query(account: account) as CFDictionary)

        let salt = UUID().uuidString.data(using: .utf8)!
        let hash = sha256((password + salt.base64EncodedString()).data(using: .utf8)!)

        var query = Account.query(account: account)
        query[kSecValueData as String] = hash
        query[kSecAttrGeneric as String] = salt // 存 salt
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.keychainFailed(status)
        }
    }

    private func verifyPassword(_ password: String, for account: String) -> Bool {
        var query = Account.query(account: account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let dict = result as? [String: Any],
              let storedHash = dict[kSecValueData as String] as? Data,
              let salt = dict[kSecAttrGeneric as String] as? Data else {
            return false
        }
        let computed = sha256((password + salt.base64EncodedString()).data(using: .utf8)!)
        return computed == storedHash
    }

    private func deletePassword(for account: String) {
        SecItemDelete(Account.query(account: account) as CFDictionary)
    }

    // MARK: - 数据迁移

    /// 把无前缀 key 的游客数据复制到 aurora.user.<userId>.* 前缀下。
    /// 只在注册时调一次。
    private func migrateGuestData(to userId: String) {
        let prefix = userKeyPrefix(for: userId)
        let guestKeys = ["aurora.library.favorites", "aurora.library.downloads",
                         "aurora.library.local", "aurora.library.playlists",
                         "aurora.library.history", "aurora.library.songTable"]
        for key in guestKeys {
            if let data = defaults.data(forKey: key) {
                defaults.set(data, forKey: prefix + key)
            }
        }
        Log.info("账号", "游客数据迁移到 \(prefix) 完成")
    }

    static func userKeyPrefix(for userId: String?) -> String {
        guard let userId, !userId.isEmpty else { return "" }
        return "aurora.user.\(userId)."
    }

    private func sha256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: 32)
        _ = data.withUnsafeBytes { bytes in
            SHA256.hash(bytes, into: &hash)
        }
        return Data(hash)
    }
}

enum AuthError: LocalizedError {
    case emptyUsername
    case passwordTooShort
    case userExists
    case wrongPassword
    case keychainFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyUsername: return "用户名不能为空"
        case .passwordTooShort: return "密码至少 4 位"
        case .userExists: return "这个用户名已经注册过了"
        case .wrongPassword: return "用户名或密码不对"
        case .keychainFailed(let code): return "钥匙串操作失败（\(code)）"
        }
    }
}
