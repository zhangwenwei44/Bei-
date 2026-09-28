import AVFoundation
import SwiftUI

@main
struct AuroraMusicApp: App {
    @StateObject private var store = PlayerStore()

    init() {
        // 必须最先装：播放闪退时全靠它把现场写进运行日志
        CrashGuard.install()
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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(ThemeSettings.mode.colorScheme)
                .onAppear { store.bootstrap() }
        }
    }
}

enum AudioSessionController {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }
}
