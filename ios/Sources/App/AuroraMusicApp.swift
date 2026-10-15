import AVFoundation
import SwiftUI

@main
struct AuroraMusicApp: App {
    /// 🔴 必须指向 PlayerStore.shared —— RootView/MainTabs 用单例引用拿 store
    /// （避免 @EnvironmentObject 的整对象订阅把 TabView 树拖进重算风暴）。
    /// 两处必须是同一个实例，environmentObject 注入仍照常供深层视图使用。
    @StateObject private var store = PlayerStore.shared
    @StateObject private var auth = AuthService.shared
    @AppStorage("aurora.disclaimer.accepted") private var disclaimerAccepted = false
    @State private var showQQSheet = false

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

        // 恢复用户登录态
        if let user = auth.currentUser {
            LibraryStore.shared.switchUser(userId: user)
            Log.info("启动", "恢复用户 \(user) 的数据")
        }
    }

    var body: some Scene {
        WindowGroup {
            if disclaimerAccepted {
                mainContent
            } else {
                DisclaimerView()
                    .preferredColorScheme(ThemeSettings.mode.colorScheme)
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        RootView()
            .environmentObject(store)
            .environmentObject(auth)
            .preferredColorScheme(ThemeSettings.mode.colorScheme)
            .onAppear {
                store.bootstrap()
                // 🔴 首次启动弹 QQ 群公告（用户点"知道了"后关闭本 App 重开就不再弹）
                let dismissed = UserDefaults.standard.bool(forKey: "aurora.qqAnnouncement.dismissed")
                let launched = UserDefaults.standard.integer(forKey: "aurora.qqAnnouncement.launchCount")
                if !dismissed {
                    // 只在前 3 次启动弹，超过 3 次用户还没关就自动不弹了
                    if launched < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showQQSheet = true
                        }
                        UserDefaults.standard.set(launched + 1, forKey: "aurora.qqAnnouncement.launchCount")
                    }
                }
            }
            .sheet(isPresented: $showQQSheet) {
                QQAnnouncementView()
            }
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
