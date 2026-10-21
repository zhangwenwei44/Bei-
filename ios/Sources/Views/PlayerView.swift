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
    /// 🔴 v2.5.47：横屏浮层自动隐藏的定时任务（4 秒无操作淡出）
    @State private var chromeHideTask: Task<Void, Never>?
    /// 音质切换弹层
    /// 「更多」弹层：音质档位 / 完整歌词 / 歌词翻译
    @State private var showMoreMenu = false
    /// 🔴 v2.5.45：动作行「音质」按钮专用弹层（原「评论」位置改为音质）
    @State private var showQualityMenu = false
    /// 🔴 v2.5.44：横屏播放器内嵌的「播放队列」面板（不再单独弹一页 sheet）
    @State private var showLandscapeQueue = false
    /// 分享弹层内容（nil = 不弹）
    @State private var shareItems: [Any]?
    @State private var dominantColor: Color = .white

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
                    LyricsPageView(isShown: $isLyricsPage)
                        .environmentObject(store)
                        .transition(.opacity)
                        .zIndex(10)
                } else if isLandscape {
                    // 横屏播放器：右上角按钮强制旋转后接管（唱片在左、信息在右）
                    landscapeBody()
                } else {
                    // 🔴 v2.5.39：主题精简，只剩「经典封面」——取色渐变背景 + 经典版式。
                    immersiveBackground.ignoresSafeArea()
                    classicBody(in: contentHeight, win: win, screen: screen)
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
        .modifier(LandscapeStatusBarHider(hidden: isLandscape && !isLyricsPage))
        // 🔴 关闭播放页时恢复竖屏 + 恢复自动熄屏（避免退出后整 App 卡横屏/永远不熄屏）
        .onDisappear {
            OrientationLock.shared.resetToPortrait()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // 🔴 播放列表 sheet：必须挂在播放页自己身上。此前只挂在 RootView 迷你条上，
        // 它在播放页 fullScreenCover 之下 —— 播放页打开时 sheet 弹不出来（点了没反应）。
        .queueSheet()
        // 分享弹层（顶栏右上角分享按钮）
        .sheet(isPresented: Binding(get: { shareItems != nil },
                                    set: { presented in if !presented { shareItems = nil } })) {
            ShareSheet(items: shareItems ?? [])
        }
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
                Image(systemName: "chevron.left")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

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
                .font(.system(size: 24, weight: .bold))
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
                // 🔴 v2.5.46：音质标签改成与 VIP 同款黄色胶囊（原白色半透明）
                Text(qualityText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppStyle.gold)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AppStyle.gold.opacity(0.18), in: Capsule())
                    .overlay(Capsule().stroke(AppStyle.gold.opacity(0.55), lineWidth: 0.6))
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
                classicCoverArt(side: side)
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
        HStack(spacing: 0) {
            // ① 喜欢 —— 🔴 v2.5.46：改回最初用的 SF Symbol 心形（用户要求）
            Button {
                store.toggleFavorite()
                Haptics.light()
            } label: {
                Image(systemName: store.isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 22))
                    .foregroundStyle(store.isLiked ? AppStyle.like : .white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            // ② 下载
            classicActionButton(glyph: .download) { download() }
            Spacer(minLength: 0)
            // ③ 音质（v2.5.45：原「评论」改为「音质」—— 点开音质选择）
            classicActionButton(glyph: .quality) { showQualityMenu = true }
            Spacer(minLength: 0)
            // ④ 歌词页
            classicActionButton(glyph: .lyric) { openLyricsPage() }
            Spacer(minLength: 0)
            // ⑤ 更多（横屏 / 歌词翻译 / 歌词微调）
            classicActionButton(glyph: .more) { showMoreMenu = true }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("音质", isPresented: $showQualityMenu, titleVisibility: .visible) {
            ForEach(MusicQuality.allCases) { q in
                // 🔴 v2.5.46：title 自带「音质」二字（至臻母带/至臻2.0 除外），不再额外拼接
                Button(q == SourceStore.shared.quality ? "✓ \(q.title)" : "\(q.title)") {
                    if q != SourceStore.shared.quality {
                        SourceStore.shared.quality = q
                        show("已切换到\(q.title)")
                    }
                }
            }
            Button("取消", role: .cancel) {}
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
            lyricPill()
                .padding(.bottom, 8)

            // 动作行：喜欢 / 下载 / 音质 / 歌词 / ⋯（纯图标均分）
            // 🔴 v2.5.47：动作行左右间距再收窄 10pt（比封面更宽一档）
            classicActionRow
                .padding(.horizontal, -10)
                .padding(.bottom, 10)

            // 进度行：已播时间 —— 细白进度条 —— 总时长
            classicProgressBlock
                .frame(height: 34)

            // 🔴 v2.5.47：播放控制行左右间距与动作行一致（收窄 10pt）
            classicDeckControls
                .frame(height: 54)
                .padding(.horizontal, -10)
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
            // 🔴 横屏背景用"无模糊"的纯取色渐变（plainGradientBackground）：
            // immersiveBackground 多一层 0.38 模糊封面图，实测会导致右列信息区
            // 显示异常/对比度糊掉。
            plainGradientBackground
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
            // 🔴 v2.5.47：进度条 + 控制行随浮层自动隐藏（视频播放器式交互）
            progressSection()
                .padding(.horizontal, 2)
                .opacity(landscapeChromeVisible ? 1 : 0)
                .allowsHitTesting(landscapeChromeVisible)
            landscapeControls()
                .padding(.top, 10)
                .opacity(landscapeChromeVisible ? 1 : 0)
                .allowsHitTesting(landscapeChromeVisible)
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
                // 🔴 v2.5.44：退出横屏时收起内嵌队列面板
                showLandscapeQueue = false
                Haptics.light()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 23, weight: .semibold))
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
                    .frame(width: 52, height: 56)
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
                    .frame(width: 52, height: 56)
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
        HStack(spacing: 3) {
            Image(systemName: "crown.fill")
                .font(.system(size: 8, weight: .bold))
            Text("VIP")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(AppStyle.gold)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(AppStyle.gold.opacity(0.18), in: Capsule())
        .overlay(Capsule().stroke(AppStyle.gold.opacity(0.55), lineWidth: 0.6))
    }

    private var qualityText: String {
        if store.isBuffering { return "缓冲中" }
        if store.isLoading { return "解析中" }
        if store.playbackError != nil { return "无法播放" }
        return store.bitrateLabel.isEmpty ? SourceStore.shared.quality.title : store.bitrateLabel
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
        if let message = showToast ?? store.playbackError {
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
                              liveTime: { store.lyricDisplayTime })
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
                // 🔴 v2.5.46：竖屏歌词页整行高亮（白、加粗），不再逐字卡拉OK填充
                // （横屏歌词块保持逐字不变 —— 用户要求只改竖屏）
                Text(line.text)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
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
                // 第二行：下一句歌词 —— 暗、小（左对齐）
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
