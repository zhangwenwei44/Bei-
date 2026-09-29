import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 文件选择器：直接在 keyWindow 根控制器上 present UIDocumentPickerViewController。
///
/// 前两版都栽过跟头：
/// - SwiftUI `.fileImporter`：和 `.sheet` 共用同一个呈现通道，iOS 16 上回调被静默吞掉；
/// - 包在 `.sheet` 里的 UIViewControllerRepresentable：文档选择器嵌在分页 sheet 里
///   在部分 iOS 16 版本上整页空白，用户侧表现就是「点从文件导入，选择器打不开」。
/// 现在绕开 SwiftUI 呈现体系，在根控制器上直接 present。
///
/// 另外用 `asCopy: true`：选择器会把文件拷进 App 的 tmp 目录，
/// 拿到的是普通明文路径，不再依赖安全作用域读文件（用户目录里的文件
/// 以前偶尔读不到，报「无权限」）。
enum FilePicker {
    @MainActor
    static func pick(types: [UTType],
                     multiple: Bool = true,
                     onPick: @escaping ([URL]) -> Void,
                     onCancel: (() -> Void)? = nil) {
        var presenter: UIViewController?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let window = windowScene.keyWindow
                ?? windowScene.windows.first { $0.isKey }
                ?? windowScene.windows.first
            if let root = window?.rootViewController {
                presenter = root
                break
            }
        }
        while let presented = presenter?.presentedViewController {
            presenter = presented
        }
        guard let presenter else {
            Log.error("文件选择", "找不到可用的根视图控制器，选择器无法弹出")
            onCancel?()
            return
        }

        let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        controller.allowsMultipleSelection = multiple
        controller.shouldShowFileExtensions = true
        let coordinator = Coordinator(onPick: onPick, onCancel: onCancel)
        controller.delegate = coordinator
        // UIDocumentPickerViewController 对 delegate 是弱引用，
        // 回调发生在 present 之后，这里用关联对象保住 coordinator 的生命周期。
        objc_setAssociatedObject(controller, &Coordinator.associationKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
        presenter.present(controller, animated: true)
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        static var associationKey: UInt8 = 0
        private let onPick: ([URL]) -> Void
        private let onCancel: (() -> Void)?

        init(onPick: @escaping ([URL]) -> Void, onCancel: (() -> Void)?) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            Log.info("文件选择", "选中 \(urls.count) 个文件：\(urls.map(\.lastPathComponent).joined(separator: ", "))")
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Log.info("文件选择", "用户取消")
            onCancel?()
        }
    }
}
