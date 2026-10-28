import Foundation

/// Supabase 后端配置。
///
/// 在 Supabase 后台（Project Settings → API）复制 Project URL 和 anon/public key，
/// 替换下面的占位符。anon / public key 是公开安全的（数据由 RLS 行级权限保护），
/// 可以直接打进 App。
enum SupabaseConfig {
    /// 例：https://abcdefg.supabase.co
    static let url = "https://YOUR-PROJECT-REF.supabase.co"
    /// 例：eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
    static let anonKey = "YOUR-ANON-PUBLIC-KEY"

    /// 是否已完成配置（占位符未替换时视为未配置，云功能自动关闭，不影响其它功能）。
    static var isConfigured: Bool {
        !url.hasPrefix("https://YOUR-") && !anonKey.hasPrefix("YOUR-")
    }
}
