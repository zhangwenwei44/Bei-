import SwiftUI

struct RootView: View {
    /// 仅用于把 store 实例传给 MiniPlayerLayer —— body 里不读它的任何属性，
    /// 所以不会因此建立订阅（SwiftUI 只对 body 中实际访问的属性建依赖）。
    @EnvironmentObject private var store: PlayerStore

    var body: some View {
        ZStack {
            // 🔴 MainTabs 在下层，负责真正的 TabBar 点击
            MainTabs()

            // 🔴 播放条浮层在上层。它内部只有播放条本身参与命中测试
            // （详见 MiniPlayerLayer 的注释），其余区域都是 ZStack 空隙，
            // 触摸落到下层 MainTabs，TabBar 才能正常点击。
            MiniPlayerLayer(store: store)
        }
        .ignoresSafeArea(.keyboard)
    }
}

/// 底部安全区（Home Indicator 高度），从 keyWindow 读取
private enum ScreenMetric {
    static var bottomSafeInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34
    }

    /// TabBar 的实际高度。
    ///
    /// 🔴 两个坑都踩过：
    /// 1. 不能硬编码 `49`。真机上 TabBar 高度 = 内容区 49 + Home Indicator 安全区。
    /// 2. 🔴 `tabBar.bounds.height` **本身就已经包含**安全区了。
    ///    之前写成 `bounds.height + safeAreaInsets.bottom` 等于加了两遍，
    ///    播放条被多抬一个安全区高度（34pt），用户反馈「怎么还调高了」。
    ///    所以这里只取 bounds.height，绝不再加 safeAreaInsets。
    static var tabBarHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let tabBar = scene?.windows.first(where: { $0.isKeyWindow })?
            .rootViewController?.children
            .compactMap { $0 as? UITabBarController }
            .first?.tabBar
        // 拿不到时退回通用值（此时才需要手动加安全区）
        guard let tabBar, tabBar.bounds.height > 0 else { return 49 + bottomSafeInset }
        // bounds.height 已含安全区，直接用
        return tabBar.bounds.height
    }
}

/// 主 Tab 容器 —— 刻意不持有/订阅 PlayerStore，避免播放进度高频更新引发整树重算。
private struct MainTabs: View {
    @State private var tab: Tab = .discover
    @State private var showKugouLogin = false

    fileprivate enum Tab: Hashable {
        case discover, search, library, profile
    }

    var body: some View {
        TabView(selection: $tab) {
            CompatNavigationStack { DiscoverView() }
                .tabItem { Label("主页", systemImage: "safari.fill") }.tag(Tab.discover)
            CompatNavigationStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(Tab.search)
            CompatNavigationStack { LibraryView() }
                .tabItem { Label("我的音乐", systemImage: "music.note.list") }.tag(Tab.library)
            CompatNavigationStack { ProfileView() }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(Tab.profile)
        }
        .sheet(isPresented: $showKugouLogin) { KugouLoginSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .auroraShowKugouLogin)) { _ in
            showKugouLogin = true
        }
        .tint(AppStyle.accent)
    }
}

/// MiniPlayer + 全屏播放页层 —— 只有这一层订阅 PlayerStore（播放进度高频更新隔离在此）。
private struct MiniPlayerLayer: View {
    /// 🔴 只订阅 MiniPlayerState，不再 @EnvironmentObject 订阅整个 PlayerStore。
    ///
    /// 根因：PlayerStore 里 `currentLyricIndex` 在播放时以 4fps 变化（歌词逐行高亮）。
    /// 浮层一旦订阅整个 PlayerStore，就会被它带着每秒重算 4 次 →
    /// 「播放时底部 TabBar 点不动，暂停就能点」（暂停后歌词不再刷新，重算停止）。
    ///
    /// MiniPlayerState 只含切歌/播放暂停时才变的低频状态，
    /// 与 PlaybackProgress（0.5s 进度）一起构成完整的重算隔离。
    @ObservedObject private var mini: MiniPlayerState
    /// 播放进度：进度条自己订阅，不经过 PlayerStore。
    @ObservedObject private var playback: PlaybackProgress
    /// 仅用于派发用户操作（toggle/step/seek），不参与 body 依赖。
    private let store: PlayerStore

    @State private var isPlayerExpanded = false

    init(store: PlayerStore) {
        self.store = store
        self.mini = store.mini
        self.playback = store.playback
    }

    var body: some View {
        // 🔴 这一层【绝对不能铺满屏幕】，否则会整层吃掉触摸、TabBar 点不动。
        //
        // 踩过的两个坑，都在本文件的历史里：
        // 1. `VStack { Spacer(); MiniPlayer }` —— 撑满全屏 → TabBar 被吃。
        // 2. `Color.clear.frame(maxWidth:.infinity, maxHeight:.infinity)`
        //    当"命中穿透底板" —— Color.clear 虽然透明，但 frame 铺满后
        //    它本身就在命中测试区里 → 照样吃掉全屏触摸。
        //
        // 现在的做法：用 ZStack + alignment 让播放条成为【尺寸只等于自身】的层，
        // 靠 frame(maxHeight:.infinity, alignment:.bottom) 把它压到屏幕底部，
        // 但 ZStack 本身不引入任何额外可命中内容 —— 播放条之外的区域全部是
        // ZStack 的空隙，触摸自然落到下层 MainTabs 的 TabBar。
        //
        // 不用 allowsHitTesting 全局禁用，因为它在 SwiftUI 里是【继承】的
        // （父级 false 会连子级一起禁，子级 true 覆盖不了），
        // 一旦禁用就会连播放条自己也点不动。
        ZStack(alignment: .bottom) {
            if mini.isVisible {
                MiniPlayer(mini: mini, playback: playback, store: store, isExpanded: $isPlayerExpanded)
                    .padding(.horizontal, 10)
                    // 底边贴住 TabBar 上沿 + 4pt 间距
                    // （tabBarHeight 已含 Home Indicator，不能再加安全区）
                    .padding(.bottom, ScreenMetric.tabBarHeight + 4)
                    .id("mini-player")
            }

            // 全屏播放页：确实要覆盖全屏并吃全部触摸
            if isPlayerExpanded, mini.isVisible {
                PlayerView(playback: playback, isExpanded: $isPlayerExpanded)
                    .transition(.move(edge: .bottom))
            }
        }
        // 让 ZStack 铺满（否则贴不到屏幕底部），但它内部除播放条外都是空隙，
        // 空隙不参与命中测试 —— 触摸落到下层 TabBar。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
                // 歌名单独一行占满宽度：音源名原来跟歌名挤在同一行，
                // 音源名一长就把歌名截没了
                Text(mini.song?.title ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(mini.song?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !mini.sourceName.isEmpty {
                        Text(mini.sourceName)
                            .font(.system(size: 9))
                            .foregroundStyle(AppStyle.accent)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
        // 🔴 关键：先 clipShape 裁住整个 MiniPlayer（含进度条 overlay）
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // 🔴 进度条独立成子视图：播放时只重绘这 2pt 小条，
        // 不重建整个 MiniPlayer（material 背景 / CoverImage / 按钮都不动）→ 降低主线程负载
        .overlay(alignment: .bottom) {
            MiniPlayerProgressBar(playback: playback)
        }
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
    @EnvironmentObject private var store: PlayerStore
    /// 进度实例由 PlayerStore 持有并注入 —— 与播放页共用同一份状态。
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
