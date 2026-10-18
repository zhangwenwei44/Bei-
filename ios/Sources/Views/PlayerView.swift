import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var store: PlayerStore
    /// 播放进度独立订阅 —— currentTime 每 0.5s 变一次。
    /// 🔴 刻意不用 store.currentTime（那是转发计算属性，不触发刷新）：
    /// 播放页确实需要跟着进度重绘，所以由调用方（RootView 的 fullScreenCover）注入同一个实例。
    @ObservedObject var playback: PlaybackProgress
    /// 歌词高亮独立订阅 —— currentLyricIndex 播放时 4fps 变一次。
    /// 🔴 同理：store.currentLyricIndex 是转发计算属性不触发刷新，
    /// 歌词高亮的重绘只应该发生在播放页（订阅这个对象），而不是全 App。
    @ObservedObject var lyricState: LyricState
    @Binding var isExpanded: Bool
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    @State private var showToast: String?
    @State private var isLyricsPage = false
    /// 横屏播放器：跟踪当前是否处于横屏（由方向锁权威驱动）
    @State private var isLandscape = false
    /// 横屏顶栏浮层（关闭/横屏按钮）：默认隐藏，点击屏幕任意处显隐切换
    @State private var landscapeChromeVisible = false
    /// 音质切换弹层
    @State private var showQualityPicker = false
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

    private var displayTime: Double { isScrubbing ? scrubValue : playback.currentTime }

    /// key window bounds = 真实可见屏幕尺寸（几何权威）。
    /// 🔴 不再读任何 window 的 bounds：设备上的第三方注入悬浮窗（如网速悬浮球）
    /// 会创建自己的 UIWindow 且可能成为 key window，其 bounds 不是屏幕尺寸
    /// （实测读到 ~427pt 宽的脏值 → 歌词页控制条整体偏移、进度条贴穿屏幕）。
    /// 改用 UIWindowScene.screen.bounds —— scene 级物理屏幕尺寸，不受任何注入窗口影响。
    /// （系统界面已永不旋转，屏幕尺寸恒定，无需担心旋转瞬间的滞后问题。）
    fileprivate static func interfaceSize(fallback: CGSize) -> CGSize {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            let s = ws.screen.bounds.size
            if s.width > 0, s.height > 0 { return s }
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
                if isLandscape {
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

                // 🔴 歌词页：改为"播放页内就地覆盖层"，共用播放页这个尺寸永远正确的容器。
                // （之前用独立 fullScreenCover，强制旋转时按旧横屏尺寸弹出且不随旋转重排 →
                // 歌词两侧被裁出屏幕。）条件渲染，关闭即彻底移出视图树，无残留命中。
                if isLyricsPage {
                    LyricsPageView(isShown: $isLyricsPage)
                        .environmentObject(store)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .frame(width: size.width, height: size.height)
            .gesture(dragGesture)
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
        // 🔴 横屏播放器时隐藏系统状态栏（沉浸播放）；退出横屏自动恢复
        .modifier(LandscapeStatusBarHider(hidden: isLandscape))
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
    /// 流光进度条：游动光点相位（0→1 往返，仅播放时动画）
    @State private var classicFlowPhase: CGFloat = 0

    // MARK: classicBody — Header + Cover + Track + Lyrics + Progress + Controls
    // 三段式 VStack：header 固定顶 / body 紧凑封面区 / deck 固定底
    private func classicBody(in contentHeight: CGFloat,
                             win: (size: CGSize, safeTop: CGFloat, safeBottom: CGFloat),
                             screen: CGRect) -> some View {
        let headerH: CGFloat = 56
        // 🔴 deckH 加大：经典控件行(约44) + 进度条(50) + 控制按钮(56) + padding
        let deckH: CGFloat = 200
        let bodyH = max(160, contentHeight - headerH - deckH)

        return VStack(spacing: 0) {
            classicHeaderBar
                .frame(height: headerH)

            classicCoverArea(height: bodyH)
                .frame(height: bodyH)

            classicDeck(bottomInset: win.safeBottom)
                .frame(height: deckH)
        }
        .frame(width: screen.width, height: contentHeight)
        // 🔴 去掉 padding(.top, win.safeTop) —— 让 headerBar 从屏幕顶部（y=0）开始！
        // PlayerView 整体已经 ignoresSafeArea，classicBody 在全屏幕坐标系里
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

    // MARK: 封面区：圆形封面 + 光晕 + 歌名 + 歌手 + 歌词预览（紧凑，高度固定 bodyH）

    private func classicCoverArea(height: CGFloat) -> some View {
        let vinylSide = max(220, min(height * 0.50, UIScreen.main.bounds.width * 0.72))
        let coverSide = vinylSide * 0.56

        return VStack(spacing: 0) {
            // 🔴 TimelineView 只负责每帧更新旋转 angle（最低 20fps，省 CPU）
            // 其他所有手势/动画都在 TimelineView 外面，避免每帧重建
            TimelineView(.animation(minimumInterval: 1/20)) { timeline in
                let playing = store.isPlaying && !store.isLoading && !store.isBuffering
                let angle = playing
                    ? (Date().timeIntervalSince(classicCoverStart) / 24.0) * 360
                    : classicCoverAngle

                classicVinylButton(side: vinylSide, coverSide: coverSide, angle: angle)
            }
            .compositingGroup()
            .offset(x: classicSwipeOffset)
            .opacity(CGFloat(1) - min(abs(classicSwipeOffset) / 260, 0.35))
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: classicSwipeOffset)
            .padding(.top, 11)  // 🔴 黑胶往下移 11pt
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

            // 7 行歌词预览
            classicLyricPreviewBox
                .padding(.top, 8)  // 🔴 歌词下移 20→8

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: store.isPlaying) { _ in classicUpdateCoverSpin() }
        .onChange(of: store.currentIndex) { _ in classicUpdateCoverSpin(); extractDominantColor() }
        .onAppear { classicUpdateCoverSpin(); extractDominantColor() }
        .onChange(of: store.artwork) { _ in extractDominantColor() }
    }

    /// 纯函数：黑胶封面按钮（不跑动画/手势）
    private func classicVinylButton(side vinylSide: CGFloat, coverSide: CGFloat, angle: Double) -> some View {
        Button {
            openLyricsPage()
        } label: {
            ZStack {
                vinylDisc(side: vinylSide)
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
                    Circle().fill(.black.opacity(0.8))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 0.5))
                }
            }
            .frame(width: vinylSide, height: vinylSide)
            .rotationEffect(.degrees(angle))
            .rotation3DEffect(.degrees(Double(classicCoverOffset.height / -18)),
                              axis: (x: 1, y: 0, z: 0), perspective: 0.55)
            .rotation3DEffect(.degrees(Double(classicCoverOffset.width / 18)),
                              axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .offset(x: classicCoverOffset.width * 0.05, y: classicCoverOffset.height * 0.05)
        }
        .buttonStyle(.plain)
    }

    /// 经典封面功能按钮行：收藏① | 下载② | 翻译③ | 歌词④ | 评论⑤
    private var classicActionRow: some View {
        HStack(spacing: 28) {  // 🔴 间距加大到 28
            // ① 收藏
            classicActionButton(icon: store.isLiked ? "heart.fill" : "heart", label: "收藏") {
                store.toggleFavorite()
            }
            // ② 下载
            classicActionButton(icon: "arrow.down.circle", label: "下载") {
                if let song = store.current {
                    Task { _ = try? await DownloadManager.shared.download(song) }
                }
            }
            // ③ 翻译
            classicActionButton(icon: "textformat", label: "翻译") {
                openLyricsPage()
            }
            // ④ 歌词
            classicActionButton(icon: "music.note.list", label: "歌词") {
                openLyricsPage()
            }
            // ⑤ 评论
            classicActionButton(icon: "bubble.left.and.bubble.right", label: "评论") {
                if let song = store.current {
                    let albumID = song.kugouAlbumID
                    let hash = song.kugouHash
                    if !albumID.isEmpty {
                        if let url = URL(string: "https://www.kugou.com/album/\(albumID).html") { UIApplication.shared.open(url) }
                    } else if !hash.isEmpty {
                        if let url = URL(string: "https://www.kugou.com/song/#\(hash)") { UIApplication.shared.open(url) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func classicActionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.light() } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
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

    // MARK: 歌词预览（4 行 + 过滤元数据）

    private struct ClassicLyricPreviewRow { let text: String; let isCurrent: Bool }

    /// 过滤：元数据关键词 + 过短 + 全标点
    private static let classicLyricMetaKeywords: Set<String> = [
        "词", "曲", "作曲", "编曲", "制作", "制作人", "监制", "录音", "混音",
        "发行", "出品", "和声", "配唱", "演奏", "吉他", "钢琴", "贝斯", "鼓",
        "弦乐", "母带", "改编", "cover", "Cover"
    ]

    private var classicLyricPreviewRows: [ClassicLyricPreviewRow] {
        guard !store.lyrics.isEmpty else { return [] }
        let current = lyricState.currentIndex ?? 0

        // 先过滤掉元数据行
        let filtered: [(idx: Int, text: String)] = store.lyrics.enumerated().compactMap { i, line in
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            let hasKw = Self.classicLyricMetaKeywords.contains { kw in
                t.hasPrefix(kw + "：") || t.hasPrefix(kw + ":") || t == kw
            }
            return hasKw ? nil : (i, t)
        }
        guard !filtered.isEmpty else { return [] }

        // 在过滤后的数组里找 current 位置，展示 current 前后共 2 行（🔴 改少）
        let currentIdxInFiltered = filtered.firstIndex { $0.idx == current } ?? 0
        let start = max(0, currentIdxInFiltered - 1)
        var rows: [ClassicLyricPreviewRow] = []
        for j in start..<min(filtered.count, start + 2) {
            let item = filtered[j]
            rows.append(ClassicLyricPreviewRow(text: item.text,
                                               isCurrent: item.idx == current))
        }
        return rows
    }

    private var classicLyricPreviewBox: some View {
        let rows = classicLyricPreviewRows
        return VStack(spacing: 3) {
            if rows.isEmpty {
                Text("暂无歌词，点击封面查看完整歌词")
                    .font(.system(size: 12))
                    .foregroundStyle(.black.opacity(0.38))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        Text(item.isCurrent ? "●" : "·")
                            .font(.system(size: 8))
                            .foregroundStyle(item.isCurrent ? dominantColor : .black.opacity(0.22))
                        Text(item.text)
                            .font(.system(size: 12, weight: item.isCurrent ? .semibold : .regular))
                            .foregroundStyle(item.isCurrent ? .black : .black.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 7 * 16 + 6 * 3) // 固定 130pt（7 行 16pt + 6 gap ×3pt）
        .padding(.horizontal, 32)
        .contentShape(Rectangle())
        .onTapGesture {
            openLyricsPage()
        }
    }

    // MARK: 播放控件（Beans 直接搬：accent=dominantColor 渐变 + 发光 + 玻璃描边）

    private func classicDeck(bottomInset: CGFloat) -> some View {
        VStack(spacing: 6) {
            // 🔴 进度条上面一行：下载 / 收藏 / 翻译 / 歌词（移到这里！）
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
        .padding(.bottom, max(10, bottomInset))
    }

    /// 流光进度条（Beans SeekBar default case 完整搬：accent 渐变 + ultraThinMaterial 轨道 + 顶部高光 + 游动光点 + 发光滑块）
    private var classicProgressBlock: some View {
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

    /// 横屏布局专用：返回【主窗口】的横屏语义真实安全区（left/right=刘海/home 侧）。
    /// 🔴 只认「尺寸=物理屏幕」的主窗口：设备上的第三方注入悬浮窗（网速悬浮球）
    /// 可能成为 key window，读它的 safeAreaInsets 会得到垃圾值。
    private static var landscapeInsets: UIEdgeInsets {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            let screen = ws.screen.bounds.size
            let mainWindows = ws.windows.filter {
                abs($0.bounds.width - screen.width) < 1 && abs($0.bounds.height - screen.height) < 1
            }
            guard let w = mainWindows.first(where: { $0.isKeyWindow }) ?? mainWindows.first else { continue }
            return w.safeAreaInsets
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
    private func roundedArtwork(width: CGFloat, height: CGFloat) -> some View {
        // 和黑胶一致：屏宽的 65%，最小 180 最大 300
        let side = max(180, min(width * 0.65, 300))
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
            // 进入横屏：顶栏浮层（关闭按钮）默认隐藏，点击屏幕任意处再显
            landscapeChromeVisible = false
            OrientationLock.shared.enterLandscape()
            // 🔴 立即置 isLandscape = true（由方向锁权威驱动），不等方向通知 ——
            // 强制旋转瞬间通知是滞后的，等它会把横屏当成竖屏布局而裁切。
            isLandscape = true
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
            let size = Self.interfaceSize(fallback: geo.size)
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
            // 🔴 背景层挂点击手势：横屏顶栏浮层默认隐藏，点击任意空白区域显隐切换
            Group {
                if currentTheme == .classic {
                    immersiveBackground
                } else {
                    glitterBackground
                }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { landscapeChromeVisible.toggle() }
            }

                HStack(spacing: 0) {
                    // 左：大封面（垂直居中，约占屏宽 38%）
                    discViewForLandscape(maxSide: min(size.height - insets.top - insets.bottom - 40,
                                                      size.width * 0.38))
                        .frame(maxWidth: size.width * 0.42, maxHeight: .infinity)

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
                    .padding(.leading, 28)
                    .padding(.trailing, insets.right + 28)   // 真实右安全区：避开 home indicator
                    .padding(.top, insets.top + 50)          // 给浮层顶栏让位
                    .padding(.bottom, max(insets.bottom, 14))
                }
                .padding(.leading, insets.left)              // 真实左安全区：避开刘海（XS 不再遮唱片）

                // 顶栏浮层：默认隐藏，点击屏幕任意处显隐。只有关闭按钮。
                // 🔴 浮层必须只包住顶栏自身（无 Spacer、无 maxHeight:infinity）：
                // 撑满全屏的不可见层会吞掉下方内容的触摸（横屏按钮点不到的元凶之一）。
                if landscapeChromeVisible {
                    VStack(spacing: 0) {
                        landscapeTopBar()
                            .frame(height: 44)
                            .padding(.top, insets.top + 18)      // 不贴顶，往下留呼吸空间
                            .padding(.leading, insets.left + 8)
                            .padding(.trailing, insets.right + 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transition(.opacity)
                }
        }
    }

    /// 横屏顶栏：只留 关闭（左）。
    /// 🔴 用户要求移除右上角旋转按钮（竖屏顶栏的横屏入口保留，横屏内不需要再切）。
    private func landscapeTopBar() -> some View {
        HStack(spacing: 0) {
            Button { animateOut() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
    }

    /// 横屏标题行：歌名大字 + 歌手小字（酷狗横屏同款排布）
    private var landscapeTitleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(store.current?.title ?? "未播放")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(store.current?.artist ?? "")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
    }

    /// 横屏歌词块：四行（上句暗 / 当前句大高亮 / 下句暗 / 下下句更暗），纯展示。
    /// 🔴 不再可点击跳转 —— 用户要求横屏点歌词就不要进歌词页（避免旋转打架/重复）。
    private var landscapeLyricsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prev = prevLyricText {
                Text(prev)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            Text(currentLyricText)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let next = nextLyricText {
                Text(next)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            if let nextNext = nextNextLyricText {
                Text(nextNext)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.22))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: currentLyricText)
        .animation(.easeInOut(duration: 0.25), value: nextLyricText)
    }

    private var prevLyricText: String? {
        guard let index = lyricState.currentIndex,
              index > 0, store.lyrics.indices.contains(index - 1) else { return nil }
        let text = store.lyrics[index - 1].text
        return text.isEmpty ? nil : text
    }

    /// 横屏第四行（更暗）：当前句的"下下一句"。
    private var nextNextLyricText: String? {
        guard let index = lyricState.currentIndex,
              store.lyrics.indices.contains(index + 2) else { return nil }
        let text = store.lyrics[index + 2].text
        return text.isEmpty ? nil : text
    }

    /// 横屏控制键单排（酷狗式）：收藏 / 上一首 / 播放 / 下一首 / 词
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
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(.white.opacity(0.16)))
            }

            Spacer(minLength: 0)

            PlayButton()

            Spacer(minLength: 0)

            Button { store.step(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
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
            roundedArtwork(width: maxSide, height: maxSide)
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

            currentLyricPill

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

    /// 双行歌词（酷狗风格）：当前行在上、高亮；下一行在下、暗、小
    private var currentLyricPill: some View {
        Button {
            openLyricsPage()
        } label: {
            VStack(spacing: 4) {
                // 第一行：当前歌词 —— 高亮、大（用户要求高亮在上面）
                Text(currentLyricText)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                // 第二行：下一句歌词 —— 暗、小
                if let next = nextLyricText {
                    Text(next)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
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

    private func actionRow() -> some View {
        // 居中簇：四项（收藏/下载/音质/歌词）整体居中，不铺满全宽；项间距 35
        // 🔴 已移除「翻译」（用户要求）；间距 30 → 25 → 35（加大）。
        HStack(spacing: 35) {
            actionButton(icon: store.isLiked ? "heart.fill" : "heart",
                         label: "收藏",
                         tint: store.isLiked ? AppStyle.like : .white) {
                store.toggleFavorite()
            }
            actionButton(icon: "arrow.down.to.line", label: downloadLabel) { download() }
            // 音质切换：点了弹确认框选档位，选完 SourceStore 自动用新音质重新解析当前歌
            actionButton(icon: "waveform",
                         label: qualityShortTitle,
                         tint: AppStyle.gold) {
                showQualityPicker = true
            }
            actionButton(icon: "text.quote", label: "歌词") {
                openLyricsPage()
            }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("选择音质", isPresented: $showQualityPicker, titleVisibility: .visible) {
            ForEach(MusicQuality.allCases) { q in
                Button(q == SourceStore.shared.quality ? "✓ \(q.title)" : q.title) {
                    if q != SourceStore.shared.quality {
                        SourceStore.shared.quality = q
                        show("已切换到\(q.title)")
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 音质按钮的短标签（动作行空间有限，用两字/Hi-Res）
    private var qualityShortTitle: String {
        switch SourceStore.shared.quality {
        case .standard: return "标准"
        case .higher: return "较高"
        case .exHigh: return "极高"
        case .lossless: return "无损"
        case .hires: return "Hi-Res"
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

    private func actionButton(icon: String,
                              label: String,
                              tint: Color = .white,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.light()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 34, height: 30)
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 进度

    private func progressSection() -> some View {
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
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { isExpanded = false }
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

/// 横屏切换图标：竖放手机 + 右上角顺时针旋转箭头（照用户参考图）。
/// 🔴 自绘组合而非用 `rectangle.landscape.rotate` —— 该 SF Symbol 在部分系统版本
/// 缺字不渲染，按钮变成一个"空圆圈"（用户截图实测）。arrow.clockwise 100% 可用。
private struct LandscapeToggleIcon: View {
    var body: some View {
        ZStack {
            // 竖放手机轮廓
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(.white, lineWidth: 1.6)
                .frame(width: 12, height: 17)
            // 右上角旋转箭头（提示把手机旋成横屏）
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 8.5, y: -6.5)
        }
        .frame(width: 24, height: 22)
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

/// 深色沉浸式全屏歌词，背景与播放页同款取色 + 专辑图模糊。
/// 词曲/编曲/制作人等简介信息独立为顶部折叠模块，滚动区只保留正文歌词。
struct LyricsPageView: View {
    @EnvironmentObject private var store: PlayerStore
    /// 歌词高亮独立订阅 —— store.currentLyricIndex 是转发计算属性不触发刷新。
    /// 这个视图没有注入链，直接从单例取同一个实例。
    @ObservedObject private var lyricState = PlayerStore.shared.lyricState
    @Binding var isShown: Bool
    @State private var isMetaExpanded = false

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
            let sz = PlayerView.interfaceSize(fallback: geo.size)
        ZStack {
            // 沉浸式取色背景（专辑图模糊 + 渐变）
            ZStack {
                LinearGradient(colors: store.currentPalette.gradient,
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                    .opacity(0.96)

                if let artwork = store.artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 72)
                        .opacity(0.42)
                        .scaleEffect(1.3)
                        .clipped()
                }

                LinearGradient(colors: [.black.opacity(0.35),
                                        .black.opacity(0.18),
                                        .black.opacity(0.3),
                                        .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶栏：降低存在感
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }

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

                // 折叠简介模块（只在有 metadata 时显示）
                metaSection
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .opacity(store.lyricMetadata.isEmpty ? 0 : 0.85)

                // 纯正文歌词滚动区（flex 占满剩余高度，底部留给控制条）
                BigLyricsView(lyrics: store.lyrics,
                              currentIndex: lyricState.currentIndex,
                              showsTranslation: store.showTranslation)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 26)
                    .padding(.top, 12)

                // 底部播放控件条：进度 + 上一首/播放/下一首（固定高度，安全区内置，不挤出屏幕）
                LyricsBottomBar()
                    .padding(.horizontal, 26)
                    .padding(.top, 8)
                    .padding(.bottom, safeBottom + 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: sz.width, height: sz.height)
        }
        .ignoresSafeArea()
        .clipped()
        .highPriorityGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.height > 60 {
                    withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
                }
            }
        )
    }

    // MARK: - 折叠简介

    private var metaSection: some View {
        let meta = store.lyricMetadata
        let orderedKeys: [(String, String)] = [
            ("演唱", "演唱"), ("作词", "作词"), ("作曲", "作曲"), ("编曲", "编曲"),
            ("原唱", "原唱"), ("制作人", "制作人"), ("监制", "监制"), ("混音", "混音"),
            ("录音", "录音"), ("和声", "和声"), ("艺人统筹", "艺人统筹"), ("统筹", "统筹"),
            ("出品", "出品"), ("企划", "企划"), ("发行", "发行")
        ]
        .filter { meta[$0.1] != nil }

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isMetaExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text("词曲编曲")
                        .font(.system(size: 11))
                    Spacer()
                    Image(systemName: isMetaExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            if isMetaExpanded && !orderedKeys.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(orderedKeys, id: \.0) { pair in
                        HStack(alignment: .top, spacing: 0) {
                            Text(pair.1 + "：")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 48, alignment: .leading)
                            Text(meta[pair.1] ?? "")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.statusBarHidden(hidden)
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
            .frame(height: 16)

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
                            let activeIdx = currentIndex
                            let isActive = activeIdx == idx
                            let isNear = activeIdx != nil && abs(idx - activeIdx!) <= 1
                            VStack(spacing: 7) {
                                Text(line.text)
                                    .font(.system(size: isActive ? 30 : 20,
                                                  weight: isActive ? .bold : .medium))
                                    .foregroundStyle(isActive ? .white : .white.opacity(isNear ? 0.45 : 0.28))
                                    .multilineTextAlignment(.center)
                                if showsTranslation, let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(.system(size: isActive ? 15 : 12))
                                        .foregroundStyle(isActive ? .white.opacity(0.78) : .white.opacity(0.3))
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .id(line.id)
                            // 关键：每行不单独加 .animation —— 以前每行都 .animation(.easeInOut(0.3), value: isActive)
                            // 导致 currentIndex 一变 100 行全部做 transition 动画。
                            // 只在容器级统一加一次 animation，SwiftUI 自动处理可见行的样式过渡。
                        }
                    }
                }
                .padding(.vertical, 120)
            }
            .mask(LinearGradient(colors: [.clear, .black.opacity(0.85), .black, .black.opacity(0.85), .clear],
                                startPoint: .top,
                                endPoint: .bottom))
            .onChange(of: currentIndex) { _ in
                guard let id = activeId else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: lyrics) { _ in proxy.scrollTo(lyrics.first?.id, anchor: .center) }
        }
        // 容器级统一动画 —— 只有一个 animation 作用在 LazyVStack 上，
        // 可见行的 active 状态样式变化会自动过渡，不可见行不渲染就不参与。
        .animation(.easeInOut(duration: 0.3), value: currentIndex)
    }

    private var activeId: UUID? {
        guard let index = currentIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }
}
