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
    /// 登录态失效，需要重新扫码登录。
    ///
    /// 🔴 触发场景：token 的签发域和调用接口的域必须一致。
    /// 早期版本用 appid=1005 签发 token，却拿去调 Android 网关（3116）的接口，
    /// 服务端一律返回 20017。修复方式是改用 3116 重新扫码 —— 但**存量用户**
    /// 本地还存着旧域签发的 token，不主动提示就永远看不到自己的歌单。
    @Published private(set) var needsRelogin = false

    private let defaults = UserDefaults.standard
    private let key = "aurora.kugou.auth"

    private init() { load() }

    var token: String { defaults.string(forKey: key + ".token") ?? "" }
    var isVip: Bool { (defaults.object(forKey: key + ".vipType") as? Int ?? 0) > 0 }
    var vipType: Int { defaults.object(forKey: key + ".vipType") as? Int ?? 0 }

    /// 设备指纹 dfid —— 未做风控注册前 "-"；registerDevice 成功后保存服务端返回的真实值
    var dfid: String {
        let v = defaults.string(forKey: "aurora_kugou_dfid") ?? "-"
        return v.isEmpty ? "-" : v
    }

    /// registerDevice 成功后保存真实 dfid
    func saveDeviceDFID(_ value: String) {
        guard !value.isEmpty, value != dfid else { return }
        defaults.set(value, forKey: "aurora_kugou_dfid")
        Log.info("酷狗", "设备 dfid 已保存 \(value)")
    }

    /// 设备 guid —— registerDevice 上报的 imei/uuid，随机生成一次后持久化（照搬 Beans ensureDevice）
    var guid: String {
        if let g = defaults.string(forKey: "aurora_kugou_guid"), !g.isEmpty { return g }
        let g = UUID().uuidString
        defaults.set(g, forKey: "aurora_kugou_guid")
        return g
    }

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

    /// 登录后补拉到头像时更新（fetchMyInfo 用）—— 只在有值且变化时写，
    /// 写完 load() 触发 @Published 刷新，UI 上的头像立即生效。
    func updateAvatar(_ avatar: String) {
        // 🔴 http → https —— ATS 阻止 HTTP，CoverImage 加载会静默失败！
        var fixed = avatar.hasPrefix("http://") ? "https://" + avatar.dropFirst(7) : avatar
        if fixed.hasPrefix("//") { fixed = "https:" + fixed }   // 协议相对地址
        guard !fixed.isEmpty, fixed != defaults.string(forKey: key + ".avatar") else { return }
        defaults.set(fixed, forKey: key + ".avatar")
        load()
        Log.info("酷狗", "头像已更新 \(fixed.prefix(60))")
    }

    func saveLogin(userId: String, token: String, nickname: String, avatar: String, vipType: Int) {
        defaults.set(userId, forKey: key + ".userId")
        defaults.set(token, forKey: key + ".token")
        defaults.set(nickname, forKey: key + ".nickname")
        // 🔴 http → https —— ATS 阻止 HTTP，CoverImage 加载会静默失败！
        let fixedAvatar = avatar.hasPrefix("http://") ? "https://" + avatar.dropFirst(7) : avatar
        defaults.set(fixedAvatar, forKey: key + ".avatar")
        defaults.set(vipType, forKey: key + ".vipType")
        // 🔴 记录 token 的签发域版本 —— 老版本存的是 1005 域签发的 token，
        // 拿去调 3116 网关必返 20017。存下版本号才能识别出这类存量用户。
        defaults.set(Self.currentTokenIssuer, forKey: key + ".tokenIssuer")
        load()
        needsRelogin = false
        Log.info("酷狗", "登录成功 user=\(nickname) id=\(userId) avatar=\(fixedAvatar.prefix(50))")
    }

    /// 当前代码签发 token 使用的域标识。
    /// 与 KugouClient.gatewayAppID 保持一致，改那边这里也要跟着改。
    static let currentTokenIssuer = "kg-gw-3116"

    /// token 是否由旧的错误域签发（老版本登录留下的）。
    ///
    /// 返回 true 意味着：当前 App 的接口域已经换成 3116，
    /// 而本地 token 还是 1005 域签发的，**必然**调不通云端歌单。
    /// 这种用户必须重新扫码登录，光重试没用。
    private var isStaleIssuer: Bool {
        guard isLoggedIn, !token.isEmpty else { return false }
        let issuer = defaults.string(forKey: key + ".tokenIssuer")
        // 老版本没有这个字段 —— 一律按过期处理，登录一次即可。
        return issuer != Self.currentTokenIssuer
    }

    /// 服务端返回 20017/20006 时调用 —— 标记需要重新登录。
    ///
    /// 20017 = 设备态/token 与请求域不匹配
    /// 20006 = token 非法或已过期
    /// 这两个错误重试无意义，唯一出路是重新扫码换新 token。
    func markTokenRejected() {
        guard !needsRelogin else { return }
        needsRelogin = true
        Log.info("酷狗", "🔴 token 被服务端拒绝（20017/20006），已标记需要重新扫码登录")
        NotificationCenter.default.post(name: .auroraKugouTokenRejected, object: nil)
    }

    /// 主动清除登录态（用户点了"重新登录"后调用，先把脏 token 扔掉）。
    func clearForRelogin() {
        for suffix in [".userId", ".token", ".nickname", ".avatar", ".vipType", ".tokenIssuer"] {
            defaults.removeObject(forKey: key + suffix)
        }
        load()
        needsRelogin = false
        Log.info("酷狗", "已清除失效登录态，请重新扫码")
    }

    func logout() {
        for suffix in [".userId", ".token", ".nickname", ".avatar", ".vipType", ".tokenIssuer"] {
            defaults.removeObject(forKey: key + suffix)
        }
        load()
        needsRelogin = false
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
        // 🔴 启动即检测：存量用户的 token 是旧域签发的，一进 App 就该提示重登，
        // 否则用户只会看到"歌单是空的"，根本不知道要重新扫码。
        needsRelogin = isStaleIssuer
        if needsRelogin {
            Log.info("酷狗", "🔴 检测到旧版本签发的 token，云歌单不可用，需重新扫码登录")
        }
    }
}
