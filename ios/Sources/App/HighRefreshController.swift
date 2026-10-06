import UIKit
import QuartzCore

/// 全局 120Hz / 高刷控制器。
///
/// 通过一个常驻的 CADisplayLink（paused=false、tick 空实现）告诉系统 App 的帧率上限。
/// ProMotion 设备（iPhone 13 Pro / 之后）会跑到 120Hz；iPhone XS / XR 等物理 60Hz 设备
/// 上开这个开关无副作用（系统最多给你 60Hz）。
///
/// 关闭时 invalidate link 让系统回到默认帧上限，省点电。
final class HighRefreshController {
    static let shared = HighRefreshController()

    private let defaultsKey = "aurora.enableHighRefresh"

    private var link: CADisplayLink?

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// App 启动时调一次：读 UserDefaults、按状态开/关
    func install() {
        apply()
    }

    func setEnabled(_ newValue: Bool) {
        UserDefaults.standard.set(newValue, forKey: defaultsKey)
        apply()
    }

    private func apply() {
        if isEnabled {
            ensureLink()
        } else {
            link?.invalidate()
            link = nil
        }
    }

    private func ensureLink() {
        if link != nil { return }
        let dl = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            // 申请系统允许的最高帧率（ProMotion ≈ 120Hz，老设备 ≈ 60Hz）
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        }
        dl.add(to: .main, forMode: .common)
        link = dl
    }

    @objc private func tick() { /* 空实现：只用来保活 link 声明"我需要高帧率" */ }
}
