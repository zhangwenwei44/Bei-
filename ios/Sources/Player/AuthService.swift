import Foundation
import Security
import Combine

/// 本地账号系统（已废弃）。
/// 迁移说明：v2.5.0 起改为游客模式 + 酷狗音乐扫码登录。
/// 这个类保留只给 LibraryStore.switchUser(userId:) 调用做兼容，
/// currentUser 永远是 nil。
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    /// 永远是 nil —— 游客模式
    @Published private(set) var currentUser: String? = nil

    private init() {
        // 清空所有本地账号痕迹（老用户升级时自动清除）
        let defaults = UserDefaults.standard
        if let oldUser = defaults.string(forKey: "aurora.auth.currentUser") {
            defaults.removeObject(forKey: "aurora.auth.currentUser")
            defaults.removeObject(forKey: "aurora.auth.registeredUsers")
            // 把老用户数据迁移回游客命名空间
            let prefix = "aurora.user.\(oldUser)."
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                let guestKey = String(key.dropFirst(prefix.count))
                let data = defaults.data(forKey: key)
                if let data { defaults.set(data, forKey: guestKey) }
                defaults.removeObject(forKey: key)
            }
            Log.info("账号", "老账号 \(oldUser) 已迁移回游客模式")
            LibraryStore.shared.switchUser(userId: nil)
        }
    }

    var isLoggedIn: Bool { false }

    func logout() { currentUser = nil }

    // 保留空实现避免外部调用崩溃
    func register(username: String, password: String) throws {}
    func login(username: String, password: String) throws {}
    func deleteAccount(username: String, password: String) throws {}
}

/// 用户数据命名空间 key 前缀（始终无前缀 —— 游客模式）
func auroraUserKeyPrefix(for userId: String?) -> String { "" }
