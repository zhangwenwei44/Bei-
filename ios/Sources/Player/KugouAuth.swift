import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 酷狗音乐账号登录态管理（扫码登录后存 token / userid / nickname）。
///
/// 和 AuthService.swift（本地账号系统）并存：
/// - AuthService 管理 App 内游客/注册用户的数据隔离
/// - KugouAuth 只管理酷狗云端账号的 token / userid / 歌单同步凭证
final class KugouAuth: ObservableObject {
    static let shared = KugouAuth()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var userId = ""
    @Published private(set) var nickname = ""
    @Published private(set) var avatarURL: URL?
    @Published private(set) var vipBadge: String?

    private let defaults = UserDefaults.standard
    private let key = "aurora.kugou.auth"

    private init() { load() }

    var token: String { defaults.string(forKey: key + ".token") ?? "" }
    var isVip: Bool { (defaults.object(forKey: key + ".vipType") as? Int ?? 0) > 0 }
    var vipType: Int { defaults.object(forKey: key + ".vipType") as? Int ?? 0 }

    /// 设备指纹 dfid —— Beans 默认 "-"（registerDevice 后才有真实值，不注册也能用）
    var dfid: String { "-" }

    /// 设备指纹 mid —— 必须持久化且与 Cookie 里的 KUGOU_API_MID 完全一致，否则 gateway 20017
    /// 算法照搬 Beans: MD5(identifierForVendor) 前 15 位 hex → UInt64 十进制
    var mid: String {
        if let saved = defaults.string(forKey: "aurora_kugou_mid"), !saved.isEmpty { return saved }
        let seed = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let hex = Data(seed.utf8).md5Hex()
        let prefix = String(hex.prefix(15))
        let value = UInt64(prefix, radix: 16).map(String.init) ?? hex
        defaults.set(value, forKey: "aurora_kugou_mid")
        return value
    }

    var cookieHeader: String {
        // 🔴 必须和 Beans 完全一致：4 项！缺 KUGOU_API_MID/dfid 会导致 gateway 20017
        var items: [(String, String)] = [
            ("userid", userId),
            ("token", token),
            ("KUGOU_API_MID", mid),
            ("dfid", dfid),
        ]
        if vipType > 0 {
            items.append(("vipType", "\(vipType)"))
            items.append(("viptype", "\(vipType)"))
        }
        return items.filter { !$0.1.isEmpty }.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    // MARK: - 登录态持久化

    func saveLogin(userId: String, token: String, nickname: String, avatar: String, vipType: Int) {
        defaults.set(userId, forKey: key + ".userId")
        defaults.set(token, forKey: key + ".token")
        defaults.set(nickname, forKey: key + ".nickname")
        // 🔴 http → https —— ATS 阻止 HTTP，CoverImage 加载会静默失败！
        let fixedAvatar = avatar.hasPrefix("http://") ? "https://" + avatar.dropFirst(7) : avatar
        defaults.set(fixedAvatar, forKey: key + ".avatar")
        defaults.set(vipType, forKey: key + ".vipType")
        load()
        Log.info("酷狗", "登录成功 user=\(nickname) id=\(userId) avatar=\(fixedAvatar.prefix(50))")
    }

    func logout() {
        for suffix in [".userId", ".token", ".nickname", ".avatar", ".vipType"] {
            defaults.removeObject(forKey: key + suffix)
        }
        load()
        Log.info("酷狗", "已退出登录")
    }

    private func load() {
        isLoggedIn = defaults.string(forKey: key + ".token") != nil
        userId = defaults.string(forKey: key + ".userId") ?? ""
        nickname = defaults.string(forKey: key + ".nickname") ?? ""
        if let av = defaults.string(forKey: key + ".avatar"), !av.isEmpty {
            // 🔴 同样转 HTTPS —— 之前登录的用户可能存了 HTTP
            let fixed = av.hasPrefix("http://") ? "https://" + av.dropFirst(7) : av
            avatarURL = URL(string: fixed)
        } else {
            avatarURL = nil
        }
        vipBadge = isVip ? "VIP" : nil
    }
}
