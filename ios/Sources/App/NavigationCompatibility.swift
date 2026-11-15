import SwiftUI
import UIKit

// MARK: - iOS 15 兼容层
// deploymentTarget=15.0 —— 所有 iOS 16+ API 都必须用 if #available 包裹

// MARK: NavigationStack ↔ NavigationView

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

// MARK: - 只有内部 if #available 包装的兼容扩展（不能在函数签名里引用 iOS 16 类型）

extension View {
    @ViewBuilder
    func compatScrollContentBackground(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) { scrollContentBackground(visibility) } else { self }
    }

    @ViewBuilder
    func compatToolbarHidden() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else { self }
    }

    /// 🔴 v2.9.7：导航栏/状态栏用**浅色**内容（深色图片上的状态栏必须是白字）。
    ///
    /// iOS 16+ 直接用 `toolbarColorScheme(.dark)`；
    /// iOS 15 没有这个 API，改走 UIKit 的 `overrideUserInterfaceStyle`，
    /// 由 `NavigationBarItemAppearance` 一并设置（见 Components.swift）。
    @ViewBuilder
    func compatToolbarLightContent() -> some View {
        if #available(iOS 16.0, *) {
            toolbarColorScheme(.dark, for: .navigationBar)
        } else { self }
    }

    /// 🔴 v2.9.7(二) / 2026-11-15 第二十一轮：状态栏内容颜色**动态**切换 ——
    /// 沉浸式页展开时大图在顶（白字），收起后白底毛玻璃导航栏（黑字）。
    ///
    /// ⚠️ 只靠 `toolbarColorScheme(.dark)` **不够**：这些页面还用
    /// `kugouNavigationBarBackground(.clear, transparent:)` 逐项覆盖
    /// `UINavigationBarAppearance`，SwiftUI 于是不再接管状态栏样式。
    /// 真机上 toolbar 的返回/三点按钮是白的，状态栏时间/信号/电量却还是黑的
    /// （用户 6 张截图：歌手页、猜你喜欢、经典推荐、新歌推荐、我喜欢、默认收藏）。
    ///
    /// 补一个纯 UIKit 锚点：把 `navigationBar.barStyle` 切到 `.black`
    /// （`UINavigationController.preferredStatusBarStyle` 跟随它）并请求刷新。
    /// 它不画任何东西、只在 dark 值变化时写一次；页面消失时恢复 `.default`，
    /// pop 回主页面不会残留。toolbarColorScheme 仍保留 —— 它负责 toolbar items 的白。
    @ViewBuilder
    func compatToolbarDynamicScheme(dark: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbarColorScheme(dark ? .dark : .light, for: .navigationBar)
                .background(ImmersiveStatusBarAnchor(lightContent: dark))
        } else {
            self.background(ImmersiveStatusBarAnchor(lightContent: dark))
        }
    }
}

// MARK: - 🔴 沉浸式页状态栏白字（UIKit 锚点，2026-11-15 第二十一轮）

/// 0 尺寸、不可交互、不参与绘制；唯一职责是把本页所在导航栈的
/// `navigationBar.barStyle` 与状态栏样式对齐到「顶栏内容是否浅色」。
private struct ImmersiveStatusBarAnchor: UIViewControllerRepresentable {
    let lightContent: Bool

    func makeUIViewController(context: Context) -> Controller {
        Controller(lightContent: lightContent)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.set(lightContent)
    }

    final class Controller: UIViewController {
        private var lightContent: Bool
        /// 上次真正写进 UINavigationBar 的值：SwiftUI 每次刷新都别触发 UIKit 重排
        /// （导航栏重排 → SwiftUI 重渲染 → 又刷新，是本项目踩过的死循环）。
        private var applied: Bool?
        private weak var attachedNav: UINavigationController?

        init(lightContent: Bool) {
            self.lightContent = lightContent
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            applyIfPossible()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyIfPossible(force: true)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // push 转场结束后 topViewController 才稳定，这里补一次。
            applyIfPossible(force: true)
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in self?.applyIfPossible(force: true) }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restore()
        }

        func set(_ value: Bool) {
            guard lightContent != value else { return }
            lightContent = value
            applyIfPossible()
        }

        /// 与 `NavigationBarItemAppearance` 同款：沿父链找本页那个导航栈，
        /// 并且只在「本页确实是栈顶」时改，绝不误伤兄弟页面。
        private func resolveContext() -> (UINavigationController, UIViewController)? {
            var candidate: UIViewController? = parent
            while let cur = candidate {
                if let nav = cur.navigationController,
                   nav.viewControllers.contains(where: { $0 === cur }) {
                    return (nav, cur)
                }
                candidate = cur.parent
            }
            return nil
        }

        private func applyIfPossible(force: Bool = false) {
            guard let (nav, host) = resolveContext(), nav.topViewController === host else { return }
            attachedNav = nav
            if !force, applied == lightContent { return }
            applied = lightContent
            let bar = nav.navigationBar
            // 两条路径一起上：老系统看 barStyle，SwiftUI/UIKit 新路径看导航栏 trait。
            // 只设其中一条在真机上都可能被逐项 UINavigationBarAppearance 覆盖掉。
            bar.barStyle = lightContent ? .black : .default
            bar.overrideUserInterfaceStyle = lightContent ? .dark : .unspecified
            nav.setNeedsStatusBarAppearanceUpdate()
            host.setNeedsStatusBarAppearanceUpdate()
        }

        private func restore() {
            guard applied != nil else { return }
            applied = nil
            let bar = attachedNav?.navigationBar
            bar?.barStyle = .default
            bar?.overrideUserInterfaceStyle = .unspecified
            attachedNav?.setNeedsStatusBarAppearanceUpdate()
        }

        // ⚠️ 刻意不写 deinit 兜底：push 到下一个沉浸式页时旧 VC 才释放，
        //    那时无条件恢复 .default 反而会把新页的白字改回黑字。
        //    viewWillDisappear（pop / push 都会调）已足够，交互式取消时
        //    viewWillAppear(force:true) 会重新设回来。
    }
}

// 🔴 v2.9.6：原来的 `compatToolbarOpaqueBackground(_:)` 已删除。
// 它走 SwiftUI 的 `toolbarBackground`，而那条路线有两个坑（run 534/535 实测）：
// - `.visible` + 颜色：SwiftUI 用自己生成的外观覆盖 appearance 代理，系统分隔线（黑线）会回来；
// - `.hidden`：导航栏丢失安全区，滚动内容顶到状态栏。
// 现在二级页/弹窗统一走 `View.kugouNavigationBarBackground()`（UIKit 的 navigationItem 逐项外观），
// 既能单独刷白这一页，又不丢安全区、没有黑线。

// MARK: - FlowLayout / Layout protocol

@available(iOS 16.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

struct LegacyFlowChips: View {
    let items: [String]
    var action: (String) -> Void
    var spacing: CGFloat = 8

    var body: some View {
        let screenW = UIScreen.main.bounds.width - 32
        var currentW: CGFloat = 0
        var currentRow: [String] = []
        var rows: [[String]] = []
        for item in items {
            let estW = CGFloat(item.count) * 7 + 24
            if currentW + estW > screenW && !currentRow.isEmpty {
                rows.append(currentRow); currentRow = []; currentW = 0
            }
            currentRow.append(item); currentW += estW + spacing
        }
        if !currentRow.isEmpty { rows.append(currentRow) }

        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { item in
                        Button { Haptics.light(); action(item) } label: {
                            Text(item).font(.system(size: 13)).foregroundStyle(AppStyle.primaryText)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(AppStyle.surface, in: Capsule())
                                .overlay(Capsule().stroke(AppStyle.stroke, lineWidth: 0.5))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
