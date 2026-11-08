import SwiftUI
import UIKit

// MARK: - 🔴 歌单 / 专辑详情共用的「沉浸式头部」容器
//
// 2026-11-07：用户要求「新歌推荐 / 每日推荐 / 猜你喜欢 / 经典推荐 / DJ推荐 / 歌单 / 专辑」
// 这些列表详情页全部按歌手主页的样式来做：
//   ① 大图铺满状态栏 + 透明导航栏；② 大图随列表 1:1 上滑收起；
//   ③ 滚到图片底部渐显毛玻璃顶栏；④ 「播放全部」行吸顶、仅列表滚动；
//   ⑤ 顶栏文字展开白 / 收起黑，收藏按钮蓝底胶囊。
//
// ⚠️ 为什么不直接复用 ArtistDetailView 里的组件：
//   那套实现（ArtistHeroLayer / ScrollViewOffsetTracker / StickyHeaderHeightKey）全是
//   private，且歌手页经过十几轮真机排障才修好白顶，改动它有回归风险。
//   这里独立复制一份已验证的几何逻辑，歌手页保持原样互不干扰。
//
// 🔴 三条来自歌手页的实锤红线（别走回头路）：
//   - 大图**绝不能**放进 ScrollView 内容 / ZStack 独立层 / GeometryReader 绝对坐标：
//     SwiftUI 的视图层级排在 UIKit 导航栏容器背景之下，0~180pt 会被那层不透明背景盖住（白顶）。
//     只能把大图做成 UIKit 浮层，插到 UINavigationController.view 里、UINavigationBar 之下。
//   - 别用 toolbarBackground(.hidden/.visible)（丢安全区 / 出黑线）；
//   - SwiftUI 坐标系换算（GeometryProxy.frame(in:.global)）在真机上不可信，
//     滚动量一律用 UIScrollView.contentOffset 的 KVO 实测 + 探针 convert(.zero, to: window)。

// MARK: - 共享样式

enum ImmersiveStyle {
    /// 收藏胶囊底色（与歌手页、「全部播放」圆钮同色）。固定值，避免顶栏明暗切换时跳色。
    static let collectBlue = Color(red: 44.0 / 255, green: 162.0 / 255, blue: 249.0 / 255)
    /// 大图兜底深色：图未加载 / 加载失败时顶部（含状态栏）也绝不露白。
    static let heroFallback = Color(red: 0.07, green: 0.07, blue: 0.09)
    /// 列表底部留白：迷你播放条 + TabBar 的高度，保证最后一首能滚到播放条上方。
    static let listBottomInset: CGFloat = 96
}

// MARK: - 吸顶行共用控件（2026-11-08 用户指定样式）

/// 多选按钮图标：用户给的「布局列表」样式 —— 两行，每行左侧一个空心圆角方框、右侧两条短横。
///
/// 🔴 自绘而不用 SF Symbol：项目最低 iOS 15，`checklist` 一类符号是 iOS 16+，
///    写不存在的 systemImage 会静默渲染空白（项目已踩过的红线）。
struct ImmersiveMultiSelectIcon: View {
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(alignment: .center, spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .stroke(color, lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2.5) {
                        Capsule(style: .continuous).fill(color).frame(width: 11, height: 1.5)
                        Capsule(style: .continuous).fill(color).frame(width: 11, height: 1.5)
                    }
                }
            }
        }
    }
}

/// 「播放全部」按钮：蓝色渐变圆钮 ▶ + 黑色粗体「播放全部」+ 灰色曲目数。
/// 用户 2026-11-08 给的样式图，替换原来的蓝色胶囊按钮。
struct ImmersivePlayAllButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 0.20, green: 0.68, blue: 0.99),
                                     Color(red: 0.06, green: 0.45, blue: 0.93)],
                            startPoint: .top, endPoint: .bottom))
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
                .frame(width: 44, height: 44)

                Text("播放全部")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.10, green: 0.11, blue: 0.13))
                Text("\(count)")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color(red: 0.67, green: 0.69, blue: 0.72))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 几何状态（容器与 toolbar 共用同一个对象，颜色才能同步刷新）

final class ImmersiveHeaderState: ObservableObject {
    /// 大图高度（与歌手页一致）。
    let headerHeight: CGFloat = 350

    /// 实测的内容上移距离（>=0），由滚动探针 KVO 写入。
    @Published var scrolled: CGFloat = 0
    /// 静止时「滚动内容 y=0」在 window 里的 y（探针直量，归一化后应为 0）。
    @Published var contentOriginYRest: CGFloat = 0
    /// 吸顶头实测高度（PreferenceKey 写入）。
    @Published var stickyHeight: CGFloat = 74

    /// 状态栏高度：用 keyWindow.safeAreaInsets.top，比 statusBarManager 稳。
    var statusBarHeight: CGFloat {
        let inset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
        return inset > 0 ? inset : 20
    }

    var navBarHeight: CGFloat { 44 }
    /// 导航栏 + 状态栏总高 = 页面 ZStack 顶部在屏幕里的 y。
    var topInset: CGFloat { statusBarHeight + navBarHeight }
    /// 大图完全收起需要的滚动距离。
    var maxDrag: CGFloat { max(1, headerHeight - topInset) }

    /// 收起进度：0 = 完全展开，1 = 大图底边抵达导航栏下沿。
    var collapseProgress: CGFloat { min(1, max(0, scrolled) / maxDrag) }

    /// 毛玻璃只在「滚到图片底部、快滚完」时才渐显（0.8 → 1），别提前出现。
    var navFrostOpacity: CGFloat { max(0, min(1, (collapseProgress - 0.8) / 0.2)) }

    /// 顶栏文字/图标色：展开纯白（深色大图）、收起纯黑（浅色毛玻璃），与毛玻璃同步。
    var navContentColor: Color {
        Color(uiColor: UIColor(white: 1 - navFrostOpacity, alpha: 1))
    }

    /// 吸顶头相对 ZStack 顶部的偏移：静止时贴大图底边，收起后钉在导航栏下沿。
    var stickyY: CGFloat { max(0, maxDrag - scrolled) }

    /// 列表顶部占位：列表静止时屏幕 y = 大图底边 + 吸顶头高。
    var listPlaceholder: CGFloat {
        max(0, headerHeight + stickyHeight - max(0, contentOriginYRest))
    }

    /// 大图上的文案随上滑淡出，名字交给导航栏标题。
    var heroTextOpacity: CGFloat { 1 - collapseProgress }

    /// 只在数值真的变化时才写 @Published，避免每次 KVO 都无谓重算整棵视图树。
    func apply(_ m: ImmersiveMetrics) {
        if scrolled != m.scrolled { scrolled = m.scrolled }
        if contentOriginYRest != m.contentOriginYRest { contentOriginYRest = m.contentOriginYRest }
    }
}

// MARK: - 容器

/// 沉浸式歌曲列表容器：调用方传入大图 / 吸顶头 / 列表，其余几何全部由本容器负责。
struct ImmersiveSongListContainer<Hero: View, Sticky: View, Content: View>: View {
    @ObservedObject var state: ImmersiveHeaderState
    let hero: Hero
    let sticky: Sticky
    let content: Content

    /// 🔴 `heroKey`：头图身份（封面 URL + 标题 + 曲目数）。异步加载完歌曲后 URL 才出现，
    ///    浮层必须据此刷新一次 rootView；滚动时 key 不变 → 不重建视图树（封面不闪）。
    let heroKey: String

    init(state: ImmersiveHeaderState,
         heroKey: String,
         @ViewBuilder hero: () -> Hero,
         @ViewBuilder sticky: () -> Sticky,
         @ViewBuilder content: () -> Content) {
        self._state = ObservedObject(wrappedValue: state)
        self.heroKey = heroKey
        self.hero = hero()
        self.sticky = sticky()
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            // ① 滚动容器：只有「占位 + 列表」。大图不在这里（会被 UIKit 层盖住）。
            ScrollView {
                VStack(spacing: 0) {
                    ImmersiveScrollTracker { m in
                        DispatchQueue.main.async { state.apply(m) }
                    }
                    .frame(height: 0)

                    Color.clear.frame(height: state.listPlaceholder)

                    content
                }
            }
            .background(AppStyle.background)
            // 🔴 绝不给 ScrollView 本体加 ignoresSafeArea(edges:.top)：
            //    每加一层就会再下推一个安全区（歌手页 180pt 白顶的老坑）。

            // ② 大图：UIKit 浮层，插在 UINavigationBar 之下 → 盖住白背景、返回按钮仍可见可点。
            ImmersiveHeroLayer(scrolled: state.scrolled,
                               headerHeight: state.headerHeight,
                               hideThreshold: state.maxDrag,
                               heroKey: heroKey,
                               hero: AnyView(hero))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            // ③ 毛玻璃顶栏：大图滚走后渐入。offset 从「导航栏下沿」提到屏幕最顶端。
            frostedBar
                .offset(y: -state.topInset)
                .allowsHitTesting(false)
                .opacity(state.navFrostOpacity)

            // ④ 吸顶头：大图未收起时贴着大图底边走，收起后钉在顶栏正下方。
            sticky
                .offset(y: state.stickyY)
                .background(AppStyle.background)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ImmersiveStickyHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .onPreferenceChange(ImmersiveStickyHeightKey.self) { state.stickyHeight = $0 }
    }

    private var frostedBar: some View {
        let screenW = UIScreen.main.bounds.width
        return ZStack {
            Rectangle().fill(.regularMaterial)
            LinearGradient(colors: [Color.black.opacity(0.06), .clear],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: screenW, height: state.topInset)
        .clipped()
    }
}

// MARK: - 大图（封面铺满 + 深色渐变 + 文案）

/// 歌单 / 专辑 / 推荐板块共用的头图。
/// 5 个推荐板块没有自己的封面，调用方把「第一首歌的封面 URL」传进来当底图。
struct ImmersiveCoverHero: View {
    let url: URL?
    let fallbackKeys: [String]
    let seed: String
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    let headerHeight: CGFloat

    var body: some View {
        let screenW = UIScreen.main.bounds.width
        return ZStack(alignment: .bottom) {
            ImmersiveStyle.heroFallback
                .frame(width: screenW, height: headerHeight)

            CoverImage(
                url: url,
                fallbackKeys: fallbackKeys,
                seed: seed,
                size: max(screenW, 800),
                corner: 0,
                displayWidth: screenW,
                displayHeight: headerHeight,
                contentMode: .fill,
                imageAlignment: .top,
                fallbackColor: ImmersiveStyle.heroFallback
            )
            .frame(width: screenW, height: headerHeight)
            .clipped()

            // 底部压暗，保证白字在任意封面上都读得清。
            LinearGradient(colors: [.clear, Color.black.opacity(0.08), Color.black.opacity(0.74)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: screenW, height: headerHeight)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
            // 🔴 文案不做逐帧淡出：大图整体随列表 1:1 滚出屏幕即可。
            //    浮层 rootView 只在 heroKey 变化时刷新，逐帧 opacity 传不进来（会看着像没生效）。
        }
        .frame(width: screenW, height: headerHeight)
        .clipped()
    }
}

// MARK: - 顶栏按钮 / 标题

/// 自绘返回按钮：系统返回按钮的 chevron 取全局 tintColor（蓝色），逐页改不了色。
struct ImmersiveBackButton: View {
    @Environment(\.dismiss) private var dismiss
    let color: Color

    var body: some View {
        Button { dismiss() } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                Text("返回")
                    .font(.system(size: 16, weight: .regular))
            }
            .foregroundStyle(color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 收起后才渐显的导航栏标题（与大图上的大字交接）。
struct ImmersiveNavTitle: View {
    let title: String
    let color: Color
    let opacity: CGFloat

    var body: some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            // 显式 Double：CGFloat 与 Double 字面量混合做 `-`/`*` 会触发 ambiguous use of operator。
            .shadow(color: .black.opacity(0.3 * (1 - Double(opacity))), radius: 2, y: 1)
            .lineLimit(1)
            .opacity(opacity)
    }
}

// MARK: - 吸顶头高度（PreferenceKey）

struct ImmersiveStickyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 74
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 🔴 大图 UIKit 浮层（复制自 ArtistHeroLayer，已验证的终局方案）

/// 0 尺寸锚点：把 UIHostingController（大图）挂到 UINavigationController.view 里、
/// `UINavigationBar` 的正下方。高于 SwiftUI 内容容器、低于导航栏按钮。
private struct ImmersiveHeroLayer: UIViewRepresentable {
    let scrolled: CGFloat
    let headerHeight: CGFloat
    let hideThreshold: CGFloat
    let heroKey: String
    let hero: AnyView

    func makeUIView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.headerHeight = headerHeight
        v.hideThreshold = hideThreshold
        v.heroKey = heroKey
        v.heroRoot = hero
        return v
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        uiView.scrolled = scrolled
        uiView.updateHero(key: heroKey, root: hero)
        uiView.applyFrame()
    }

    final class AnchorView: UIView {
        var scrolled: CGFloat = 0
        var headerHeight: CGFloat = 350
        var hideThreshold: CGFloat = 262
        var heroKey: String = ""
        /// 最新的头图视图值：安装浮层时用它，避免「歌曲先加载完、浮层后挂上」漏掉封面。
        var heroRoot: AnyView?

        /// 🔴 头图身份变了才换 rootView（例如歌曲异步加载完、封面 URL 从 nil 变成有值）。
        ///    滚动时 key 不变 → 只改 frame，不重建 SwiftUI 视图树（封面不会闪）。
        func updateHero(key: String, root: AnyView) {
            heroRoot = root
            guard key != heroKey else { return }
            heroKey = key
            hosting?.rootView = root
        }

        private var heroView: UIView?
        private var hosting: UIHostingController<AnyView>?
        private weak var container: UIView?
        private weak var hostVC: UIViewController?
        private var retry = 0
        private var monitoring = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                heroView?.removeFromSuperview()
                heroView = nil
                hosting = nil
                container = nil
                return
            }
            installIfNeeded()
            startVisibilityMonitoring()
        }

        private func resolveNavContext() -> (UINavigationBar, UIViewController)? {
            var node: UIResponder? = self
            while let cur = node {
                if let vc = cur as? UIViewController, let nav = vc.navigationController {
                    return (nav.navigationBar, vc)
                }
                node = cur.next
            }
            return nil
        }

        /// 🔴 本页是否仍是导航栈顶。浮层挂在 UINavigationController.view 上（整条栈共用），
        ///    push 到普通白底页时若不隐藏，旧大图会一直盖在下一页内容上。
        private var isHostOnTop: Bool {
            guard let host = hostVC, let nav = host.navigationController else { return true }
            // 响应链偶尔会先给到容器 VC；那不是栈里的项，宁可不隐藏（避免误判成白顶）。
            guard nav.viewControllers.contains(where: { $0 === host }) else { return true }
            return nav.topViewController === host
        }

        /// 低频轮询（0.2s）：push/pop 后及时隐藏 / 恢复浮层。页面销毁（window=nil）后自动停止。
        private func startVisibilityMonitoring() {
            guard !monitoring else { return }
            monitoring = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.window != nil else { return }
                if let view = self.heroView {
                    view.isHidden = self.scrolled >= self.hideThreshold || !self.isHostOnTop
                }
                self.monitoring = false
                self.startVisibilityMonitoring()
            }
        }

        private func installIfNeeded() {
            guard heroView == nil, let root = heroRoot else { return }
            // 🔴 绝不 fallback 到 rootView.addSubview —— 那会把大图盖在返回/收藏按钮上。
            guard let (bar, pageHost) = resolveNavContext(), let parent = bar.superview else {
                if retry < 6 {
                    retry += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.installIfNeeded()
                    }
                }
                return
            }
            let heroHost = UIHostingController(rootView: root)
            let view = heroHost.view!
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.clipsToBounds = true
            hosting = heroHost
            heroView = view
            container = parent
            hostVC = pageHost
            view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: headerHeight)
            parent.insertSubview(view, belowSubview: bar)
            applyFrame()
        }

        func applyFrame() {
            guard let view = heroView else { return }
            var origin = CGPoint.zero
            if let win = window, let parent = container {
                origin = parent.convert(CGPoint.zero, from: win)
            }
            view.frame.origin = CGPoint(x: origin.x, y: origin.y - scrolled)
            // 与 SwiftUI 侧毛玻璃渐入区间同步淡出，别把渐入的材质压住。
            let fadeStart = hideThreshold * 0.8
            if scrolled <= fadeStart {
                view.alpha = 1
            } else {
                view.alpha = max(0, 1 - (scrolled - fadeStart) / max(1, hideThreshold - fadeStart))
            }
            // 🔴 滚走后隐藏；页面已不在栈顶（被 push 到别的页）也必须隐藏，
            //    否则这块大图会一直浮在下一页内容之上。
            view.isHidden = scrolled >= hideThreshold || !isHostOnTop
        }
    }
}

// MARK: - 🔴 滚动几何实测（UIKit contentOffset KVO，不信任何 GeometryReader 坐标）

struct ImmersiveMetrics: Equatable {
    var scrolled: CGFloat = 0
    var contentOriginYRest: CGFloat = 0
}

private struct ImmersiveScrollTracker: UIViewRepresentable {
    let onMetricsChange: (ImmersiveMetrics) -> Void

    func makeUIView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.backgroundColor = .clear
        view.onMetricsChange = onMetricsChange
        return view
    }

    func updateUIView(_ uiView: TrackerView, context: Context) {
        uiView.onMetricsChange = onMetricsChange
        uiView.attachToScrollViewIfNeeded()
        uiView.report()
    }

    final class TrackerView: UIView {
        var onMetricsChange: ((ImmersiveMetrics) -> Void)?
        private weak var observed: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var last: ImmersiveMetrics?

        func attachToScrollViewIfNeeded() {
            guard observed == nil else { return }
            var candidate: UIView? = self
            while let node = candidate {
                if let scrollView = node as? UIScrollView {
                    observed = scrollView
                    observation = scrollView.observe(\.contentOffset, options: [.new, .initial]) { [weak self] _, _ in
                        self?.report()
                    }
                    return
                }
                candidate = node.superview
            }
        }

        /// 静止时的 contentOffset.y 基准。滚动量按「相对首帧」算，
        /// 不依赖 adjustedContentInset 的绝对值（不同 iOS 版本 / 安全区会变）。
        private var restOffsetY: CGFloat?

        /// 🔴 2026-11-08：不再手动改 UIScrollView 的 inset。
        ///
        /// 之前为了把「内容原点」压到 y=0，设过 `.never` + `contentInset.top = 0` +
        /// `contentInset.bottom = safeAreaInsets.bottom`，实测带来两个真机 bug：
        ///   ① SwiftUI 仍按自己的 safeArea 布局、UIKit 按被改过的 inset 绘制 →
        ///      绘制位置与命中测试错开约一行（第一首点不到、点第二首却播第一首）；
        ///   ② 导航栈外层 `safeAreaInset(edge:.bottom)`（迷你播放条）传给 ScrollView 的
        ///      bottom inset 被手动覆盖成只剩 home indicator → 最后一首被播放条压住。
        ///
        /// 大图早已改成 UIKit 浮层（挂在 UINavigationBar 之下），白顶不再依赖「内容原点 = 0」，
        /// 所以把 inset 交还 UIKit 自动管理；`contentOriginYRest` 用探针实测，
        /// `listPlaceholder = 大图高 + 吸顶头高 − 实测内容原点` 对任意原点都成立。
        func report() {
            // 🔴 每次都尝试 attach：首帧 superview 链可能还没连上，挂不上就永远测不到数值。
            attachToScrollViewIfNeeded()
            guard let sv = observed else { return }
            let offsetY = sv.contentOffset.y
            if let base = restOffsetY {
                // UIKit 可能因 safeArea 变化把起点调小，同步下调基准，别误判成已滚动。
                if offsetY < base { restOffsetY = offsetY }
            } else {
                restOffsetY = offsetY
            }
            let scrolled = max(0, offsetY - (restOffsetY ?? offsetY))
            let trackerY = convert(CGPoint.zero, to: nil).y
            let m = ImmersiveMetrics(scrolled: scrolled, contentOriginYRest: trackerY + scrolled)
            guard m != last else { return }
            last = m
            onMetricsChange?(m)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                attachToScrollViewIfNeeded()
                report()
                // 首帧 safeArea / contentInset 未定，稍后再量两次（不在 report 里递归派发）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.report() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.report() }
            }
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachToScrollViewIfNeeded()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        deinit { observation?.invalidate() }
    }
}
