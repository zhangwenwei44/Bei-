import UIKit
import SwiftUI

/// 全局屏幕方向锁。
///
/// 平时锁竖屏（App 整体竖屏，iPhone 的 Info.plist 也只声明了竖屏）；
/// 进入「横屏播放器」时允许横屏并强制设备旋转到横屏，退出时恢复竖屏。
///
/// 根视图控制器的 `supportedInterfaceOrientationsFor` 读取这里的 `mask`，
/// 从而真正掌控 App 能旋转到哪些方向（覆盖 Info.plist 的声明）。
final class OrientationLock: ObservableObject {
    static let shared = OrientationLock()

    /// 当前允许的屏幕方向（AppDelegate.supportedInterfaceOrientationsFor 读取）。
    @Published var mask: UIInterfaceOrientationMask = .portrait
    /// 是否处于横屏播放器模式。
    @Published var isLandscapePlayer = false

    private init() {}

    /// 进入横屏播放器：允许横屏 + 强制设备旋转到横屏。
    func enterLandscape() {
        guard !isLandscapePlayer else { return }
        isLandscapePlayer = true
        mask = .landscape
        forceRotate(to: .landscapeRight)
    }

    /// 退出横屏播放器：恢复竖屏 + 强制设备旋转回竖屏。
    func exitLandscape() {
        isLandscapePlayer = false
        mask = .portrait
        forceRotate(to: .portrait)
    }

    /// 兜底：无论当前什么状态，直接恢复竖屏（关闭播放页时调用，避免退出后整 App 卡横屏）。
    func resetToPortrait() {
        isLandscapePlayer = false
        mask = .portrait
        forceRotate(to: .portrait)
    }

    /// 进入全屏歌词页：无论当前是不是横屏播放器，都临时把全局方向放宽成竖屏
    /// 并把设备强制转回竖屏，让歌词页始终以竖屏竖排呈现（否则会继承横屏播放器的
    /// 横屏 mask，导致「横屏状态下点歌词」歌词页被拉伸成横宽）。
    func presentPortraitForLyrics() {
        mask = .portrait
        forceRotate(to: .portrait)
    }

    /// 退出全屏歌词页：恢复进入前的方向状态。
    /// 之前是横屏播放器就把设备转回横屏；否则保持竖屏（无需旋转）。
    func restoreOrientationAfterLyrics() {
        if isLandscapePlayer {
            mask = .landscape
            forceRotate(to: .landscapeRight)
        } else {
            mask = .portrait
        }
    }

    // 🔴 必须先改 mask 允许目标方向，再 setValue 强制旋转，否则系统会因
    // 目标方向不在允许列表里而忽略这次旋转请求。
    private func forceRotate(to orientation: UIInterfaceOrientation) {
        // KVC 改 UIDevice.orientation 是业界通用做法（App Store 安全）。
        // UIInterfaceOrientation 与 UIDeviceOrientation 在 portrait/landscape*
        // 上的 rawValue 一致，直接传 rawValue 即可。
        UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
        UINavigationController.attemptRotationToDeviceOrientation()
    }
}

/// App 级方向回调：把全局方向锁暴露给系统。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}
