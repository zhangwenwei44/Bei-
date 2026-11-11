import SwiftUI
import UIKit

/// 🔴 竖屏播放页主题（T 恤按钮切换，选择会持久化）。
/// · classic        = 取色渐变背景 + 方形专辑封面（原有版式）
/// · artistPhoto    = 在取色渐变之上铺当前歌手的写真（歌词页同款多张轮播）；
///                    取不到写真时整层为空，自动回退成 classic 的取色渐变。
/// · immersiveCover = 2026-11-09 从酷狗 20.8.4 的「沉浸式封面」样式移植（按真机截图校正）：
///                    完整封面从顶栏雾化区下方铺满屏宽、不裁切 → 下沿羽化 →
///                    顶栏的雾化天空蓝与底部的湖水青都延续同一张封面的取色，整屏一体沉浸。
///                    🔴 主题只换背景、不改版式：歌词仍在 deck 里歌名下方，
///                    只去掉中间方形封面。取不到封面时整层为空，自动回退取色背景。
enum PlayerPageTheme: String, CaseIterable, Identifiable {
    case classic
    case artistPhoto
    case immersiveCover
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "经典封面"
        case .artistPhoto: return "歌手写真"
        case .immersiveCover: return "沉浸式封面"
        }
    }
    /// 🔴 2026-11-10「我的播放器」卡片面板用的短名称（酷狗同款），以及卡片展示顺序。
    ///    只改卡片文案，不改 rawValue / AppStorage 的持久化值，老用户的选择不会丢。
    var cardTitle: String {
        switch self {
        case .immersiveCover: return "沉浸封面"
        case .classic: return "方形封面"
        case .artistPhoto: return "歌手写真"
        }
    }
    static let cardOrder: [PlayerPageTheme] = [.immersiveCover, .classic, .artistPhoto]
}

struct PlayerView: View {
    @EnvironmentObject private var store: PlayerStore
    /// 🔴 v2.9.3：订阅下载管理器，让动作行的「下载」按钮实时反映
    /// 当前歌曲的下载状态（未下载 / 下载中 / 已下载）。
    @ObservedObject private var downloads = DownloadManager.shared
    /// 🔴 v2.9.26：订阅音效设置，使动作行「OFF/ON」角标随预设切换实时刷新
    /// （PlayerActionIcon 内部读 SoundEffectSetting.shared，但只有订阅方重渲染才会反映）。
    @ObservedObject private var soundEffectSetting = SoundEffectSetting.shared
    /// 🔴 刻意用 `let` 不用 @ObservedObject（v2.5.35 关键修复）：
    /// playback.currentTime 播放时 4fps 变化，若 PlayerView 订阅它，整棵播放页树
    /// （含横屏全部按钮/进度/歌词）每秒被重建 4 次 —— SwiftUI 在持续 re-diff 期间
    /// 会丢触摸事件，实测表现为横屏返回按钮「要点几下才有反应」、暂停后再按播放没反应。
    /// 现在这里只是快照读取（不订阅、不触发重建），真正需要实时进度的小块 UI
    /// （进度条/歌词条）拆成独立子视图自行订阅 playback，高频刷新被限制在局部。
    let playback: PlaybackProgress
    /// 同上：歌词高亮 currentIndex 的订阅也收归子视图（LyricPill/LandscapeLyricsBlock），
    /// PlayerView 本体只保留切歌/播放暂停等低频刷新。
    let lyricState: LyricState
    @Binding var isExpanded: Bool

    @State private var showToast: String?
    @State private var isLyricsPage = false
    /// 横屏播放器：跟踪当前是否处于横屏（由方向锁权威驱动）
    @State private var isLandscape = false
    /// 横屏浮层显隐（关闭按钮 + 底部横条）：默认隐藏，点击屏幕切换
    @State private var landscapeChromeVisible = false
    /// 🔴 v2.5.47：横屏浮层自动隐藏的定时任务（4 秒无操作淡出）
    @State private var chromeHideTask: Task<Void, Never>?
    /// 音质切换弹层
    /// 「更多」弹层：音质档位 / 完整歌词 / 歌词翻译
    @State private var showMoreMenu = false
    /// 🔴 v2.5.45：动作行「音质」按钮专用弹层（原「评论」位置改为音质）
    @State private var showQualityMenu = false
    /// 🔴 动作行「音效」按钮专用面板（三频段音效预设）
    @State private var showSoundEffectPanel = false
    /// 🔴 v2.5.44：横屏播放器内嵌的「播放队列」面板（不再单独弹一页 sheet）
    @State private var showLandscapeQueue = false
    /// 分享弹层内容（nil = 不弹）
    @State private var shareItems: [Any]?
    @State private var dominantColor: Color = .white
    /// 🔴 播放页主题：T 恤按钮切换（经典封面 / 歌手写真 / 沉浸式封面），选择持久化。
    @AppStorage("aurora.playerPageTheme") private var playerPageTheme: PlayerPageTheme = .classic
    @State private var showThemePicker = false

    /// 参数顺序必须与属性声明顺序一致：playback / lyricState 在 isExpanded 之前。
    init(playback: PlaybackProgress, lyricState: LyricState, isExpanded: Binding<Bool>) {
        self.playback = playback
        self.lyricState = lyricState
        self._isExpanded = isExpanded
    }

    /// key window bounds = 真实可见屏幕尺寸（几何权威）。
    /// 🔴 不再读任何 window 的 bounds：设备上的第三方注入悬浮窗（如网速悬浮球）
    /// 会创建自己的 UIWindow 且可能成为 key window，其 bounds 不是屏幕尺寸
    /// （实测读到 ~427pt 宽的脏值 → 歌词页控制条整体偏移、进度条贴穿屏幕）。
    /// 改用 UIWindowScene.screen.bounds —— scene 级物理屏幕尺寸，不受任何注入窗口影响。
    /// （系统界面已永不旋转，屏幕尺寸恒定，无需担心旋转瞬间的滞后问题。）
    fileprivate static func interfaceSize(fallback: CGSize) -> CGSize {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            let screen = ws.screen.bounds.size
            let sMax = max(screen.width, screen.height)
            let sMin = min(screen.width, screen.height)
            // 🔴 取【全屏窗口】的实时 bounds：窗口随旋转实时变化，比 UIScreen.bounds / geo.size 可靠——
            // 强制旋转后 screen.bounds 与 GeometryReader 都可能滞留旧方向（竖屏），导致横屏播放器
            // 按竖屏宽度布局 → 封面居左、右侧大片空白（用户实测 v2.5.29）。
            // 用 max/min 与屏幕最大/最小边比对 → 不管屏幕当前报横报竖都能认出全屏窗口（免疫方向滞后）；
            // 第三方注入的小悬浮窗边太小，匹配不上，天然被排除。优先 key 的全屏窗口（= 当前播放窗口）。
            let fullScreen = ws.windows.filter { w in
                let b = w.bounds.size
                return abs(max(b.width, b.height) - sMax) < 1 && abs(min(b.width, b.height) - sMin) < 1
            }
            if let win = fullScreen.first(where: { $0.isKeyWindow }) ?? fullScreen.first {
                let s = win.bounds.size
                if s.width > 0, s.height > 0 { return s }
            }
            if screen.width > 0, screen.height > 0 { return screen }
        }
        return fallback
    }

    /// 竖屏语义的顶/底安全区（top=刘海侧，bottom=home indicator 侧）。
    /// 🔴 只认"尺寸=物理屏幕"的主窗口：第三方注入的悬浮窗可能成为 key window，
    /// 读它的 safeAreaInsets 会得到垃圾值。
    fileprivate static var safeAreaInsets: (top: CGFloat, bottom: CGFloat) {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            let screen = ws.screen.bounds.size
            let mainWindows = ws.windows.filter {
                abs($0.bounds.width - screen.width) < 1 && abs($0.bounds.height - screen.height) < 1
            }
            guard let w = mainWindows.first(where: { $0.isKeyWindow }) ?? mainWindows.first else { continue }
            let top = w.safeAreaInsets.top > 0 ? w.safeAreaInsets.top : 44
            let bottom = w.safeAreaInsets.bottom >= 20 ? w.safeAreaInsets.bottom : 34
            return (top, bottom)
        }
        return (44, 34)
    }

    var body: some View {
        // 🔴 用 GeometryReader 实测"容器真实尺寸"，不再用 UIScreen.main.bounds：
        // 强制横竖屏旋转的瞬间 UIScreen 是滞后的（可能还停在旧方向），按它布局
        // 内容会被裁出屏幕（"横屏/歌词页挤出屏幕"的根因）。geo.size 永远=真实可见尺寸，
        // 旋转完成时 GeometryReader 也会自动用新尺寸重排，无需靠方向通知猜。
        GeometryReader { geo in
            let size = Self.interfaceSize(fallback: geo.size)
            let screen = CGRect(origin: .zero, size: size)
            // 尺寸用 geo.size（真实容器，防裁切）；安全区顶/底用 key window（geo.safeAreaInsets
            // 在 .ignoresSafeArea() 下是 0，会让顶栏贴到状态栏 —— 用户截图实测）。
            let insets = Self.safeAreaInsets
            let win = (size: size, safeTop: insets.top, safeBottom: insets.bottom)
            let contentHeight = size.height - win.safeTop - win.safeBottom

            ZStack {
                // 🔴 歌词页优先级最高：打开歌词页时【只】显示歌词页，绝不再叠横屏播放器。
                // 旧结构是 `if isLandscape { landscapeBody } ... if isLyricsPage { LyricsPageView }` 两个并列条件，
                // 从横屏进歌词页时 presentPortraitForLyrics() 只改 mask+旋转、不会把 isLandscapePlayer 置回 false，
                // 于是 isLandscape 仍为 true → 横屏播放器和竖屏歌词页同时渲染、左右错乱拼接（实测截图）。
                // 改成 else-if 链：isLyricsPage 一开，横屏播放器整棵移出视图树，从根上消除拼接。
                if isLyricsPage {
                    // 🔴 2026-11-10：沉浸式封面主题走酷狗同款歌词页（顶栏 ∨、歌名居中带标签、
                    //    竖屏播放器同款动作行、进度条时间在下、缩小后的控件行）；
                    //    经典封面 / 歌手写真主题仍用原 LyricsPageView，一个像素都不动。
                    if playerPageTheme == .immersiveCover {
                        KugouLyricsPage(isShown: $isLyricsPage,
                                        onEnterLandscape: enterLandscapeFromLyrics)
                            .environmentObject(store)
                            .transition(.opacity)
                            .zIndex(10)
                    } else {
                        LyricsPageView(isShown: $isLyricsPage,
                                       onEnterLandscape: enterLandscapeFromLyrics)
                            .environmentObject(store)
                            .transition(.opacity)
                            .zIndex(10)
                    }
                } else if isLandscape {
                    // 横屏播放器：右上角按钮强制旋转后接管（唱片在左、信息在右）
                    landscapeBody()
                } else {
                    // 取色渐变始终垫底：写真主题取不到图时自动回退成经典背景。
                    immersiveBackground.ignoresSafeArea()
                    // 🔴 2026-11-09 修复「写真主题下动作行/播放按钮被挤没」：
                    //    ArtistPhotoBackdrop 内部的 Image.resizable().scaledToFill() 没有精确
                    //    frame，会以写真原图像素尺寸（约 1442pt 高）参与 ZStack 布局；
                    //    ZStack 以最大子视图为对齐基准 → classicBody 被垂直居中下推
                    //    ≈(1442-812)/2 = 315pt（与截图实测一致），底部歌词/动作行/
                    //    进度/控件整块被裁出屏幕。
                    //    🔴 照抄歌词页 v2.6.8 已验证的修法（见 LyricsPage 背景层注释）：
                    //    **背景层锁死为屏幕尺寸 + clipped**，写真只在框内绘制、不再撑大 ZStack。
                    //    层级 / 动画 / 主题切换全部保持原样，不改视图结构。
                    //    🔴 不加第二层 .ignoresSafeArea：外层 GeometryReader 已经忽略安全区，
                    //    再叠一层会把内容下推一个安全区（历史白顶坑）。
                    if playerPageTheme == .artistPhoto {
                        ArtistPhotoBackdrop(artist: store.current?.artist ?? "",
                                            title: store.current?.title ?? "",
                                            hash: store.current?.kugouHash ?? "")
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    } else if playerPageTheme == .immersiveCover {
                        // 🔴 与写真层同一套红线：背景层锁死屏幕尺寸 + clipped + 不吃点击，
                        //    否则原图像素尺寸会撑大 ZStack，把动作行/播放控件挤没。
                        // 🔴 主题只换背景：歌词仍由 classicDeck 放在歌名下方，不额外做浮层。
                        ImmersiveCoverBackdrop(artwork: store.artwork, size: size)
                            .transition(.opacity)
                    }
                    classicBody(in: contentHeight, win: win, screen: screen)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: playerPageTheme)
            .frame(width: size.width, height: size.height)
            // 🔴 仅竖屏播放页允许「下滑关闭整个播放器」；歌词页 / 横屏播放器改用各自的
            // 左上角返回按钮（用户要求移除下滑关闭）。否则下滑手势会和歌词页按钮 / 横屏
            // 返回键抢手势，且歌词页下滑会把整页播放器一起 dismiss。
            // 🔴 主题卡片面板打开时关掉下滑关闭：否则横滑卡片若带一点纵向位移，
            //    会和播放页的下滑 dismiss 手势打架（面板关掉、播放器也一起退）。
            .gesture((!isLyricsPage && !isLandscape && !showThemePicker) ? dragGesture : nil)
            .overlay(alignment: .bottom) { toastLayer }
            // 🔴 进入/退出歌词页时接管方向：
            // 进歌词页 → 临时强制竖屏；退歌词页 → 延迟 0.4s 恢复（避免动画打架）。
            .onChange(of: isLyricsPage) { presented in
                if presented {
                    OrientationLock.shared.presentPortraitForLyrics()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        OrientationLock.shared.restoreOrientationAfterLyrics()
                    }
                }
            }
        }
        .ignoresSafeArea()
        // 🔴 isLandscape 由方向锁权威驱动（enterLandscape/exitLandscape 同步设置）
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            isLandscape = OrientationLock.shared.isLandscapePlayer
        }
        .onAppear {
            isLandscape = OrientationLock.shared.isLandscapePlayer
            // 🔴 v2.8.3：常亮统一走 IdleTimerKeeper（多原因登记），不再直接改全局 bool
            IdleTimerKeeper.shared.set("player-landscape", isLandscape)
        }
        // 🔴 横屏播放器时隐藏系统状态栏（沉浸播放）；退出横屏自动恢复。
        // 🔴 加 !isLyricsPage：从横屏进歌词页时 isLandscapePlayer 不会置回 false，isLandscape 仍为 true，
        // 若不排除会把竖屏歌词页的状态栏也误藏。歌词页自己管理 safeTop。
        .modifier(LandscapeStatusBarHider(hidden: isLandscape && !isLyricsPage))
        // 🔴 关闭播放页时恢复竖屏 + 恢复自动熄屏（避免退出后整 App 卡横屏/永远不熄屏）
        .onDisappear {
            OrientationLock.shared.resetToPortrait()
            // 🔴 v2.8.3：只撤销自己的常亮原因，不再一票否决其它模块（下载/歌词页）的常亮
            IdleTimerKeeper.shared.set("player-landscape", false)
        }
        // 🔴 播放列表 sheet：必须挂在播放页自己身上。此前只挂在 RootView 迷你条上，
        // 它在播放页 fullScreenCover 之下 —— 播放页打开时 sheet 弹不出来（点了没反应）。
        .queueSheet()
        // 分享弹层（顶栏右上角分享按钮）
        .sheet(isPresented: Binding(get: { shareItems != nil },
                                    set: { presented in if !presented { shareItems = nil } })) {
            ShareSheet(items: shareItems ?? [])
        }
        // 🔴 2026-11-10：主题选择从系统 confirmationDialog 文字列表改成酷狗同款
        //    「我的播放器」横向卡片预览面板。用自定义 overlay 而不是 sheet：
        //    ① iOS 15 链式多个 .sheet(isPresented:) 只有最后一个生效（项目既有红线）；
        //    ② 半屏白色圆角面板 + 半透明遮罩要能盖住播放页又不切走整页。
        //    🔴 点卡片只切主题、不关面板 —— 选中卡片当场变蓝框，用户能立刻看到结果。
        .overlay(alignment: .bottom) {
            if showThemePicker {
                PlayerThemePickerPanel(
                    current: playerPageTheme,
                    onSelect: { picked in
                        guard picked != playerPageTheme else { return }
                        playerPageTheme = picked
                        show("已切换到\(picked.title)")
                    },
                    onMore: { show("更多皮肤敬请期待") },
                    onClose: { showThemePicker = false }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: showThemePicker)
    }

    // MARK: - 经典封面（参考 Beans ReferencePlaybackView · 紧凑版）

    @State private var classicCoverStart: Date = Date()
    @State private var classicCoverAngle: Double = 0
    @State private var classicCoverPausedAngle: Double = 0
    @State private var classicCoverOffset: CGSize = .zero
    @State private var classicSwipeOffset: CGFloat = 0
    // 🔴 classicFlowPhase 已随 classicProgressBlock 拆到独立子视图 ClassicProgressBlock
    //（高频进度刷新不再牵动 PlayerView 本体，见 playback 属性注释）。

    // MARK: classicBody — Header + Cover(弹性) + Deck(内容自适应) + Controls
    // header 固定顶 / 封面弹性填充 / deck 内容自适应（不再用固定高度硬裁歌词）
    private func classicBody(in contentHeight: CGFloat,
                             win: (size: CGSize, safeTop: CGFloat, safeBottom: CGFloat),
                             screen: CGRect) -> some View {
        let headerH: CGFloat = 56

        return VStack(spacing: 0) {
            classicHeaderBar
                .frame(height: headerH)

            classicCoverArea          // 弹性：GeometryReader 吃掉剩余高度

            classicDeck               // 内容自适应：歌词+动作行+进度+控件，绝不裁切
        }
        .frame(width: screen.width, height: contentHeight, alignment: .top)
        // 🔴 v2.5.41：用户要求顶栏往上移一点（原来紧贴状态栏下沿，视觉上偏低）
        .padding(.top, max(win.safeTop - 12, 6))
        .frame(width: screen.width, height: screen.height, alignment: .top)  // 铺满全屏、顶对齐
        .clipped()
    }

    /// 🔴 v2.5.39 版式对齐参考图：顶栏只留「左下箭头（收起）」+「右分享」两个按钮，
    /// 中间不再堆歌名（歌名已挪到封面下方的大标题区）；横屏入口改到「更多」弹层里。
    private var classicHeaderBar: some View {
        HStack(alignment: .center, spacing: 8) {
            // 🔴 v2.5.42：用户要求「向下箭头」改「向左箭头」（返回语义）
            Button { animateOut() } label: {
                // 🔴 用户要求：只改线条粗细（改细），不改图标与大小 —— 还原 SF Symbol chevron.left，仅降字重让线条更细。
                Image(systemName: "chevron.left")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // 🔴 2026-11-08：横屏按钮前面加「主题更换」（T 恤，Lucide shirt）。
            // 🔴 现在正式可用：点开在「经典封面 / 歌手写真 / 沉浸式封面」之间切换，选择会记住。
            Button { showThemePicker = true } label: {
                LucideIcon(icon: .shirt, size: 22, color: .white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            .buttonStyle(.plain)

            // 🔴 v2.5.42：右上角从「分享」改回「横屏」按钮（分享挪进「更多」菜单）
            Button { toggleLandscape() } label: {
                LandscapeToggleIcon()
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 44)
        .padding(.horizontal, 10)
    }

    /// 分享当前歌曲：优先酷狗歌曲页链接，没有 hash 时退回「歌名 - 歌手」文本。
    private func shareCurrentSong() {
        guard let song = store.current else { return }
        var items: [Any] = []
        if !song.kugouHash.isEmpty,
           let url = URL(string: "https://www.kugou.com/song/#\(song.kugouHash)") {
            items.append(url)
        } else if !song.kugouAlbumID.isEmpty,
                  let url = URL(string: "https://www.kugou.com/album/\(song.kugouAlbumID).html") {
            items.append(url)
        } else {
            items.append("\(song.title) - \(song.artist)")
        }
        if let artwork = store.artwork { items.append(artwork) }
        shareItems = items
        Haptics.light()
    }

    /// 封面下方的信息区（对齐参考图）：大标题 → 歌手 + 音质/伴唱等徽标，全部左对齐。
    private var classicTitleBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(store.current?.title ?? "未在播放")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

            // 歌手 + 徽标
            // 🔴 v2.5.44：用户要求 —— 移除黄色「极高音质」标签、移除「专辑」标签、加入「VIP」标签。
            // 现在歌手名后面只保留两个：VIP（金色胶囊）+ 音质（白色半透明胶囊）。
            HStack(spacing: 6) {
                Text(store.current?.artist ?? "未知歌手")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                vipPill
                // 🔴 3.0.0：已下载的歌曲在歌手名后面补一个「本地」标签，
                //    与 VIP / 音质胶囊同一套白色半透明视觉。
                if let current = store.current,
                   current.source == .local || downloads.item(for: current)?.isDone == true {
                    LocalTag(textColor: .white.opacity(0.85))
                }
                // 🔴 v2.9.16：音质胶囊改成**可点击**（点击换音质），
                // 音质入口从动作行挪到这里。档位名由 QualityPill 自己订阅 SourceStore。
                QualityPill(statusText: qualityStatusText) { showQualityMenu = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 封面区：专辑封面方图（弹性填充，歌词已移到底部 deck）

    // MARK: 封面区：专辑封面方图（点进歌词页）+ 左右滑切歌；歌词已移到底部 deck
    private var classicCoverArea: some View {
        // 🔴 用 GeometryReader 实测剩余空间，封面随容器自适应（deck 内容高度变化也不会互相挤压/裁切）。
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            // 🔴 v2.5.39 参考图：封面是主视觉，占可用高度 90%、屏宽 86%（原 66%/82% 偏小）。
            let side = max(150, min(h * 0.90, w * 0.86))

            VStack(spacing: 0) {
                // 🔴 2026-11-09：歌手写真主题下移除中间的方形专辑封面 —— 写真本身就是主视觉。
                //    保留「同尺寸透明占位」：header / deck 的弹性几何、deck 左右内缩、
                //    左右滑切歌的手势命中区全部原样不动（不重算布局 = 不碰安全区红线）。
                //    经典封面主题仍显示原封面；歌词页入口由动作行的「歌词」按钮提供。
                classicCoverVisual(side: side)
                    .offset(x: classicSwipeOffset)
                    .opacity(CGFloat(1) - min(abs(classicSwipeOffset) / 260, 0.35))
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: classicSwipeOffset)
                    .padding(.top, 0)    // 🔴 v2.5.41：封面再上移（原 10pt 呼吸去掉），下方留白由 Spacer 吸收
                    .gesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            classicCoverOffset = value.translation
                            if abs(value.translation.width) > abs(value.translation.height) {
                                classicSwipeOffset = value.translation.width
                            }
                        }
                        .onEnded { value in
                            classicCoverOffset = .zero
                            if abs(value.translation.width) > 120
                                && abs(value.translation.width) > abs(value.translation.height) {
                                Haptics.soft()
                                if value.translation.width < 0 { store.step(1) } else { store.step(-1) }
                            }
                            classicSwipeOffset = 0
                        }
                )

                // 🔴 歌词已移到经典底部 deck 的动作行上方（用户要求"改在动作行上方显示"）
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: store.isPlaying) { _ in classicUpdateCoverSpin() }
        .onChange(of: store.currentIndex) { _ in classicUpdateCoverSpin(); extractDominantColor() }
        .onAppear { classicUpdateCoverSpin(); extractDominantColor() }
        .onChange(of: store.artwork) { _ in extractDominantColor() }
    }

    /// 封面区视觉主体：只有经典主题画方形专辑封面；写真 / 沉浸式封面主题不画
    /// （铺满的背景层本身就是主视觉）。
    /// 🔴 非经典主题用同尺寸透明占位而不是直接把整个封面区删掉，避免 VStack 弹性高度
    ///    重新分配后 deck 上移、以及左右滑切歌手势丢失。
    @ViewBuilder
    private func classicCoverVisual(side: CGFloat) -> some View {
        if playerPageTheme == .classic {
            classicCoverArt(side: side)
        } else {
            Color.clear
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
    }

    /// 专辑封面方图（圆角 + 描边 + 投影）：点一下进歌词页。
    /// 🔴 经典主题原本是「黑胶唱片中心嵌小圆图」，用户要求直接展示完整专辑封面。
    private func classicCoverArt(side: CGFloat) -> some View {
        Button { openLyricsPage() } label: {
            Group {
                if let artwork = store.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.3)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.26, weight: .light))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(width: side, height: side)
            // 🔴 v2.5.41：去掉原来那圈 1pt 白色描边（在浅色封面上就是一条显眼的"白边"），
            // 投影也收小，避免边缘出现发白的散射圈。
            .clipShape(RoundedRectangle(cornerRadius: side * 0.04, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    /// 动作行（参考图同款）：纯图标、无文字、整行均分 —— 喜欢 / 下载 / 评论 / 歌词 / ⋯
    private var classicActionRow: some View {
        // 🔴 v2.9.27：引用音效状态，使动作行 OFF/ON 角标随预设切换实时刷新
        _ = soundEffectSetting.current
        return HStack(spacing: 0) {
            // ① 喜欢 —— 🔴 v2.9.27：改用自绘 HeartGlyph（同一个 PlayerActionIcon 体系），
            // 线宽 = size/24*1.5、画布占满 24pt，与下载/音效图标**完全相同**的线条粗细与大小
            // （原来 SF Symbol 心形在 24pt 常规字重下描边偏细、字形偏小，和旁边的不一致）。
            Button {
                store.toggleFavorite()
                Haptics.light()
            } label: {
                PlayerActionIcon(
                    glyph: .favorite,
                    active: store.isLiked,
                    tint: store.isLiked ? AppStyle.like : .white,
                    size: 24
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                // 🔴 v2.9.30：心形已放大撑满画布（顶到 y≈2.5、底到 y≈21.5），
                // 与下载框（顶 y≈0.7）顶部基本齐平，仅需轻微上移 2pt 让视觉顶部对齐。
                .offset(y: -2)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            // ② 下载 / 下载中 / 已下载（状态图标）
            classicDownloadButton
            Spacer(minLength: 0)
            // 🔴 v2.9.16：音质按钮从动作行移除（用户要求）——
            // 音质入口改到「歌手名」后面的胶囊标签，点击即换音质。
            // ③·⑤ 音效（新增：点开音效预设面板）
            // 🔴 v2.9.27：显式传入 soundEffectOn（来自 PlayerView 订阅的 soundEffectSetting），
            // 保证切预设/开总开关后角标立刻 OFF↔ON，不依赖图标内部读单例的渲染时机。
            Button {
                showSoundEffectPanel = true
                Haptics.light()
            } label: {
                PlayerActionIcon(
                    glyph: .soundEffect,
                    size: 24,
                    soundEffectOn: soundEffectSetting.current != .off
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            // ④ 歌词页
            classicActionButton(glyph: .lyric) { openLyricsPage() }
            Spacer(minLength: 0)
            // ⑤ 更多（横屏 / 歌词翻译 / 歌词微调）
            classicActionButton(glyph: .more) { showMoreMenu = true }
        }
        .frame(maxWidth: .infinity)
        // 🔴 v2.7.5：原来这里是 confirmationDialog 弹出的系统菜单（用户反馈"音质列表没改到"，
        // 弹出来的还是老式 action sheet）。现在改成弹出整页的酷狗风格音质页。
        .sheet(isPresented: $showQualityMenu) {
            CompatNavigationStack {
                QualitySettingsView()
            }
        }
        // 🔴 v2.9.26：音效页改为全屏呈现（用户要求全屏显示，匹配蝰蛇音效参考页）
        .fullScreenCover(isPresented: $showSoundEffectPanel) {
            SoundEffectPanel()
        }
        .confirmationDialog("更多", isPresented: $showMoreMenu, titleVisibility: .visible) {
            Button("完整歌词") { openLyricsPage() }
            Button("分享歌曲") { shareCurrentSong() }
            Button(store.showTranslation ? "关闭歌词翻译" : "开启歌词翻译") {
                store.showTranslation.toggle()
                Haptics.light()
            }
            // 🔴 歌词时间微调：不同音源 LRC 时间戳可能整首偏早/偏晚，给用户一个校准旋钮
            Button("歌词延后 0.5 秒") {
                store.adjustLyricOffset(by: 0.5)
                show("歌词已延后 0.5 秒")
            }
            Button("歌词提前 0.5 秒") {
                store.adjustLyricOffset(by: -0.5)
                show("歌词已提前 0.5 秒")
            }
            Button("歌词对齐重置") {
                store.resetLyricOffset()
                show("歌词对齐已重置")
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 下载动作按钮：根据当前歌曲的下载状态切换图标。
    /// 未下载 → 下载箭头（点一下开始下载）；
    /// 下载中 → 下载箭头 + 外圈细环进度（禁用，提示「正在下载…」）；
    /// 已下载 → 下载托盘 + 对勾（点一下提示「已经下载好了」）。
    ///
    /// 🔴 2026-11-08：下载中的**环形进度动画取消**，改成和「下载完成」同款底部胶囊提示
    /// （见 `activeDownloadText` / `toastLayer`）。按钮本身三个状态仍用同一套自绘线条图标，
    /// 下载中只把图标调暗一点，不再叠 Circle().trim 转圈。
    private var classicDownloadButton: some View {
        let item = store.current.flatMap { downloads.item(for: $0) }
        let state = item?.state
        let isActive = state?.isActive == true
        return Button {
            // 下载进度已由底部胶囊常驻显示，这里不再重复弹提示
            if state == .done { show("已经下载好了") }
            else if !isActive { download() }
        } label: {
            PlayerActionIcon(glyph: state == .done ? .downloaded : .download, size: 24)
                .opacity(isActive ? 0.55 : 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 动作按钮（参考图：只有图标没有文字，44×44 命中区）
    private func classicActionButton(glyph: PlayerActionGlyph,
                                     active: Bool = false,
                                     tint: Color = .white,
                                     action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.light() } label: {
            PlayerActionIcon(glyph: glyph, active: active, tint: tint, size: 24)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: CoverSpin（TimelineView 驱动旋转，这里只处理暂停时保存角度 + 播放时重置起点）

    private func classicUpdateCoverSpin() {
        if store.isPlaying {
            classicCoverStart = Date()
            classicCoverAngle = classicCoverPausedAngle
        } else {
            let elapsed = Date().timeIntervalSince(classicCoverStart)
            classicCoverPausedAngle += elapsed * (360.0 / 24.0)
            classicCoverAngle = classicCoverPausedAngle
        }
    }

    // MARK: 播放控件（Beans 直接搬：accent=dominantColor 渐变 + 发光 + 玻璃描边）

    /// 🔴 v2.5.45：专辑封面边长 side = min(剩余高*0.9, 屏宽*0.86)，封面水平居中，
    /// 因此左右留白 = (屏宽 - side)/2。让封面下方信息区（歌名/歌词/动作行/进度/控件）
    /// 用同样的左右 padding，做到与专辑左右边缘齐平。
    private var classicSideInset: CGFloat {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let side = min(h * 0.90, w * 0.86)
        return max(12, (w - side) / 2)
    }

    private var classicDeck: some View {
        VStack(spacing: 6) {
            // 🔴 参考图版式：封面下方先放「大标题 + 歌手 + 徽标」（左对齐）
            classicTitleBlock
                .padding(.bottom, 10)

            // 歌词两行：当前句（卡拉OK逐字）+ 下一句（暗）
            // 🔴 主题只换背景、不改版式：三个主题的歌词都留在 deck 里歌名下方。
            lyricPill()
                .padding(.bottom, 8)

            // 动作行：喜欢 / 下载 / 音质 / 歌词 / ⋯（纯图标均分）
            // 🔴 v2.5.47：动作行左右间距再收窄 10pt（比封面更宽一档）
            classicActionRow
                .padding(.horizontal, -10)
                .padding(.bottom, 10)

            // 进度行：已播时间 —— 细白进度条 —— 总时长
            // 🔴 2026-11-11 用户要求「沉浸封面主题：歌名 / 歌手 / 歌词 / 动作行 / 进度条往上移点」：
            //    只在进度条与控件行之间加留白（仅该主题）。deck 变高 → 弹性封面区缩小
            //    → deck 顶部（歌名起）整体上移；控件行仍在 deck 底部，位置不变。
            //    🔴 第二轮用户反馈「往下移点，调太多了」：32pt → 16pt，保留一半上移量。
            //    其它两个主题一行不动。
            classicProgressBlock
                .frame(height: 34)
                .padding(.bottom, playerPageTheme == .immersiveCover ? 16 : 0)

            // 🔴 v2.5.47：播放控制行左右间距与动作行一致（收窄 10pt）
            // 🔴 2026-11-10：沉浸式封面主题换成酷狗自绘控件行（实心三角上一首/下一首、
            //    半透明白圆盘播放键）；顺序/随机/循环与列表沿用经典主题的 SF Symbol。
            //    🔴 控件整体缩小（行高 68→54），与用户「播放控件改小点」的要求一致。
            //    经典封面 / 歌手写真主题保持原来的 classicDeckControls 不变。
            if playerPageTheme == .immersiveCover {
                KugouControlsRow()
                    .frame(height: 54)
                    .padding(.horizontal, -10)
            } else {
                classicDeckControls
                    .frame(height: 54)
                    .padding(.horizontal, -10)
            }
        }
        // 🔴 v2.5.45：左右间距与专辑封面齐平（之前固定 15，导致信息区比专辑更宽）
        .padding(.horizontal, classicSideInset)
        .padding(.top, 2)
        // 🔴 classicBody 已在内容高度里扣除底部安全区（deck 底部正好落在 home 指示条上方），
        // 这里只留少量呼吸，不再重复加 safeBottom（否则内容会被 fixed height 裁掉 → 歌词被"移除"）。
        .padding(.bottom, 8)
    }

    /// 流光进度条 —— 已拆到独立子视图 ClassicProgressBlock（见其注释）：
    /// 4fps 实时进度刷新被限制在这一小块，不再整树重建（横屏按钮吞点击的根因）。
    private var classicProgressBlock: some View {
        ClassicProgressBlock(playback: store.playback, dominantColor: dominantColor)
    }

    // MARK: 控件行：循环 ← 上一曲/播放/下一曲 → 队列
    // 🔴 v2.5.39：参考图版式 —— 全部改成"裸图标"（去掉玻璃圆底/渐变圆），
    // 白色实心图标 + 轻微投影，横向均分；播放键最大号。

    private var classicDeckControls: some View {
        ZStack {
            // 两侧：循环 / 队列
            HStack {
                classicModeButton
                Spacer(minLength: 0)
                classicQueueButton
            }

            // 中间三个：上一曲 / 播放暂停 / 下一曲
            HStack(spacing: 34) {
                classicPrevNextButton(icon: "backward.end.fill") { store.step(-1) }
                classicPlayPauseButton
                classicPrevNextButton(icon: "forward.end.fill") { store.step(1) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
    }

    /// 模式按钮（裸图标；激活时用主色高亮）
    private var classicModeButton: some View {
        let icon: String
        let active: Bool
        switch store.mode {
        case .shuffle: icon = "shuffle"; active = true
        case .single:  icon = "repeat.1"; active = true
        case .order:   icon = "repeat";   active = false
        }
        return Button { store.cycleMode(); Haptics.light() } label: {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(active ? dominantColor : .white.opacity(0.85))
                .frame(width: 44, height: 48)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    /// 队列按钮（裸图标）
    private var classicQueueButton: some View {
        Button { store.isQueuePresented.toggle(); Haptics.light() } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(store.isQueuePresented ? dominantColor : .white.opacity(0.85))
                .frame(width: 44, height: 48)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    /// 上一曲/下一曲（裸图标，白色实心）
    private func classicPrevNextButton(icon: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.light() } label: {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.32), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }

    /// 播放暂停（参考图：大白图标，无圆底）；加载/缓冲时转圈
    private var classicPlayPauseButton: some View {
        Button { store.toggle(); Haptics.soft() } label: {
            ZStack {
                // 🔴 同上：缓冲态只在"正在播放"时才画转圈
                if store.isLoading || (store.isBuffering && store.isPlaying) {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.white)
                        .offset(x: store.isPlaying ? 0 : 2)
                }
            }
            .frame(width: 64, height: 60)
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    /// 横屏布局专用：返回【全屏播放窗口】的横屏语义真实安全区（left/right=刘海/home 侧）。
    /// 🔴 用 max/min 与屏幕最大/最小边认全屏窗口（免疫 screen.bounds 方向滞后）；第三方小悬浮窗匹配不上，天然排除。
    private static var landscapeInsets: UIEdgeInsets {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            let screen = ws.screen.bounds.size
            let sMax = max(screen.width, screen.height)
            let sMin = min(screen.width, screen.height)
            let fullScreen = ws.windows.filter { w in
                let b = w.bounds.size
                return abs(max(b.width, b.height) - sMax) < 1 && abs(min(b.width, b.height) - sMin) < 1
            }
            if let w = fullScreen.first(where: { $0.isKeyWindow }) ?? fullScreen.first {
                return w.safeAreaInsets
            }
        }
        // 兜底（竖屏语义值近似横屏）：刘海侧 44、home 侧 34
        return UIEdgeInsets(top: 0, left: 44, bottom: 21, right: 0)
    }

    // MARK: - 背景（封面取色渐变 + 封面虚化，酷狗风格）

    private var immersiveBackground: some View {
        ZStack {
            // 底段用封面暗色调（不用近黑的 near），避免底部发黑
            LinearGradient(colors: [store.currentPalette.light,
                                    store.currentPalette.main,
                                    store.currentPalette.dark,
                                    store.currentPalette.dark],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            if let artwork = store.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 64)
                    .opacity(0.38)
                    .scaleEffect(1.25)
                    .clipped()
            }
            // 压暗层：底部不再压成近黑，而是叠封面同色系的暗色调，
            // 整体保持取色氛围（用户反馈纯黑部分不好看）
            LinearGradient(colors: [.black.opacity(0.16),
                                    .black.opacity(0.03),
                                    .clear,
                                    store.currentPalette.dark.opacity(0.45),
                                    store.currentPalette.dark.opacity(0.85)],
                           startPoint: .top,
                           endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: store.currentIndex)
        .animation(.easeInOut(duration: 0.5), value: store.currentPalette)
        // 注意：不在 blur 外层加 .drawingGroup() —— SwiftUI blur 在 iOS 16+ 走 Metal vImage GPU 管线，
        // 外层 .drawingGroup() 会强制分配一张 ~12MB 全屏 backing store 做二次光栅化，产生双倍显存峰值。
    }

    /// 横屏专用背景：纯取色渐变（**不带模糊封面图**）。
    /// 🔴 竖屏沉浸背景那层 0.38 模糊封面在横屏会让右列信息区对比度糊掉，故横屏单独用这一版。
    private var plainGradientBackground: some View {
        ZStack {
            LinearGradient(colors: [store.currentPalette.light,
                                    store.currentPalette.main,
                                    store.currentPalette.dark,
                                    store.currentPalette.dark],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.30),
                                    .black.opacity(0.06),
                                    .clear,
                                    .black.opacity(0.22),
                                    .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: store.currentIndex)
        .animation(.easeInOut(duration: 0.5), value: store.currentPalette)
    }

    /// 从专辑封面提取主色调（CIAreaAverage 滤镜）
    private func extractDominantColor() {
        guard let image = store.artwork else { dominantColor = .white; return }
        DispatchQueue.global(qos: .utility).async {
            guard let cg = image.cgImage,
                  let filter = CIFilter(name: "CIAreaAverage") else { return }
            let ci = CIImage(cgImage: cg)
            let extent = CGRect(x: 0, y: 0, width: ci.extent.width, height: ci.extent.height)
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
            guard let out = filter.outputImage else { return }
            let ctx = CIContext(options: nil)
            guard let cgOut = ctx.createCGImage(out, from: out.extent) else { return }
            // 读 1x1 像素
            let width = 1, height = 1, bpp = 4
            var pixel = [UInt8](repeating: 0, count: width * height * bpp)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            guard let ctx2 = CGContext(data: &pixel, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: bpp,
                                       space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx2.draw(cgOut, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let r = Double(pixel[0]) / 255
            let g = Double(pixel[1]) / 255
            let b = Double(pixel[2]) / 255
            let color = Color(red: r, green: g, blue: b).opacity(0.92)
            DispatchQueue.main.async { dominantColor = color }
        }
    }

    /// 普通版：圆角矩形封面（原始样式）
    private func roundedArtwork(width: CGFloat, height: CGFloat,
                                ratio: CGFloat = 0.65, maxCap: CGFloat = 300) -> some View {
        // 和黑胶一致：屏宽的 65%，最小 180 最大 300（横屏封面可传更大 ratio/maxCap 放大）
        let side = max(180, min(width * ratio, maxCap))
        return Group {
            if let artwork = store.artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
                    .frame(width: side, height: side).clipped()
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                }.frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    // MARK: - 横屏播放器（参考酷狗：右上角「横屏」按钮进入）

    /// 进入/退出横屏播放器的切换：由顶栏的「横屏」按钮调用。
    private func toggleLandscape() {
        if OrientationLock.shared.isLandscapePlayer {
            OrientationLock.shared.exitLandscape()
            isLandscape = false
            // 🔴 v2.5.44：进出横屏都收起内嵌队列面板
            showLandscapeQueue = false
            IdleTimerKeeper.shared.set("player-landscape", false)
        } else {
            OrientationLock.shared.enterLandscape()
            // 🔴 立即置 isLandscape = true（由方向锁权威驱动），不等方向通知 ——
            // 强制旋转瞬间通知是滞后的，等它会把横屏当成竖屏布局而裁切。
            isLandscape = true
            // 浮层（关闭按钮 + 底部横条）默认隐藏，点击屏幕显出
            landscapeChromeVisible = false
            // 横屏播放屏幕常亮
            IdleTimerKeeper.shared.set("player-landscape", true)
        }
    }

    /// 打开全屏歌词页。
    /// 🔴 从横屏播放器进入时不能立刻 present：播放页会按当下（横屏）
    /// 尺寸布局，随后强制转竖屏时内容仍按横宽渲染 → 歌词/控件两侧被裁出屏幕。
    /// 先强制转竖屏，等旋转稳定（0.45s）再弹歌词页，保证按竖屏尺寸布局。
    private func openLyricsPage() {
        if isLandscape {
            OrientationLock.shared.presentPortraitForLyrics()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeInOut(duration: 0.3)) { isLyricsPage = true }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { isLyricsPage = true }
        }
    }

    /// 🔴 v2.5.49：歌词页右上角「横屏」按钮 —— 关掉歌词页后进入横屏播放器。
    /// 时序：先退歌词页（触发 onChange 里的 0.4s restore），等方向稳定后再进横屏，
    /// 避免歌词页退场动画和强制旋转打架。若本来就是从横屏进的歌词页，
    /// 关闭歌词页时 restoreOrientationAfterLyrics 会自动恢复横屏，无需再转。
    private func enterLandscapeFromLyrics() {
        Haptics.light()
        let wasLandscape = isLandscape
        withAnimation(.easeInOut(duration: 0.3)) { isLyricsPage = false }
        guard !wasLandscape else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            toggleLandscape()
        }
    }

    /// 横屏布局（酷狗式，参考用户截图）。
    /// 🔴 播放页由 UIKit present() 呈现 + 系统强制旋转（见 RootView），
    /// 窗口尺寸/安全区就是横屏语义的真实值，直接布局即可。
    private func landscapeBody() -> some View {
        GeometryReader { geo in
            // 尺寸用 scene.screen（不受第三方注入悬浮窗污染）；geo 仅兜底
            // 🔴 用容器自身尺寸（geo.size）：横屏播放器此刻就在真实横屏窗口里，geo.size 就是横屏尺寸，
            // 比 screen.bounds/keyWindow 更可靠（后两者在强制旋转瞬间可能滞后）。
            let size = geo.size
            let insets = Self.landscapeInsets
            landscapeContent(size: size, insets: insets)
                .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
    }

    /// 横屏内容（酷狗式版式，由系统旋转到横屏后真实横屏窗口里布局）：
    /// 左侧大封面垂直居中；右侧 标题行 → 四行歌词 → 进度 →
    /// 单排控制键（收藏/上一首/播放/下一首/列表）。顶栏浮层只留关闭。
    private func landscapeContent(size: CGSize, insets: UIEdgeInsets) -> some View {
        ZStack {
            // 🔴 横屏背景用"无模糊"的纯取色渐变（plainGradientBackground）：
            // immersiveBackground 多一层 0.38 模糊封面图，实测会导致右列信息区
            // 显示异常/对比度糊掉。
            plainGradientBackground

            // 🔴 v2.6.4：底部动态波纹 —— 相位取自 AVPlayer 实时播放头，
            // 严格跟着音乐走，暂停即静止。垫在内容层下面，纯装饰不挡操作。
            LandscapeRippleView(isPlaying: store.isPlaying) { store.preciseTime }
                .frame(height: 130)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            HStack(spacing: 0) {
                // 左：大封面（垂直居中，约占屏宽 44%）
                // 🔴 主题精简后横屏固定用圆角封面：ratio 0.82、上限 340
                roundedArtwork(width: min(size.height - insets.top - insets.bottom - 24,
                                          size.width * 0.44),
                               height: min(size.height - insets.top - insets.bottom - 24,
                                           size.width * 0.44),
                               ratio: 0.82, maxCap: 340)
                    .frame(maxWidth: size.width * 0.46, maxHeight: .infinity)

                // 右：信息列
                VStack(alignment: .leading, spacing: 0) {
                    landscapeTitleRow
                    landscapeLyricsBlock
                        .padding(.top, 16)
                    Spacer(minLength: 10)
                    // 🔴 v2.6.4：底部横条（进度条 + 播放按钮）恢复【常显】——
                    // v2.6.3 跟顶栏一起自动隐藏，用户实测进度条和播放键找不到；
                    // 现在只有顶栏（返回/收藏/下载）会 4 秒自动隐藏，底部这一排一直可见。
                    progressSection()
                        .padding(.horizontal, 2)
                    landscapeControls()
                        .padding(.top, 20)   // 🔴 v2.5.49：播放按钮行与进度条的间距加大
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                // 🔴 layoutPriority(1)：HStack 分配宽度时右列优先，绝不被左侧封面槽挤没
                // （用户实测横屏右侧信息区整片空白，排查 size 无误后加这道保险）。
                .layoutPriority(1)
                .padding(.leading, 28)
                .padding(.trailing, insets.right + 28)   // 真实右安全区：避开 home indicator
                .padding(.top, insets.top + 50)          // 给浮层顶栏让位
                .padding(.bottom, max(insets.bottom, 14))
            }
            .padding(.leading, insets.left)              // 真实左安全区：避开刘海（XS 不再遮唱片）
        }
        // 🔴 v2.5.49：点击手势挂到整个 ZStack 并用 contentShape 铺满全屏 ——
        // 之前挂在背景渐变层上，点到 Spacer/封面等区域时手势收不到，
        // 表现就是"点了没反应、浮层藏不住"。按钮仍优先响应（Button 吞掉自己的点击）。
        .contentShape(Rectangle())
        .onTapGesture {
            // 🔴 v2.5.44：队列面板开着时，点空白先关面板（再点才切浮层）
            if showLandscapeQueue {
                withAnimation(.easeOut(duration: 0.22)) { showLandscapeQueue = false }
                scheduleChromeHide()
            } else if landscapeChromeVisible {
                // 🔴 v2.5.47：可见时点击立即隐藏
                chromeHideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) { landscapeChromeVisible = false }
            } else {
                // 隐藏时点击 → 显示并在 4 秒后自动隐藏
                scheduleChromeHide()
            }
        }
        .onAppear { scheduleChromeHide() }
        .onDisappear { chromeHideTask?.cancel() }
        // 🔴 v2.5.44：队列面板内嵌在右侧（不再是单独的 sheet 页）
        .overlay(alignment: .trailing) {
            if showLandscapeQueue {
                landscapeQueuePanel(size: size, insets: insets)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        // 🔴 顶栏浮层用 overlay(alignment:.top) 钉在顶部：
        // 🔴 v2.5.47：顶栏（返回/收藏/下载）随浮层自动隐藏 —— 4 秒无操作淡出，
        // 点空白处唤出。只保留一个 overlay（之前误留了两个叠加，白白多一层按钮）。
        .overlay(alignment: .top) {
            if landscapeChromeVisible {
                landscapeTopBar(insets: insets)
                    .zIndex(10)
                    .transition(.opacity)
            }
        }
    }

    /// 🔴 v2.5.47：横屏浮层自动隐藏调度 —— 显示 chrome 并在 4 秒无操作后淡出。
    /// 任何按钮点击不会触发背景 tap，因此 chrome 在操作期间保持可见；
    /// 点背景、进入横屏、关面板都会重新计时。
    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { landscapeChromeVisible = true }
        chromeHideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { landscapeChromeVisible = false }
        }
    }

    /// 🔴 v2.6.4/v2.6.7：横屏底部动态波纹 —— 参考酷狗横屏的声波条。
    ///
    /// 🔴 v2.6.7 修复"不会动"：
    /// 之前相位直接取 AVPlayer 播放头（preciseTime），一旦播放头推进慢、
    /// 或者取到的是静止值（暂停/缓冲），波形就几乎看不出在动。
    /// 现在改成两个时间源分工：
    /// · **相位**用 TimelineView 的墙钟 —— 每帧都推进，波形一定在动；
    /// · **振幅**用播放头算出的节拍包络 —— 波纹的起伏节奏仍然跟着音乐走，
    ///   音乐停了（暂停）TimelineView 直接 paused，整层冻住。
    /// 可见度也提上来了（透明度 + 亮色冠部），之前太淡基本看不见。
    private struct LandscapeRippleView: View {
        let isPlaying: Bool
        /// 每帧读取实时播放头（闭包形式：TimelineView 每次刷新都会重新调用）
        let timeProvider: () -> Double

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 40.0, paused: !isPlaying)) { timeline in
                Canvas { context, size in
                    // 墙钟相位：保证每帧都在动
                    let phase = timeline.date.timeIntervalSinceReferenceDate
                    // 音乐节拍：振幅跟着歌曲时间轴起伏
                    let beat = Self.beatEnergy(timeProvider())
                    let h = size.height
                    for layer in 0...2 {
                        let layerD = Double(layer)
                        let speed = 2.2 + layerD * 1.3
                        let ampBase = h * (0.26 - 0.05 * layerD)
                        let alpha = (0.30 - 0.07 * layerD) * (0.45 + 0.55 * beat)
                        guard alpha > 0.004 else { continue }
                        var path = Path()
                        var x: CGFloat = 0
                        var first = true
                        while x <= size.width + 6 {
                            let nx = Double(x) / 58.0
                            // 两列正弦叠加：波形有起伏变化，不像单一正弦那么机械
                            let w = sin(nx * 2.1 + phase * speed + layerD * 1.9) * 0.7
                                  + sin(nx * 4.6 - phase * speed * 0.7 + layerD * 0.8) * 0.3
                            let y = h - ampBase * (0.28 + 0.72 * beat) * (0.45 + 0.55 * w)
                            if first { path.move(to: CGPoint(x: x, y: y)); first = false }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                            x += 6
                        }
                        path.addLine(to: CGPoint(x: size.width, y: h))
                        path.addLine(to: CGPoint(x: 0, y: h))
                        path.closeSubpath()
                        context.fill(path, with: .color(.white.opacity(alpha)))
                    }
                }
            }
            .allowsHitTesting(false)
            .opacity(isPlaying ? 1 : 0)
            .animation(.easeInOut(duration: 0.6), value: isPlaying)
        }

        /// 拍点能量 0...1：144BPM 网格，每拍一个确定的强弱（哈希拍号得到），
        /// 拍内用指数衰减包络 —— 看起来像真的在跟着节拍跳。
        private static func beatEnergy(_ t: Double) -> Double {
            guard t.isFinite, t >= 0 else { return 0.4 }
            let bpm = 2.4                      // 每秒 2.4 拍 ≈ 144 BPM
            let beat = t * bpm
            let index = beat.rounded(.down)
            let frac = beat - index
            // 拍号哈希：同一拍内每帧结果一致（不会抖）
            var h = UInt64(bitPattern: Int64(index)) &* 6364136223846793005
            h ^= h >> 33
            let noise = Double((h >> 11) & 0xFFFF) / 65535.0
            let env = exp(-frac * 3.4)         // 攻击后快速衰减
            return 0.3 + 0.7 * (0.35 + 0.65 * noise) * env
        }
    }

    /// 横屏顶栏：只留 关闭（左）。
    /// 🔴 用户要求：不要圆圈底、图标改为向左的箭头（返回语义）。
    /// 🔴 退出横屏 → 回【竖屏播放页】，不再 dismiss 到主页（用户要求"退出不要退到主页"）。
    private func landscapeTopBar(insets: UIEdgeInsets) -> some View {
        HStack(spacing: 0) {
            Button {
                // 🔴 退出横屏 → 回竖屏播放页（不 dismiss 到主页）：恢复系统旋转 +
                // 置 isLandscape=false 让根布局切回竖屏主题；播放页本身不消失。
                OrientationLock.shared.exitLandscape()
                isLandscape = false
                // 离开横屏取消屏幕常亮
                IdleTimerKeeper.shared.set("player-landscape", false)
                // 🔴 v2.5.44：退出横屏时收起内嵌队列面板
                showLandscapeQueue = false
                Haptics.light()
            } label: {
                // 🔴 用户要求：只改线条粗细（改细），不改图标与大小 —— 还原 SF Symbol chevron.left，仅降字重让线条更细。
                Image(systemName: "chevron.left")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            }
            // 🔴 显式命中区 + contentShape：保证 56×56 全覆盖可点（不受图标自身 bounds 限制）
            .contentShape(Rectangle())
            Spacer(minLength: 0)
            // 🔴 v2.5.46：右侧与返回键同高度加「收藏」「下载」（用户要求）
            Button {
                store.toggleFavorite()
                Haptics.light()
            } label: {
                Image(systemName: store.isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 21))
                    .foregroundStyle(store.isLiked ? AppStyle.like : .white)
                    .frame(width: 52, height: 56)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .contentShape(Rectangle())
            }
            Button {
                download()
                Haptics.light()
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 56)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .frame(height: 56)
        // 🔴 v2.5.46：返回按钮整体上移（顶栏 padding 由 +10 减到 +2）
        .padding(.top, max(insets.top, 10) + 2)
        // 🔴 v2.5.45：返回按钮回到安全区内（insets.left + 2），避免压在屏幕左缘的系统
        // 边缘手势区里 —— 之前 inset-10 让按钮左半部分落在屏幕边缘手势带，
        // 部分点按会被系统边缘手势吞掉，表现就是"有时要按几下才按到"。同时整体仍比
        // 初版（insets.left+14）更靠左。命中区也由 44×44 放大到 56×56。
        .padding(.leading, insets.left + 2)
        .padding(.trailing, insets.right + 2)
    }

    /// 横屏标题：「歌名 - 歌手」单行（用户要求移除会员试听条）。
    private var landscapeTitleRow: some View {
        Text(landscapeTitleText)
            .font(.system(size: 23, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    /// 横屏标题文本：歌名 - 歌手（单行，酷狗横屏同款）。
    private var landscapeTitleText: String {
        let title = store.current?.title ?? "未播放"
        let artist = store.current?.artist ?? ""
        return artist.isEmpty ? title : "\(title) - \(artist)"
    }

    /// 横屏歌词块 —— 已拆到独立子视图 LandscapeLyricsBlock（见其注释）：
    /// 歌词高亮 + 进度的 4fps 订阅收进小块，横屏控制按钮不再被整树重建吞掉点击。
    private var landscapeLyricsBlock: some View {
        LandscapeLyricsBlock()
    }

    /// 横屏控制键单排（v2.5.44 改版）：
    /// 播放模式（顺序/单曲/随机） / 上一首 / 播放 / 下一首 / 列表
    /// - 🔴 收藏按钮改播放模式：用户要求「收藏按钮改顺序播放随机播放」；
    /// - 🔴 上一首 / 播放 / 下一首 全部去掉圆圈底，只留裸图标（用户要求"不要圆圈"）；
    /// - 🔴 列表改成横屏内直接展开队列面板，不再 .sheet 弹一页（用户要求 + 解决"按不到"）。
    private func landscapeControls() -> some View {
        HStack(spacing: 0) {
            // ① 播放模式（顺序播放 / 单曲循环 / 随机播放）
            Button { store.cycleMode(); Haptics.light() } label: {
                Image(systemName: store.mode.icon)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(store.mode == .order ? .white : dominantColor)
                    // 🔴 v2.7.3：边距继续改小 36→32（与竖屏一致，用户要求再收一点）
                    .frame(width: 32, height: 50)
                    .contentShape(Rectangle())
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }

            Spacer(minLength: 0)

            // ② 上一首（裸图标，无圆底）
            Button { store.step(-1); Haptics.light() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }

            Spacer(minLength: 0)

            // ③ 播放/暂停（裸图标，无圆底 —— 与竖屏同一套）
            classicPlayPauseButton

            Spacer(minLength: 0)

            // ④ 下一首（裸图标，无圆底）
            Button { store.step(1); Haptics.light() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }

            Spacer(minLength: 0)

            // ⑤ 列表：在横屏播放器内直接展开队列面板（不再弹 sheet）
            Button {
                withAnimation(.easeOut(duration: 0.22)) { showLandscapeQueue.toggle() }
                Haptics.light()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(showLandscapeQueue ? dominantColor : .white)
                    // 🔴 v2.7.3：边距继续改小 36→32（与竖屏一致，用户要求再收一点）
                    .frame(width: 32, height: 50)
                    .contentShape(Rectangle())
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
        }
        .buttonStyle(.plain)
    }

    /// 横屏内嵌播放队列面板（v2.5.44）：
    /// 🔴 用户要求「列表改成直接在横屏播放器显示，不要单独一个页显示」——
    /// 旧实现是 .sheet(isPresented:)，在横屏里 sheet 的点击区域会受 presentation detent /
    /// 手势区影响，实测"有时按不到"；改成右侧内嵌面板，按钮全部是普通 Button，
    /// 命中区 52×56 并显式 contentShape，稳定可点。
    private func landscapeQueuePanel(size: CGSize, insets: UIEdgeInsets) -> some View {
        LandscapeQueuePanel(width: min(size.width * 0.40, 380),
                            topInset: insets.top,
                            rightInset: insets.right,
                            accent: dominantColor) {
            withAnimation(.easeOut(duration: 0.22)) { showLandscapeQueue = false }
        }
    }

    /// 🔴 v2.5.44：VIP 徽标（紧跟歌手后面）。
    /// 顶掉原来的黄色「极高音质」音质徽标（qualityPill 已删除）：
    /// 用户要求「移除黄色极高音质标签、移除专辑标签、加入 VIP 标签」。
    private var vipPill: some View {
        // 🔴 用户要求：VIP 标签按歌曲真实 VIP 状态显示（tags 含 "VIP" 才出现）；
        // 文字改灰白、跟歌手名同色（白 0.85 + 淡白半透明底，小圆角、无图标）。
        Group {
            if store.current?.tags.contains("VIP") ?? false {
                VIPTag(textColor: .white.opacity(0.85))
            }
        }
    }

    /// 播放状态提示（缓冲中 / 解析中 / 无法播放）；正常播放时为空 ——
    /// 此时音质胶囊显示**当前选择的音质档位**（由 QualityPill 自己订阅 SourceStore，
    /// 改完音质立刻刷新，不用整棵播放页树重建）。
    private var qualityStatusText: String {
        if store.isBuffering { return "缓冲中" }
        if store.isLoading { return "解析中" }
        if store.playbackError != nil { return "无法播放" }
        return ""
    }

    /// 双行歌词 —— 已拆到独立子视图 LyricPill（见其注释）：
    /// 歌词高亮 + 进度的 4fps 订阅收进小块，不再整树重建。
    private func lyricPill() -> some View {
        LyricPill(onOpen: { openLyricsPage() })
    }

    /// 动作行按钮：图标统一走自绘图标集 PlayerActionIcon（线宽/画布/圆角一致）
    private func actionButton(glyph: PlayerActionGlyph,
                              label: String,
                              active: Bool = false,
                              tint: Color = .white,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.light()
        } label: {
            VStack(spacing: 5) {
                PlayerActionIcon(glyph: glyph, active: active, tint: tint, size: 22)
                    .frame(width: 34, height: 30)
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 进度

    /// 进度条 —— 已拆到独立子视图 PlayerProgressSection（见其注释）：
    /// 4fps 实时进度刷新被限制在这一小块，横屏控制按钮不再被整树重建吞掉点击。
    private func progressSection() -> some View {
        PlayerProgressSection(playback: store.playback, dominantColor: dominantColor)
    }

    // MARK: - 反馈

    @ViewBuilder
    private var toastLayer: some View {
        // 🔴 2026-11-08：下载中也走这条胶囊提示（原来在按钮上画环形进度）。
        //    优先级：手动提示 > 播放错误 > 下载进度常驻提示。
        if let message = showToast ?? store.playbackError ?? activeDownloadText {
            Text(message)
                .font(.system(size: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 40)
                .transition(.opacity)
                // 🔴 v2.5.42 关键修复（横屏播放键「点了没反应」的真凶之一）：
                // playbackError 一旦被置位就会一直显示这条胶囊提示（.bottom + 40pt），
                // 它默认是可命中测试的 —— 常驻时正好压在横屏底部控件行上，把
                // 播放/暂停的点击全吃掉。提示条纯展示，必须 allowsHitTesting(false)。
                .allowsHitTesting(false)
        }
    }

    /// 🔴 2026-11-08：下载中的进度改成与「下载完成」一样的胶囊文字提示，
    /// 跟着 `DownloadManager.items`（@Published）刷新；下载结束 / 失败自动消失。
    private var activeDownloadText: String? {
        guard let song = store.current,
              let item = downloads.item(for: song),
              item.state.isActive else { return nil }
        let pct = Int((item.progress * 100).rounded())
        return "正在下载 \(max(0, min(100, pct)))%"
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                if value.translation.height > 90 || value.predictedEndTranslation.height > 140 {
                    animateOut()
                }
            }
    }

    private func animateIn() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { isExpanded = true }
    }

    private func animateOut() {
        // 🔴 双保险关闭（横屏「退出点不到」的最终修复）：
        // 此前只回写 isExpanded 绑定，靠 RootView.onChange 间接调 PlayerPresenter.dismiss()
        // —— 实测在横屏 + 强制旋转组合下这条间接链没有生效（点退出毫无反应）。
        // 现在两路并发：
        // 1) isExpanded = false：维持 SwiftUI 状态一致（迷你条恢复显示等）；
        // 2) 直接调 PlayerPresenter.dismiss()：UIKit 层立刻销毁 presented VC，必然生效。
        // dismiss() 幂等（currentVC 已置空时是 no-op），两条路不会重复销毁。
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { isExpanded = false }
        PlayerPresenter.shared.dismiss()
    }

    private func show(_ message: String) {
        withAnimation { showToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { showToast = nil }
        }
    }

    // MARK: - 动作

    private func download() {
        guard let song = store.current, song.isRemote else { return show("本地音频不用下载") }
        if DownloadManager.shared.isDownloaded(song) {
            show("已经在下载列表里了")
            return
        }
        Task {
            do {
                _ = try await DownloadManager.shared.download(song)
                await MainActor.run { show("下载完成") }
            } catch {
                await MainActor.run { show(error.localizedDescription) }
            }
        }
    }
}

/// 进度条光点：跟着进度跑的脉冲白色光点 + 发光光晕
private struct GlowDot: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            // 外层光晕（脉冲放大淡出）
            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: 20, height: 20)
                .scaleEffect(pulse ? 1.4 : 0.7)
                .opacity(pulse ? 0 : 0.8)

            // 中层发光
            Circle()
                .fill(.white.opacity(0.6))
                .frame(width: 14, height: 14)
                .blur(radius: 3)

            // 核心白点
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// 横屏切换图标（v2.5.22 重新设计）：横放手机轮廓 + 环绕手机的顺时针旋转箭头。
/// 🔴 自绘组合而非用 `rectangle.landscape.rotate` —— 该 SF Symbol 在部分系统版本
/// 缺字不渲染，按钮变成一个"空圆圈"（用户截图实测）。Circle trim / 自绘路径 100% 可用。
private struct LandscapeToggleIcon: View {
    var body: some View {
        // 🔴 v2.9.18：用户连续两次反馈太大 —— 30→26→22pt，线宽按比例 1.9→1.65→1.4。
        LandscapeIconShape()
            .stroke(.white, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: 22, height: 22)
    }
}

/// 横屏按钮（参考图 ebd3「横屏」同款，1:1 量过像素）：
/// **竖屏手机（顶部一条粗短听筒条）+ 右下角横屏小屏（与手机共用右边和底边）
///  + 右上角「粗弧线 + V 形箭头尖（尖端朝左下）」**
/// 🔴 v2.9.14 修正：之前弧线末端只有一根回勾线、听筒是细线，
/// 参考图是**标准箭头（两条翼的 V）** + **粗短条**，现在按比例还原。
private struct LandscapeIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24.0
        func X(_ v: CGFloat) -> CGFloat { rect.minX + v * s }
        func Y(_ v: CGFloat) -> CGFloat { rect.minY + v * s }
        var p = Path()
        // 竖屏手机（高瘦圆角矩形）
        p.addRoundedRect(in: CGRect(x: X(1.0), y: Y(0.8), width: 11.6 * s, height: 21.6 * s),
                         cornerSize: CGSize(width: 2.6 * s, height: 2.6 * s))
        // 顶部听筒：一条**粗短横条**（比线宽更粗，用双倍线宽画短横线）
        p.move(to: CGPoint(x: X(5.0), y: Y(3.3)))
        p.addLine(to: CGPoint(x: X(8.6), y: Y(3.3)))
        // 横屏小屏（左边与手机右边共用、底边与手机底边齐平）
        p.addRoundedRect(in: CGRect(x: X(12.6), y: Y(11.2), width: 9.2 * s, height: 11.2 * s),
                         cornerSize: CGSize(width: 2.4 * s, height: 2.4 * s))
        // 右上角：粗弧线从左上弯到右下
        p.move(to: CGPoint(x: X(14.4), y: Y(1.4)))
        p.addCurve(to: CGPoint(x: X(21.0), y: Y(6.0)),
                   control1: CGPoint(x: X(17.6), y: Y(1.4)),
                   control2: CGPoint(x: X(21.0), y: Y(3.2)))
        // 弧末的 V 形箭头尖（两条翼，尖端朝左下）
        p.move(to: CGPoint(x: X(19.9), y: Y(5.1)))
        p.addLine(to: CGPoint(x: X(21.0), y: Y(6.0)))
        p.addLine(to: CGPoint(x: X(22.1), y: Y(5.3)))
        return p
    }
}

/// 歌手名后的**音质胶囊**：显示当前选择的音质档位，点击可切换音质。
/// 🔴 v2.9.16：音质入口从动作行移到歌手名旁边（用户要求）。
/// 刻意做成**独立子视图**并自己订阅 SourceStore —— PlayerView 本体不订阅它，
/// 避免音源列表变化时整棵播放页树重建（与 playback/lyricState 的处理原则一致）。
private struct QualityPill: View {
    /// 播放状态提示（缓冲中/解析中/无法播放）；为空时显示当前音质档位
    var statusText: String = ""
    var onTap: () -> Void

    @ObservedObject private var sourceStore = SourceStore.shared

    private var title: String {
        statusText.isEmpty ? sourceStore.quality.title : statusText
    }

    var body: some View {
        Button {
            onTap()
            Haptics.light()
        } label: {
            // 🔴 用户要求：音质标签文字改灰白、跟歌手名同色（竖屏播放页深色封面上用白 0.85）。
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct PlayButton: View {
    @EnvironmentObject private var store: PlayerStore
    @State private var pulse = false

    var body: some View {
        Button {
            store.toggle()
            Haptics.soft()
        } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 52, height: 52)
                    .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
                    // 🔴 v2.7.0：圆圈**恒定可见**。
                    // 旧写法是 `.opacity(pulse ? 0 : 0.55)` —— 播放中 pulse=true
                    // 直接把圆圈透明度设成 0，整个圆圈消失（用户反馈"播放暂停按钮
                    // 圆圈按几下就消失不显示"）。现在只保留轻微的呼吸缩放。
                    .scaleEffect(pulse ? 1.06 : 1)
                    .opacity(0.55)
                    .animation(.easeInOut(duration: 0.25), value: pulse)

                // 🔴 暂停时绝不显示转圈：暂停后 isPlaybackLikelyToKeepUp 会转 false，
                // 旧写法会让播放键卡在 ProgressView（"按一下就卡住"）。
                if store.isLoading || (store.isBuffering && store.isPlaying) {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .offset(x: store.isPlaying ? 0 : 2)
                }
            }
            .frame(width: 80, height: 76)
            // 🔴 命中区显式声明：ZStack 里只有 52pt 的圆和图标是实心的，
            // 四周透明区域默认不吃点击 → 加大底框 + contentShape 让整块可点。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onChange(of: store.isPlaying) { playing in pulse = playing }
    }
}

/// 横屏内嵌播放队列面板（v2.5.44）。
/// 🔴 抽成独立子视图：面板内有 20+ 行的列表，若整块塞进 PlayerView 的函数里，
/// 类型检查开销大（本项目踩过 "unable to type-check" 的坑）；独立出去也让
/// 面板自身的刷新与播放页主体解耦。
private struct LandscapeQueuePanel: View {
    @EnvironmentObject private var store: PlayerStore
    var width: CGFloat
    var topInset: CGFloat
    var rightInset: CGFloat
    var accent: Color
    /// 关闭面板（由父视图把 showLandscapeQueue 置 false 并带动画）
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 2) { rows }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 24)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                // 🔴 v2.5.47：面板底色改为与歌曲沉浸背景同款取色渐变（不透明，
                // 不再用黑色 —— 用户要求"改跟歌曲一样的沉浸背景色不要透明"）
                .fill(LinearGradient(colors: [store.currentPalette.main,
                                              store.currentPalette.dark,
                                              store.currentPalette.dark],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.6))
        )
        .padding(.trailing, rightInset + 12)
        .padding(.vertical, 10)
    }

    /// 头部：标题 + 曲目数 + 播放模式 + 关闭
    private var header: some View {
        HStack(spacing: 10) {
            Text("播放队列")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
            Text("\(store.queue.count) 首")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Button { store.cycleMode(); Haptics.light() } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.mode.icon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.mode.title)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(store.mode == .order ? .white.opacity(0.85) : accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.14), in: Capsule())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button { Haptics.light(); dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset + 56)
        .padding(.bottom, 10)
    }

    /// 曲目行（点击切歌并自动收起面板）
    private var rows: some View {
        ForEach(Array(store.queue.enumerated()), id: \.element.id) { idx, song in
            Button {
                store.jump(to: idx)
                Haptics.light()
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: idx == store.currentIndex ? "waveform" : "music.note")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(idx == store.currentIndex ? accent : .white.opacity(0.45))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(idx == store.currentIndex ? accent : .white)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(idx == store.currentIndex
                            ? Color.white.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 全屏歌词页

/// 卡拉OK单行歌词：已唱部分纯白、未唱部分半透白，用横向渐变做前景色。
///
/// 🔴 为什么用 TimelineView 墙钟插值：
/// `PlaybackProgress.currentTime` 只有 2Hz（每 0.5s 一跳），直接拿它驱动渐变，
/// 逐字填充就会一跳一跳的 = 卡顿。这里在两次 currentTime 更新之间按墙钟时间线性
/// 插值出一个平滑的"当前秒"，交给 TimelineView(.animation) 每帧重绘 —— 达到 60fps
/// 顺滑，且每帧重算只发生在这一个极小的 Text 上，不会带着整个播放页整树重算。
/// 暂停时不插值（冻结），也顺带省电。
private struct KaraokeLine: View {
    let text: String
    let start: Double
    let end: Double
    let isPlaying: Bool
    /// 🔴 playback 必须声明在默认参数之前（第 5 位）：Swift 的合成成员初始化器会把
    /// "无默认值的参数"排在"有默认值的参数"前面，若 playback 落在 font/lineLimit/align/
    /// liveTime 这些默认值之后，调用时就会报 "argument 'font' must precede argument
    /// 'liveTime'"。这里把它放到 isPlaying 之后、所有默认值之前，调用顺序就对了。
    /// 🔴 用 let 而非 @ObservedObject（v2.5.38 关键修复）：liveTime 已直接读
    /// player.currentTime() 驱动逐字填充，playback 仅作 syncBase 兜底读取，
    /// 不再需要订阅。旧写法 @ObservedObject 会让 KaraokeLine 在播放时随
    /// playback.currentTime(4fps) 每秒重建 4 次 → 其 TimelineView 被反复销毁重建，
    /// 逐字填充卡顿（"歌词慢了"）+ 主线程被 4Hz 重建+30fps TimelineView 双重占用，
    /// 横屏播放/暂停按钮触摸被吞（"按一次就卡住"）。改为 let 后，KaraokeLine 只靠
    /// 自己的 TimelineView 更新，整棵歌词视图不再随 4fps 进度抖动。
    let playback: PlaybackProgress
    /// 字号/字重（播放页迷你条 16pt；歌词页当前句 26pt bold）。
    var font: Font = .system(size: 16, weight: .medium, design: .rounded)
    /// 行数限制：播放页迷你条 1 行；歌词页当前句允许换行传 nil。
    var lineLimit: Int? = 1
    /// 水平对齐：播放页/歌词页居中；横屏播放器左对齐。
    var align: Alignment = .center
    /// 🔴 精确播放头（AVPlayer 实时值）：注入后逐帧直读，填充与演唱严格同步，
    /// 根治「逐字跟不上」。未注入时退回 墙钟插值 兜底。
    var liveTime: (() -> Double)? = nil

    @State private var baseTime: Double = 0
    @State private var baseStamp: Date = Date()

    private var progress: Double {
        guard end > start else { return 1 }
        // 🔴 优先精确播放头：每帧直读 AVPlayer，暂停时播放头静止 → 填充自然冻结。
        let now: Double
        if let liveTime {
            now = liveTime()
        } else {
            now = isPlaying ? baseTime + Date().timeIntervalSince(baseStamp) : baseTime
        }
        return min(max((now - start) / (end - start), 0), 1)
    }

    private var line: some View {
        Text(text)
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: progress),
                        .init(color: .white.opacity(0.4), location: progress),
                        .init(color: .white.opacity(0.4), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .font(font)
            .lineLimit(lineLimit)
            .multilineTextAlignment(align.horizontal == .leading ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: align)
    }

    var body: some View {
        // 🔴 始终用 TimelineView，不在播放/暂停时切换视图结构。
        // 旧写法 `if isPlaying { TimelineView } else { line }` 在暂停瞬间会把 TimelineView
        // 换成静态 Text（视图类型/结构突变），实测导致横屏播放/暂停按钮点了卡住、命中抖动。
        // 现在暂停只是让 progress 冻结（见 progress：暂停用 baseTime），结构稳定、点击正常。
        // 🔴 minimumInterval 1/30：文字渐变填充 30fps 足够顺滑，渲染负载减半 ——
        // 高频重绘也是横屏按钮「要点几下」的帮凶，能省则省。
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in line }
            .onAppear { syncBase() }
            .onChange(of: start) { _ in syncBase() }   // 切到下一句时立即对齐基准（兜底路径用）
    }

    private func syncBase() {
        baseTime = playback.currentTime
        baseStamp = Date()
    }
}

/// 深色沉浸式全屏歌词，背景与播放页同款取色 + 专辑图模糊。
/// 词曲/编曲/制作人等简介信息独立为顶部折叠模块，滚动区只保留正文歌词。
struct LyricsPageView: View {
    @EnvironmentObject private var store: PlayerStore
    /// 歌词高亮独立订阅 —— store.currentLyricIndex 是转发计算属性不触发刷新。
    /// 这个视图没有注入链，直接从单例取同一个实例。
    @ObservedObject private var lyricState = PlayerStore.shared.lyricState
    @Binding var isShown: Bool
    /// 🔴 v2.5.49：右上角「横屏」按钮回调（由 PlayerView 注入，处理方向切换时序）。
    var onEnterLandscape: (() -> Void)? = nil
    /// 🔴 v2.6.2：歌词页歌手写真背景开关（设置页可关，默认开）
    @AppStorage("aurora.lyricsArtistPhoto") private var showArtistPhoto: Bool = true
    /// 🔴 v2.7.1：沉浸模式 —— 收起时进度条 + 播放控件 + **顶栏的返回/横屏按钮**
    /// 一起隐藏（用户要求），只留底部的展开按钮可以恢复。
    @State private var chromeHidden = false

    private var safeTop: CGFloat {
        // 🔴 复用 PlayerView.safeAreaInsets（过滤第三方注入窗口），不再直接读 keyWindow
        max(44, PlayerView.safeAreaInsets.top + 6)
    }

    private var safeBottom: CGFloat {
        max(8, PlayerView.safeAreaInsets.bottom)
    }

    var body: some View {
        // 🔴 用 GeometryReader 实测 cover 真实尺寸来约束布局：        // 之前用 UIScreen.main.bounds 钳制，但强制旋转瞬间 UIScreen 可能还停在横屏
        // (852 宽) 而窗口已是竖屏(393) → 内容被钳成 852 宽、两侧被裁出屏幕（实测）。
        // 改用容器自身尺寸（永远正确），任何方向竞态都不会再溢出裁切。
        GeometryReader { geo in
            // 🔴 用容器自身尺寸（geo.size）—— 歌词页是播放页内的覆盖层，它的容器就是播放页
            // 根 ZStack，尺寸永远等于真实窗口。之前用 interfaceSize(screen/keyWindow) 会在
            // 强制旋转/覆盖层场景拿到和真实容器对不上的尺寸 → 歌词被排到屏幕外变成空白（实测）。
            let sz = geo.size
        ZStack {
            // 沉浸式取色背景
            // 🔴 改为完全不透明：①渐变不再打折（原 0.96 会透出底下播放页）；
            // ②删掉模糊专辑图浮层 —— 它在歌词正后方形成一团"幽灵唱片"，
            // 用户误以为是播放页透出来（实测截图可见盘面轮廓）。底部再垫纯色。
            ZStack {
                // 🔴 v2.8.3：兜底背景换成固定的「蓝色耳机」海报图，不再用专辑取色渐变
                // （用户要求：写真取不到时也别显示取色背景）。
                // 写真取到时 ArtistPhotoBackdrop 铺在最上层把它盖住。
                Image("LyricsFallback")
                    .resizable()
                    .scaledToFill()
                    .frame(width: sz.width, height: sz.height)
                    .clipped()

                LinearGradient(colors: [.black.opacity(0.35),
                                        .black.opacity(0.18),
                                        .black.opacity(0.3),
                                        .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)

                // 🔴 v2.6.3：歌手写真背景移到最上层 —— v2.6.2 把它压在 0.35~0.55
                // 黑色渐变之下，加上自身遮罩，双层压暗后照片几乎不可见
                // （用户反馈"歌词页显示不出歌手写真"）。
                // 🔴 v2.6.7：写真不再模糊；🔴 v2.6.8：多张写真轮播。
                if showArtistPhoto {
                    ArtistPhotoBackdrop(artist: store.current?.artist ?? "",
                                        title: store.current?.title ?? "",
                                        // 🔴 v2.7.5：带上 hash，用它反查精确 singerid 取写真
                                        hash: store.current?.kugouHash ?? "")
                        .ignoresSafeArea()
                }
            }
            // 🔴 v2.6.8：背景层锁死为屏幕尺寸 + 裁剪。
            // 写真是 scaledToFill 的大图，一旦它的尺寸超过屏幕，
            // 父级 ZStack 会被撑大，歌词内容就跟着被顶出屏幕（用户实测"歌词页挤出屏幕"）。
            .frame(width: sz.width, height: sz.height)
            .clipped()
            .ignoresSafeArea()
            // 🔴 已移除下滑关闭手势：用户要求只用左上角返回按钮关闭歌词页（横屏同理），
            // 下滑手势会和按钮 / 进度条抢手势且易误触。关闭统一由左上角 chevron.left 按钮完成。

            VStack(spacing: 0) {
                // 顶栏：返回按钮清晰可见，标题文字保持低存在感
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
                    } label: {
                        // 🔴 v2.7.0：返回按钮去掉圆圈底（用户要求），只留箭头 + 阴影。
                        // 之前套了半透明黑圆，在亮色写真上像一个小黑点。
                        // 🔴 用户要求：只改线条粗细（改细），不改图标与大小 —— 还原 SF Symbol chevron.left，仅降字重让线条更细。
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                    // 🔴 v2.7.1：沉浸模式时顶栏按钮一起隐藏（保留占位，标题不跑位）
                    .opacity(chromeHidden ? 0 : 1)
                    .allowsHitTesting(!chromeHidden)

                    Spacer()

                    VStack(spacing: 3) {
                        Text(store.current?.title ?? "")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(store.current?.artist ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .opacity(0.62)   // 🔴 v2.6.7：只让标题文字低调，按钮保持清晰
                    .padding(.horizontal, 8)

                    Spacer()

                    // 🔴 v2.5.49：右上角改「横屏播放器」按钮（原翻译按钮，翻译入口保留在播放页「更多」菜单）
                    Button {
                        onEnterLandscape?()
                    } label: {
                        LandscapeToggleIcon()
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // 🔴 v2.7.1：沉浸模式时顶栏按钮一起隐藏
                    .opacity(chromeHidden ? 0 : 1)
                    .allowsHitTesting(!chromeHidden)
                }
                .foregroundStyle(.white)
                .padding(.top, safeTop)
                // 🔴 v2.6.7：不再给整个顶栏套 opacity(0.5) —— 那会把左上角
                // 返回按钮和右上角横屏按钮一起变得几乎看不见。
                // 改成只让中间的「歌名/歌手」文字保持低存在感。

                // 纯正文歌词滚动区（flex 占满剩余高度，底部留给控制条）
                // 🔴 显式宽度：超长歌词行会把 LazyVStack 的理想宽度撑到 570pt+，
                // 整个 VStack 跟着超宽（控制条同属一个 VStack → 进度条贴穿屏幕、
                // 上一首/下一首被挤出屏幕）。显式 frame 强制约束，不依赖提案链。
                BigLyricsView(lyrics: store.lyrics,
                              currentIndex: lyricState.currentIndex,
                              showsTranslation: store.showTranslation,
                              playback: PlayerStore.shared.playback,
                              isPlaying: store.isPlaying,
                              liveTime: { store.lyricDisplayTime })
                    .frame(width: sz.width - 52)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                // 底部播放控件条：进度 + 上一首/播放/下一首（固定高度，安全区内置，不挤出屏幕）
                LyricsBottomBar(chromeHidden: $chromeHidden)
                    .frame(width: sz.width - 52)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, safeBottom + 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: sz.width, height: sz.height)
        }
        .ignoresSafeArea()
        .clipped()
        // 🔴 v2.7.3：沉浸模式 —— 收起时隐藏系统状态栏（时间/信号/电量那一条）。
        // iOS 16+ 用 statusBarHidden(_:)，iOS 15 的旧 API 已弃用（用了会编译告警），
        // 所以 15 上不处理。
        .modifier(LyricsStatusBarHider(hidden: chromeHidden))
        // 🔴 v2.7.3：沉浸模式屏幕常亮 —— 看歌词时手机不熄屏。
        // 🔴 v2.8.3：改走 IdleTimerKeeper，且退出沉浸要**撤销**原因（原来无论进出都设 true），
        // 歌词页关闭时也要撤销，别把常亮永久留在全局。
        .onChange(of: chromeHidden) { hidden in
            IdleTimerKeeper.shared.set("lyrics-immersive", hidden)
            Log.info("歌词页", hidden ? "进入沉浸模式（隐藏状态栏 + 常亮）" : "退出沉浸模式")
        }
        .onDisappear {
            IdleTimerKeeper.shared.set("lyrics-immersive", false)
        }
        // 🔴 整页下滑关闭手势已移到背景层（.gesture）：highPriorityGesture 会把
        // 进度条的拖动手势整个吃掉（进度条拖不动的根因），不能再挂在这。
    }
}

/// 🔴 v2.7.3：歌词页沉浸模式 —— 隐藏系统状态栏。
/// iOS 16+ 用 statusBarHidden(_:)；iOS 15 的 statusBar(hidden:) 已弃用，
/// 用了会触发编译告警 → CI 的 warning-as-error 会挂，所以 15 上不处理。
private struct LyricsStatusBarHider: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.statusBarHidden(hidden)
        } else {
            content
        }
    }
}

/// 全屏歌词页底部播放控件条：进度条 + 上一首 / 播放 / 下一首。
/// 固定在歌词页底部，内置于安全区，永远不会被歌词滚动区挤出屏幕。
/// 横屏播放器时隐藏系统状态栏。
/// iOS 16+ 的 statusBarHidden(_:)；iOS 15 不处理（旧 statusBar(hidden:) 已弃用，
/// 直接调用会触发弃用警告 → CI 的 warning-as-error 会挂）。
private struct LandscapeStatusBarHider: ViewModifier {
    let hidden: Bool
    /// 🔴 v2.5.41：不再隐藏 home 横条 —— `persistentSystemOverlays(.hidden)` 会让系统
    /// 把底部区域（播放控件那一行）的**第一次点击吞掉**去恢复 home 指示条，
    /// 实测表现就是横屏「播放/暂停按一下没反应、要点几下」（用户反复反馈）。
    /// 播放控件的可靠性优先，home 横条改为系统默认（.automatic）。
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .statusBarHidden(hidden)
                .persistentSystemOverlays(.automatic)
        } else {
            content
        }
    }
}

private struct LyricsBottomBar: View {
    @EnvironmentObject private var store: PlayerStore
    /// 直接订阅同一个 PlaybackProgress 实例，保证进度条随播放实时刷新
    @ObservedObject private var playback = PlayerStore.shared.playback
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    private var displayTime: Double { isScrubbing ? scrubValue : playback.currentTime }

    /// 🔴 v2.7.1：沉浸模式开关（收起进度条 + 播放控件 + 顶栏按钮）
    @Binding var chromeHidden: Bool

    var body: some View {
        VStack(spacing: 10) {
            // 🔴 v2.7.0：进度条上方的「收起控件」按钮。
            // 🔴 v2.7.1：收起时顶栏的返回/横屏按钮也一起隐藏（沉浸看歌词），
            // 只留这个展开按钮可以恢复。
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { chromeHidden.toggle() }
                Haptics.light()
            } label: {
                Image(systemName: chromeHidden ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !chromeHidden {
            // 🔴 v2.7.2：进度条改成和【竖屏播放器】同一套版式 ——
            // 「已播时间 —— 细白进度条 —— 总时长」同一行，时间贴两侧
            // （之前歌词页是进度条一行、时间另起一行，跟播放页不一致）。
            HStack(spacing: 12) {
                Text(displayTime.clockString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(minWidth: 38, alignment: .leading)

                GeometryReader { geo in
                    let w = geo.size.width
                    let pf = max(0, min(1, playback.progress))
                    let bf = max(0, min(1, playback.bufferedFraction))
                    let px = pf * w
                    let trackH: CGFloat = 4
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.30)).frame(height: trackH)
                        Capsule().fill(.white.opacity(0.42)).frame(width: bf * w, height: trackH)
                        Capsule().fill(.white).frame(width: px, height: trackH)
                        // 🔴 v2.7.3：常显定位点（滑块）—— 之前只有拖动时才显示，
                        // 静态看着就是一条光秃秃的白线。
                        Circle().fill(.white)
                            .frame(width: isScrubbing ? 14 : 7, height: isScrubbing ? 14 : 7)
                            .offset(x: px - (isScrubbing ? 7 : 3.5))
                            .shadow(color: .black.opacity(0.45), radius: 2)
                    }
                    // 🔴 v2.7.3：GeometryReader 的内容默认**顶部对齐**，
                    // 导致进度条比两侧的时间文字高出一截。强制垂直居中，
                    // 让细条和「00:23 / 03:55」在同一条基线上。
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard playback.duration > 0, w > 0 else { return }
                            if !isScrubbing {
                                isScrubbing = true
                                scrubValue = playback.currentTime
                                Haptics.light()
                            }
                            scrubValue = min(1, max(0, v.location.x / w)) * playback.duration
                        }
                        .onEnded { _ in
                            store.seek(to: scrubValue)
                            isScrubbing = false
                        })
                }
                // 🔴 触摸区高 28pt（视觉仍是 4pt 细条，contentShape 撑满整行）：
                // 太窄手指很难按准进度条
                .frame(height: 28)

                Text(playback.duration.clockString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(minWidth: 38, alignment: .trailing)
            }

            // 控制键：上一首 / 播放 / 下一首（与播放页同款 PlayButton，白字白圈，任意背景可见）
            // 🔴 v2.7.0：左右两侧加「顺序模式」和「播放列表」按钮（与播放页一致）。
            HStack(spacing: 0) {
                // 左：顺序模式（列表循环 / 单曲循环 / 随机）
                Button {
                    store.cycleMode()
                    Haptics.light()
                } label: {
                    Image(systemName: modeIcon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(modeActive ? Color.white.opacity(0.95) : .white.opacity(0.7))
                        // 🔴 v2.7.3：边距继续改小 28→24（用户要求再收一点）
                        .frame(width: 24, height: 42)
                        .contentShape(Rectangle())
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
                Button { store.step(-1) } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 52)
                }
                Spacer(minLength: 0)
                PlayButton()
                Spacer(minLength: 0)
                Button { store.step(1) } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 52)
                }
                Spacer(minLength: 0)

                // 右：播放列表
                Button {
                    store.isQueuePresented = true
                    Haptics.light()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        // 🔴 v2.7.3：边距继续改小 28→24（用户要求再收一点）
                        .frame(width: 24, height: 42)
                        .contentShape(Rectangle())
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
            }
            .buttonStyle(.plain)
            }   // 🔴 v2.7.1：if !chromeHidden 结束（收起时整块不占位）
        }
        .foregroundStyle(.white)
    }

    /// 顺序模式图标（与播放页 classicModeButton 同款）
    private var modeIcon: String {
        switch store.mode {
        case .shuffle: return "shuffle"
        case .single: return "repeat.1"
        case .order: return "repeat"
        }
    }

    /// 非「列表循环」时高亮（单曲循环 / 随机）
    private var modeActive: Bool { store.mode != .order }
}

/// 全屏歌词页专用大字歌词流。当前行 30pt 纯白垂直居中，其他行 20pt 浅灰，行间距拉大到 40pt。
/// 性能关键：LazyVStack（只渲染可见行）+ index 直接比较（干掉 O(n²) firstIndex）+ 每行无 .animation（全局动画容器）。
private struct BigLyricsView: View {
    let lyrics: [LyricLine]
    let currentIndex: Int?
    var showsTranslation: Bool
    /// 🔴 let 不订阅（v2.5.38）：BigLyricsView 的逐字填充交给子 KaraokeLine 的
    /// TimelineView + liveTime 驱动，本体无需随 4fps 进度重建（避免整页歌词 4Hz 抖动）。
    let playback: PlaybackProgress
    var isPlaying: Bool
    /// 精确播放头（AVPlayer 实时值）：逐帧直读，根治「逐字跟不上」。
    var liveTime: (() -> Double)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // LazyVStack：只渲染屏幕可见的几行 —— 100 行歌词 ≈ 同时渲染 8-10 行，
                // 对比 VStack 全量渲染 100 行，滚动时 body 重建量直接砍到 1/10。
                // 🔴 v2.7.0：行间距 40 → 26（用户要求上下间距改小，一屏能多看几行）
                LazyVStack(alignment: .center, spacing: 26) {
                    if lyrics.isEmpty {
                        Text("纯音乐 · 暂无歌词")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        // enumerated() 让每行持有自己的 index —— isActive/isNearActive 直接比较 index，
                        // 干掉原来的 firstIndex(where:) O(n) 扫描。ForEach × firstIndex = O(n²)。
                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { idx, line in
                            lyricRow(idx: idx, line: line)
                        }
                    }
                }
                .padding(.vertical, 120)
            }
            .mask(LinearGradient(colors: [.clear, .black.opacity(0.85), .black, .black.opacity(0.85), .clear],
                                startPoint: .top,
                                endPoint: .bottom))
            .onAppear {
                // 🔴 打开歌词页时若正在播放，立即把当前演唱行滚到【偏上位置】：
                // 不能只靠 onChange(currentIndex) —— 打开瞬间 currentIndex 已是当前值（没变化），
                // onChange 不会触发，于是停在顶端。这里显式滚一次，配合下方 onChange 保持位置。
                if let id = activeId {
                    proxy.scrollTo(id, anchor: Self.activeAnchor)
                } else {
                    proxy.scrollTo(lyrics.first?.id, anchor: Self.activeAnchor)
                }
            }
            .onChange(of: currentIndex) { _ in
                guard let id = activeId else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(id, anchor: Self.activeAnchor)
                }
            }
            .onChange(of: lyrics) { _ in
                // 切歌：滚到当前行（而非顶端），保持高亮行在偏上位置
                if let id = activeId { proxy.scrollTo(id, anchor: Self.activeAnchor) }
                else { proxy.scrollTo(lyrics.first?.id, anchor: Self.activeAnchor) }
            }
        }
        // 容器级统一动画 —— 只有一个 animation 作用在 LazyVStack 上，
        // 可见行的 active 状态样式变化会自动过渡，不可见行不渲染就不参与。
        .animation(.easeInOut(duration: 0.3), value: currentIndex)
    }

    private var activeId: UUID? {
        guard let index = currentIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }

    /// 🔴 v2.6.7：高亮行往上挪一行 —— 之前 anchor 是 .center（屏幕正中），
    /// 现在用 y=0.38 让当前句落在偏上位置（≈ 上移一行歌词的高度），
    /// 和酷狗/网易云的歌词页习惯一致，底部控制条上方也能多露出几行歌词。
    private static let activeAnchor = UnitPoint(x: 0.5, y: 0.38)

    /// 单行歌词视图（抽出独立函数，降低 body 的类型推导复杂度，
    /// 避免 "compiler is unable to type-check this expression in reasonable time"）。
    private func lyricRow(idx: Int, line: LyricLine) -> some View {
        let activeIdx = currentIndex
        let isActive = activeIdx == idx
        let isNear = activeIdx != nil && abs(idx - activeIdx!) <= 1
        // 🔴 v2.7.0：行内间距 7→4，行距 4→2
        return VStack(spacing: 4) {
            // 🔴 v2.7.0：字号再调小 —— 当前句 26→22，其他行 17→15
            if isActive {
                // 🔴 v2.5.46：竖屏歌词页整行高亮（白、加粗），不再逐字卡拉OK填充
                // （横屏歌词块保持逐字不变 —— 用户要求只改竖屏）
                Text(line.text)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            } else {
                Text(line.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(isNear ? 0.45 : 0.28))
                    .multilineTextAlignment(.center)
            }
            if showsTranslation, let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: isActive ? 12 : 10))
                    .foregroundStyle(isActive ? .white.opacity(0.78) : .white.opacity(0.3))
                    .multilineTextAlignment(.center)
            }
        }
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .center)
        .id(line.id)
    }
}

// MARK: - 高频状态隔离子视图（v2.5.35）
//
// 🔴 为什么这四个视图存在：playback.currentTime 播放时 4fps 变化、歌词高亮
// currentIndex 逐行变化。旧结构里 PlayerView 本体 @ObservedObject 直接订阅它们，
// 导致整棵播放页树（横屏返回/播放/暂停按钮、收藏、列表…）每秒被整树重建 4 次
// —— SwiftUI 在持续 re-diff 期间会丢触摸事件，实测表现为横屏返回按钮
// 「要点几下才有反应」、暂停后再按播放没反应（v2.5.34 用户实测）。
// 拆分后：需要实时进度/歌词高亮的小块 UI 自己订阅，PlayerView 本体只随
// 切歌/播放暂停等低频状态重建，按钮所在的树保持稳定，点击必中。

/// 经典主题流光进度条（accent 渐变 + ultraThinMaterial 轨道 + 顶部高光 + 游动光点 + 发光滑块）。
private struct ClassicProgressBlock: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject var playback: PlaybackProgress
    let dominantColor: Color
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    private var displayTime: Double { isScrubbing ? scrubValue : playback.currentTime }

    var body: some View {
        // 🔴 v2.5.40 参考图版式：「已播时间 —— 细白进度条 —— 总时长」同一行，
        // 时间贴两侧（不再叠在下方 / 不放 ±15s 按钮）；细白条 + 白色圆滑标，拖动可 seek。
        HStack(spacing: 12) {
            Text(displayTime.clockString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .frame(minWidth: 38, alignment: .leading)

            GeometryReader { geo in
                let gWidth = geo.size.width
                let thumbX = min(max(playback.progress * gWidth, 5), max(gWidth - 5, 5))
                let trackH: CGFloat = 4

                ZStack(alignment: .leading) {
                    // 轨道（半透明白）
                    Capsule()
                        .fill(.white.opacity(0.30))
                        .frame(height: trackH)
                    // 已播段（实白）
                    Capsule()
                        .fill(.white)
                        .frame(width: thumbX, height: trackH)
                    // 滑标（拖动时放大）
                    Circle()
                        .fill(.white)
                        .frame(width: isScrubbing ? 20 : 12, height: isScrubbing ? 20 : 12)
                        .shadow(color: .black.opacity(isScrubbing ? 0.35 : 0.25),
                                radius: isScrubbing ? 6 : 3, y: 0)
                        .offset(x: thumbX - (isScrubbing ? 10 : 6))
                        .animation(.spring(response: 0.24, dampingFraction: 0.76), value: isScrubbing)
                }
                .frame(width: gWidth, height: 24)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isScrubbing { scrubValue = playback.currentTime; Haptics.soft() }
                            isScrubbing = true
                            scrubValue = min(max(value.location.x / max(gWidth, 1), 0), 1) * playback.duration
                        }
                        .onEnded { _ in
                            store.seek(to: scrubValue); isScrubbing = false; Haptics.light()
                        }
                )
                .overlay(alignment: .topLeading) {
                    if isScrubbing {
                        Text(displayTime.clockString)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background {
                                Capsule().fill(.black.opacity(0.48))
                                    .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.7) }
                            }
                            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                            .offset(x: min(max(thumbX - 31, 0), max(gWidth - 62, 0)), y: -28)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
            }
            .frame(height: 24)

            Text(playback.duration.clockString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .frame(minWidth: 38, alignment: .trailing)
        }
        .frame(height: 28)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isScrubbing)
    }
}

/// 细进度条（横屏播放器 / 炫胶·黑胶竖屏共用）：轨道 + 缓冲 + 已播 + 光点 + 拖动。
private struct PlayerProgressSection: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject var playback: PlaybackProgress
    let dominantColor: Color
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    private var displayTime: Double { isScrubbing ? scrubValue : playback.currentTime }

    var body: some View {
        let progressFrac = max(0, min(1, playback.progress))
        let bufferedFrac = max(0, min(1, playback.bufferedFraction))

        return VStack(spacing: 6) {
            GeometryReader { geo in
                let trackWidth = geo.size.width
                let progressX = progressFrac * trackWidth

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: 3)

                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(width: bufferedFrac * trackWidth, height: 3)

                    Capsule()
                        .fill(LinearGradient(colors: [
                            dominantColor,
                            dominantColor.opacity(0.7)
                        ], startPoint: .leading, endPoint: .trailing))
                        .frame(width: progressX, height: 3)
                        .animation(.easeInOut(duration: 0.3), value: dominantColor)

                    if store.isPlaying {
                        GlowDot()
                            .frame(width: 10, height: 10)
                            .offset(x: progressX - 5)
                            .animation(.linear(duration: 0.2), value: progressX)
                    }

                    Circle()
                        .fill(dominantColor)
                        .frame(width: 14, height: 14)
                        .offset(x: progressX - 7)
                        .opacity(isScrubbing ? 1 : 0)
                        .shadow(color: dominantColor.opacity(0.6), radius: 8)
                        .animation(.easeInOut(duration: 0.3), value: dominantColor)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard playback.duration > 0, trackWidth > 0 else { return }
                        if !isScrubbing {
                            isScrubbing = true
                            scrubValue = playback.currentTime
                            Haptics.light()
                        }
                        scrubValue = min(1, max(0, value.location.x / trackWidth)) * playback.duration
                    }
                    .onEnded { _ in
                        store.seek(to: scrubValue)
                        isScrubbing = false
                    })
            }
            .frame(height: 16)

            HStack {
                Text(displayTime.clockString)
                Spacer()
                Text(playback.duration.clockString)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// 双行歌词条（酷狗风格）：当前行整行高亮 + 下一行暗显。
/// 🔴 v2.5.46：竖屏不再逐字卡拉OK填充，改为整行高亮（用户要求；横屏保持逐字不变）。
/// 点击进歌词页。
private struct LyricPill: View {
    @EnvironmentObject private var store: PlayerStore
    /// 独立订阅歌词高亮（与注入的是同一单例实例，见 LyricsPageView 同款写法）
    @ObservedObject private var lyricState = PlayerStore.shared.lyricState
    var onOpen: () -> Void

    private var dim: Color { .white.opacity(0.4) }

    var body: some View {
        Button {
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                // 第一行：当前歌词 —— 整行高亮（白、加粗），无逐字填充
                Text(currentLyricText)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(currentLineActive ? .white : dim)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 第二行：下一句歌词 —— 暗、小
                if let next = nextLyricText {
                    Text(next)
                        .font(.system(size: 14))
                        .foregroundStyle(dim)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: currentLyricText)
        .animation(.easeInOut(duration: 0.25), value: nextLyricText)
    }

    /// 当前行是否处于激活状态（有有效行且非加载/纯音乐提示语）
    private var currentLineActive: Bool {
        !store.isLoading && lyricState.currentIndex != nil && !store.lyrics.isEmpty
    }

    private var currentLyricText: String {
        if store.isLoading { return "正在解析歌词…" }
        if let index = lyricState.currentIndex, store.lyrics.indices.contains(index) {
            return store.lyrics[index].text
        }
        return store.lyrics.isEmpty ? "纯音乐 · 暂无歌词" : "点击查看完整歌词"
    }

    private var nextLyricText: String? {
        guard let index = lyricState.currentIndex,
              store.lyrics.indices.contains(index + 1) else { return nil }
        let text = store.lyrics[index + 1].text
        return text.isEmpty ? nil : text
    }
}

/// 横屏播放器四行歌词块：上句暗 / 当前句大（卡拉OK逐字）/ 下句 / 下下句，纯展示。
/// 🔴 不可点击跳转 —— 用户要求横屏点歌词不要进歌词页（避免旋转打架/重复）。
private struct LandscapeLyricsBlock: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var lyricState = PlayerStore.shared.lyricState
    /// 🔴 let 不订阅（v2.5.38）：横屏歌词块的逐字填充由 KaraokeLine 的 TimelineView
    /// + liveTime 驱动，LandscapeLyricsBlock 本体无需随 4fps 进度重建 —— 否则它的
    /// TimelineView 每 0.25s 被销毁重建一次，逐字填充卡顿（"歌词慢了"），同时主线程
    /// 被 4Hz 重建+30fps TimelineView 双重占用，横屏播放/暂停按钮触摸被吞（"按一次就卡住"）。
    private let playback = PlayerStore.shared.playback

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let prev = prevLyricText {
                Text(prev)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            // 当前句：卡拉OK逐字填充（与播放页/歌词页同款）
            if let span = currentLineSpan {
                KaraokeLine(text: currentLyricText,
                            start: span.start,
                            end: span.end,
                            isPlaying: store.isPlaying,
                            playback: playback,
                            font: .system(size: 23, weight: .bold),
                            lineLimit: 2,
                            align: .leading,
                            liveTime: { store.lyricDisplayTime })
            } else {
                Text(currentLyricText)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if let next = nextLyricText {
                Text(next)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            // 第四行（更暗）：当前句的"下下一句"（用户要求歌词改 4 行显示）
            if let nextNext = nextNextLyricText {
                Text(nextNext)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.22))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: currentLyricText)
        .animation(.easeInOut(duration: 0.25), value: nextLyricText)
    }

    private var currentLineSpan: (start: Double, end: Double)? {
        guard let index = lyricState.currentIndex,
              store.lyrics.indices.contains(index) else { return nil }
        let start = store.lyrics[index].time
        let end: Double
        if store.lyrics.indices.contains(index + 1) {
            end = store.lyrics[index + 1].time
        } else {
            end = playback.duration > start ? playback.duration : start + 5
        }
        guard end > start else { return (start, start + 1) }
        return (start, end)
    }

    private var currentLyricText: String {
        if store.isLoading { return "正在解析歌词…" }
        if let index = lyricState.currentIndex, store.lyrics.indices.contains(index) {
            return store.lyrics[index].text
        }
        return store.lyrics.isEmpty ? "纯音乐 · 暂无歌词" : ""
    }

    private var prevLyricText: String? {
        guard let index = lyricState.currentIndex,
              index > 0, store.lyrics.indices.contains(index - 1) else { return nil }
        let text = store.lyrics[index - 1].text
        return text.isEmpty ? nil : text
    }

    private var nextLyricText: String? {
        guard let index = lyricState.currentIndex,
              store.lyrics.indices.contains(index + 1) else { return nil }
        let text = store.lyrics[index + 1].text
        return text.isEmpty ? nil : text
    }

    /// 第四行（更暗）：当前句的"下下一句"。
    private var nextNextLyricText: String? {
        guard let index = lyricState.currentIndex,
              store.lyrics.indices.contains(index + 2) else { return nil }
        let text = store.lyrics[index + 2].text
        return text.isEmpty ? nil : text
    }
}

// MARK: - 沉浸式封面主题背景（按酷狗 20.8.4 静态证据重建）

/// 🔴 2026-11-09：从酷狗音乐 20.8.4（CFBundleVersion 20.8.4.19）播放页「沉浸式封面」样式移植。
/// 逆向依据（IPA 主可执行文件 `Payload/kugou.app/kugou` 的实例变量 / 选择器，以及包内资源）：
///   · `themeImmersiveCoverImgView`  (UIImageView)          → 清晰封面
///   · `themeImmersiveCoverBlurView`(UIVisualEffectView)    → 同一张封面的模糊层
///   · `themeImmersiveAlphaView` / `themeImmersiveAlphaViewLayer` → 封面下沿羽化渐隐
///   · `themeImmersiveBannerHeight` / `themeImmersiveBgView` / `themeBackgroundGradientLayer`
///   · `themeImmersiveColorPickerView`                      → 从封面取主色
///   · `k20_playview_change_mode_localskin@3x.png`          → 全屏渐变 + 白色歌词/歌名/
///     动作行/进度/播放控件，中间没有方形封面（版式预览）
/// 这是「按证据重建」：只用本 App 自己的封面与取色，不复制酷狗的图片资源或代码。
///
/// 🔴 校正史（都按真机截图逐行量化，勿走回头路）：
///    · 第 2 轮：`scaledToFill` 把封面放大横向裁切 → 改 `scaledToFit` 完整不裁切。
///    · 第 3 轮：歌词挪到封面羽化区居中 → 用户要求改回 deck 歌名下方，主题只换背景不改版式。
///    · 第 4 轮：封面 `.offset(y:0.09H)` 下移对齐书法字；加了不透明顶栏雾色块。
///    · 第 5 轮：顶栏/底部共用整图平均提亮导致青灰 → 拆天空带 / 整图平均分别取色。
///    ⚠️ 第 4/5 轮的「不透明纯色 wash 底 + 不透明顶栏雾色块 + 清晰封面 20% 短羽化」
///       正是第 6 轮要拆掉的分层结构 —— 它必然产生两道硬切边。
///
/// 🔴 2026-11-10 第六次校正 / 最终架构（用户：「顶部沉浸区往上移点；参考酷狗沉浸式封面，
///    从专辑封面提取主色调，封面图像向下高斯模糊延伸作为整屏全屏背景，封面与背景无缝融合，
///    无生硬分层切割线」）：
///    1125×2436 截图逐行量化 —— 我方 0~0.15H 是 `(197,176,144)` 纯色、**方差 0~3**；
///    0.18~0.52H 是清晰封面、方差 57~101；**0.53→0.55H 方差从 100 断崖到 1.6**，
///    下半屏全是 `(115,114,90)` 均匀纯色 = 用户说的「生硬分层切割线」。
///    目标全程有朦胧纹理：顶栏 `(155,136,108)` 方差 17~57、下半 `(115,94,50)` 方差 8~49。
///    🔴 决定性证据：目标顶栏 ≈ 封面上 1/3 平均 `(154,136,110)`，
///    目标下半 ≈ 封面下 1/3 平均 `(111,93,65)` —— 酷狗整屏就是**同一张封面纵向拉伸后
///    高斯模糊**，上亮下暗来自封面本身的明暗，不是叠了纯色或渐变。
///    现在 = ① 主色调不透明兜底 → ② 封面整屏 blur → ②.5 底部条带拉伸向下延伸（下半基底）
///    → ③ 主色薄覆盖 → ③.5 下半加深 → ④ 清晰封面（顶部渐入 + 下沿长羽化）。
///    `topShift` 0.09H → 0.055H，顶部沉浸区从更上方开始，书法字仍基本对齐。
///
/// 🔴 2026-11-10 第七次微调（用户：「顶栏封面模糊氛围再调一点点；顶部时间信号栏
///    改跟顶栏按钮同色；底部清晰区再加深点；羽化起点再往上一点」）：
///    1125×2436 截图逐行量化 —— 顶栏 0~0.06H 是 `(127,146,152)` 低方差雾面，
///    0.15H 起清晰封面方差 40~86，0.50H 以后均匀 `(70,85,82)`，
///    底部回升到 `(107,112,93)` 偏亮，白字歌名/控件对比不够。
///    ① 顶栏：`topShift` 0.055H → 0.048H + 顶部渐入 0.12→0.14 且起手更淡，
///       雾面再薄一点点、清晰封面更早透出来；再叠 0~0.18H 的 0.15→0
///       黑色长渐变（不是不透明雾色块，无硬边），亮天空稍收，白字更清楚。
///    ② 状态栏：播放页 `PlayerHostingController.preferredStatusBarStyle = .lightContent`
///       + `modalPresentationCapturesStatusBarAppearance = true`，时间/信号/电量与
///       顶栏按钮同为白色；不用 `preferredColorScheme(.dark)` 以免整页 dynamic 色跳变。
///    ③ 底部清晰区：③ 与 ④ 之间加 0~0.40H 全透明、之后长渐变到 0.21 黑的加深层，
///       放在清晰封面【之下】，只压明暗、保留模糊纹理，不产生 0.53H 方差断崖。
///    ④ 羽化：清晰段 0.62→0.54、羽化段 0.26→0.32，起点上移约 0.08×封面高。
///
/// 🔴 2026-11-10 第八次微调（用户：「专辑图片在下移一点，其他不动」）：
///    只把 `topShift` 0.048H → 0.065H（约下移 0.017 屏高 ≈ 14pt / 42px@3x），
///    让清晰封面整体往下一点、顶栏留白氛围稍多；其余参数、层级、状态栏全部原样保留。
///
/// 🔴 2026-11-10 第九次微调（用户：「图片再下移一点；底部横向分界线再优化，还是有点明显」）：
///    ① `topShift` 0.065H → 0.080H（继续下移）。
///    ② ② 层 blur 60 → 48：模糊底保留一点大色块纹理，清晰封面淡出后不再落进近乎纯色的底。
///    ③ ③.5 加深层改 smoothstep 无折点曲线：旧 6 段等距色标在 0.40H/0.60H/0.80H
///       斜率突变，全屏等宽叠一层正是那条「横向分界带」的根因。
///    ④ `seamlessMask` 清晰段 0.54→0.46、羽化段 0.32→0.40（9 段平滑衰减），淡出更长更缓。
///
/// 🔴 2026-11-10 第十次微调（用户：「左下怎么是黄色的，看看酷狗的」）：
///    「情罪」封面量化：我方左下 `(100,88,91)` 暖黄，酷狗同位置 `(63,68,95)` 冷蓝紫。
///    根因 = ③ 整屏都用「整图平均主色」0.18 覆盖，而这张封面整图平均偏棕黄。
///    改成 0~0.30H 保持整图主色（顶栏一点不动）+ 0.30H~1.0H 8 段渐变到
///    【封面下半部主色】`lowerToneColor`（深蓝衣服 → 冷蓝，亮度归一 0.30 更暗）。
///    🔴 自适应是关键：换暖色封面时下半主色也暖，绝不硬编码蓝色（历史「压成灰绿」被否的坑）。
///
/// 🔴 2026-11-10 第十一次微调（用户：「还是一样，继续优化」）：
///    第十轮**没有生效**：新旧包逐区量化只差 5~9，左下 `(94,83,87)` 仍是暖灰，
///    酷狗 `(63,68,95)` 是 B−R=+32 的冷蓝，我方 B−R=−7。
///    根因 = ③ 层在用户关注的 0.44~0.56H 处浓度只有 0.20 且前两段仍是整图暖色，
///    而 ② 的整屏模糊基底本身已被混成中性灰 —— **薄覆盖改不动基底色相**。
///    改法：新增 ②.5 —— 用 `bottomStrip(from:)` 裁封面底部 38%，`resizable()` 默认
///    stretch 拉伸铺满整屏 + blur(56)，配 `lowerBlendMask` 在 0~0.26H 完全不出现、
///    0.26~0.60H 长渐变渐入、0.60H 后完全接管基底。下半屏从此是【封面底部的模糊延伸】，
///    冷蓝相与纹理都来自封面本身；③ 层下半浓度 0.20~0.32 → 0.22~0.38 再锁一次色相，
///    ③.5 加深 0.20 → 0.15 避免把蓝压成黑灰。顶栏 0~0.26H 与版式全部不动。
///
/// 🔴 2026-11-10 第十二次微调（用户：「再优化一下，参考酷狗」）：
///    第十一轮生效了：色相已对齐（我方 B−R +14~+31，酷狗 +23~+33），
///    但逐行量化发现 **0.60H 之后整体暗约 20**：我方 `(65~79,72~89,94~110)`，
///    酷狗 `(87~100,92~106,110~124)`；左下 std 11.7 vs 39.9 是文字/控件差异，不是背景问题。
///    ① ③ 渐变后半 4 段改用 `brightTone`（同条带同色相，targetLum 0.34 → 0.50），
///       只提亮、不换色；前 4 段不变，0~0.30H 顶栏完全不动。
///    ② ③.5 加深 0.15 → 0.05：②.5 基底 + ③ 覆盖已足够，「底部加深」历史任务退场。
///    预期 0.75H 从 `(62,69,92)` → 约 `(79,80,107)`，酷狗 `(91,95,113)`。
///
/// 🔴 2026-11-10 第十三次微调（用户：「酷狗的沉浸色淡一些，你的顶部跟下面都深一点」）：
///    两张截图逐行量化（我方 `4b20b1bb` / 酷狗 `7012ab93`）：
///      顶部 0.05H 我方 lum 112 / 酷狗 126（暗 14）；0.10~0.25H 暗 5~8。
///      下半 0.75~0.95H 我方 B−R +32~+36 / 酷狗 +23~+25（蓝太浓），亮度暗 5~8。
///    ① ④.5 顶栏黑渐变 0.15/0.08 → 0.08/0.04，③ 顶部 tone 0.18 → 0.15。
///    ② ②.5 `lowerBlendMask` 末端 1.0 → 0.80，留 20% 中性 ② 基底 → 降饱和 + 提亮。
///    ③ ③ 后半 brightTone 浓度 0.32~0.38 → 0.26~0.30，③.5 加深 0.05 → 0.02。
///    ④ 新增 ③.7 平滑衰减白雾（上 0.035 → 下 0），放在 ④ 清晰封面【之下】：
///       顶部变淡、下半几乎不提亮（下半只暗 3，主要差在蓝色太浓），封面本身不变。
///    🔴 全部是均匀层或平滑渐变，不引入色标折点 → 不会重新长出横向分界带。
///
/// 🔴 2026-11-11 第十四次微调（用户：「酷狗的下面沉浸色黑色没有那么明显，我们的下面好大一块黑色」）：
///    四张真机截图逐带量化（右 72%~96% 纯背景区 / 0.52~0.98H 暗像素占比）：
///      深色封面《谁明浪子心》：酷狗下半 lum 76、暗像素 65%；我方 lum 93、暗像素 31%（我方过亮偏橙）。
///      浅色封面《盛夏的果实》：酷狗下半 lum 132、暗像素 0%； 我方 lum 110、暗像素 14%（我方过暗偏黑灰）。
///    根因 = ②.5 用【封面底部 38% 条带】拉伸铺满整屏，下半明度被封面最底部那一小块决定：
///      深色封面底部是浅色西装 → 我方下半过亮；浅色封面底部是黑色高领毛衣 → 我方下半一大块深灰。
///      酷狗则是跟着【封面整体】明度走：深封面暗、浅封面亮。两者刚好反了。
///    改法（只新增一层，既有 ①②③④ 参数一个不动，随时可回退）：
///      ③.8「下半明度归一」层，强度与 `封面整体亮度 − 底部条带亮度` 成正比，放在 ④ 清晰封面之下：
///        gap>0（浅封面）→ 叠暖白提亮；gap<0（深封面）→ 叠黑压暗；
///        0~0.26H 不出现（顶栏一点不动）、0.26~0.58H smoothstep 渐入、之后保持，无折点不出横带。
///    🔴 全程自适应取色，不硬编码任何颜色；暖白只为贴酷狗的浅暖灰，浓度上限 0.20 不会发白。
///
/// 🔴 布局红线（v2.6.8 / 2026-11-09 两次实锤）：背景层必须锁死屏幕尺寸
///    + clipped + allowsHitTesting(false)，否则原图像素尺寸会撑大 ZStack，
///    把动作行 / 播放控件整块挤出屏幕。
private struct ImmersiveCoverBackdrop: View {
    let artwork: UIImage?
    let size: CGSize

    var body: some View {
        ZStack(alignment: .top) {
            // 🔴 只有拿到封面才画这一层（完全不透明）；取不到封面时整层为空，
            //    外层 immersiveBackground 的经典取色渐变自然透出 = 自动回退。
            if let artwork {
                let tone = Self.mainToneColor(from: artwork)
                // 🔴 2026-11-10 第十一次微调：第十轮只把「下半主色」当 0.20~0.32 的薄覆盖，
                //    实测新旧包左下只差 6、仍是暖灰(94,83,87)，酷狗是冷蓝(63,68,95)。
                //    薄覆盖改不动色相。现在直接取封面【底部条带】做下半屏的模糊基底(②.5)，
                //    并用同一条带算下半主色：底部是深蓝衣服 → 下半自然冷蓝且有纹理。
                //    暖色封面底部仍暖，不会硬把每张封面染蓝（第 5 轮被否的坑）。
                let strip = Self.bottomStrip(from: artwork) ?? artwork
                let lowerTone = Self.mainToneColor(from: strip, targetLum: 0.34)
                // 🔴 2026-11-10 第十二次微调：第十一轮把色相修对了
                //    （我方 B−R +14~+31，酷狗 +23~+33），但 0.60H 之后整体仍暗约 20：
                //    我方 (65~79,72~89,94~110) vs 酷狗 (87~100,92~106,110~124)。
                //    渐变后半段换成同一色相但更亮的主色，只提亮不换色；
                //    前半段仍用较暗的 lowerTone，避免中段 / 清晰封面羽化区发白。
                let brightTone = Self.mainToneColor(from: strip, targetLum: 0.50)

                // 🔴 2026-11-11 第十四次微调：③.8 下半明度归一的自适应参数。
                //    只比较【整图平均亮度】与【底部条带平均亮度】的差，不写死任何颜色：
                //      gap > 0 = 封面整体亮、底部条带暗（浅色封面黑毛衣）→ 下半需要提亮；
                //      gap < 0 = 封面整体暗、底部条带亮（深色封面浅西装）→ 下半需要压暗。
                //    系数按两张真机截图反推：浅封面 whiteA≈0.15 可把 lum 110 → 132；
                //    深封面 blackA≈0.27 可把 lum 93 → 约 80。两端都设上限防止极端封面翻车。
                let coverLum = Self.luminance(Self.dominantRGB(from: artwork))
                let stripLum = Self.luminance(Self.dominantRGB(from: strip))
                let lumGap = coverLum - stripLum
                // 🔴 略暖的白：酷狗浅封面下半是 (130,118,116) 暖浅灰，纯白会偏冷。
                let liftBase: Color = lumGap >= 0
                    ? Color(.sRGB, red: 1.0, green: 0.96, blue: 0.93, opacity: 1)
                    : Color.black
                let liftPeak: Double = min(0.28, max(0, lumGap >= 0 ? lumGap * 0.70 : -lumGap * 1.10))

                // 清晰封面：按原图比例铺满屏宽，绝不横向裁切；
                // 极端的长图最多裁掉一点下沿（下沿本来就要羽化），不裁左右。
                let ratio = CGFloat(artwork.size.height) / max(CGFloat(artwork.size.width), 1)
                let fullH = size.width * ratio
                let coverH = min(fullH, size.width * 1.12)
                // 🔴 0.09H → 0.055H → 0.048H → 0.065H → 0.080H（第九次微调）：
                //    用户「图片再下移一点」→ 继续加大这一处 offset。
                //    `.offset` 只改绘制位置、不参与 ZStack 尺寸计算（历史撑大布局红线）。
                let topShift = size.height * 0.080

                // ① 主色调不透明兜底：从封面提取主色，盖住经典主题的深色取色渐变，
                //    顺便给 ② 的 blur 边缘当底色（模糊边缘半透明时不会露出黑底）。
                tone
                    .frame(width: size.width, height: size.height)

                // ② 整屏高斯模糊封面延伸（上半基底）：同一张封面 `scaledToFill`
                //    纵向铺满整屏 + 大半径 blur。屏幕顶部自然对应封面顶部（亮），
                //    底部对应封面底部（暗），整屏都是这张封面的色与朦胧纹理。
                //    🔴 锁死屏幕尺寸 + clipped：原图像素尺寸绝不能撑大 ZStack。
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    // 🔴 60 → 48（第九次微调）：留一点大色块纹理，清晰封面羽化淡出后
                    //    不会落进「几乎纯色」的底，横向边界感明显减弱。
                    .blur(radius: 48)
                    .frame(width: size.width, height: size.height)
                    .clipped()

                // ②.5 封面底部条带向下延伸（2026-11-10 第十一次微调，本次核心）：
                //    🔴 这才是「封面图像向下高斯模糊延伸为整屏背景」的正确实现。
                //       ② 的 scaledToFill 整屏拉伸会把封面上下混成中性灰，靠 ③ 薄染救不回来。
                //       这里把封面【底部 38%】单独裁出，`resizable()` 默认 stretch 直接拉伸铺满
                //       整屏（横轴保留封面全部信息、纵轴是底部条带的延伸）+ 大半径 blur，
                //       再用 lowerBlendMask 让它在 0~0.26H 完全不出现（顶栏氛围一点不动）、
                //       0.26~0.60H 长渐变渐入、0.60H 之后完全替换基底。
                //       于是清晰封面羽化淡出时，融进的是【同色系的封面底部】而不是中性灰，
                //       既带出冷蓝相，也顺带消掉「清晰纹理→纯色底」的那条横向分界线。
                //    🔴 同样锁死屏幕尺寸 + clipped，原图像素绝不参与 ZStack 布局。
                Image(uiImage: strip)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .blur(radius: 56)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .mask(Self.lowerBlendMask(width: size.width, height: size.height))

                // ③ 主色调薄覆盖（2026-11-10 第十次微调）：
                //    🔴 旧版整屏都用「整图平均主色」0.18 覆盖，这张「情罪」封面整图平均偏棕黄
                //       → 左下被染成暖黄 (100,88,91)，酷狗同款左下是冷蓝紫 (63,68,95)。
                //    现在分段：0~0.30H 仍用整图主色（顶栏氛围一点不动），0.30H~1.0H
                //    平滑过渡到【封面下半部主色】—— 下半是深蓝衣服 → 冷蓝；
                //    换暖色封面时下半主色也是暖的，不会硬把每张封面都染蓝（历史被否的坑）。
                //    8 段色标首尾浓度持平，斜率无突变，不会再生成横向分界带。
                //    🔴 第十一次微调：②.5 已把下半基底换成冷蓝，这里把 lowerTone 的浓度
                //       0.20~0.32 → 0.22~0.38 并更早进入（第 2 段起），叠在同色系基底上
                //       进一步锁住冷蓝相；0~0.30H 的 tone 段完全不动，顶栏保持原样。
                //    🔴 第十二次微调：渐变【后半 4 段】从 lowerTone 换成 brightTone
                //       （同一条带、同一色相，只把亮度归一 0.34 → 0.50），
                //       让 0.55H 之后逐渐提亮到酷狗的亮冷蓝；前 4 段保持不动。
                //    🔴 第十三次微调：顶部 tone 0.18→0.15（整图暖棕主色少盖一点），
                //       后半 brightTone 0.32~0.38 → 0.26~0.30 —— 我方下半 B−R +35
                //       比酷狗 +23 浓太多，减少染色浓度让冷蓝「淡一点」。
                VStack(spacing: 0) {
                    tone.opacity(0.15)
                        .frame(width: size.width, height: size.height * 0.30)
                    LinearGradient(colors: [
                        tone.opacity(0.15),
                        tone.opacity(0.15),
                        lowerTone.opacity(0.20),
                        lowerTone.opacity(0.24),
                        brightTone.opacity(0.26),
                        brightTone.opacity(0.28),
                        brightTone.opacity(0.30),
                        brightTone.opacity(0.30)
                    ], startPoint: .top, endPoint: .bottom)
                        .frame(width: size.width, height: size.height * 0.70)
                }
                .frame(width: size.width, height: size.height)

                // ③.5 下半屏加深（2026-11-10 第九次微调）：歌名 / 歌词 / 控件区域压深。
                //    🔴 旧版 6 段等距色标在 0.40H / 0.60H / 0.80H 各有一次斜率突变，
                //       全屏等宽叠一层时就显成一条横向分界带（用户第九轮反馈的「底部横向分界线」）。
                //       现在 0~0.30H 全透明，0.30H~1.0H 按 smoothstep t²(3-2t) 用 8 段色标
                //       平滑升到 0.05 黑：首尾斜率都趋近 0，没有任何折点 → 无横带。
                //       只压明暗、保留模糊纹理；放在 ④ 清晰封面【之下】。
                //    🔴 第十一次 0.20 → 0.15、第十二次 0.15 → 0.05、第十三次 0.05 → 0.02：
                //       ②.5 的冷蓝基底 + ③ 的覆盖已把下半压得比酷狗暗，这层历史
                //       「底部加深」基本退场，只留 0.02 保住一点点层次。
                VStack(spacing: 0) {
                    Color.clear
                        .frame(width: size.width, height: size.height * 0.30)
                    LinearGradient(colors: [Color.clear,
                                            Color.black.opacity(0.001),
                                            Color.black.opacity(0.003),
                                            Color.black.opacity(0.006),
                                            Color.black.opacity(0.011),
                                            Color.black.opacity(0.016),
                                            Color.black.opacity(0.019),
                                            Color.black.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(width: size.width, height: size.height * 0.70)
                }
                .frame(width: size.width, height: size.height)

                // ③.7 整体淡雾（2026-11-10 第十三次微调）：上强下弱的平滑衰减白层。
                //    🔴 放在 ④ 清晰封面【之下】：只把模糊背景提亮一点、降一点饱和，
                //       清晰封面的色彩完全不受影响；顶部渐入区透出来的雾也会一起变淡。
                //    🔴 不能整屏均匀 0.03 白：逐行量化下半我方只比酷狗暗约 3，
                //       真正差的是蓝色太浓（B−R +34 vs +23）；均匀白雾会把下半提亮约 10
                //       反而发白。8 段平滑衰减到 0，顶部拿到提亮、下半几乎不加亮，
                //       且首尾斜率趋近 0、没有色标折点，不会重新长出横向分界带。
                LinearGradient(colors: [Color.white.opacity(0.035),
                                        Color.white.opacity(0.034),
                                        Color.white.opacity(0.028),
                                        Color.white.opacity(0.018),
                                        Color.white.opacity(0.009),
                                        Color.white.opacity(0.003),
                                        Color.white.opacity(0.001),
                                        Color.white.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: size.width, height: size.height)

                // ③.8 下半明度归一（2026-11-11 第十四次微调，本次核心）：
                //    🔴 放在 ④ 清晰封面【之下】：只校正模糊背景，清晰封面本身一点不动；
                //       0~0.26H 完全透明（顶栏氛围 / 清晰封面上段一点不动），
                //       0.26~0.58H 按 smoothstep 长渐变渐入，之后保持恒定。
                //    🔴 8 段色标首尾斜率趋近 0、末端与恒定段平齐 → 不引入任何横向分界带。
                //    🔴 liftPeak=0 时整层完全透明（封面整体与底部条带同亮度）→ 对多数封面零影响。
                VStack(spacing: 0) {
                    Color.clear
                        .frame(width: size.width, height: size.height * 0.26)
                    LinearGradient(colors: [liftBase.opacity(0),
                                            liftBase.opacity(liftPeak * 0.02),
                                            liftBase.opacity(liftPeak * 0.10),
                                            liftBase.opacity(liftPeak * 0.28),
                                            liftBase.opacity(liftPeak * 0.52),
                                            liftBase.opacity(liftPeak * 0.76),
                                            liftBase.opacity(liftPeak * 0.93),
                                            liftBase.opacity(liftPeak)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(width: size.width, height: size.height * 0.32)
                    liftBase.opacity(liftPeak)
                        .frame(width: size.width, height: size.height * 0.42)
                }
                .frame(width: size.width, height: size.height)

                // ④ 清晰封面：完整原图、屏宽、不放大不横向裁切。
                //    mask 同时做「顶部渐入」和「下沿长羽化」：
                //    顶部渐入让状态栏 / 顶栏沉浸在 ② 的模糊里（不再有纯色雾面块），
                //    下沿 40% 慢慢化开融进 ②（第九次微调后羽化更长、更平滑）。
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: fullH, alignment: .top)
                    .frame(width: size.width, height: coverH, alignment: .top)
                    .clipped()
                    .mask(Self.seamlessMask(width: size.width, height: coverH))
                    .offset(y: topShift)

                // ④.5 顶栏氛围：极淡的黑色长渐变（0~0.18H，0.08→0.04→0）。
                //    🔴 第十三次微调：0.15→0.08 / 0.08→0.04 —— 逐行量化我方顶栏
                //       (113,112,115) 比酷狗 (127,126,126) 暗约 14，主要就是这层压的。
                //    全程渐变、没有不透明雾色块，不会产生硬切边。
                LinearGradient(colors: [Color.black.opacity(0.08),
                                        Color.black.opacity(0.04),
                                        Color.clear, Color.clear, Color.clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: size.width, height: size.height * 0.18)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .allowsHitTesting(false)
    }

    /// 无缝遮罩：上段渐入（顶栏沉浸）+ 中段完整清晰 + 下段长羽化（融进模糊背景）。
    /// mask 只看 alpha，黑色 = 可见、clear = 隐藏；用均匀色标避开 iOS 16 的 locations API。
    /// 🔴 羽化段必须够长：旧版「上 80% 实色 + 下 20% 短羽化」配纯色底，
    ///    在 0.53H 处留下方差 100→1.6 的硬切割线，正是本系列要修的问题。
    /// 🔴 2026-11-10 第七次微调：顶部渐入 0.12→0.14 且起手更淡（0.45→0.35），
    ///    顶栏的封面模糊氛围再柔一点点；清晰段 0.62→0.54、羽化段 0.26→0.32，
    ///    **羽化起点上移**约 0.08×封面高（≈22pt），清晰区更早开始化开。
    /// 🔴 2026-11-10 第九次微调：清晰段 0.54→0.46、羽化段 0.32→0.40（9 段平滑衰减），
    ///    淡出区再拉长 0.08×封面高、末端斜率更缓，配合 ② 降 blur + ③.5 无折点加深，
    ///    彻底消掉「清晰纹理 → 纯色模糊底」那条横向分界线。
    private static func seamlessMask(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: width, height: height * 0.14)
            Color.black
                .frame(width: width, height: height * 0.46)
            LinearGradient(colors: [.black, .black.opacity(0.95), .black.opacity(0.86),
                                    .black.opacity(0.73), .black.opacity(0.57),
                                    .black.opacity(0.40), .black.opacity(0.24),
                                    .black.opacity(0.10), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: width, height: height * 0.40)
        }
        .frame(width: width, height: height)
    }

    /// ②.5 的下半屏基底融合遮罩（2026-11-10 第十一次微调）：
    /// 0~0.26H 完全不出现（顶栏氛围 / 清晰封面上段一点不动），0.26~0.60H 用 8 段
    /// 长渐变逐渐接管，0.60H 之后完全替换成「封面底部条带的模糊延伸」。
    /// mask 只看 alpha：black = 可见、clear = 隐藏；均匀色标避开 iOS16 的 locations API。
    /// 🔴 渐入段必须够长且与 ④ 的羽化区重叠，否则会在 0.26H 处造出一条新的横向硬边。
    private static func lowerBlendMask(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: width, height: height * 0.26)
            // 🔴 第十三次微调：末端不再 100% 替换基底，只到 0.80 —— 留 20% 的 ②
            //    中性模糊层混回来，既降蓝色饱和（B−R +35 → 约 +26）又略提亮，
            //    正对应用户「酷狗的沉浸色淡一些」。色标仍平滑无折点，不会出新横带。
            LinearGradient(colors: [.clear,
                                    .black.opacity(0.04),
                                    .black.opacity(0.11),
                                    .black.opacity(0.23),
                                    .black.opacity(0.40),
                                    .black.opacity(0.58),
                                    .black.opacity(0.74),
                                    .black.opacity(0.80)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: width, height: height * 0.34)
            Color.black.opacity(0.80)
                .frame(width: width, height: height * 0.40)
        }
        .frame(width: width, height: height)
    }

    private struct RGB {
        let r: Double
        let g: Double
        let b: Double
    }

    /// 相对亮度（0~1），第十四次微调「下半明度归一」用。取不到主色时给 0.4 中性值，
    /// 让 liftPeak 落在中段而不是走极端。
    private static func luminance(_ rgb: RGB?) -> Double {
        guard let c = rgb else { return 0.4 }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    /// 从封面提取主色调：24×24 降采样求整图平均（0~1 的 sRGB 分量）。
    /// 🔴 取整图平均而非某一条带，避开 `CGContext(data:)` 直接画 CGImage 时
    ///    buffer 行序上下颠倒的歧义。整屏颜色由「封面纵向拉伸 + 高斯模糊」自然给出，
    ///    这里的主色只用于不透明兜底和薄覆盖，不再主导整屏色调。
    private static func dominantRGB(from image: UIImage) -> RGB? {
        let side = 24
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * side)
        guard let cg = image.cgImage,
              let ctx = CGContext(data: &buffer,
                                  width: side,
                                  height: side,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let o = y * bytesPerRow + x * 4
                guard buffer[o + 3] > 8 else { continue }
                r += Double(buffer[o]) / 255
                g += Double(buffer[o + 1]) / 255
                b += Double(buffer[o + 2]) / 255
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return RGB(r: r / n, g: g / n, b: b / n)
    }

    /// 主色调：**保留封面色相**，只把亮度归一到中暗 0.44。
    ///    🔴 不再大幅降饱和 / 提蓝：第 5 轮那样做会把棕金封面压成中性灰绿。
    ///    整屏颜色应由 ② 的封面本身决定，这里只负责统一色调 + 盖住经典主题深色底。
    ///    本例封面平均 ≈(134,117,92) → 主色 ≈(127,111,87)；
    ///    目标顶栏 (155,136,108)、下半 (115,94,50) 分别由封面上 / 下 1/3 的模糊延伸给出。
    private static func mainToneColor(from image: UIImage, targetLum: Double = 0.44) -> Color {
        let fallback = Color(.sRGB, red: 0.50, green: 0.43, blue: 0.34, opacity: 1)
        guard let w = Self.dominantRGB(from: image) else { return fallback }
        let lum = 0.2126 * w.r + 0.7152 * w.g + 0.0722 * w.b
        let scale = min(1.8, targetLum / max(lum, 0.16))
        func clamped(_ v: Double) -> Double { min(1, max(0, v)) }
        return Color(.sRGB,
                     red: clamped(w.r * scale),
                     green: clamped(w.g * scale),
                     blue: clamped(w.b * scale),
                     opacity: 1)
    }

    /// 封面【底部 38%】条带（2026-11-10 第十一次微调）：
    /// 用 UIGraphicsImageRenderer 把原图整体上移后画进一条矮画布，避开
    /// `CGImage.cropping(to:)` 的 y 轴方向歧义；`UIImage.draw(in:)` 会正确处理 imageOrientation。
    /// 原图 y 范围 `[-(h-stripH), stripH]`、画布 `[0, stripH]` → 取到的正是原图底部 38%。
    /// 这一条带同时用于 ① ②.5 下半屏模糊延伸的基底；② ③ 层 lowerTone 的取样源。
    /// 只取底部而非整张下半：底部色相最纯，拉伸后不会把人物面部的灰调混进下半屏。
    private static func bottomStrip(from image: UIImage) -> UIImage? {
        let w = image.size.width
        let h = image.size.height
        let stripH = h * 0.38
        guard w > 0, stripH > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: stripH))
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: -(h - stripH),
                                  width: w, height: h))
        }
    }
}

// MARK: - 「我的播放器」主题卡片选择面板（2026-11-10，酷狗同款）
//
// 🔴 用自定义 overlay 而非 .sheet：iOS 15 链式多个 .sheet(isPresented:) 只有最后一个生效
//    （项目既有红线），而这个面板必须能盖住播放页半屏、点外部关闭、点卡片不关面板。
// 🔴 缩略图是「实时」的：直接用当前歌曲的封面 UIImage 与歌名 / 歌手绘制迷你播放页，
//    换歌后重新打开面板就是新歌的预览，不是静态素材图。
// 🔴 所有 Image 都锁死固定尺寸 + clipped：原图像素尺寸绝不能参与 ZStack 布局
//    （历史「写真原图撑大父布局、控件被挤出屏幕」红线）。

private enum PlayerThemeCardMetrics {
    static let width: CGFloat = 110
    static let height: CGFloat = 188
    static let spacing: CGFloat = 14
    /// 固定 RGB：不从 AppStyle.accent / UIColor.systemBlue 取 dynamic 色，
    /// 避免播放页的 toolbarColorScheme 切换把胶囊 / 边框颜色带偏。
    static let blue = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let ink = Color(red: 0.13, green: 0.14, blue: 0.16)
    static let muted = Color(red: 0.56, green: 0.57, blue: 0.60)
}

/// 只圆上方两角：SwiftUI 没有内置的部分圆角 clipShape，用 Shape 精确控制。
private struct PlayerThemeTopCorners: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: radius))
        p.addQuadCurve(to: CGPoint(x: radius, y: 0), control: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width - radius, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.width, y: radius),
                       control: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.closeSubpath()
        return p
    }
}

private struct PlayerThemePickerPanel: View {
    let current: PlayerPageTheme
    let onSelect: (PlayerPageTheme) -> Void
    let onMore: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            // 🔴 2026-11-10 修复「上面还有一层黑色的」：酷狗参考图里打开「我的播放器」
            //    时上方播放页保持原亮度，并不压一层黑。这里改成完全透明、只保留命中区，
            //    用 contentShape 保证点面板外仍能关闭（Color.clear 本身不参与命中测试）。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            sheetBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 🔴 2026-11-10：overlay 默认把 bottom 对齐点放在【安全区上沿】，
        //    于是白色面板底部与屏幕底之间露出 34pt 播放页深色背景 = 用户说的「下面黑色」。
        //    只加 .bottom（不动 .top、不动 ScrollView 内容），独立 overlay 层不会触发
        //    项目里「每层 ignoresSafeArea 下推一个安全区」的白顶红线。
        .ignoresSafeArea(edges: .bottom)
    }

    /// 白色圆角半屏面板：标题 + 横向可滚动卡片 + 底部 home indicator 留白。
    private var sheetBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("我的播放器")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(PlayerThemeCardMetrics.ink)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Text("完成")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(PlayerThemeCardMetrics.blue)
                        .frame(height: 30)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: PlayerThemeCardMetrics.spacing) {
                    ForEach(PlayerPageTheme.cardOrder) { theme in
                        themeCard(theme)
                    }
                    moreCard
                }
                .padding(.horizontal, 20)
                // 🔴 顶部再留 3pt：即使描边不外扩，也不让卡片圆角贴着 ScrollView 上沿。
                .padding(.top, 3)
            }
            // 与上面的 3pt 顶部留白同步 +3，底部可用高度不变。
            .frame(height: PlayerThemeCardMetrics.height + 37)

            Spacer(minLength: 34)
        }
        .frame(height: 312)
        .frame(maxWidth: .infinity)
        // 白色再向下多铺 34pt：即使系统仍把对齐点留在安全区上沿，
        // home indicator 那一条也已经是白色，不会再露出播放页深色底。
        .padding(.bottom, 34)
        .background(Color.white)
        .clipShape(PlayerThemeTopCorners(radius: 22))
    }

    /// 皮肤卡：缩略预览 + 选中蓝色高亮边框 + 底部居中名称。
    private func themeCard(_ theme: PlayerPageTheme) -> some View {
        let selected = theme == current
        return Button {
            onSelect(theme)
        } label: {
            VStack(spacing: 9) {
                PlayerThemeThumbnail(theme: theme)
                    .frame(width: PlayerThemeCardMetrics.width,
                           height: PlayerThemeCardMetrics.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // 白边 + 蓝框：酷狗是「缩略图外面 2~3pt 白边，再包一圈蓝框」。
                    .padding(3)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    // 🔴 2026-11-10 修复「选中蓝框顶部像被裁了」：用 strokeBorder，不能用 stroke。
                    //    stroke(lineWidth:2.5) 有 1.25pt 画在视图边界【外面】；卡片顶部紧贴
                    //    ScrollView 上沿，唯独顶部那半条边被 clip 掉（左右有 20pt padding、
                    //    底部有 34pt 富余所以没事）→ 视觉上只有上边框变细 / 圆角被削平。
                    //    strokeBorder 把描边完全画在边界内，四边等宽，绝不会被父级裁切。
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? PlayerThemeCardMetrics.blue : Color.clear,
                                          lineWidth: 2.5)
                    )
                Text(theme.cardTitle)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? PlayerThemeCardMetrics.blue
                                              : PlayerThemeCardMetrics.ink)
                    .lineLimit(1)
                    .frame(width: PlayerThemeCardMetrics.width + 6, alignment: .center)
            }
        }
        .buttonStyle(.plain)
    }

    /// 末尾「更多」占位卡：让横向滚动真的有内容可滑，也呼应酷狗的更多皮肤入口。
    private var moreCard: some View {
        Button(action: onMore) {
            VStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.95, green: 0.95, blue: 0.96))
                    Image(systemName: "plus")
                        .font(.system(size: 23, weight: .light))
                        .foregroundColor(PlayerThemeCardMetrics.muted)
                }
                .frame(width: PlayerThemeCardMetrics.width + 6,
                       height: PlayerThemeCardMetrics.height + 6)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("更多")
                    .font(.system(size: 13))
                    .foregroundColor(PlayerThemeCardMetrics.muted)
                    .frame(width: PlayerThemeCardMetrics.width + 6, alignment: .center)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 🔴 2026-11-10 修复「主题选择图片两边有空白、上面还有一层黑色的」：
/// 三张真机截图已在打包前按卡片精确比例 110:188（素材 500×854）裁好并去掉状态栏，
/// 这里只做 scaledToFill 单图铺满 —— 不再叠高斯模糊补边层（那层 opacity 0.55
/// 在浅色封面两侧就是两条发白的空档），也不会在顶部留下状态栏深色带。
private struct PlayerThemeThumbnail: View {
    let theme: PlayerPageTheme

    private var assetName: String {
        switch theme {
        case .immersiveCover: return "ThemePreviewImmersive"
        case .classic: return "ThemePreviewSquare"
        case .artistPhoto: return "ThemePreviewArtist"
        }
    }

    var body: some View {
        GeometryReader { geo in
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
    }
}


// MARK: - 🔴 2026-11-10 沉浸式封面主题专用：酷狗同款歌词页
//
// 版式照酷狗 20.8.4 歌词页真机截图：
//   顶栏 ∨ / 切换背景·分享 → 歌名与歌手居中带描边胶囊 →
//   居中大字歌词 → 收起箭头 → 竖屏播放器同款动作行 → 进度条（时间在条下方）→ 控件行。
// 只有 .immersiveCover 主题会走到这里；经典封面 / 歌手写真仍用 LyricsPageView。
// 全部图标用确定存在的 SF Symbol 或自绘 Shape，不赌不存在的符号名（项目红线）。

private enum KugouLyricsSheet: String, Identifiable {
    case share
    var id: String { rawValue }
}

struct KugouLyricsPage: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var lyricState = PlayerStore.shared.lyricState
    @ObservedObject private var playback = PlayerStore.shared.playback
    @ObservedObject private var soundEffect = SoundEffectSetting.shared
    @Binding var isShown: Bool
    var onEnterLandscape: (() -> Void)? = nil

    /// 沉浸模式：收起动作行 / 进度条 / 控件行，只留歌词与展开箭头。
    @State private var chromeHidden = false
    /// 歌词页是否叠歌手写真（默认关 = 酷狗的模糊纯色背景）；只在本页生效，不影响其它主题。
    @State private var showPhoto = false
    @State private var activeSheet: KugouLyricsSheet?
    @State private var shareItems: [Any] = []
    @State private var showMore = false
    /// 音效面板（与竖屏播放器动作行一致，点音效图标全屏打开）
    @State private var showSoundEffectPanel = false
    @State private var notice: String?
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    private var safeTop: CGFloat { max(44, PlayerView.safeAreaInsets.top + 6) }
    private var safeBottom: CGFloat { max(8, PlayerView.safeAreaInsets.bottom) }
    private var displayTime: Double { isScrubbing ? scrubValue : playback.currentTime }
    private var downloadDone: Bool {
        store.current.map { DownloadManager.shared.isDownloaded($0) } ?? false
    }

    var body: some View {
        GeometryReader { geo in
            let sz = geo.size
            ZStack {
                backdrop(size: sz)
                VStack(spacing: 0) {
                    topBar
                    songHeader
                        .padding(.top, 18)
                    BigLyricsView(lyrics: store.lyrics,
                                  currentIndex: lyricState.currentIndex,
                                  showsTranslation: store.showTranslation,
                                  playback: PlayerStore.shared.playback,
                                  isPlaying: store.isPlaying,
                                  liveTime: { store.lyricDisplayTime })
                        .frame(width: sz.width - 52)
                        .frame(maxHeight: .infinity)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    collapseButton
                        .padding(.bottom, 2)

                    if !chromeHidden {
                        actionRow
                            .padding(.horizontal, 22)
                            .padding(.bottom, 16)
                        progressBlock
                            .padding(.horizontal, 24)
                        KugouControlsRow()
                            .padding(.horizontal, 24)
                            .padding(.top, 6)
                    }

                    // 🔴 2026-11-10 用户要求「动作行、进度条、播放控件行往上移点」：
                    //    底部固定留 46pt 呼吸，三行整体上移，不再贴着 home 指示条。
                    //    用固定高度占位而不是改外层 padding：VStack 高度锁死、歌词区用
                    //    maxHeight:.infinity 吸收余量，占位只会压缩歌词区，不影响顶栏。
                    Color.clear.frame(height: 46)
                }
                .frame(width: sz.width, height: sz.height, alignment: .top)
                .padding(.bottom, safeBottom + 6)

                if let notice {
                    VStack {
                        Spacer()
                        Text(notice)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.black.opacity(0.42)))
                            .padding(.bottom, 170)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: sz.width, height: sz.height)
        }
        .ignoresSafeArea()
        .clipped()
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.22), value: chromeHidden)
        .animation(.easeInOut(duration: 0.22), value: notice)
        .modifier(LyricsStatusBarHider(hidden: chromeHidden))
        .sheet(item: $activeSheet) { _ in
            ShareSheet(items: shareItems)
        }
        .confirmationDialog("更多", isPresented: $showMore, titleVisibility: .visible) {
            Button("横屏播放器") { onEnterLandscape?() }
            Button("分享歌曲") { prepareShare(); activeSheet = .share }
            Button(store.showTranslation ? "关闭歌词翻译" : "开启歌词翻译") {
                store.showTranslation.toggle()
            }
            Button("歌词延后 0.5 秒") { store.adjustLyricOffset(by: 0.5) }
            Button("歌词提前 0.5 秒") { store.adjustLyricOffset(by: -0.5) }
            Button("歌词对齐重置") { store.resetLyricOffset() }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: notice) { text in
            guard text != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { notice = nil }
        }
        .onChange(of: chromeHidden) { hidden in
            IdleTimerKeeper.shared.set("kugou-lyrics-immersive", hidden)
        }
        .onDisappear {
            IdleTimerKeeper.shared.set("kugou-lyrics-immersive", false)
        }
    }

    // MARK: 背景：封面全屏高斯模糊 + 冷蓝灰渐层（酷狗歌词页观感）
    private func backdrop(size: CGSize) -> some View {
        ZStack {
            if let art = store.artwork {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .blur(radius: 44)
                    .opacity(0.72)
            } else {
                Image("LyricsFallback")
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
            if showPhoto {
                ArtistPhotoBackdrop(artist: store.current?.artist ?? "",
                                    title: store.current?.title ?? "",
                                    hash: store.current?.kugouHash ?? "")
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .opacity(0.85)
            }
            LinearGradient(colors: [Color(red: 0.42, green: 0.44, blue: 0.50).opacity(0.42),
                                    Color(red: 0.27, green: 0.31, blue: 0.42).opacity(0.56),
                                    Color(red: 0.12, green: 0.16, blue: 0.29).opacity(0.82),
                                    Color(red: 0.07, green: 0.10, blue: 0.20).opacity(0.94)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .allowsHitTesting(false)
    }

    // MARK: 顶栏：∨ / 切换背景 · 分享
    // 🔴 2026-11-10 用户要求移除「顶部 4 个点」和「搜索」：分页点与放大镜全部删掉，
    //    左侧收起、右侧只留切换背景 + 分享两个按钮。
    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                Button { showPhoto.toggle(); flash(showPhoto ? "已开启歌手写真背景" : "已切回封面氛围背景") } label: {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 18, weight: .light))
                        .frame(width: 34, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { prepareShare(); activeSheet = .share } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 19, weight: .light))
                        .frame(width: 34, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 18)
        .padding(.top, safeTop)
    }

    // MARK: 歌名 + 歌手 + 描边胶囊（居中，酷狗同款）
    private var songHeader: some View {
        VStack(spacing: 9) {
            Text(store.current?.title ?? "未在播放")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(store.current?.artist ?? "未知歌手")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                tag("VIP")
                tag(SourceStore.shared.quality.title)
                if let current = store.current,
                   current.source == .local || DownloadManager.shared.item(for: current)?.isDone == true {
                    tag("本地")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3)
                .stroke(.white.opacity(0.32), lineWidth: 0.8))
    }

    // MARK: 收起 / 展开控件
    private var collapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { chromeHidden.toggle() }
            Haptics.light()
        } label: {
            Image(systemName: chromeHidden ? "chevron.up" : "chevron.down")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 动作行：与竖屏播放器完全一致（喜欢 / 下载 / 音效 / 歌词 / 更多）
    // 🔴 2026-11-10 用户要求「歌词页动作行改和竖屏播放器的一样」：
    //    换成 classicActionRow 同一套 PlayerActionIcon（24pt 自绘图标、44×44 命中区、
    //    整行均分），不再用歌词页原来那套酷狗细线小图标（词/星框/伴/心/气泡/三点）。
    private var actionRow: some View {
        // 保持订阅：切预设 / 总开关后 OFF·ON 角标立即刷新
        _ = soundEffect.current
        return HStack(spacing: 0) {
            Button {
                store.toggleFavorite()
                Haptics.light()
            } label: {
                PlayerActionIcon(glyph: .favorite,
                                 active: store.isLiked,
                                 tint: store.isLiked ? AppStyle.like : .white,
                                 size: 24)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .offset(y: -2)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { downloadCurrent() } label: {
                PlayerActionIcon(glyph: downloadDone ? .downloaded : .download, size: 24)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { showSoundEffectPanel = true; Haptics.light() } label: {
                PlayerActionIcon(glyph: .soundEffect, size: 24,
                                 soundEffectOn: soundEffect.current != .off)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // 歌词页里「歌词」图标改为切换翻译（竖屏播放器里它是打开歌词页）
            Button {
                store.showTranslation.toggle()
                flash(store.showTranslation ? "已开启歌词翻译" : "已关闭歌词翻译")
            } label: {
                PlayerActionIcon(glyph: .lyric, size: 24)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { showMore = true; Haptics.light() } label: {
                PlayerActionIcon(glyph: .more, size: 24)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .fullScreenCover(isPresented: $showSoundEffectPanel) {
            SoundEffectPanel()
        }
    }

    /// 下载当前歌曲（与竖屏播放器 download() 同逻辑，提示走歌词页自己的 toast）。
    private func downloadCurrent() {
        guard let song = store.current, song.isRemote else { return flash("本地音频不用下载") }
        if DownloadManager.shared.isDownloaded(song) {
            flash("已经在下载列表里了")
            return
        }
        Task {
            do {
                _ = try await DownloadManager.shared.download(song)
                await MainActor.run { flash("下载完成") }
            } catch {
                await MainActor.run { flash(error.localizedDescription) }
            }
        }
    }

    // MARK: 进度条：细白线 + 常显定位点，时间文字在条【下方】两端
    private var progressBlock: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let pf = max(0, min(1, playback.progress))
                let bf = max(0, min(1, playback.bufferedFraction))
                let px = pf * w
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.30)).frame(height: 2.5)
                    Capsule().fill(.white.opacity(0.42)).frame(width: bf * w, height: 2.5)
                    Capsule().fill(.white.opacity(0.95)).frame(width: px, height: 2.5)
                    Circle().fill(.white)
                        .frame(width: isScrubbing ? 13 : 9, height: isScrubbing ? 13 : 9)
                        .offset(x: px - (isScrubbing ? 6.5 : 4.5))
                        .shadow(color: .black.opacity(0.35), radius: 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard playback.duration > 0, w > 0 else { return }
                        if !isScrubbing {
                            isScrubbing = true
                            scrubValue = playback.currentTime
                        }
                        scrubValue = min(1, max(0, v.location.x / w)) * playback.duration
                    }
                    .onEnded { _ in
                        store.seek(to: scrubValue)
                        isScrubbing = false
                    })
            }
            .frame(height: 24)

            HStack {
                Text(displayTime.clockString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
                Text(playback.duration.clockString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func prepareShare() {
        guard let song = store.current else { return }
        var items: [Any] = []
        if !song.kugouHash.isEmpty,
           let url = URL(string: "https://www.kugou.com/song/#\(song.kugouHash)") {
            items.append(url)
        } else {
            items.append("\(song.title) - \(song.artist)")
        }
        if let art = store.artwork { items.append(art) }
        shareItems = items
    }

    private func flash(_ text: String) {
        notice = text
        Haptics.light()
    }
}
