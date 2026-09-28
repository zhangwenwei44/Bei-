import AVFoundation
import SwiftUI

@main
struct AuroraMusicApp: App {
    @StateObject private var store = PlayerStore()

    init() {
        Log.info("启动", "App 启动，版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        AudioSessionController.activate()
        // 首次启动把随包发布的音源装上，用户不用再手动导入
        let installed = BundledSources.installMissing()
        Log.info("启动", "内置音源安装完成，本次装了 \(installed) 个")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
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
