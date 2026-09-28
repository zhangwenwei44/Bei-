import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 直接持有 `UIDocumentPickerViewController` 的文件选择器。
///
/// 为什么不用 SwiftUI 的 `.fileImporter`：SourceSettingsView 上同时挂了四五个
/// `.sheet`，`.fileImporter` 和它们共用同一个呈现通道，历史上出现过选完文件
/// 回调根本不触发的情况（用户侧表现为「点了没反应」）。自己持有
/// UIDocumentPickerViewController 并在独立 sheet 里呈现，行为可预期。
struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: false —— 拿到的应该是安全作用域 URL，startAccessingSecurityScopedResource 才有意义
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        controller.allowsMultipleSelection = true
        controller.shouldShowFileExtensions = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            Log.info("文件选择", "选中 \(urls.count) 个文件：\(urls.map(\.lastPathComponent).joined(separator: ", "))")
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Log.info("文件选择", "用户取消")
            parent.onCancel()
        }
    }
}
