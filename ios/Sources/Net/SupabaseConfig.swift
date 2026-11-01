import Foundation

/// Supabase 后端配置。
///
/// 在 Supabase 后台（Project Settings → API）复制 Project URL 和 anon/public key，
/// 替换下面的占位符。anon / public key 是公开安全的（数据由 RLS 行级权限保护），
/// 可以直接打进 App。
enum SupabaseConfig {
    /// 例：https://abcdefg.supabase.co
    static let url = "https://qwyihlheumyoioknczha.supabase.co"
    /// 例：eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
    static let anonKey = "sb_publishable_tG4NmUmPWTTMOM26OhWXSA_tNm0P8UX"

    /// 管理员账号邮箱（白名单）：**只有这个账号能修改云端横幅 / 进入管理面板**。
    ///
    /// 🔴 v2.9.11 安全修复（真实事故）：以前「实验室」只判断"有没有登录云账号"，
    ///   而登录用的密码又被硬编码进了 App 二进制（LicenseAdmin.passcode），
    ///   任何人解压 IPA 就能登录管理员账号 → 把管理员设置的横幅换成自己的图。
    ///   现在 App 内**不再保存任何密码**，只保留邮箱白名单；真正的权限边界在服务器
    ///   （storage 桶的 RLS 策略只放行这个账号，见 ios/Supabase/banner_admin_policy.sql）。
    static let adminEmail = "953936355@qq.com"

    /// 判断某个邮箱是不是管理员账号（大小写/空格都容错）。
    static func isAdminEmail(_ email: String?) -> Bool {
        guard let email else { return false }
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !e.isEmpty && e == adminEmail.lowercased()
    }

    /// 是否已完成配置（占位符未替换时视为未配置，云功能自动关闭，不影响其它功能）。
    static var isConfigured: Bool {
        !url.hasPrefix("https://YOUR-") && !anonKey.hasPrefix("YOUR-")
    }
}
