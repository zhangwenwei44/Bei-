import AVFoundation
import SwiftUI

@main
struct AuroraMusicApp: App {
    /// 🔴 必须指向 PlayerStore.shared —— RootView/MainTabs 用单例引用拿 store
    /// （避免 @EnvironmentObject 的整对象订阅把 TabView 树拖进重算风暴）。
    /// 两处必须是同一个实例，environmentObject 注入仍照常供深层视图使用。
    @StateObject private var store = PlayerStore.shared
    @StateObject private var auth = AuthService.shared
    // 🔴 v2.5.50：启动检查更新 —— 检测到新版本弹全屏强制更新浮层（不可关闭）
    @StateObject private var updater = AppUpdater.shared
    // 🔴 v2.9.0：一机一码授权 —— 未激活时在整 App 之上盖授权锁屏
    @StateObject private var license = LicenseManager.shared
    // 🔴 v2.5.41：用户要求移除「启动公告」与「免责声明」——App 直接进入主界面，
    // QQ 群入口改到「设置」页（见 ProfileView 的「加入 QQ 交流群」）。
    /// 🔴 注入 AppDelegate：接管 supportedInterfaceOrientations，配合 OrientationLock
    /// 实现「平时锁竖屏、横屏播放器时强制横屏」。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 🔴 v2.6.5：回到前台时再查一次更新 —— 之前只在冷启动查一次，
    /// App 挂在后台期间发布的新版本，回到前台也收不到推送。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 必须最先装：播放闪退时全靠它把现场写进运行日志
        CrashGuard.install()
        HighRefreshController.shared.install()
        Log.info("启动", "App 启动，版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        AudioSessionController.activate()
        // 混淆脚本的 JSContext 很占内存，和 AVPlayer 叠加容易触发 jetsam。
        // 收到内存警告就先把缓存丢掉。
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            ScriptSourceRunner.shared.handleMemoryWarning()
        }
        // 预先建好目录，否则「文件」App 里看不到这个文件夹，用户没法往里放音源
        SourceStore.prepareImportDirectory()
        // 首次启动把随包发布的音源装上，用户不用再手动导入
        let installed = BundledSources.installMissing()
        Log.info("启动", "内置音源安装完成，本次装了 \(installed) 个")

        // 🔴 v2.9.6(修正)：导航栏刷成酷狗淡蓝 + 去掉系统自带的底部分隔线（黑线）。
        // 必须在 init 里装，appearance 代理只对之后创建的导航栏生效。
        AppStyle.installNavigationBarAppearance()

        // 恢复用户登录态
        if let user = auth.currentUser {
            LibraryStore.shared.switchUser(userId: user)
            Log.info("启动", "恢复用户 \(user) 的数据")
        }
    }

    /// 🔴 v2.6.3：启动 splash —— 系统启动图经常 <1 秒就被撤掉，
    /// 用户要求启动图至少显示 2 秒：进 App 后再铺一层同样的启动图，
    /// 满 2 秒淡出。放在 ForceUpdateView overlay 之上（后写的 overlay 在上层）。
    @State private var splashVisible = true

    var body: some Scene {
        WindowGroup {
            // 🔴 不再有启动公告 / 免责声明拦截：直接进主界面。
            RootView()
                .environmentObject(store)
                .environmentObject(auth)
                .preferredColorScheme(ThemeSettings.mode.colorScheme)
                .onAppear { store.bootstrap() }
                // 🔴 v2.5.50：启动后台查一次版本，有新版 → 全屏强制更新浮层（无关闭按钮）
                .task { await updater.checkForLaunch() }
                .overlay {
                    if updater.forceUpdateActive {
                        ForceUpdateView()
                            .transition(.opacity)
                    }
                }
                // 🔴 v2.6.3：启动图至少显示 2 秒
                .overlay {
                    if splashVisible {
                        LaunchSplashView()
                            .transition(.opacity)
                            .zIndex(100)
                    }
                }
                // 🔴 v2.8.4：启动图至少显示 5 秒（之前 2 秒）
                .task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    withAnimation(.easeOut(duration: 0.35)) { splashVisible = false }
                }
                // 🔴 v2.9.0：授权锁屏 —— 等启动图淡出后再盖，避免遮住启动海报；
                // 强制更新浮层优先级更高（先更新再激活）。
                .overlay {
                    if !splashVisible && !updater.forceUpdateActive && !license.isActivated {
                        LockScreenView()
                            .transition(.opacity)
                            .zIndex(300)
                    }
                }
                // 🔴 v2.6.5：前台回来补一次更新检查（自带 5 分钟节流）
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        Task { await updater.checkOnForeground() }
                    }
                }
        }
    }
}

/// 🔴 v2.6.3：启动 splash 层 —— 与 LaunchScreen.storyboard 同款视觉
/// （蓝色底 + LaunchImage），衔接系统启动图不跳变。
/// 🔴 v2.8.5：改回全屏铺满（scaledToFill + 固定屏幕尺寸 + clipped）——
/// 用户要求海报铺满整个屏幕、不要上下蓝边。之前 v2.8.3 的「挤出屏幕」
/// 其实是 scaledToFill 无尺寸约束导致布局膨胀，这次用 GeometryReader
/// 锁死屏幕尺寸再裁切，视觉与 storyboard 的 aspectFill 完全一致。
private struct LaunchSplashView: View {
    var body: some View {
        ZStack {
            Color(red: 0.291, green: 0.552, blue: 0.983).ignoresSafeArea()
            if let ui = UIImage(named: "LaunchImage") {
                GeometryReader { geo in
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
            }
        }
        .transition(.opacity)
    }
}

enum AudioSessionController {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        // 🔴 .duckOthers —— 播放时压低其他 App 的声音（视频/游戏/语音等），
        // .mixWithOthers —— 允许和其他 App 同时播放（比如后台刷抖音时继续放歌），
        // .defaultToSpeaker —— 没有外接音频时走扬声器，iOS 14+ 必须显式设置
        try? session.setCategory(.playback,
                                 mode: .default,
                                 options: [.duckOthers, .mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true, options: [])
        // 监听路由变化：AirPods 断连/插耳机时自动暂停（PlayerStore 里已经有 routeChange handler）
    }
}
