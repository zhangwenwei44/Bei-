import Foundation

/// 🔴 v2.9.0：授权密钥（一机一码）。
///
/// 授权码 = SHA256("密钥|设备ID") 的十六进制前 16 位，App 本地重算校验，
/// 不联网、无服务器、永久有效。
///
/// ⚠️ 仓库是公开的：这里保留一份默认密钥，保证不配置任何东西也能构建出可用的包。
/// 若要防止别人照着源码自己签发授权码，请在 GitHub 仓库
/// Settings → Secrets and variables → Actions 新增 Secret `LICENSE_SECRET`，
/// CI 会用真实密钥覆盖本文件（见 .github/workflows/build-ios.yml）。
/// 注意：切换密钥后旧授权码会失效，需要重新发放。
enum LicenseSecret {
    // 分段拼接：避免整串明文连续出现在二进制的字符串表里
    private static let parts = [
        "617c9ed9",
        "46bb4ae7",
        "0429a0f5",
        "b2145c78",
        "5763758f",
        "928a877b",
    ]

    static var value: String { parts.joined() }
}
