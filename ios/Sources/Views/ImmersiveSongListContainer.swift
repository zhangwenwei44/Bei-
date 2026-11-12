import SwiftUI
import UIKit

// MARK: - 🔴 歌单 / 专辑详情共用的「沉浸式头部」容器
//
// 2026-11-07：用户要求「新歌推荐 / 每日推荐 / 猜你喜欢 / 经典推荐 / DJ推荐 / 歌单 / 专辑」
// 这些列表详情页全部按歌手主页的样式来做：
//   ① 大图铺满状态栏 + 透明导航栏；② 大图随列表 1:1 上滑收起；
//   ③ 滚到图片底部渐显毛玻璃顶栏；④ 「播放全部」行吸顶、仅列表滚动；
//   ⑤ 顶栏文字展开白 / 收起黑（2026-11-08 起收藏并入右上角三点竖菜单，不再有蓝胶囊）。
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
    /// 大图兜底深色：图未加载 / 加载失败时顶部（含状态栏）也绝不露白。
    static let heroFallback = Color(red: 0.07, green: 0.07, blue: 0.09)
    /// 列表底部留白：迷你播放条 + TabBar 的高度，保证最后一首能滚到播放条上方。
    static let listBottomInset: CGFloat = 96
}

// MARK: - 吸顶行共用控件（2026-11-08 用户指定样式）

// 🔴 2026-11-12：`ImmersiveMultiSelectIcon` 已移到 `PlaylistActionIcons.swift`
//    （用户给的截图是「2 个勾 + 3 条短横」，不再是两个空心方框）。
//    类型名不变，SearchView 等调用点无需改动。

/// 「播放全部」按钮：蓝色渐变圆钮 ▶ + 黑色粗体「播放全部」+ 灰色曲目数。
/// 用户 2026-11-08 给的样式图，替换原来的蓝色胶囊按钮。
struct ImmersivePlayAllButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        // 🔴 2026-11-09：按用户要求整体改小（圆钮 44→34、标题 18→15、播放三角 17→13）。
        //    吸顶条高度由 PreferenceKey 实测，按钮变小后会自动跟着变矮，不用改几何代码。
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 0.20, green: 0.68, blue: 0.99),
                                     Color(red: 0.06, green: 0.45, blue: 0.93)],
                            startPoint: .top, endPoint: .bottom))
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
                .frame(width: 34, height: 34)

                Text("播放全部")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.10, green: 0.11, blue: 0.13))
                Text("\(count)")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color(red: 0.67, green: 0.69, blue: 0.72))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 几何状态（容器与 toolbar 共用同一个对象，颜色才能同步刷新）

/// 🔴 2026-11-13：高频滚动量单独成一个 ObservableObject。
///
/// 旧版把 `scrolled` 直接 @Published 在 `ImmersiveHeaderState` 上，而歌单详情页
/// （PlaylistViews / LibraryView）用 `@StateObject` 持有同一个对象、并在 body 里读
/// `navContentColor` / `navFrostOpacity` —— 于是**每滚动 0.5pt，整个页面 body
/// 连同几百行的 LazyVStack 内容闭包全部重算一次**，这就是 A–Z 排序大歌单上滑
/// 掉帧 + 抖动的真正主因。
///
/// 现在：滚动量只由「大图浮层 / 毛玻璃 / 吸顶头」这一小块视觉层订阅；
/// 页面 body 与歌曲列表完全不订阅它，只在顶栏配色跨过台阶时低频刷新。
final class ImmersiveScrollProgress: ObservableObject {
    @Published var scrolled: CGFloat = 0
}

final class ImmersiveHeaderState: ObservableObject {
    /// 大图高度（与歌手页一致）。
    let headerHeight: CGFloat = 350

    /// 🔴 高频滚动量：只有 `ImmersiveVisualChrome` 订阅，整棵列表不受影响。
    let scrollProgress = ImmersiveScrollProgress()
    var scrolled: CGFloat { scrollProgress.scrolled }

    /// 静止时「滚动内容 y=0」在 window 里的 y（探针直量，归一化后应为 0）。
    @Published var contentOriginYRest: CGFloat = 0
    /// 吸顶头实测高度（PreferenceKey 写入）。
    @Published var stickyHeight: CGFloat = 74

    /// 🔴 顶栏毛玻璃/文字色用的**低频阶梯值**（0.05 一档）。
    ///    整个收起过程最多发布 21 次，取代原来的每 0.5pt 一次（约 520 次）。
    @Published var navFrostOpacity: CGFloat = 0

    /// 🔴 2026-11-12 第三轮：字母索引的展开态单独成一个只发 Bool 的对象。
    let letterIndexMode = PlaylistLetterIndexMode()

    /// 🔴 2026-11-12：右侧 A–Z 快速索引用。由容器里的 ScrollViewReader 在出现时写入，
    ///    非 @Published —— 只是个可调用的代理，写它不该触发 body 重算。
    var scrollProxy: ScrollViewProxy?

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

    func collapseProgress(for s: CGFloat) -> CGFloat { min(1, max(0, s) / maxDrag) }
    /// 连续毛玻璃进度：只给视觉层用，不发布、不触发页面 body 重算。
    func frostOpacity(for s: CGFloat) -> CGFloat {
        max(0, min(1, (collapseProgress(for: s) - 0.8) / 0.2))
    }
    /// 吸顶头相对 ZStack 顶部的偏移：静止时贴大图底边，收起后钉在导航栏下沿。
    func stickyY(for s: CGFloat) -> CGFloat { max(0, maxDrag - s) }

    /// 顶栏文字/图标色：展开纯白（深色大图）、收起纯黑（浅色毛玻璃），与毛玻璃同步。
    var navContentColor: Color {
        Color(uiColor: UIColor(white: 1 - navFrostOpacity, alpha: 1))
    }

    /// 列表顶部占位：列表静止时屏幕 y = 大图底边 + 吸顶头高。
    var listPlaceholder: CGFloat {
        max(0, headerHeight + stickyHeight - max(0, contentOriginYRest))
    }

    /// 大图上的文案随上滑淡出，名字交给导航栏标题。
    var heroTextOpacity: CGFloat { 1 - collapseProgress(for: scrolled) }

    /// 🔴 2026-11-13 第四轮：修 A–Z 歌单「上滑抖动 / 卡顿」。
    ///
    ///   ① 滚动量写进独立的 `scrollProgress`，页面 body 与歌曲列表不再逐帧重算；
    ///   ② 顶栏配色按 0.05 台阶发布，整个收起过程只刷新 ~21 次；
    ///   ③ 内容原点的容差从 0.5pt 提到 2pt —— 旧版在列表顶端（scrolled<1）时
    ///      实测值会 ±1pt 抖，直接改变 `listPlaceholder` 高度 → 整个列表上下跳；
    ///      现在只有真正的大变化（旋转 / 安全区改变）才允许更新。
    func apply(_ m: ImmersiveMetrics) {
        if m.scrolled < 1 {
            let measured = (m.contentOriginYRest * 2).rounded() / 2
            if abs(contentOriginYRest - measured) >= 2 {
                contentOriginYRest = measured
            }
        }
        let q = (m.scrolled * 2).rounded() / 2
        if abs(scrollProgress.scrolled - q) >= 0.5 { scrollProgress.scrolled = q }

        let raw = frostOpacity(for: q)
        let step = (raw * 20).rounded() / 20
        if abs(navFrostOpacity - step) > 0.001 { navFrostOpacity = step }

        // 字母条只在跨过阈值那一次写 @Published，滚动全程零刷新。
        let expanded = q >= maxDrag * 0.9
        if letterIndexMode.expanded != expanded { letterIndexMode.expanded = expanded }
    }
}

// MARK: - 容器

/// 沉浸式歌曲列表容器：调用方传入大图 / 吸顶头 / 列表，其余几何全部由本容器负责。
struct ImmersiveSongListContainer<Hero: View, Sticky: View, Content: View>: View {
    @ObservedObject var state: ImmersiveHeaderState
    /// 🔴 头图 / 吸顶头在 init 里装箱一次，滚动时不再每次 body 重算都重新包 AnyView。
    let heroBox: AnyView
    let stickyBox: AnyView
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
        self.heroBox = AnyView(hero())
        self.stickyBox = AnyView(sticky())
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            // ① 滚动容器：只有「占位 + 列表」。大图不在这里（会被 UIKit 层盖住）。
            // 🔴 2026-11-13：本 body **不读高频滚动量**，只在内容原点/吸顶头高度
            //    等低频事件变化时重算 —— 大歌单滚动时列表树保持稳定，不再掉帧。
            // 🔴 2026-11-09：外层保持 VStack —— 沉浸式几何（探针 / 占位 / 大图浮层）
            //    已在真机反复验证，不动它。大歌单的懒加载由 content 自己用 LazyVStack
            //    完成（见 KugouPlaylistDetail.content），嵌套 Lazy 反而可能让 SwiftUI
            //    在测量高度时把行全部构建出来。
            // 🔴 2026-11-12：外层包 ScrollViewReader，把代理交给 state，供右侧字母索引
            //    scrollTo 定位。它不改变几何，也不给 ScrollView 加任何 ignoresSafeArea。
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ImmersiveScrollTracker { m in
                            // KVO contentOffset 回调本就在主线程，同步应用才能与
                            // UIScrollView 同帧；再 async 一帧就是上滑时的错位抖动。
                            state.apply(m)
                        }
                        .frame(height: 0)

                        Color.clear.frame(height: state.listPlaceholder)

                        content
                    }
                }
                .background(AppStyle.background)
                .onAppear { state.scrollProxy = proxy }
            }
            // 🔴 绝不给 ScrollView 本体加 ignoresSafeArea(edges:.top)：
            //    每加一层就会再下推一个安全区（歌手页 180pt 白顶的老坑）。

            // ②③④ 所有「逐帧跟随滚动」的视觉层集中在这个小视图里：
            // 它订阅 scrollProgress，每帧只重算三个视图，绝不碰歌曲列表。
            ImmersiveVisualChrome(state: state,
                                  heroKey: heroKey,
                                  hero: heroBox,
                                  sticky: stickyBox)
        }
    }
}

/// 🔴 2026-11-13：把「大图浮层 / 毛玻璃 / 吸顶头」从容器 body 里拆出来。
///    容器 body 不再订阅高频滚动量，歌曲列表就不会随滚动逐帧重建。
private struct ImmersiveVisualChrome: View {
    @ObservedObject var state: ImmersiveHeaderState
    @ObservedObject var progress: ImmersiveScrollProgress
    let heroKey: String
    let hero: AnyView
    let sticky: AnyView

    init(state: ImmersiveHeaderState, heroKey: String, hero: AnyView, sticky: AnyView) {
        self._state = ObservedObject(wrappedValue: state)
        self._progress = ObservedObject(wrappedValue: state.scrollProgress)
        self.heroKey = heroKey
        self.hero = hero
        self.sticky = sticky
    }

    var body: some View {
        let s = progress.scrolled
        return ZStack(alignment: .top) {
            // ② 大图：UIKit 浮层，插在 UINavigationBar 之下 → 盖住白背景、返回按钮仍可见可点。
            ImmersiveHeroLayer(scrolled: s,
                               headerHeight: state.headerHeight,
                               hideThreshold: state.maxDrag,
                               heroKey: heroKey,
                               hero: hero)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            // ③ 毛玻璃顶栏：大图滚走后渐入。用连续进度，视觉上不台阶化。
            frostedBar
                .offset(y: -state.topInset)
                .allowsHitTesting(false)
                .opacity(state.frostOpacity(for: s))

            // ④ 吸顶头：大图未收起时贴着大图底边走，收起后钉在顶栏正下方。
            sticky
                .offset(y: state.stickyY(for: s))
                .background(AppStyle.background)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ImmersiveStickyHeightKey.self, value: geo.size.height)
                    }
                )
        }
        // 🔴 视觉层每帧重算时 GeometryReader 都会回传同一个高度；@Published 不去重，
        //    无条件赋值会让整页（含歌曲列表）又逐帧失效，前面的性能拆分就白做了。
        //    只有高度真的变化才写。
        .onPreferenceChange(ImmersiveStickyHeightKey.self) { h in
            if abs(state.stickyHeight - h) > 0.5 { state.stickyHeight = h }
        }
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
                    // 🔴 2026-11-11：排序弹窗打开期间临时隐藏大图浮层。
                    //    浮层挂在 nav.view 上、层级高于 SwiftUI 内容层，不隐藏会盖住
                    //    从底部升起的弹窗标题区。轮询 0.2s 自动恢复，只影响弹窗期间。
                    view.isHidden = self.scrolled >= self.hideThreshold
                        || !self.isHostOnTop
                        || PlaylistSortOverlayState.shared.isPresented
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
        /// 🔴 同步 apply 会写 @Published → SwiftUI 可能立刻触发 layoutSubviews →
        ///    又回到 report()。加一个不可重入标志，切断这条递归链。
        private var isReporting = false

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
            guard !isReporting else { return }
            isReporting = true
            defer { isReporting = false }
            // 🔴 每次都尝试 attach：首帧 superview 链可能还没连上，挂不上就永远测不到数值。
            attachToScrollViewIfNeeded()
            guard let sv = observed else { return }
            let offsetY = sv.contentOffset.y
            if let base = restOffsetY {
                // 🔴 2026-11-13：只在「非手势、非惯性」时同步下调静止基准。
                //    旧版无条件 `if offsetY < base { restOffsetY = offsetY }`：
                //    列表在顶部下拉回弹（rubber band）时 offsetY 会更负，基准被压低；
                //    松手回到 -adjustedInset 后 scrolled 突然变成正的几十 pt，
                //    大图 / 吸顶头猛地一跳 = 用户看到的「上滑抖动」。
                //    safeArea 变大导致的基准下移发生在静止时，仍允许同步。
                if offsetY < base,
                   !sv.isDragging, !sv.isDecelerating,
                   base - offsetY < 40 {
                    restOffsetY = offsetY
                }
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
