import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var store: PlayerStore
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
    /// 音质切换弹层
    /// 「更多」弹层：音质档位 / 完整歌词 / 歌词翻译
    @State private var showMoreMenu = false
    @AppStorage("aurora.playerTheme") private var playerTheme: String = "glitter"
    @State private var vinylStart: Date = Date()
    @State private var dominantColor: Color = .white

    /// 参数顺序必须与属性声明顺序一致：playback / lyricState 在 isExpanded 之前。
    init(playback: PlaybackProgress, lyricState: LyricState, isExpanded: Binding<Bool>) {
        self.playback = playback
        self.lyricState = lyricState
        self._isExpanded = isExpanded
    }

    private enum Theme: String {
        case vinyl, classic
        /// 炫胶唱片：黑胶版式 + 炫彩高光盘面
        case glitter
    }
    private var currentTheme: Theme { Theme(rawValue: playerTheme) ?? .classic }

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
                    LyricsPageView(isShown: $isLyricsPage)
                        .environmentObject(store)
                        .transition(.opacity)
                        .zIndex(10)
                } else if isLandscape {
                    // 横屏播放器：右上角按钮强制旋转后接管（唱片在左、信息在右）
                    landscapeBody()
                } else {
                    // 经典/黑胶沿用取色渐变背景；炫胶自带全屏背景
                    switch currentTheme {
                    case .classic:
                        immersiveBackground.ignoresSafeArea()
                        classicBody(in: contentHeight, win: win, screen: screen)
                    case .vinyl:
                        immersiveBackground.ignoresSafeArea()
                        vinylBody(in: contentHeight, win: win, screen: screen)
                    case .glitter:    glitterBody(in: contentHeight, win: win, screen: screen)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            // 🔴 仅竖屏播放页允许「下滑关闭整个播放器」；歌词页 / 横屏播放器改用各自的
            // 左上角返回按钮（用户要求移除下滑关闭）。否则下滑手势会和歌词页按钮 / 横屏
            // 返回键抢手势，且歌词页下滑会把整页播放器一起 dismiss。
            .gesture((!isLyricsPage && !isLandscape) ? dragGesture : nil)
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
            UIApplication.shared.isIdleTimerDisabled = isLandscape
        }
        // 🔴 横屏播放器时隐藏系统状态栏（沉浸播放）；退出横屏自动恢复。
        // 🔴 加 !isLyricsPage：从横屏进歌词页时 isLandscapePlayer 不会置回 false，isLandscape 仍为 true，
        // 若不排除会把竖屏歌词页的状态栏也误藏。歌词页自己管理 safeTop。
        .modifier(LandscapeStatusBarHider(hidden: isLandscape && !isLyricsPage,
                                          hideHomeIndicator: isLandscape && !isLyricsPage && !landscapeChromeVisible))
        // 🔴 关闭播放页时恢复竖屏 + 恢复自动熄屏（避免退出后整 App 卡横屏/永远不熄屏）
        .onDisappear {
            OrientationLock.shared.resetToPortrait()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // 🔴 播放列表 sheet：必须挂在播放页自己身上。此前只挂在 RootView 迷你条上，
        // 它在播放页 fullScreenCover 之下 —— 播放页打开时 sheet 弹不出来（点了没反应）。
        .queueSheet()
    }

    /// 酷狗黑胶（当前默认）：黑胶封面 + 信息堆叠 + Spacer 推控制到底
    private func vinylBody(in contentHeight: CGFloat,
                           win: (size: CGSize, safeTop: CGFloat, safeBottom: CGFloat),
                           screen: CGRect) -> some View {
        VStack(spacing: 0) {
            topBar()
            artworkStage(in: CGSize(width: screen.width, height: contentHeight))
            meta(width: screen.width)
        }
        .frame(width: screen.width, height: contentHeight, alignment: .top)
        .padding(.top, win.safeTop)
        .clipped()
    }

    // MARK: - 炫胶唱片（暖金渐变 + 巨大炫彩唱片 + 底部暗区信息，对齐酷狗版式）

    /// 炫胶背景：取色渐变铺满（底段用封面暗色而非近黑），顶部微压、底部轻收
    private var glitterBackground: some View {
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

    private func glitterBody(in contentHeight: CGFloat,
                             win: (size: CGSize, safeTop: CGFloat, safeBottom: CGFloat),
                             screen: CGRect) -> some View {
        ZStack(alignment: .top) {
            glitterBackground

            VStack(spacing: 0) {
                topBar()
                    .frame(height: 44)
                    .padding(.top, win.safeTop)

                // 主视觉：巨大炫彩唱片（酷狗实测约占屏宽 80%）
                glitterDiscArea(width: screen.width)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 8)

                // 底部暗区信息：歌词 + 动作行 + 进度 + 控件
                meta(width: screen.width)
            }
            .frame(width: screen.width, height: contentHeight, alignment: .top)
        }
        .frame(width: screen.width, height: screen.height, alignment: .top)
        .clipped()
    }

    private func glitterDiscArea(width: CGFloat) -> some View {
        let side = max(250, min(width * 0.80, 330))
        let coverSide = side * 0.44

        return TimelineView(.animation(minimumInterval: 1/30)) { _ in
            let angle = isSpinning
                ? (Date().timeIntervalSince(vinylStart) / 20.0) * 360
                : 0
            ZStack {
                glitterDisc(side: side)

                Group {
                    if let artwork = store.artwork {
                        Image(uiImage: artwork).resizable().scaledToFill()
                    } else {
                        ZStack {
                            LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.3)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "music.note")
                                .font(.system(size: coverSide * 0.3, weight: .light))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                .frame(width: coverSide, height: coverSide)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 2))
                .overlay(alignment: .center) {
                    Circle()
                        .fill(.white.opacity(0.92))
                        .frame(width: 10, height: 10)
                }
            }
            .rotationEffect(.degrees(angle))
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onChange(of: store.isPlaying) { playing in
            if playing { vinylStart = Date() }
        }
        .onChange(of: store.currentIndex) { _ in
            vinylStart = Date()
            extractDominantColor()
        }
        .onAppear { extractDominantColor() }
    }

    /// 炫胶盘面：亮银底盘 + 彩虹角向炫彩 + 强白光扫过 + 细沟槽
    /// （酷狗炫胶是亮色炫彩盘面，不是黑胶的深黑盘）
    private func glitterDisc(side: CGFloat) -> some View {
        ZStack {
            // 亮银底盘
            Circle()
                .fill(RadialGradient(colors: [.white,
                                              Color(white: 0.90),
                                              Color(white: 0.74)],
                                     center: .center,
                                     startRadius: side * 0.05,
                                     endRadius: side * 0.52))

            // 彩虹角向炫彩
            Circle()
                .fill(AngularGradient(colors: [
                    Color(red: 1.00, green: 0.30, blue: 0.45),
                    Color(red: 1.00, green: 0.80, blue: 0.25),
                    Color(red: 0.25, green: 0.90, blue: 0.60),
                    Color(red: 0.25, green: 0.60, blue: 1.00),
                    Color(red: 0.75, green: 0.35, blue: 1.00),
                    Color(red: 1.00, green: 0.30, blue: 0.45)
                ], center: .center))
                .opacity(0.42)

            // 白色高光扫光
            Circle()
                .fill(AngularGradient(colors: [.clear,
                                               .white.opacity(0.85),
                                               .clear,
                                               .white.opacity(0.45),
                                               .clear],
                                      center: .center))

            // 唱片沟槽
            ForEach(0..<9, id: \.self) { i in
                Circle()
                    .stroke(.black.opacity(0.05), lineWidth: 1)
                    .frame(width: side - CGFloat(i) * (side / 12),
                           height: side - CGFloat(i) * (side / 12))
            }

            // 外圈金属边
            Circle()
                .stroke(LinearGradient(colors: [.white.opacity(0.9),
                                                .black.opacity(0.15),
                                                .white.opacity(0.7),
                                                .black.opacity(0.12)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 2.5)
                .frame(width: side - 2, height: side - 2)

            // 中心挖空（放专辑封面）
            Circle()
                .fill(.clear)
                .frame(width: side * 0.44, height: side * 0.44)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: side, height: side)
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
        .padding(.top, win.safeTop)                          // 整块下移到状态栏下方
        .frame(width: screen.width, height: screen.height, alignment: .top)  // 铺满全屏、顶对齐
        .clipped()
    }

    private var classicHeaderBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { animateOut() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }

            // 🔴 居中：歌名 + 歌手同一行（用户要求改在一行显示）
            HStack(alignment: .center, spacing: 6) {
                Text(store.current?.title ?? "未在播放")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(store.current?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)

            Button { toggleLandscape() } label: {
                LandscapeToggleIcon()
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 10)
    }

    // MARK: 封面区：专辑封面方图（弹性填充，歌词已移到底部 deck）

    // MARK: 封面区：专辑封面方图（点进歌词页）+ 左右滑切歌；歌词已移到底部 deck
    private var classicCoverArea: some View {
        // 🔴 用 GeometryReader 实测剩余空间，封面随容器自适应（deck 内容高度变化也不会互相挤压/裁切）。
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            // 🔴 封面改大：占可用高度 66%、屏宽 82%；圆角改小（classicCoverArt 内 side*0.04）。
            let side = max(180, min(h * 0.66, w * 0.82))

            VStack(spacing: 0) {
                classicCoverArt(side: side)
                    .offset(x: classicSwipeOffset)
                    .opacity(CGFloat(1) - min(abs(classicSwipeOffset) / 260, 0.35))
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: classicSwipeOffset)
                    .padding(.top, 10)   // 🔴 封面上移：贴顶（留 10pt 呼吸），下方留白由 Spacer 吸收
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
            .clipShape(RoundedRectangle(cornerRadius: side * 0.04, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.04, style: .continuous)
                    .stroke(.white.opacity(0.28), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
    }

    /// 经典主题动作行：与炫胶/黑胶一致，酷狗同款四项（喜欢 / 下载 / 评论 / 更多）
    private var classicActionRow: some View {
        HStack(spacing: 28) {  // 🔴 间距加大到 28
            // ① 喜欢（激活时实心红心）
            classicActionButton(glyph: .favorite,
                                label: "喜欢",
                                active: store.isLiked,
                                tint: store.isLiked ? AppStyle.like : .white) {
                store.toggleFavorite()
            }
            // ② 下载
            classicActionButton(glyph: .download, label: "下载") {
                if let song = store.current {
                    Task { _ = try? await DownloadManager.shared.download(song) }
                }
            }
            // ③ 评论
            classicActionButton(glyph: .comment, label: "评论") { openComments() }
            // ④ 更多（音质 / 完整歌词 / 歌词翻译）
            classicActionButton(glyph: .more, label: "更多") { showMoreMenu = true }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("更多", isPresented: $showMoreMenu, titleVisibility: .visible) {
            ForEach(MusicQuality.allCases) { q in
                Button(q == SourceStore.shared.quality ? "✓ \(q.title)音质" : "\(q.title)音质") {
                    if q != SourceStore.shared.quality {
                        SourceStore.shared.quality = q
                        show("已切换到\(q.title)")
                    }
                }
            }
            Button("完整歌词") { openLyricsPage() }
            Button(store.showTranslation ? "关闭歌词翻译" : "开启歌词翻译") {
                store.showTranslation.toggle()
                Haptics.light()
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 经典主题动作按钮：同样走自绘图标集，与炫胶/黑胶动作行风格一致
    private func classicActionButton(glyph: PlayerActionGlyph,
                                     label: String,
                                     active: Bool = false,
                                     tint: Color = .white,
                                     action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.light() } label: {
            VStack(spacing: 4) {
                PlayerActionIcon(glyph: glyph, active: active, tint: tint, size: 22)
                    .frame(width: 44, height: 44)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
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

    private var classicDeck: some View {
        VStack(spacing: 4) {
            // 🔴 歌词移到动作行上方：白色 + 卡拉OK逐字（用户要求"改在动作行上方显示"）
            lyricPill()
                .padding(.bottom, 2)

            // 进度条上面一行：下载 / 收藏 / 评论 / 更多
            classicActionRow
                .padding(.top, 2)
                .padding(.bottom, 2)

            classicProgressBlock
                .frame(height: 50)

            classicDeckControls
                .frame(height: 56)
        }
        .padding(.horizontal, 15)
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

    // MARK: 控件行：循环 ← 上一曲/播放/下一曲 → 队列（Beans deckRow 复刻）

    private var classicDeckControls: some View {
        ZStack {
            // 两侧：循环 / 队列
            HStack {
                classicModeButton
                Spacer(minLength: 0)
                classicQueueButton
            }

            // 中间三个：上一曲 / 播放暂停 / 下一曲
            HStack(spacing: 18) {
                classicPrevNextButton(icon: "backward.fill") { store.step(-1) }
                classicPlayPauseButton
                classicPrevNextButton(icon: "forward.fill") { store.step(1) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
    }

    /// 模式按钮（玻璃圆底，激活=dominantColor）
    private var classicModeButton: some View {
        let icon: String
        let active: Bool
        switch store.mode {
        case .shuffle: icon = "shuffle"; active = true
        case .single:  icon = "repeat.1"; active = true
        case .order:   icon = "arrow.right"; active = false
        }
        return Button { store.cycleMode(); Haptics.light() } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? dominantColor : .white.opacity(0.75))
                .frame(width: 36, height: 36)
                .background { classicButtonSurface(size: 36, active: active) }
        }
        .buttonStyle(.plain)
    }

    /// 队列按钮（玻璃圆底）
    private var classicQueueButton: some View {
        Button { store.isQueuePresented.toggle(); Haptics.light() } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(store.isQueuePresented ? dominantColor : .white.opacity(0.75))
                .frame(width: 36, height: 36)
                .background { classicButtonSurface(size: 36, active: store.isQueuePresented) }
        }
        .buttonStyle(.plain)
    }

    /// 上一曲/下一曲：玻璃圆底 + dominantColor icon（🔴 着色！）
    private func classicPrevNextButton(icon: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.light() } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(dominantColor)
                .frame(width: 44, height: 44)
                .background { classicButtonSurface(size: 44) }
        }
        .buttonStyle(.plain)
    }

    /// 播放暂停：渐变填充圆 + 玻璃描边 + 播放时 dominantColor 发光 shadow
    private var classicPlayPauseButton: some View {
        Button { store.toggle(); Haptics.soft() } label: {
            ZStack {
                // 渐变填充圆
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [dominantColor.opacity(0.82),
                                     dominantColor.opacity(0.52)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1)
                    }
                    .shadow(color: dominantColor.opacity(0.55),
                            radius: store.isPlaying ? 22 : 12, y: 0)

                if store.isLoading || store.isBuffering {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: store.isPlaying ? 0 : 2)
                }
            }
            .frame(width: 62, height: 62)
        }
        .buttonStyle(.plain)
    }

    /// 玻璃按钮底：半透明圆 + active 时 dominantColor 描边
    private func classicButtonSurface(size: CGFloat, active: Bool = false) -> some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))
            Circle()
                .strokeBorder(
                    active ? dominantColor.opacity(0.52) : .white.opacity(0.18),
                    lineWidth: 0.8
                )
        }
        .frame(width: size, height: size)
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

    // MARK: - 封面（黑胶 or 普通圆角矩形，由 playerTheme 控制）

    private func artworkStage(in size: CGSize) -> some View {
        let targetHeight = size.height * 0.44
        return Group {
            if currentTheme == .vinyl {
                vinylArtwork(width: size.width, height: targetHeight)
            } else if currentTheme == .glitter {
                vinylArtwork(width: size.width, height: targetHeight, glitter: true)
            } else {
                roundedArtwork(width: size.width, height: targetHeight)
            }
        }
        .frame(maxWidth: .infinity, minHeight: targetHeight, idealHeight: targetHeight, maxHeight: targetHeight)
        .animation(.easeInOut(duration: 0.4), value: store.currentIndex)
        .animation(.easeInOut(duration: 0.3), value: playerTheme)
    }

    /// 黑胶版：TimelineView(.animation) 每帧驱动旋转，黑胶盘+封面一起转
    private func vinylArtwork(width: CGFloat, height: CGFloat, glitter: Bool = false) -> some View {
        // 封面尺寸：屏宽的 65%，最小 220 最大 300 — 和 stage 高度无关
        // 之前用 height * 0.38（整屏高度的 38%）→ 封面太大，挤占 meta 空间
        let vinylSide = max(220, min(width * 0.65, 300))
        let coverSide = vinylSide * 0.56

        return TimelineView(.animation(minimumInterval: 1/30)) { timeline in
            let angle = isSpinning
                ? (Date().timeIntervalSince(vinylStart) / 20.0) * 360
                : 0
            ZStack {
                vinylDisc(side: vinylSide, glitter: glitter)

                Group {
                    if let artwork = store.artwork {
                        Image(uiImage: artwork).resizable().scaledToFill()
                    } else {
                        ZStack {
                            LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.3)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "music.note")
                                .font(.system(size: coverSide * 0.3, weight: .light))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                .frame(width: coverSide, height: coverSide)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1.5))
                .overlay(alignment: .center) {
                    Circle()
                        .fill(.black.opacity(0.8))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 0.5))
                }
            }
            .rotationEffect(.degrees(angle))
        }
        .frame(width: vinylSide, height: vinylSide)
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .onChange(of: store.isPlaying) { playing in
            if playing { vinylStart = Date() }
        }
        .onChange(of: store.currentIndex) { _ in
            vinylStart = Date()
            extractDominantColor()
        }
        .onAppear { extractDominantColor() }
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

    /// 黑胶盘纹理：多层同心圆环 + 高光
    private func vinylDisc(side: CGFloat, glitter: Bool = false) -> some View {
        ZStack {
            // 底盘：深黑色
            Circle()
                .fill(LinearGradient(colors: [.black, .black.opacity(0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            // 唱针高光（顶部弧形反光）
            Circle()
                .fill(AngularGradient(colors: [
                    .clear,
                    .white.opacity(0.06),
                    .clear,
                    .white.opacity(0.04),
                    .clear
                ], center: .center))

            // 唱片纹理环（用 stroke 画多层同心圆）
            ForEach(0..<8, id: \.self) { i in
                Circle()
                    .stroke(.white.opacity(0.04), lineWidth: 1)
                    .frame(width: side - CGFloat(i) * (side / 14),
                           height: side - CGFloat(i) * (side / 14))
            }

            // 外圈金属质感边框
            Circle()
                .stroke(LinearGradient(colors: [
                    .white.opacity(0.3),
                    .white.opacity(0.05),
                    .white.opacity(0.25),
                    .white.opacity(0.05)
                ], startPoint: .top, endPoint: .bottom),
                        lineWidth: 2)
                .frame(width: side - 2, height: side - 2)

            // 炫胶高光：彩虹角向渐变 + 强 specular（仅炫胶唱片主题）
            if glitter {
                Circle()
                    .fill(AngularGradient(colors: [
                        Color(red: 1.00, green: 0.25, blue: 0.45),
                        Color(red: 1.00, green: 0.85, blue: 0.30),
                        Color(red: 0.30, green: 0.95, blue: 0.65),
                        Color(red: 0.30, green: 0.55, blue: 1.00),
                        Color(red: 0.80, green: 0.35, blue: 1.00),
                        Color(red: 1.00, green: 0.25, blue: 0.45)
                    ], center: .center))
                    .opacity(0.30)
                    .blendMode(.screen)

                Circle()
                    .fill(AngularGradient(colors: [
                        .clear, .white.opacity(0.55), .clear,
                        .white.opacity(0.25), .clear
                    ], center: .center))
                    .opacity(0.8)
                    .blendMode(.screen)
            }

            // 中心挖空（放专辑封面）
            Circle()
                .fill(.clear)
                .frame(width: side * 0.56, height: side * 0.56)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: side, height: side)
    }

    private var isSpinning: Bool { store.isPlaying && !store.isLoading && !store.isBuffering }

    // MARK: - 横屏播放器（参考酷狗：右上角「横屏」按钮进入）

    /// 进入/退出横屏播放器的切换：由顶栏的「横屏」按钮调用。
    private func toggleLandscape() {
        if OrientationLock.shared.isLandscapePlayer {
            OrientationLock.shared.exitLandscape()
            isLandscape = false
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            OrientationLock.shared.enterLandscape()
            // 🔴 立即置 isLandscape = true（由方向锁权威驱动），不等方向通知 ——
            // 强制旋转瞬间通知是滞后的，等它会把横屏当成竖屏布局而裁切。
            isLandscape = true
            // 浮层（关闭按钮 + 底部横条）默认隐藏，点击屏幕显出
            landscapeChromeVisible = false
            // 横屏播放屏幕常亮
            UIApplication.shared.isIdleTimerDisabled = true
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
            // 背景跟随主题（经典/黑胶取色渐变；炫胶自带全屏炫彩）
            // 🔴 用户要求"参考炫胶唱片主题的横屏"：横屏背景统一用炫胶的纯取色渐变。
            // 经典原先在横屏用 immersiveBackground（多一层 0.38 模糊封面图），实测会导致
            // 右列信息区显示异常/对比度糊掉，故横屏一律改用无模糊图的 glitterBackground。
            glitterBackground
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { landscapeChromeVisible.toggle() }
            }

            HStack(spacing: 0) {
                // 左：大封面（垂直居中，约占屏宽 44%）
                discViewForLandscape(maxSide: min(size.height - insets.top - insets.bottom - 24,
                                                  size.width * 0.44))
                    .frame(maxWidth: size.width * 0.46, maxHeight: .infinity)

                // 右：信息列
                VStack(alignment: .leading, spacing: 0) {
                    landscapeTitleRow
                    landscapeLyricsBlock
                        .padding(.top, 16)
                    Spacer(minLength: 10)
                    progressSection()
                        .padding(.horizontal, 2)
                    landscapeControls()
                        .padding(.top, 10)
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
        // 🔴 顶栏浮层用 overlay(alignment:.top) 钉在顶部：
        // - 放 ZStack 里不带 alignment 会被居中（实测关闭按钮浮在唱片中间）；
        // - 带全屏 frame 又可能吞下方触摸；
        // overlay 只在自身内容处可点击，两个问题都没有。
        // 🔴 顶栏（关闭按钮）改为始终可见：用户反馈"退出按钮有时能按到有时按不到"，
        // 旧逻辑默认隐藏、要点空白处才弹出，容易点不到。现在常驻，稳定可点。
        .overlay(alignment: .top) {
            landscapeTopBar(insets: insets)
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
                UIApplication.shared.isIdleTimerDisabled = false
                Haptics.light()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            }
            // 🔴 显式命中区 + contentShape：保证 44×44 全覆盖可点（不受图标自身 bounds 限制）
            .contentShape(Rectangle())
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .frame(height: 44)
        .padding(.top, max(insets.top, 10) + 14)
        .padding(.leading, insets.left + 14)
        .padding(.trailing, insets.right + 8)
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

    /// 横屏控制键单排（酷狗式）：收藏 / 上一首 / 播放 / 下一首 / 列表
    /// （退出只保留左上角一处 —— 用户要求移除收藏旁的关闭按钮）
    private func landscapeControls() -> some View {
        HStack(spacing: 0) {
            Button {
                store.toggleFavorite()
                Haptics.light()
            } label: {
                Image(systemName: store.isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 22))
                    .foregroundStyle(store.isLiked ? AppStyle.like : .white)
                    .frame(width: 44, height: 48)
            }

            Spacer(minLength: 0)

            Button { store.step(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 48)
                    .background(Circle().fill(.white.opacity(0.16)))
            }

            Spacer(minLength: 0)

            PlayButton()

            Spacer(minLength: 0)

            Button { store.step(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 48)
                    .background(Circle().fill(.white.opacity(0.16)))
            }

            Spacer(minLength: 0)

            Button {
                // 「词」改「列表」：点击弹出播放列表（酷狗横屏同款）
                store.isQueuePresented = true
                Haptics.light()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 48)
            }
        }
        .buttonStyle(.plain)
    }

    /// 横屏下的唱片：跟随主题选择黑胶 / 炫胶 / 普通圆角封面。
    /// 🔴 glitterDiscArea 内部会再乘 0.80（竖屏版式），横屏要"左大封面"，
    /// 传入 maxSide/0.8 抵消这个二次缩小，让唱片真正用满给定的 maxSide。
    @ViewBuilder
    private func discViewForLandscape(maxSide: CGFloat) -> some View {
        switch currentTheme {
        case .glitter:
            glitterDiscArea(width: maxSide / 0.8)
        case .vinyl:
            vinylArtwork(width: maxSide, height: maxSide)
        case .classic:
            // 横屏封面改大：ratio 0.82、上限 340（竖屏仍用默认 0.65/300，不受影响）
            roundedArtwork(width: maxSide, height: maxSide, ratio: 0.82, maxCap: 340)
        }
    }

    // MARK: - 顶栏

    private func topBar() -> some View {
        HStack(spacing: 0) {
            Button { animateOut() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }

            // 歌名 + 歌手同一行（用户要求改在一行显示）
            HStack(alignment: .center, spacing: 6) {
                Text(store.current?.title ?? "未播放")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(store.current?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)

            Button { toggleLandscape() } label: {
                LandscapeToggleIcon()
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
        }
        // 关闭 / 横屏 按钮同为 40×40 圆形底，图标齐平
        .frame(height: 44)
        .foregroundStyle(.white)
    }

    /// 顶栏中间显示的专辑名（优先歌曲专辑，fallback 源名）
    private var albumDisplay: String {
        if let album = store.current?.album, !album.isEmpty { return album }
        return store.sourceName.isEmpty ? "在线播放" : store.sourceName
    }

    /// 音质徽标：紧跟在歌手后面
    private var qualityPill: some View {
        HStack(spacing: 3) {
            if store.isLoading {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8, weight: .bold))
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(qualityText)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(AppStyle.gold.opacity(0.22), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(AppStyle.gold.opacity(0.45), lineWidth: 0.5))
    }

    private var qualityText: String {
        if store.isBuffering { return "缓冲中" }
        if store.isLoading { return "解析中" }
        if store.playbackError != nil { return "无法播放" }
        return store.bitrateLabel.isEmpty ? SourceStore.shared.quality.title : store.bitrateLabel
    }

    // MARK: - 信息区

    private func meta(width: CGFloat) -> some View {
        // VStack 外层 frame height = contentHeight（已扣 safeTop+safeBottom），
        // 底部正好在 home indicator 顶部。Spacer 在最前，把 歌词+动作行+进度+控件
        // 整块推到底部：信息区紧贴播放控件上方（用户要求酷狗黑胶版式）。
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            lyricPill()

            actionRow()
                .padding(.top, 18)

            progressSection()
                .padding(.top, 20)
                .padding(.horizontal, 15)

            controls()
                .padding(.top, 14)
        }
        .frame(width: width - 36, alignment: .leading)
        .padding(.bottom, 2)
        .layoutPriority(1)
    }

    private func tagRow() -> some View {
        HStack(spacing: 8) {
            Button {
                if let song = store.current {
                    NotificationCenter.default.post(name: .navigateToArtist, object: song)
                }
            } label: {
                HStack(spacing: 3) {
                    Text(store.current?.artist ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 120, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .buttonStyle(.plain)

            if let album = store.current?.album, !album.isEmpty {
                Text("·")
                    .foregroundStyle(.white.opacity(0.4))
                Text(album)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    /// 双行歌词 —— 已拆到独立子视图 LyricPill（见其注释）：
    /// 歌词高亮 + 进度的 4fps 订阅收进小块，不再整树重建。
    private func lyricPill() -> some View {
        LyricPill(onOpen: { openLyricsPage() })
    }

    /// 酷狗同款动作行：喜欢 / 下载 / 评论 / 更多
    /// 🔴 音质与歌词入口挪进「更多」弹层（歌词区本身点一下也能进歌词页）
    private func actionRow() -> some View {
        HStack(spacing: 35) {
            actionButton(glyph: .favorite,
                         label: "喜欢",
                         active: store.isLiked,
                         tint: store.isLiked ? AppStyle.like : .white) {
                store.toggleFavorite()
            }
            actionButton(glyph: .download, label: downloadLabel) { download() }
            actionButton(glyph: .comment, label: "评论") { openComments() }
            actionButton(glyph: .more, label: "更多") { showMoreMenu = true }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("更多", isPresented: $showMoreMenu, titleVisibility: .visible) {
            ForEach(MusicQuality.allCases) { q in
                Button(q == SourceStore.shared.quality ? "✓ \(q.title)音质" : "\(q.title)音质") {
                    if q != SourceStore.shared.quality {
                        SourceStore.shared.quality = q
                        show("已切换到\(q.title)")
                    }
                }
            }
            Button("完整歌词") { openLyricsPage() }
            Button(store.showTranslation ? "关闭歌词翻译" : "开启歌词翻译") {
                store.showTranslation.toggle()
                Haptics.light()
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 评论：跳到酷狗该歌曲/专辑的 Web 页（与经典主题一致）
    private func openComments() {
        guard let song = store.current else { return }
        let albumID = song.kugouAlbumID
        let hash = song.kugouHash
        if !albumID.isEmpty {
            if let url = URL(string: "https://www.kugou.com/album/\(albumID).html") { UIApplication.shared.open(url) }
        } else if !hash.isEmpty {
            if let url = URL(string: "https://www.kugou.com/song/#\(hash)") { UIApplication.shared.open(url) }
        }
    }

    private var modeLabel: String {
        switch store.mode {
        case .order: return "顺序"
        case .single: return "单曲"
        case .shuffle: return "随机"
        }
    }

    private var downloadLabel: String {
        guard let song = store.current else { return "下载" }
        if let item = DownloadManager.shared.item(for: song), item.state.isActive {
            return "\(Int(item.progress * 100))%"
        }
        return DownloadManager.shared.isDownloaded(song) ? "已下" : "下载"
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

    // MARK: - 控制

    private func controls() -> some View {
        HStack(spacing: 0) {
            Button { store.cycleMode() } label: {
                Image(systemName: store.mode.icon)
                    .font(.system(size: 20))
                    .frame(width: 44, height: 56)
            }

            Spacer(minLength: 0)

            Button { store.step(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
            }

            Spacer(minLength: 0)

            PlayButton()

            Spacer(minLength: 0)

            Button { store.step(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
            }

            Spacer(minLength: 0)

            Button { store.isQueuePresented = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 56)
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        // controls 在 meta VStack 里，meta 已有 16pt bottom padding
        // 不需要再加 safeBottom，SwiftUI 自动处理
    }

    // MARK: - 反馈

    @ViewBuilder
    private var toastLayer: some View {
        if let message = showToast ?? store.playbackError {
            Text(message)
                .font(.system(size: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 40)
                .transition(.opacity)
        }
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
        ZStack {
            // 横放手机轮廓（提示旋转后的目标姿态）
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: 13, height: 9.5)
            // 环绕手机的顺时针旋转弧线（留 1/4 缺口给箭头）
            Circle()
                .trim(from: 0.04, to: 0.76)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 20, height: 20)
            // 弧线末端三角箭头（顺时针切向：顶部处朝右）
            ArrowTipShape()
                .fill(.white)
                .frame(width: 6.5, height: 6.5)
                .offset(x: 1, y: -10)
        }
        .frame(width: 30, height: 30)
    }
}

/// 小三角箭头（尖端朝右），配合旋转弧线使用
private struct ArrowTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: 0, y: rect.maxY))
        p.closeSubpath()
        return p
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
                    .scaleEffect(pulse ? 1.16 : 1)
                    .opacity(pulse ? 0 : 0.55)

                if store.isLoading || store.isBuffering {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .offset(x: store.isPlaying ? 0 : 2)
                }
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onChange(of: store.isPlaying) { playing in pulse = playing }
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

    private var safeTop: CGFloat {
        // 🔴 复用 PlayerView.safeAreaInsets（过滤第三方注入窗口），不再直接读 keyWindow
        max(44, PlayerView.safeAreaInsets.top + 6)
    }

    private var safeBottom: CGFloat {
        max(8, PlayerView.safeAreaInsets.bottom)
    }

    var body: some View {
        // 🔴 用 GeometryReader 实测 cover 真实尺寸来约束布局：
        // 之前用 UIScreen.main.bounds 钳制，但强制旋转瞬间 UIScreen 可能还停在横屏
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
                // dark 本身就是 Color，不能再包一层 Color(:) —— 那是 iOS 17 才有的
                // Color.init(_:) 重载，iOS 15 部署目标直接编译失败（run #385）。
                store.currentPalette.dark

                LinearGradient(colors: store.currentPalette.gradient,
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)

                LinearGradient(colors: [.black.opacity(0.35),
                                        .black.opacity(0.18),
                                        .black.opacity(0.3),
                                        .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
            // 🔴 已移除下滑关闭手势：用户要求只用左上角返回按钮关闭歌词页（横屏同理），
            // 下滑手势会和按钮 / 进度条抢手势且易误触。关闭统一由左上角 chevron.left 按钮完成。

            VStack(spacing: 0) {
                // 顶栏：降低存在感
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .contentShape(Rectangle())

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
                    .padding(.horizontal, 8)

                    Spacer()

                    Button {
                        store.showTranslation.toggle()
                    } label: {
                        Image(systemName: "character.bubble")
                            .font(.system(size: 18, weight: .medium))
                            .opacity(store.showTranslation ? 1 : 0.4)
                            .frame(width: 44, height: 44)
                    }
                }
                .foregroundStyle(.white)
                .padding(.top, safeTop)
                .opacity(0.5)  // 顶栏低存在感

                // 纯正文歌词滚动区（flex 占满剩余高度，底部留给控制条）
                // 🔴 显式宽度：超长歌词行会把 LazyVStack 的理想宽度撑到 570pt+，
                // 整个 VStack 跟着超宽（控制条同属一个 VStack → 进度条贴穿屏幕、
                // 上一首/下一首被挤出屏幕）。显式 frame 强制约束，不依赖提案链。
                BigLyricsView(lyrics: store.lyrics,
                              currentIndex: lyricState.currentIndex,
                              showsTranslation: store.showTranslation,
                              playback: PlayerStore.shared.playback,
                              isPlaying: store.isPlaying,
                              liveTime: { store.preciseTime })
                    .frame(width: sz.width - 52)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                // 底部播放控件条：进度 + 上一首/播放/下一首（固定高度，安全区内置，不挤出屏幕）
                LyricsBottomBar()
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
        // 🔴 整页下滑关闭手势已移到背景层（.gesture）：highPriorityGesture 会把
        // 进度条的拖动手势整个吃掉（进度条拖不动的根因），不能再挂在这。
    }
}

/// 全屏歌词页底部播放控件条：进度条 + 上一首 / 播放 / 下一首。
/// 固定在歌词页底部，内置于安全区，永远不会被歌词滚动区挤出屏幕。
/// 横屏播放器时隐藏系统状态栏。
/// iOS 16+ 的 statusBarHidden(_:)；iOS 15 不处理（旧 statusBar(hidden:) 已弃用，
/// 直接调用会触发弃用警告 → CI 的 warning-as-error 会挂）。
private struct LandscapeStatusBarHider: ViewModifier {
    let hidden: Bool
    /// 用户要求：横屏浮层隐藏时，底部 home 横条也一并隐藏；点击屏幕显出浮层时恢复
    var hideHomeIndicator: Bool = false
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .statusBarHidden(hidden)
                .persistentSystemOverlays(hideHomeIndicator ? .hidden : .automatic)
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

    var body: some View {
        VStack(spacing: 10) {
            // 进度条
            GeometryReader { geo in
                let w = geo.size.width
                let pf = max(0, min(1, playback.progress))
                let bf = max(0, min(1, playback.bufferedFraction))
                let px = pf * w
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 3)
                    Capsule().fill(.white.opacity(0.32)).frame(width: bf * w, height: 3)
                    Capsule().fill(.white).frame(width: px, height: 3)
                    Circle().fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: px - 6)
                        .opacity(isScrubbing ? 1 : 0)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
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
            // 🔴 触摸区高 28pt（视觉仍是 3pt 细条，contentShape 撑满整行）：
            // 16pt 太窄，手指很难按准进度条
            .frame(height: 28)

            HStack {
                Text(displayTime.clockString)
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Text(playback.duration.clockString)
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.7))

            // 控制键：上一首 / 播放 / 下一首（与播放页同款 PlayButton，白字白圈，任意背景可见）
            HStack(spacing: 0) {
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
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
    }
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
                LazyVStack(alignment: .center, spacing: 40) {
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
                // 🔴 打开歌词页时若正在播放，立即把当前演唱行滚到【中间】：
                // 不能只靠 onChange(currentIndex) —— 打开瞬间 currentIndex 已是当前值（没变化），
                // onChange 不会触发，于是停在顶端。这里显式滚一次，配合下方 onChange 保持居中。
                if let id = activeId {
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    proxy.scrollTo(lyrics.first?.id, anchor: .center)
                }
            }
            .onChange(of: currentIndex) { _ in
                guard let id = activeId else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: lyrics) { _ in
                // 切歌：滚到当前行（而非顶端），保持高亮行居中
                if let id = activeId { proxy.scrollTo(id, anchor: .center) }
                else { proxy.scrollTo(lyrics.first?.id, anchor: .center) }
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

    /// 单行歌词视图（抽出独立函数，降低 body 的类型推导复杂度，
    /// 避免 "compiler is unable to type-check this expression in reasonable time"）。
    private func lyricRow(idx: Int, line: LyricLine) -> some View {
        let activeIdx = currentIndex
        let isActive = activeIdx == idx
        let isNear = activeIdx != nil && abs(idx - activeIdx!) <= 1
        return VStack(spacing: 7) {
            // 🔴 用户要求字号调小：当前句 30→26，其他行 20→17
            if isActive {
                // 当前句：卡拉OK逐字填充（已唱纯白 / 未唱半透白），与播放页迷你条同款
                let end = (idx + 1 < lyrics.count) ? lyrics[idx + 1].time : (line.time + 5)
                // 🔴 KaraokeLine 参数顺序必须严格匹配声明顺序：
                // text, start, end, isPlaying, playback, font, lineLimit, align, liveTime。
                // liveTime 是最后一个（带默认值的）参数，必须放在最末尾，否则报
                // "argument 'font' must precede argument 'liveTime'"。
                KaraokeLine(text: line.text,
                            start: line.time,
                            end: end,
                            isPlaying: isPlaying,
                            playback: playback,
                            font: .system(size: 26, weight: .bold),
                            lineLimit: nil,
                            liveTime: liveTime)
            } else {
                Text(line.text)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(isNear ? 0.45 : 0.28))
                    .multilineTextAlignment(.center)
            }
            if showsTranslation, let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: isActive ? 14 : 11))
                    .foregroundStyle(isActive ? .white.opacity(0.78) : .white.opacity(0.3))
                    .multilineTextAlignment(.center)
            }
        }
        .lineSpacing(4)
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
    /// 游动光点相位（0→1 往返，仅播放时动画）
    @State private var classicFlowPhase: CGFloat = 0

    private var displayTime: Double { isScrubbing ? scrubValue : playback.currentTime }

    var body: some View {
        let progressFrac = max(0, min(1, playback.progress))

        return GeometryReader { geo in
            let gWidth = geo.size.width
            let thumbX = min(max(progressFrac * gWidth, 10), max(gWidth - 10, 10))
            let trackH: CGFloat = 5

            ZStack(alignment: .leading) {
                // 清透轨道 + 玻璃材质覆盖 + 细边描边（Beans 流光）
                Capsule()
                    .fill(.white.opacity(0.55))
                    .frame(height: trackH)
                Capsule()
                    .fill(.ultraThinMaterial)
                    .frame(height: trackH)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }

                // 已播放段：accent 渐变 + shadow 发光 + 顶部高光
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [dominantColor, dominantColor.opacity(0.6), .white.opacity(0.85)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: thumbX, height: trackH)
                    .shadow(color: dominantColor.opacity(0.45), radius: 4, y: 1)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.white.opacity(0.55), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: trackH / 2).clipShape(Capsule())
                    }

                // 游动光点（仅播放时往返游动，Beans 流光的灵魂）
                if store.isPlaying {
                    ZStack {
                        // 外层柔光晕
                        Circle()
                            .fill(.white.opacity(0.35))
                            .blur(radius: 4)
                            .frame(width: 14, height: 14)
                        // 内层实白点
                        Circle()
                            .fill(.white.opacity(0.95))
                            .frame(width: 5, height: 5)
                            .shadow(color: .white.opacity(0.7), radius: 2)
                    }
                    .offset(x: max(2, thumbX - 5) * classicFlowPhase)
                    .animation(.linear(duration: 2.4).repeatForever(autoreverses: true),
                               value: classicFlowPhase)
                }

                // 发光滑块（白底 + stroke + accent shadow）
                Circle()
                    .fill(.white)
                    .frame(width: isScrubbing ? 22 : 14, height: isScrubbing ? 22 : 14)
                    .overlay { Circle().strokeBorder(.white.opacity(0.95), lineWidth: 0.8) }
                    .shadow(color: dominantColor.opacity(0.7),
                            radius: isScrubbing ? 10 : 3.5, y: isScrubbing ? 3 : 1)
                    .offset(x: thumbX - (isScrubbing ? 11 : 7))
                    .animation(.spring(response: 0.24, dampingFraction: 0.76), value: isScrubbing)
            }
            .frame(width: gWidth, height: 34)
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
                        .shadow(color: dominantColor.opacity(0.35), radius: 10, y: 4)
                        .offset(x: min(max(thumbX - 31, 0), max(gWidth - 62, 0)), y: -25)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .onAppear {
                if store.isPlaying, classicFlowPhase == 0 { classicFlowPhase = 1 }
            }
            .onChange(of: store.isPlaying) { playing in
                classicFlowPhase = playing ? 1 : 0
            }

            HStack(spacing: 6) {
                seekPillButton("gobackward.15") { store.seek(to: max(0, playback.currentTime - 15)) }
                Text(displayTime.clockString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.56))
                    .frame(minWidth: 34, alignment: .leading)
                Spacer(minLength: 0)
                Text(playback.duration.clockString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.56))
                    .frame(minWidth: 34, alignment: .trailing)
                seekPillButton("goforward.15") { store.seek(to: max(0, min(playback.duration, playback.currentTime + 15))) }
            }
            .offset(y: 26)
        }
        .frame(height: 60)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isScrubbing)
    }

    private func seekPillButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 30, height: 22)
        }
        .buttonStyle(.plain)
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

/// 双行歌词条（酷狗风格 + 卡拉OK逐字）：当前行卡拉OK填充 + 下一行暗显。
/// 炫胶 / 黑胶 / 经典三主题竖屏共用；点击进歌词页。
private struct LyricPill: View {
    @EnvironmentObject private var store: PlayerStore
    /// 独立订阅歌词高亮 + 进度（与注入的是同一单例实例，见 LyricsPageView 同款写法）
    @ObservedObject private var lyricState = PlayerStore.shared.lyricState
    /// 🔴 let 不订阅（v2.5.38）：LyricPill 的逐字填充由 KaraokeLine 的 TimelineView
    /// + liveTime 驱动，无需随 4fps 进度重建（否则迷你歌词条每秒抖 4 次）。
    private let playback = PlayerStore.shared.playback
    var onOpen: () -> Void

    private var dim: Color { .white.opacity(0.4) }

    var body: some View {
        Button {
            onOpen()
        } label: {
            VStack(spacing: 4) {
                // 第一行：当前歌词 —— 高亮、大，卡拉OK逐字填充
                if let span = currentLineSpan {
                    KaraokeLine(text: currentLyricText,
                                start: span.start,
                                end: span.end,
                                isPlaying: store.isPlaying,
                                playback: playback,
                                liveTime: { store.preciseTime })
                } else {
                    // 纯音乐 / 解析中 / 无当前行：静态半透白
                    Text(currentLyricText)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(dim)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                // 第二行：下一句歌词 —— 暗、小
                if let next = nextLyricText {
                    Text(next)
                        .font(.system(size: 13))
                        .foregroundStyle(dim)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: currentLyricText)
        .animation(.easeInOut(duration: 0.25), value: nextLyricText)
    }

    /// 当前歌词行的起止时间：start=本句 time，end=下一句 time；末行用整曲时长兜底。
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
                            liveTime: { store.preciseTime })
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
