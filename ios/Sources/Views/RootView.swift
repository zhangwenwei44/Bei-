import UIKit
import SwiftUI

struct RootView: View {
    /// 🔴 刻意不用 @EnvironmentObject 拿 store：ObservableObject 是**整对象粒度**
    /// 订阅 —— body 里读一下（哪怕只是传引用给子层）就把 RootView 挂到了
    /// PlayerStore 的 objectWillChange 上，播放期间 RootView → MainTabs →
    /// 整棵 TabView 树跟着任何 @Published 变化重算，TabBar 手势被持续打断。
    /// 改用单例引用传递：不建立任何订阅，TabView 树在播放期间结构静止。
    /// 子层各取所需：MiniPlayerOverlay 订 mini/playback，
    /// 播放页（UIKit present 的 UIHostingController）注入 playback/lyricState。
    private var store: PlayerStore { PlayerStore.shared }
    @State private var isPlayerExpanded = false

    var body: some View {
        // 🔴 迷你播放条的挂载点：每个 Tab 的导航栈【外层】（见 MainTabs.tabRoot）。
        //
        // ## 五版血泪史（别再改回去了）
        // 1. ZStack + VStack/Spacer 浮层 → 浮层铺满全屏吃掉 TabBar 触摸
        // 2. 整层 allowsHitTesting(false) → 播放条自己也点不了（继承性）
        // 3. Color.clear 铺满当穿透底板 → Color 在命中区里，照样吃触摸
        // 4. safeAreaInset 套在 TabView【整体】上 → inset 内容被放到 TabView
        //    frame 最底边，而 TabBar 就住在那 → 播放条下坠 + 直接盖住 TabBar
        //    （图4「TabBar 显示不出来」的根因）
        // 5. ✅ 现方案：safeAreaInset 套在每个 Tab 的导航栈外层 —— 这个区域的
        //    底边就是 TabBar 上沿，播放条被布局钉在 TabBar 正上方，
        //    二者结构上不可能重叠，TabBar 由 TabView 正常渲染。
        MainTabs(store: store, isExpanded: $isPlayerExpanded)
            // 🔴 播放页改用 **UIKit 级 present()** 呈现（UIHostingController +
            // modalPresentationStyle=.fullScreen），替代 SwiftUI fullScreenCover。
            //
            // ## 为什么废弃 fullScreenCover（第七版）
            // 横屏播放器需要强制旋转界面（enterLandscape → mask + 强制旋转）。
            // SwiftUI fullScreenCover 的 presentation 容器在强制旋转后命中测试区
            // 不随旋转更新 —— 视觉正常但按钮点不到（实测：返回/收藏/列表全灭，
            // 连换 scene.screen/window bounds 几何钳制都治不好）。
            // UIKit present() 是业界标准横屏播放器方案，旋转与命中测试都由
            // UIKit 正确处理。关闭即销毁 presented VC，同样无 SwiftUI 树残留。
            .onChange(of: isPlayerExpanded) { expanded in
                if expanded {
                    PlayerPresenter.shared.present(
                        rootView: PlayerView(playback: store.playback,
                                             lyricState: store.lyricState,
                                             isExpanded: $isPlayerExpanded)
                            // cover 内容不自动继承呈现方的 environmentObject，显式注入
                            .environmentObject(store)
                    )
                } else {
                    PlayerPresenter.shared.dismiss()
                }
            }
            .onAppear {
                // 极小概率：启动即处于展开态（如进程被杀后恢复），补齐呈现
                if isPlayerExpanded {
                    PlayerPresenter.shared.present(
                        rootView: PlayerView(playback: store.playback,
                                             lyricState: store.lyricState,
                                             isExpanded: $isPlayerExpanded)
                            .environmentObject(store)
                    )
                }
            }
    }
}

/// 播放页的 UIKit 呈现器（RootView 私有）。
///
/// 🔴 主窗口按「bounds == screen 尺寸」过滤：设备上的第三方注入悬浮窗
/// （如网速悬浮球）会创建自己的 UIWindow 且可能成为 key window，
/// 绝不能拿它的 rootViewController 来 present。
final class PlayerPresenter {
    static let shared = PlayerPresenter()
    private weak var currentVC: UIViewController?
    private init() {}

    /// 尺寸等于物理屏幕的主窗口（过滤注入悬浮窗）。
    private var mainWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { w in
                let s = w.screen.bounds
                return w.bounds.width > 0
                    && abs(w.bounds.width - s.width) < 1
                    && abs(w.bounds.height - s.height) < 1
            }
    }

    private var rootViewController: UIViewController? {
        mainWindow?.rootViewController
    }

    /// 泛型入口：接受任意 SwiftUI 根视图（.environmentObject 会擦成不透明类型，
    /// 不能用 UIHostingController<PlayerView> 的具体泛型收编）。
    func present<Content: View>(rootView: Content) {
        guard currentVC == nil, let root = rootViewController,
              root.presentedViewController == nil else { return }
        let vc = PlayerHostingController(rootView: rootView)
        vc.modalPresentationStyle = .fullScreen
        vc.modalTransitionStyle = .coverVertical
        currentVC = vc
        root.present(vc, animated: true, completion: nil)
    }

    func dismiss() {
        guard let vc = currentVC else { return }
        currentVC = nil
        vc.dismiss(animated: true, completion: nil)
    }
}

/// 🔴 v2.6.4：播放页容器 —— 横屏播放器时隐藏系统 home 指示条（底部那条白杠）。
///
/// 为什么不用 `UIApplication.shared.isHomeIndicatorAutoHidden`：现代 iOS 由
/// **UIViewController 的 prefersHomeIndicatorAutoHidden** 决定，全局属性不生效。
/// 这里动态读 OrientationLock —— 进横屏为 true、退横屏自动恢复。
final class PlayerHostingController<Content: View>: UIHostingController<Content> {
    override var prefersHomeIndicatorAutoHidden: Bool {
        OrientationLock.shared.isLandscapePlayer
    }
}

/// 主 Tab 容器 —— 刻意不订阅 PlayerStore（store 仅作构造参数传递），
/// 避免播放进度高频更新引发整树重算。
private struct MainTabs: View {
    /// 仅用于把 store 传给各 Tab 的播放条 —— body 不读它的属性，不建立订阅。
    private let store: PlayerStore
    @Binding var isExpanded: Bool

    @State private var tab: Tab = .discover
    @State private var showKugouLogin = false

    init(store: PlayerStore, isExpanded: Binding<Bool>) {
        self.store = store
        self._isExpanded = isExpanded
    }

    fileprivate enum Tab: Hashable {
        case discover, search, library, profile
    }

    var body: some View {
        TabView(selection: $tab) {
            tabRoot(DiscoverView())
                .tabItem { Label("主页", systemImage: "house.fill") }.tag(Tab.discover)
            tabRoot(SearchView())
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(Tab.search)
            tabRoot(LibraryView())
                .tabItem { Label("我的音乐", image: "MyMusicIcon") }.tag(Tab.library)
            tabRoot(ProfileView())
                .tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(Tab.profile)
        }
        // 键盘弹出时不抬 TabBar/播放条（搜索页打字时保持原位，与旧版行为一致）
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $showKugouLogin) { KugouLoginSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .auroraShowKugouLogin)) { _ in
            showKugouLogin = true
        }
        .tint(AppStyle.accent)
        // 🔴 头像兜底：已登录但本地没存头像的存量用户（二维码登录响应没给、
        // 或旧版本登录的），启动时走 usercenter 补拉一次。失败静默，不影响使用。
        .task {
            let auth = KugouAuth.shared
            if auth.isLoggedIn, !auth.needsRelogin, auth.avatarURL == nil {
                await KugouClient.shared.fetchMyInfo()
            }
        }
    }

    /// 🔴 每个 Tab 的根容器：导航栈【外层】套 safeAreaInset。
    ///
    /// Tab 内容区的 bottom 安全区天然到 TabBar 上沿为止，所以播放条被布局
    /// 钉在 TabBar 正上方（底边贴住 TabBar 上沿）—— 不需要任何手动高度
    /// 计算 / allowsHitTesting 花招，命中测试由布局结构保证。
    /// 挂在导航栈外层还意味着 push 进二级页后播放条依然常驻。
    private func tabRoot<Content: View>(_ content: Content) -> some View {
        CompatNavigationStack { content }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayerOverlay(store: store, isExpanded: $isExpanded)
            }
    }
}

/// 迷你播放条 —— 每个 Tab 导航栈外层的 bottom safeAreaInset 内容，不是浮层。
///
/// ## 为什么不用 ZStack 浮层（前三次都失败了）
///
/// 1. `VStack { Spacer(); MiniPlayer }` → 该层撑满全屏，吃掉 TabBar 的触摸。
/// 2. 整层 `.allowsHitTesting(false)` → 播放条也点不进去。
///    SwiftUI 的 allowsHitTesting 是**继承**的：父级 false 会连子级一起禁，
///    子级设 true 覆盖不了。
/// 3. `Color.clear.frame(铺满)` 当"命中穿透底板" → Color 虽透明，
///    但 frame 铺满后它自身就在命中测试区里，照样吃掉全屏触摸。
///
/// 三次都是「让浮层不吃触摸」，但浮层的布局始终铺满屏幕。
///
/// ## 第四次的错法（也别再犯）
///
/// `safeAreaInset` 套在 TabView **整体**上 —— inset 内容被放到 TabView frame
/// 的最底边，而 TabBar 就住在那里 → 播放条下坠盖住 TabBar。
///
/// ## 现在的方案：挂对宿主
///
/// safeAreaInset 套在【每个 Tab 的导航栈外层】（MainTabs.tabRoot）。
/// Tab 内容区的 bottom 安全区天然到 TabBar 上沿为止，播放条被布局钉在
/// TabBar 正上方 —— 结构上不可能重叠，命中测试由布局保证。
private struct MiniPlayerOverlay: View {
    /// 🔴 只订阅 MiniPlayerState，不订阅整个 PlayerStore。
    ///
    /// 根因：PlayerStore 里 `currentLyricIndex` 在播放时以 4fps 变化
    /// （歌词逐行高亮）。一旦订阅整个 PlayerStore，播放条每秒重算 4 次。
    @ObservedObject private var mini: MiniPlayerState
    /// 播放进度：进度条自己订阅，不经过 PlayerStore。
    @ObservedObject private var playback: PlaybackProgress
    /// 仅用于派发用户操作（toggle/step/seek），不参与 body 依赖。
    private let store: PlayerStore

    @Binding var isExpanded: Bool

    init(store: PlayerStore, isExpanded: Binding<Bool>) {
        self.store = store
        self.mini = store.mini
        self.playback = store.playback
        self._isExpanded = isExpanded
    }

    var body: some View {
        VStack(spacing: 0) {
            if mini.isVisible {
                MiniPlayer(mini: mini, playback: playback, store: store, isExpanded: $isExpanded)
                    .padding(.horizontal, 10)
                    // 🔴 底边贴住 TabBar 上沿（用户明确要求的形态）。
                    // 不要再垫 padding —— 垫了就是"悬浮偏高"，用户已纠正过一次。
                    .padding(.bottom, 0)
                    .id("mini-player")
            }
        }
        // 🔴 不加全宽材质背板：播放条自己是圆角胶囊 + ultraThinMaterial，
        // 外面再糊一条全宽色带会把它变成一根"粗条"（也盖住 TabBar 上沿的层次）。
        // 隐藏时 VStack 高度为 0，inset 自动消失。
        // 播放页由 RootView 的 fullScreenCover 呈现（见 RootView.body）。
        .queueSheet()
    }
}

// MARK: - 迷你播放条

struct MiniPlayer: View {
    /// 🔴 低频状态走 mini，高频进度走 playback —— 不订阅整个 PlayerStore。
    /// 只要 body 里还读任何一个 PlayerStore 的高频属性（如 currentLyricIndex 4fps），
    /// 整个播放条就会跟着每秒重算 4 次。
    @ObservedObject var mini: MiniPlayerState
    /// 进度条专用的高频订阅对象 —— 见 PlaybackProgress 文档。
    @ObservedObject var playback: PlaybackProgress
    /// 仅用于派发用户操作（toggle/step），不参与 body 依赖。
    let store: PlayerStore
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            CoverImage(url: mini.song?.artworkURL,
                       fallbackKeys: mini.song?.coverFallbackKeys ?? [],
                       seed: "\(mini.song?.artist ?? "")-\(mini.song?.title ?? "")",
                       size: 40,
                       corner: 8)

            VStack(alignment: .leading, spacing: 2) {
                // 第一行：歌曲名；第二行：歌手名（排第一）+ 音质
                Text(mini.song?.title ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                HStack(spacing: 6) {
                    Text(mini.song?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !mini.qualityName.isEmpty {
                        // 🔴 v2.5.47：音质标签改成与播放页同款黄色胶囊（原蓝色纯文字）
                        Text(mini.qualityName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(AppStyle.gold)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppStyle.gold.opacity(0.18), in: Capsule())
                            .overlay(Capsule().stroke(AppStyle.gold.opacity(0.55), lineWidth: 0.5))
                    }
                }
            }

            Spacer(minLength: 0)

            if mini.isLoading {
                ProgressView()
                    .tint(AppStyle.accent)
                    .frame(width: 26, height: 26)
            } else {
                Button {
                    store.toggle()
                } label: {
                    Image(systemName: mini.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }

            Button {
                store.step(1)
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(AppStyle.secondaryText)
                    .frame(width: 30, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        // 🔴 进度条独立成子视图：播放时只重绘这 2pt 小条，
        // 不重建整个 MiniPlayer（material 背景 / CoverImage / 按钮都不动）→ 降低主线程负载
        .overlay(alignment: .bottom) {
            MiniPlayerProgressBar(playback: playback)
        }
        // 🔴 关键：clipShape 必须写在进度条 overlay 【之后】。
        //
        // SwiftUI 的 clipShape 只裁剪它【之前】的内容，之后的 overlay 不受裁剪。
        // 之前顺序是 clipShape → overlay(进度条)，进度条是全宽 GeometryReader，
        // 左右两端直接伸出圆角矩形（图2 的根因）。
        // 现在顺序是 overlay(进度条) → clipShape → overlay(描边)：
        // 进度条先画进视图层级，再被圆角整体裁住，描边最后画在裁剪结果之上。
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppStyle.stroke, lineWidth: 1)
        )
        // 浮在 TabBar 之上，给一点投影把层次拉开
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
        // 🔴 hitTest 区域严格限制在圆角矩形内，超出的地方（比如 TabBar）不拦截
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { expand() }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    if abs(value.translation.height) > 24, value.translation.height < 0 { expand() }
                }
        )
    }

    private func expand() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { isExpanded = true }
    }
}

/// MiniPlayer 底部 2pt 进度条 —— 独立订阅 PlaybackProgress，播放时只重绘它自己，
/// 避免每 0.5s 把整个 MiniPlayer（material/封面/按钮）全部重建。
/// 🔴 订阅 progress 而非 PlayerStore：后者每 0.5s 变一次 currentTime，
/// 会连带触发四个主页面的整树重算（TabBar 卡死的根因）。
private struct MiniPlayerProgressBar: View {
    /// 进度实例由 PlayerStore 持有并注入 —— 与播放页共用同一份状态。
    /// 🔴 订阅 progress 而非 PlayerStore：后者每 0.5s 变一次 currentTime，
    /// 会连带触发四个主页面的整树重算（TabBar 卡死的根因）。
    /// （曾经这里还有一个从 environment 拿 store 的死订阅，从未读过却把
    ///  整个 PlayerStore 订了个遍 —— 已删。）
    @ObservedObject var playback: PlaybackProgress

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(AppStyle.accent)
                .frame(width: geo.size.width * max(0, min(1, playback.progress)), height: 2)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
