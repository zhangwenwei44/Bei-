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
    /// 🔴 2026-11-15：大图兜底改成「深蓝灰」而不是近黑色。
    ///    近黑底 + 白色音符占位在真机上就是「先过一下黑色图片」；
    ///    现在配合 CoverImage 的缓存首帧图，过渡看起来是一次正常的淡入。
    static let heroFallback = Color(red: 0.20, green: 0.22, blue: 0.27)
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
                    // 🔴 2026-11-17：原来硬编码近黑色，深色模式下整个按钮文字
                    //    和深色列表底融为一体（用户截图「播放全部」看不清）。
                    .foregroundStyle(AppStyle.primaryText)
                Text("\(count)")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(AppStyle.secondaryText)
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
    /// 🔴 2026-11-15：内容原点只在入页后的短时间内允许收敛，之后锁死。
    ///    旧版每次回到列表顶部（scrolled<1）都重新实测，探针值 ±1~2pt 的抖动会
    ///    反复改写 `listPlaceholder` → 整张列表上下跳几下（用户实机反馈）。
    private var originSettleDeadline: TimeInterval = 0
    /// 吸顶头实测高度（PreferenceKey 写入）。
    @Published var stickyHeight: CGFloat = 74

    /// 🔴 顶栏毛玻璃/文字色用的**低频阶梯值**（0.05 一档）。
    ///    整个收起过程最多发布 21 次，取代原来的每 0.5pt 一次（约 520 次）。
    ///    ⚠️ 2026-11-15：这 21 次发布仍然会让页面 body（含整棵 LazyVStack）
    ///    反复重算 —— 滑回顶部时连发就是「列表抖几下」。现在改成滚动停止后
    ///    才对齐一次（见 scheduleNavAppearance），滚动中一次都不发布。
    @Published var navFrostOpacity: CGFloat = 0
    /// 🔴 2026-11-15 第二十二轮：**不去抖**的深浅判定。
    ///    毛玻璃背景用连续 `frostOpacity(for:)` 逐帧渐入，但顶栏文字 / 状态栏
    ///    原来读去抖 0.12s 的 navFrostOpacity → 背景已经白、文字还是白字
    ///    （用户截图 789d3075「顶栏变色有点慢」）。这里跨 0.5 阈值那一次
    ///    立刻发布，整个收起过程最多 2 次，不会像连续值那样引发列表抖。
    @Published var navIsDark: Bool = true
    private var navAppearanceWork: DispatchWorkItem?

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

    /// 顶栏文字/图标色：展开纯白（深色大图）、收起纯黑（浅色毛玻璃）。
    /// 🔴 第二十二轮：改用即时 `navIsDark` 二值，与状态栏白/黑字同一时刻切换，
    ///    不再等 0.12s 去抖。`navFrostOpacity` 仍只管标题渐显这类连续动效。
    /// 🔴 2026-11-17：深色主题下毛玻璃底也是深色，收起后不能把文字切成黑色
    ///    （用户反馈「上滑后顶栏字体颜色看不清」）。展开态保持白字。
    var navContentColor: Color { navIsDark || AppStyle.isDarkTheme ? .white : .black }

    /// 状态栏 / UIKit 锚点用的同一判据：展开态或深色主题都必须用白色内容。
    var navUsesDarkChrome: Bool { navIsDark || AppStyle.isDarkTheme }

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
        // 🔴 2026-11-15：滚动中绝不改写内容原点。
        //    探针实测值会随 contentOffset 有 ±1~2pt 抖动，改写它就会改
        //    listPlaceholder → 整张列表上下跳。只在「静止 + 入页收敛期」才量。
        if m.scrolled < 1, !m.interacting {
            let measured = (m.contentOriginYRest * 2).rounded() / 2
            let now = Date.timeIntervalSinceReferenceDate
            if originSettleDeadline == 0 { originSettleDeadline = now + 0.8 }
            // 入页 0.8s 内让首帧 / 0.15s / 0.5s 三次补测收敛到准确值；
            // 之后只有安全区、旋转这类大变化才允许改写，顶部回弹再也不会顶动列表。
            let settling = now < originSettleDeadline
            if (settling && abs(contentOriginYRest - measured) >= 2)
                || abs(contentOriginYRest - measured) > 12 {
                contentOriginYRest = measured
            }
        }
        let q = (m.scrolled * 2).rounded() / 2
        if abs(scrollProgress.scrolled - q) >= 0.5 { scrollProgress.scrolled = q }

        let raw = frostOpacity(for: q)
        // 🔴 第二十二轮：深浅判定**立即**发布（不走去抖），但只在跨阈值那一次写。
        let wantsDark = raw < 0.5
        if navIsDark != wantsDark {
            if Thread.isMainThread { navIsDark = wantsDark }
            else { DispatchQueue.main.async { [weak self] in self?.navIsDark = wantsDark } }
        }
        let step = (raw * 20).rounded() / 20
        // 🔴 2026-11-15 第十五轮：滚动过程中不发布顶栏配色。
        //    每级台阶都会让页面 body 重算（含整棵歌曲列表树），滑回顶部时
        //    21 级台阶连发 → 列表「抖几下」。毛玻璃视觉层仍逐帧平滑渐入
        //    （ImmersiveVisualChrome 直接用 frostOpacity(for:) 连续算），
        //    顶栏文字 / 状态栏配色只在停止滚动 0.12s 后一次性对齐。
        scheduleNavAppearance(step)

        // 字母条只在跨过阈值那一次写 @Published，滚动全程零刷新。
        // 🔴 2026-11-15：加滞回（进 0.92 / 出 0.78）——旧版单一阈值在
        //    scrolled 量化到 0.5pt 后会在临界点反复横跳，导致字母条/滑动条
        //    浮层反复重建、列表视觉层跟着抖几下。
        let enter = maxDrag * 0.92
        let exit = maxDrag * 0.78
        let expanded = letterIndexMode.expanded ? (q >= exit) : (q >= enter)
        if letterIndexMode.expanded != expanded { letterIndexMode.expanded = expanded }

        // 🔴 2026-11-13：蓝圆跟随「当前吸顶头下方第一行」的首字母。
        //    屏幕 y = topInset + stickyHeight；内容坐标 = 屏幕 y − 内容原点 y + 已滚动量。
        //    两组数据都来自实测的 contentOriginYRest / listPlaceholder，不做坐标猜测。
        let contentY = topInset + stickyHeight - max(0, contentOriginYRest) + q
        letterIndexMode.syncVisible(contentY: contentY, listStart: listPlaceholder)
    }

    /// 滚动一停才把顶栏配色对齐到最终值；连续滚动时不断取消上一个任务，
    /// 因此整个收起/展开过程只有「停手」那一次 @Published 写入。
    private func scheduleNavAppearance(_ step: CGFloat) {
        navAppearanceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if abs(self.navFrostOpacity - step) > 0.001 {
                self.navFrostOpacity = step
            }
        }
        navAppearanceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    deinit { navAppearanceWork?.cancel() }
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

/// 🔴 2026-11-15 第二十三轮：撤销第二十二轮的 `ImmersivePopState`。
///
///    那个单例 `@Published` 会在 `dismantleUIView` / `didMoveToWindow` 里被写 ——
///    也就是「SwiftUI 正在拆视图树的同时发布变更」，真机上会触发
///    AttributeGraph 重入崩溃（用户反馈「返回时闪退」）。

/// 🔴 2026-11-15 第二十五轮：前两轮在「早拆」和「不拆」之间来回摆，都只解决了一半。
///
///    · 第二十三轮横滑没触发：当时 `isHostOnTop` 里有 `return transitionCoordinator != nil`，
///      pop 期间恰为 true，`!isHostOnTop` 永远不成立 → 大图静止盖在返回后的主页上一会儿。
///    · 第二十四轮改成「非栈顶立刻隐藏」：残留没了，但 `dismantleUIView` 在 pop
///      第一帧就把大图从 nav.view 上摘掉，右半屏整块纯白（用户截图 2860a0cc）。
///
///    终局：`isHostOnTop` 保持严格判据（绝不让大图停在下一页上），但在
///    **确认是 pop 转场**时先让大图用系统同一条转场曲线横滑出屏，再销毁。
///    判据用 `coord.viewController(forKey:.from)` 已不在 `nav.viewControllers`
///    （push 时 from 仍在栈里），不依赖 hostVC 是不是 nav 的直接子 VC。
///    全程纯 UIKit，不写任何 SwiftUI 状态，不会重现第二十二轮的闪退。

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
            // 🔴 第二十四轮：转场期间不给顶栏补色、也不让大图跟着滑。
            //    大图浮层一离开栈顶就隐藏，旧页内容整体随系统转场滑走，
            //    中间帧不会出现「静止不动的白色方块 / 静止不动的大图」。
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
                fallbackColor: ImmersiveStyle.heroFallback,
                // 🔴 2026-11-14：头图绝不复用列表页缓存的 150px 小图，
                //    否则 480px 歌单封面会被放大成糊图（用户真机截图）。
                hiRes: true
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
        // 🔴 2026-11-14 第十二轮：SwiftUI 偶尔会短暂把 Representable 拆掉又更新同一个
        //    UIView（列表刷新 / heroKey 变化）。若此时已被 dismantle 且不允许复活，
        //    大图会永久消失 → 顶部露出一大块白（用户截图「有时候会成空白」）。
        //    只要视图还在窗口里、本页仍是栈顶，就允许补装回来。
        uiView.reviveIfNeeded()
        uiView.applyFrame()
    }

    /// 🔴 2026-11-14：SwiftUI 把这个 Representable 移出视图树时拆掉浮层。
    ///    以前只靠 didMoveToWindow(window==nil)，而 pop 返回后 SwiftUI 可能隔几秒
    ///    才真正释放 destination 视图 → 上一张歌单大图会盖在列表上好几秒。
    /// 🔴 第二十五轮：pop 转场第一帧就会 dismantle。此刻直接拆会让右半屏
    ///    整整 0.35s 都是白顶；先交给横滑动画接管，转场结束再销毁。
    static func dismantleUIView(_ uiView: AnchorView, coordinator: Void) {
        uiView.schedulePopHandoff()
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
        /// 🔴 2026-11-14：hostVC 是 weak，pop 后页面 VC 可能立刻被释放 → 变 nil。
        ///    必须另外记住导航控制器本身（它随整条栈存活），否则判断会漏掉。
        private weak var navController: UINavigationController?
        /// 防止「首帧没连上导航控制器」时轮询与自身重试叠加挂出一串延迟闭包。
        private var asyncRetryScheduled = false
        private var monitoring = false
        /// 已拆除（页面 pop / Representable 被移除）：重试闭包不得再装回大图。
        private var tornDown = false
        /// 首帧没拿到 coordinator 时的老兜底：先隐藏，0.42s 后放行。
        private var transitioning = false
        private var didRevealOnce = false
        /// 🔴 第二十五轮：pop 横滑期间由 alongside 动画独占大图的 x / alpha / isHidden。
        ///    `applyFrame()`、0.05s 轮询都不得插手，否则正在滑走的大图会被拽回 x=0
        ///    或被提前隐藏（右半屏又变白）。
        var popSliding = false
        /// 等待转场 coordinator 出现的短窗口，避免重复排队。
        private var dismantleScheduled = false
        /// 🔴 第二十九轮：pop 第一帧由 `auroraImmersivePopWillBegin` 置位。
        ///    这段窗口里大图已被提到 UINavigationBar 之上、必须保持可见且不改 frame，
        ///    直到 `startPopSlideIfNeeded()` 接管横滑（popSliding）或浮层被销毁。
        ///    否则 0.05s 轮询的 `!isHostOnTop` 会把它重新隐藏，灰白带又露出来。
        private var popCovering = false
        private var popObservers: [NSObjectProtocol] = []

        deinit {
            popObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                // pop 转场里锚点会先脱离 window；此时若直接摘掉大图，右侧中间帧整块白。
                // 先给系统转场一个短窗口来接管横滑，超时才真正拆除。
                schedulePopHandoff()
                return
            }
            installIfNeeded()
            startVisibilityMonitoring()
        }

        /// 🔴 2026-11-15 第二十七轮：pop **第一帧**就把大图提到 UINavigationBar 之上。
        ///    灰白条是导航栏把两页 appearance 交叉淡化画出来的背景，只要浮层还在
        ///    bar 之下、或 isHidden=true，它就会露出来。第二十六轮只在 coordinator
        ///    接管时提层，coordinator 晚到 0.08s → 用户看到「灰白闪一下就没了」。
        ///    pop 刚起时旧页仍占满屏幕，大图静止在原位这 0.08s 完全不违和，
        ///    不会重现「图片带出来一会」（那个问题是浮层迟迟不销毁、盖在返回后的
        ///    主页上好几秒，不是这里的短窗口）。
        private func raiseHeroAboveBar() {
            guard let view = heroView, scrolled < hideThreshold else { return }
            view.isHidden = false
            view.superview?.bringSubviewToFront(view)
        }

        /// 🔴 第二十九轮：pop 第一帧的 UIKit 钩子（早于 dismantleUIView）。
        ///    只做纯 UIKit 的提层 + 尝试接管横滑，绝不写任何 SwiftUI 状态。
        private func registerPopNotifications() {
            guard popObservers.isEmpty else { return }
            let center = NotificationCenter.default
            let willBegin = center.addObserver(forName: .auroraImmersivePopWillBegin,
                                               object: nil, queue: .main) { [weak self] note in
                guard let self, let nav = note.object as? UINavigationController,
                      nav === self.navController, !self.tornDown, !self.popSliding else { return }
                self.popCovering = true
                self.transitioning = false
                self.raiseHeroAboveBar()
                // coordinator 此刻可能还没挂上；失败也没关系，popCovering 会保持
                // 提层，高频轮询 / schedulePopHandoff 会继续尝试接管横滑。
                _ = self.startPopSlideIfNeeded()
            }
            let didCancel = center.addObserver(forName: .auroraImmersivePopDidCancel,
                                               object: nil, queue: .main) { [weak self] note in
                guard let self, let nav = note.object as? UINavigationController,
                      nav === self.navController, !self.tornDown, !self.popSliding else { return }
                self.popCovering = false
                self.restoreHeroBelowBar()
                self.applyFrame()
            }
            popObservers = [willBegin, didCancel]
        }

        private func unregisterPopNotifications() {
            popObservers.forEach { NotificationCenter.default.removeObserver($0) }
            popObservers.removeAll()
        }

        /// 交互式取消 / 判定并非 pop 时把层级放回 bar 之下，别盖住返回、收藏按钮。
        func restoreHeroBelowBar() {
            guard let view = heroView, let parent = view.superview,
                  let bar = navController?.navigationBar,
                  bar.superview === parent else { return }
            parent.insertSubview(view, belowSubview: bar)
        }

        /// 🔴 dismantle / 脱离 window 都走这里：coordinator 有可能下一帧才挂上。
        ///    真的是离开本页时，第一帧就提层遮住导航栏 crossfade 的灰白条；
        ///    随后要么交给 pop 横滑，要么在 0.08s / 0.6s 两道兜底里销毁。
        func schedulePopHandoff() {
            // 🔴 2026-11-15 第二十八轮：绝不能无条件提层。
            //    第二十七轮为消除灰白闪帧，在这里一律 `raiseHeroAboveBar()`
            //    （把大图设为可见 + 提到导航栏之上）。但 SwiftUI 切 tab / 列表刷新
            //    也会走 dismantle / didMoveToWindow(nil)，那些场景里大图本来是隐藏
            //    的，被无条件放出来后就没有人再拆 → 返回完成后整块深色浮层
            //    （高度正好 headerHeight）盖在主页上半部分（用户截图 d72175f1）。
            //    只有「本页确实已不是栈顶」才是离开场景，才需要提层遮灰白。
            // 横滑已接管时别再动层级，避免多余的重排干扰 alongside 动画。
            if !isHostOnTop, !popSliding { raiseHeroAboveBar() }
            // 🔴 第二十八轮终极兜底：无论上面走哪条路径（横滑 completion 被吞、
            //    交互式 cancelled 误报、轮询复活误判），0.6s 后只要锚点已不在
            //    当前栈顶页面视图树里，就强制摘掉浮层。正常显示中的页面不受影响。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.heroView != nil, !self.popSliding else { return }
                if self.window == nil || !self.isAnchorOnCurrentTopPage {
                    self.removeHeroLayer()
                }
            }
            if startPopSlideIfNeeded() || popSliding || tornDown { return }
            guard !dismantleScheduled else { return }
            dismantleScheduled = true
            let hero = heroView
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, hero] in
                guard let self else { hero?.removeFromSuperview(); return }
                self.dismantleScheduled = false
                if self.startPopSlideIfNeeded() || self.popSliding { return }
                // 🔴 残留元凶：旧版只凭 `window != nil && isHostOnTop` 就 return 不拆。
                //    pop 完成后 hostVC 常已释放，isHostOnTop 会回退到
                //    isDescendant(of: topView)，navController 为 nil 时更直接返回
                //    true → 大图永久留在 nav.view 上。改用强判据：hostVC 必须还在
                //    导航栈里且确实是栈顶（= 只是 SwiftUI 短暂拆装），否则一律销毁。
                if self.window != nil,
                   let nav = self.navController, let host = self.hostVC,
                   nav.viewControllers.contains(where: { $0 === host }),
                   nav.topViewController === host {
                    self.restoreHeroBelowBar()
                    self.applyFrame()
                    return
                }
                self.removeHeroLayer()
            }
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
        ///    **只要不是栈顶就必须隐藏** —— 否则它会静止停在屏幕顶部，盖住正在滑入
        ///    或已经显示出来的下一页（用户截图 0e6dbe29「返回图片会带出来一会」）。
        private var isHostOnTop: Bool {
            guard let nav = navController else { return true }
            if let host = hostVC {
                // 🔴 pop 完成时 UINavigationController 会立刻把旧页移出 viewControllers，
                //    这一条优先判掉（「退出后还显示几秒」的修复不能回退）。
                guard nav.viewControllers.contains(where: { $0 === host }) else { return false }
                // 🔴 第二十四轮：旧版在这里 `return nav.transitionCoordinator != nil`
                //    （本意是防止 push 首帧误隐藏），但 pop 转场期间同样成立 →
                //    大图一直 isHidden=false，静止盖在返回后的主页上一会儿。
                //    push 首帧本来就由 `transitioning` 隐藏，旧页大图也不该盖在下一页上；
                //    pop 回来时 topViewController 变回本页，轮询会自动恢复显示。
                return nav.topViewController === host
            }
            // hostVC 已释放（weak 置 nil）：只能看本视图是否仍属于当前栈顶页。
            guard let topView = nav.topViewController?.view else { return true }
            return isDescendant(of: topView)
        }

        /// 🔴 第二十五轮：只认「真的正在 pop 本页」的系统转场 coordinator。
        ///
        ///    `nav.viewControllers` 在 pop 一开始就移除了 from VC，而 push 时
        ///    from（旧页）仍留在栈里 —— 这是唯一能稳定区分 push / pop 的判据，
        ///    不依赖 hostVC 是不是导航控制器的直接子 VC（SwiftUI 里常是内层 child）。
        private func leavingPopCoordinator() -> UIViewControllerTransitionCoordinator? {
            guard !popSliding, !tornDown, heroView != nil,
                  let nav = navController else { return nil }
            // 少数 SwiftUI 转场里 nav 自身的 coordinator 为空、页面 VC 上才有。
            let active = nav.transitionCoordinator ?? hostVC?.transitionCoordinator
            guard let coord = active, coord.isAnimated else { return nil }
            if let from = coord.viewController(forKey: .from) {
                if nav.viewControllers.contains(where: { $0 === from }) { return nil } // push
            } else if let host = hostVC, nav.viewControllers.contains(where: { $0 === host }) {
                return nil // 拿不到 from 时，旧页仍在栈里按 push 处理
            }
            // 从更深页面 pop 回本页时，本页重新变成栈顶，大图不该滑走。
            guard !isHostOnTop else { return nil }
            return coord
        }

        /// pop 期间把大图挂到与旧页相同的横滑曲线上；返回 true 表示已接管、调用方不要拆浮层。
        func startPopSlideIfNeeded() -> Bool {
            guard let coord = leavingPopCoordinator(),
                  let view = heroView,
                  scrolled < hideThreshold else { return false }
            popSliding = true
            // 🔴 第二十九轮：横滑已接管，改由 popSliding 独占大图的 frame / 可见性，
            //    popCovering 这段「第一帧保护」功成身退（避免状态残留卡住还原逻辑）。
            popCovering = false
            transitioning = false
            view.isHidden = false
            view.alpha = 1
            // 🔴 2026-11-15 第二十六轮：右侧「白顶」的真正元凶。
            //    pop 中间帧 UINavigationBar 会把两页的 appearance 交叉淡化，从状态栏
            //    底部到导航栏底部画出一条半透明灰白背景（截图 37f836de 右侧
            //    x≈440 起、y≈140~263 的灰白条，里面还叠着两页 toolbar 文字）。
            //    大图浮层是 `insertSubview(view, belowSubview: bar)`，顶部恰好被这条
            //    灰白盖住 —— 第二十五轮横滑其实生效了（深色大图确实滑到右侧），
            //    但顶栏那一条依旧是白的。转场期间把大图提到 bar 之上，用封面自己的
            //    深色盖掉它；浮层已在 alongside 动画里随页横滑，颜色/位置天然一致，
            //    且 `isUserInteractionEnabled=false` 不会吞掉边缘返回手势。
            //    🔴 第二十七轮：第一帧的提层已在 schedulePopHandoff 做过，这里幂等补一次。
            raiseHeroAboveBar()
            let startX = view.frame.origin.x
            let width = UIScreen.main.bounds.width
            _ = coord.animate(alongsideTransition: { _ in
                view.frame.origin.x = startX + width
            }, completion: { [weak self, weak view] ctx in
                guard let view else { return }
                if ctx.isCancelled {
                    // 交互式返回滑到一半松手回弹：只有本页确实回到栈顶（hostVC
                    // 仍在栈里且就是 top）才允许把大图复位保留；否则一律销毁。
                    // 🔴 第二十八轮：旧版只判 `window != nil`，系统把已完成的
                    //    pop 报成 cancelled 时大图就复位到 x=0 永久盖住主页。
                    self?.popSliding = false
                    view.frame.origin.x = startX
                    if let self = self, self.window != nil,
                       let nav = self.navController, let host = self.hostVC,
                       nav.viewControllers.contains(where: { $0 === host }),
                       nav.topViewController === host {
                        self.restoreHeroBelowBar()
                        self.applyFrame()
                    } else {
                        view.removeFromSuperview()
                        self?.removeHeroLayer()
                    }
                } else {
                    view.removeFromSuperview()
                    self?.removeHeroLayer()
                }
            })
            // 兜底：系统偶发吞掉 completion（连点返回 / 交互式转场被打断），
            // 1s 后无论如何都把浮层从 nav.view 上摘掉，绝不留到下一页。
            let hero = view
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { hero.removeFromSuperview(); return }
                guard self.popSliding else { return }
                hero.removeFromSuperview()
                self.removeHeroLayer()
            }
            return true
        }

        /// 低频轮询（0.05s）：push/pop 后及时隐藏 / 恢复浮层。页面销毁（window=nil）后自动停止。
        private func startVisibilityMonitoring() {
            guard !monitoring, !tornDown else { return }
            monitoring = true
            // 🔴 第二十九轮：pop 第一帧起改成每帧轮询（0.016s），让横滑尽快接管；
            //    平时仍 0.05s，只有几个属性读取，开销可忽略。
            let interval: TimeInterval = (popCovering || popSliding) ? 0.016 : 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                guard let anchor = self, anchor.window != nil, !anchor.tornDown else {
                    self?.monitoring = false
                    return
                }
                let target = anchor
                // 🔴 第二十五轮：dismantle 没抢到 coordinator 时，这里补一次 pop 接管。
                //    必须放在隐藏逻辑之前，否则会先白一帧。
                target.startPopSlideIfNeeded()
                // 🔴 2026-11-14：浮层没装上（首帧导航上下文未连、或 SwiftUI 短暂拆装）
                //    且本页仍在栈顶 → 持续补装。以前 installIfNeeded 只重试 6 次就放弃，
                //    一旦 1.2s 内没连上，整页顶部就永久是一片白。
                if !target.tornDown, !target.popSliding, target.isHostOnTop, target.heroView == nil {
                    target.installIfNeeded()
                }
                // 🔴 第二十九轮：popCovering 期间大图必须保持可见且停在 bar 之上。
                //    轮询里 `!isHostOnTop` 的常规隐藏会把提层撤掉，导航栏那条
                //    半透明 crossfade 灰带立刻重新露出来 = 用户说的「闪一下顶栏」。
                if let view = target.heroView, !target.popSliding, !target.popCovering {
                    // 🔴 2026-11-11：排序弹窗打开期间临时隐藏大图浮层。
                    //    浮层挂在 nav.view 上、层级高于 SwiftUI 内容层，不隐藏会盖住
                    //    从底部升起的弹窗标题区。轮询自动恢复，只影响弹窗期间。
                    // 🔴 `!isHostOnTop` 保证 push 到下一页时立刻隐藏，绝不让浮层
                    //    静止留在屏幕上「带出来一会」。
                    view.isHidden = target.transitioning || target.scrolled >= target.hideThreshold
                        || !target.isHostOnTop
                        || PlaylistSortOverlayState.shared.isPresented
                }
                target.monitoring = false
                target.startVisibilityMonitoring()
            }
        }

        /// 立即从 nav.view 上摘掉大图（页面被 pop / SwiftUI 视图销毁时调用）。
        func removeHeroLayer() {
            tornDown = true
            transitioning = false
            popSliding = false
            popCovering = false
            asyncRetryScheduled = false
            unregisterPopNotifications()
            heroView?.removeFromSuperview()
            heroView = nil
            hosting = nil
            container = nil
            hostVC = nil
        }

        /// 🔴 第二十八轮：只按「锚点是否还在当前栈顶页面的视图树里」判断能否复活。
        ///    `isHostOnTop` 在 hostVC 被释放后会回退到 isDescendant(of:)，navController
        ///    为 nil 时更直接返回 true —— 拿它当复活条件，pop 完成后会把大图重新
        ///    装回主页（用户截图 d72175f1）。切 tab 回来 / 列表刷新短暂拆装时，
        ///    锚点仍在栈顶页面视图树里 → 允许复活；页面真正 pop 掉后 SwiftUI 不会再
        ///    updateUIView，且锚点已不在新栈顶视图树里 → 一律不复活。
        private var isAnchorOnCurrentTopPage: Bool {
            guard let nav = navController, let top = nav.topViewController else { return false }
            return isDescendant(of: top.view)
        }

        /// SwiftUI 把 Representable 拆掉后又用同一个 UIView 继续更新时，允许复活。
        func reviveIfNeeded() {
            guard tornDown, !popSliding, window != nil, isAnchorOnCurrentTopPage else { return }
            tornDown = false
            transitioning = false
            installIfNeeded()
        }

        private func installIfNeeded() {
            guard !tornDown, heroView == nil, let root = heroRoot else { return }
            // 🔴 绝不 fallback 到 rootView.addSubview —— 那会把大图盖在返回/收藏按钮上。
            guard let (bar, pageHost) = resolveNavContext(), let parent = bar.superview else {
                // 不设次数上限：0.12s 可见性轮询会一直补装。只用一个标志去重复调度。
                guard !asyncRetryScheduled else { return }
                asyncRetryScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self else { return }
                    self.asyncRetryScheduled = false
                    guard !self.tornDown, self.window != nil else { return }
                    self.installIfNeeded()
                }
                return
            }
            asyncRetryScheduled = false
            let heroHost = UIHostingController(rootView: root)
            let view = heroHost.view!
            // 🔴 SwiftUI 头图首帧还没画出来时的兜底：与 ImmersiveStyle.heroFallback
            //    同色的深蓝灰（不再是近黑色，避免进页面先闪一张「黑图」）。
            view.backgroundColor = UIColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1)
            view.isUserInteractionEnabled = false
            view.clipsToBounds = true
            hosting = heroHost
            heroView = view
            container = parent
            hostVC = pageHost
            navController = pageHost.navigationController
            view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: headerHeight)
            parent.insertSubview(view, belowSubview: bar)
            // 🔴 第二十九轮：浮层一装上就监听 pop 第一帧通知，
            //    保证返回时提层不晚于 UINavigationBar 画 crossfade 灰带。
            registerPopNotifications()

            // 🔴 第二十轮：push 转场期间一律隐藏，转场结束后一次性显示（**不做 alpha 淡入**，
            //    淡入挡不住 —— 0.32s 没走完 alpha 已接近 1，中间帧照样盖住列表）。
            //    nav 的 coordinator 比 destination VC 的更可靠；两者都取不到时，
            //    仅「本视图首次安装」仍保护一次（首帧响应链可能还没连上）。
            let coord = navController?.transitionCoordinator ?? pageHost.transitionCoordinator
            let inTransition = coord?.isAnimated == true
            let shouldGuard = inTransition || !didRevealOnce
            if shouldGuard {
                transitioning = true
                view.isHidden = true
            }
            applyFrame()
            if shouldGuard {
                // 「只放行一次」：转场 completion 与兜底定时器谁先到都只生效一次。
                let reveal = { [weak self, weak view] in
                    guard let self, let view, !self.tornDown,
                          self.heroView === view, self.transitioning else { return }
                    self.transitioning = false
                    self.didRevealOnce = true
                    self.applyFrame()
                }
                // 用与歌手页完全相同的调用形态（已过 CI），避开 existential 类型推断差异。
                if let tc = navController?.transitionCoordinator, tc.isAnimated {
                    _ = tc.animate(alongsideTransition: nil) { _ in reveal() }
                } else if let tc = pageHost.transitionCoordinator, tc.isAnimated {
                    _ = tc.animate(alongsideTransition: nil) { _ in reveal() }
                }
                // 兜底：交互式取消 / completion 不回调 / 首帧没拿到 coordinator
                // 都不能让大图永久隐藏。0.42s 略长于标准 push(0.35s)。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { reveal() }
            }
        }

        func applyFrame() {
            guard let view = heroView else { return }
            // 🔴 pop 横滑期间大图的 frame / alpha / isHidden 全部由 alongside 动画独占。
            //    连 frame.origin 的其他分量都不写 —— 在 UIView 动画进行中重设 frame
            //    可能把正在跑的动画打断，让大图瞬间跳到屏外（右侧又变白）。
            //    🔴 第二十九轮：popCovering（第一帧提层、横滑尚未接管）同样不许改，
            //    否则末尾的 `!isHostOnTop` 会把刚提到 bar 之上的大图重新隐藏。
            guard !popSliding, !popCovering else { return }
            var origin = CGPoint.zero
            if let win = window, let parent = container {
                origin = parent.convert(CGPoint.zero, from: win)
            }
            // 🔴 push 转场期间 parent.convert 会带上转场位移，把大图推到屏幕右侧
            //    （半屏错位）；此时大图本就隐藏，x 钉 0。
            view.frame.origin = CGPoint(x: transitioning ? 0 : origin.x,
                                        y: origin.y - scrolled)
            // 与 SwiftUI 侧毛玻璃渐入区间同步淡出，别把渐入的材质压住。
            let fadeStart = hideThreshold * 0.8
            if scrolled <= fadeStart {
                view.alpha = 1
            } else {
                view.alpha = max(0, 1 - (scrolled - fadeStart) / max(1, hideThreshold - fadeStart))
            }
            // 🔴 滚走后隐藏；页面已不在栈顶（被 push 到别的页）也必须隐藏，
            //    否则这块大图会静止浮在下一页内容之上 —— 就是「返回图片带出来一会」。
            // 🔴 push 转场期间恒定隐藏，避免「浮层抢在页面滑入之前出现」。
            view.isHidden = transitioning || scrolled >= hideThreshold || !isHostOnTop
        }
    }
}

// MARK: - 🔴 滚动几何实测（UIKit contentOffset KVO，不信任何 GeometryReader 坐标）

struct ImmersiveMetrics: Equatable {
    var scrolled: CGFloat = 0
    var contentOriginYRest: CGFloat = 0
    /// 🔴 手势 / 惯性滚动中不允许改写 listPlaceholder（见 ImmersiveHeaderState.apply）。
    var interacting: Bool = false
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
                   // 🔴 2026-11-15：排除「顶部下拉回弹区」。
                   //    回弹时 contentOffset 会比 -adjustedContentInset.top 更负，
                   //    旧版把它当成新的静止基准，松手回到原位后 scrolled 突然变正
                   //    几十 pt → 大图/吸顶头猛地一跳（滑到顶部抖几下）。
                   offsetY >= -sv.adjustedContentInset.top - 1,
                   base - offsetY < 40 {
                    restOffsetY = offsetY
                }
            } else {
                restOffsetY = offsetY
            }
            let scrolled = max(0, offsetY - (restOffsetY ?? offsetY))
            let trackerY = convert(CGPoint.zero, to: nil).y
            let m = ImmersiveMetrics(scrolled: scrolled,
                                     contentOriginYRest: trackerY + scrolled,
                                     interacting: sv.isDragging || sv.isDecelerating)
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
