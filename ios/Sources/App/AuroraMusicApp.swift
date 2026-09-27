import AVFoundation
import SwiftUI

@main
struct AuroraMusicApp: App {
    @StateObject private var store = PlayerStore()

    init() {
        AudioSessionController.activate()
        // 首次启动把随包发布的音源装上，用户不用再手动导入
        BundledSources.installMissing()
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
