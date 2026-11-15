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
        /// 🔴 第二十三轮：页面可见期间的收敛校验。状态栏黑字回归的根因不是配色逻辑，
        ///    而是「写进去的时机」——push 开始时旧页 `viewWillDisappear` 会 restore
        ///    成 .default，可能晚于新页 anchor 的 viewWillAppear；`navIsDark` 又只在
        ///    跨阈值时发布一次，值没变就没有第二次补写机会，于是整页一直是黑字。
        private var visible = false
        private var verifyScheduled = false
        private var didInitialBurst = false

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
            visible = true
            applyIfPossible(force: true)
            startVerifying()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // push 转场结束后 topViewController 才稳定，这里补一次。
            visible = true
            applyIfPossible(force: true)
            startVerifying()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in self?.applyIfPossible(force: true) }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            visible = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restore()
        }

        /// SwiftUI 每次刷新都走这里：不再因「值没变」而早退，会被 UIKit 实际状态
        /// 拦住，所以不会引发重排死循环，但能顺手把外部覆盖修回来。
        func set(_ value: Bool) {
            lightContent = value
            applyIfPossible()
        }

        /// 入页后密集补刷 4 次，覆盖 push 转场（0.35s）与旧页 restore 的交错时序；
        /// 之后 0.3s 一次低频收敛，只写 UIKit 属性、不碰任何 SwiftUI 状态。
        private func startVerifying() {
            guard !verifyScheduled else { return }
            verifyScheduled = true
            if !didInitialBurst {
                didInitialBurst = true
                for delay in [0.04, 0.15, 0.32, 0.55] as [TimeInterval] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.visible else { return }
                        self.applyIfPossible(force: true)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.verifyScheduled = false
                guard self.visible, self.view.window != nil else { return }
                self.applyIfPossible()
                self.startVerifying()
            }
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
            // 🔴 第二十三轮兜底：`UIViewControllerRepresentable` 作为 child VC 时，
            //    SwiftUI 转发 viewWillAppear / didMove(toParent:) 的时序并不保证，
            //    父链可能还没接上就错过了唯一一次 apply，状态栏于是整页黑字。
            //    改从本视图自己的响应链往上找导航栈，并用视图归属确认本页就是栈顶
            //    （转场期间 top 仍是旧页时返回 nil，由低频校验在下一拍补上）。
            var node: UIResponder? = view
            while let cur = node {
                if let vc = cur as? UIViewController, let nav = vc.navigationController,
                   let top = nav.topViewController, view.isDescendant(of: top.view) {
                    return (nav, top)
                }
                node = cur.next
            }
            return nil
        }

        private func applyIfPossible(force: Bool = false) {
            guard let (nav, host) = resolveContext(), nav.topViewController === host else { return }
            attachedNav = nav
            let bar = nav.navigationBar
            let wantsStyle: UIBarStyle = lightContent ? .black : .default
            let wantsTrait: UIUserInterfaceStyle = lightContent ? .dark : .unspecified
            // 🔴 比较 UIKit **实际值**，而不是只比较 SwiftUI 传进来的 Bool：
            //    旧页 restore / 逐项 appearance 刷新都可能把导航栏改回 .default。
            let changed = bar.barStyle != wantsStyle || bar.overrideUserInterfaceStyle != wantsTrait
            if !force, !changed, applied == lightContent { return }
            applied = lightContent
            if changed {
                // 两条路径一起上：老系统看 barStyle，SwiftUI/UIKit 新路径看导航栏 trait。
                // 只设其中一条在真机上都可能被逐项 UINavigationBarAppearance 覆盖掉。
                bar.barStyle = wantsStyle
                bar.overrideUserInterfaceStyle = wantsTrait
            }
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
