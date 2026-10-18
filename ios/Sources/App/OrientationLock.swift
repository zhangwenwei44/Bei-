import UIKit
import SwiftUI

/// 全局屏幕方向锁。
///
/// 🔴 方向锁**永远竖屏**：横屏播放器不再旋转系统界面，而是 SwiftUI 内容
/// 用 `rotationEffect(±90°)` 在竖屏窗口内自转渲染。
///
/// ## 为什么放弃强制系统旋转（血泪史，别改回去）
/// 旧方案：进入横屏时改 mask + `UIDevice.setValue` 强制旋转（后来还加了
/// iOS 16 的 `requestGeometryUpdate`）。实测（XS）：
/// - fullScreenCover 的 presentation 容器命中区不随强制旋转正确更新
///   → 横屏里 返回/收藏/列表 按钮全部点不到（视觉正常、点击无反应）；
/// - 容器几何变"脏"（实测比屏幕宽 ~52pt）
///   → 歌词页底部控制条整体偏移，进度条贴穿屏幕、按钮被边缘裁掉。
/// 内容自转方案下系统界面从不旋转，上述两个问题整类消失，
/// 且 SwiftUI 对 rotationEffect 旋转后的内容命中测试是保证正确的。
final class OrientationLock: ObservableObject {
    static let shared = OrientationLock()

    /// 当前允许的屏幕方向（AppDelegate.supportedInterfaceOrientationsFor 读取）。
    /// 永远竖屏 —— 横屏播放器由 SwiftUI 内容自转实现，不转系统界面。
    @Published var mask: UIInterfaceOrientationMask = .portrait
    /// 是否处于横屏播放器模式（纯 UI 状态，驱动播放页切换到自转布局）。
    @Published var isLandscapePlayer = false

    private init() {}

    /// 进入横屏播放器（不再旋转系统界面，只切 UI 状态）。
    func enterLandscape() {
        isLandscapePlayer = true
    }

    /// 退出横屏播放器。
    func exitLandscape() {
        isLandscapePlayer = false
    }

    /// 兜底：无论当前什么状态，恢复竖屏 UI（关闭播放页时调用）。
    func resetToPortrait() {
        isLandscapePlayer = false
    }
}

/// App 级方向回调：把全局方向锁暴露给系统。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}
