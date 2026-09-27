import SwiftUI
import UIKit

/// 系统分享面板。安装 .ipa 靠它选 AppSync / Zebra / Filza——
/// 新版 iOS 上 `UIApplication.open` 没有 .ipa 的处理器，分享面板才是可靠路径。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
