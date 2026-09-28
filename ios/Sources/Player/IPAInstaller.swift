import UIKit

/// IPA 安装器。
///
/// 越狱设备上装 IPA 的现实情况：
/// - `UIApplication.open(ipaURL)` 在 iOS 15 以后系统没给 .ipa 注册 open 处理器，
///   基本调不动任何东西
/// - 真正能装的是 AppSync / Zebra / Sileo / Filza，它们都注册了 .ipa 的文档处理器，
///   所以必须让用户从系统分享面板里挑
///
/// 之前用 SwiftUI 的 `.sheet` 套 `.sheet` 来弹分享面板，而 UpdateView 本身
/// 又是从 ProfileView 用 sheet 呈现的——iOS 16 上嵌套 sheet 经常弹不出来。
/// 这里改成拿最顶层的 ViewController 直接 present，不依赖 SwiftUI 的呈现通道。
@MainActor
enum IPAInstaller {
    /// 在最顶层界面弹出系统分享面板，让用户选安装器。
    @discardableResult
    static func presentShareSheet(for url: URL, from presenter: UIViewController? = nil) -> Bool {
        guard url.isFileURL else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.error("更新", "分享面板失败：文件不存在 \(url.path)")
            return false
        }
        let host = presenter ?? topViewController()
        guard let host else {
            Log.error("更新", "分享面板失败：找不到顶层 ViewController")
            return false
        }
        Log.info("更新", "在顶层控制器 \(type(of: host)) 上呈现分享面板，文件 \(url.lastPathComponent)")
        // 已经在呈现别的控制器时，要等它结束再 present，否则会被系统忽略
        if host.presentedViewController != nil, !(host.presentedViewController is UIActivityViewController) {
            Log.info("更新", "先关掉当前呈现的 \(type(of: host.presentedViewController!)) 再弹分享面板")
            host.dismiss(animated: true) { present(host: host, url: url) }
            return true
        }
        present(host: host, url: url)
        return true
    }

    private static func present(host: UIViewController, url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad 上 UIActivityViewController 必须有锚点，否则直接崩
        if let popover = controller.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX,
                                       y: host.view.bounds.midY,
                                       width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        host.present(controller, animated: true) {
            Log.info("更新", "已呈现系统分享面板，选一个安装器即可")
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? scenes.flatMap { $0.windows }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
