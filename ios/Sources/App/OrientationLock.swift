import UIKit
import SwiftUI

/// 全局屏幕方向锁。
///
/// 平时锁竖屏；进入「横屏播放器」时允许横屏并强制设备旋转到横屏，退出时恢复竖屏。
///
/// 🔴 横屏播放器由 RootView 用 **UIKit 级 present()** 呈现（UIHostingController
/// + modalPresentationStyle=.fullScreen），不是 SwiftUI fullScreenCover ——
/// 强制旋转时 fullScreenCover 的 SwiftUI presentation 容器命中区不随旋转更新
/// （实测横屏里返回/收藏/列表按钮全部点不到）。UIKit present() 是标准解法。
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
    /// 并把设备强制转回竖屏，让歌词页始终以竖屏竖排呈现。
    func presentPortraitForLyrics() {
        mask = .portrait
        forceRotate(to: .portrait)
    }

    /// 退出全屏歌词页：恢复进入前的方向状态。
    func restoreOrientationAfterLyrics() {
        if isLandscapePlayer {
            mask = .landscape
            forceRotate(to: .landscapeRight)
        } else {
            mask = .portrait
        }
    }

    // 🔴 必须先改 mask 允许目标方向，再触发旋转，否则系统会因
    // 目标方向不在允许列表里而忽略这次旋转请求。
    private func forceRotate(to orientation: UIInterfaceOrientation) {
        let target = mask
        if #available(iOS 16.0, *) {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .forEach { scene in
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: target))
                    scene.windows.forEach {
                        $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    }
                }
            UIViewController.attemptRotationToDeviceOrientation()
        }
        // iOS 15 及以下（以及 requestGeometryUpdate 未生效时的兜底）：
        // KVC 改 UIDevice.orientation 是业界通用做法（App Store 安全）。
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
