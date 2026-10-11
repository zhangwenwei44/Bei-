import SwiftUI

// MARK: - iOS 15 兼容层
// 项目原本 deploymentTarget=16.0 用了 NavigationStack（iOS 16 专属），
// iOS 15 上 NavigationStack 类不存在 → 启动即崩溃。
// 本文件提供 NavigationStack/NavigationView 的自动 fallback。

/// 兼容导航容器：iOS 16+ 用 NavigationStack，iOS 15 用 NavigationView
/// - Note: NavigationView 在 iOS 15 有已知问题（双击 tab 不会 popToRoot），
///   但作为 NavigationStack 的运行时 fallback 足够用。
struct CompatNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

// MARK: - iOS 16 scrollContentBackground 兼容

extension View {
    /// iOS 16+ 用原生 scrollContentBackground(.hidden)，iOS 15 做不到就忽略
    @ViewBuilder
    func compatScrollContentBackground(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(visibility)
        } else {
            self
        }
    }

    /// iOS 16+ 用原生 toolbarBackground/.toolbarColorScheme，iOS 15 忽略
    @ViewBuilder
    func compatToolbarHidden() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
    }
}
