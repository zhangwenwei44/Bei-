import UIKit

/// 🔴 v2.8.3：屏幕常亮的统一入口。
///
/// ## 为什么需要它
/// 之前 UpdateView（下载更新包）、PlayerView（横屏 / 歌词页沉浸模式）、
/// DownloadManager（歌曲下载）各自直接改 `UIApplication.shared.isIdleTimerDisabled`。
/// 全局只有这一个 bool：A 模块设 true 之后 B 模块退出时设 false，
/// 就把 A 的常亮顺手关掉了 —— 表现是「更新包下载中屏幕照样熄屏」
/// （播放页 onDisappear 一跑就中招），改回 true 也来不及。
///
/// 改成**多原因登记**：任何一个原因在场就常亮，最后一个原因离场才允许熄屏。
final class IdleTimerKeeper {
    static let shared = IdleTimerKeeper()

    private var reasons = Set<String>()
    private let lock = NSLock()

    private init() {}

    /// 登记一个常亮原因（keep=true 生效 / false 撤销）。
    /// reason 用调用方自己的稳定字符串，如 "update-download"、"player-landscape"。
    func set(_ reason: String, _ keep: Bool) {
        lock.lock()
        if keep { reasons.insert(reason) } else { reasons.remove(reason) }
        let keepAwake = !reasons.isEmpty
        lock.unlock()
        if Thread.isMainThread {
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        } else {
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        }
    }
}
