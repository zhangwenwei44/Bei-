import SwiftUI

struct RootView: View {
    /// 仅用于把 store 实例传给 MiniPlayerOverlay —— body 里不读它的任何属性，
    /// 所以不会因此建立订阅（SwiftUI 只对 body 中实际访问的属性建依赖）。
    @EnvironmentObject private var store: PlayerStore
    @State private var isPlayerExpanded = false

    var body: some View {
        // 🔴 终于换对方案：用 safeAreaInset，而不是 ZStack 浮层。
        //
        // 为什么之前三次都失败：ZStack 里的播放条是【浮在 TabView 之上】的，
        // 只要它所在的层参与命中测试且覆盖了 TabBar 区域，TabBar 就点不动。
        // 试过的三种错法都记在 MiniPlayerOverlay 的注释里。
        //
        // safeAreaInset 是【布局】方案：播放条被塞进 TabView 的安全区，
        // TabView 的内容区自动缩小、播放条永远在 TabBar 上方，
        // 二者不可能重叠 —— 从根上不存在遮挡问题。
        MainTabs()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayerOverlay(
                    store: store,
                    isExpanded: $isPlayerExpanded
                )
            }
            // 🔴 播放页必须挂在【全屏宿主】的 overlay 上。
            //
            // 之前挂在 MiniPlayerOverlay 的 overlay 里 —— 而 MiniPlayerOverlay 是
            // safeAreaInset 的内容，frame 只有播放条那么高，overlay 的 frame
            // 跟随宿主，播放页被"锚"在底部一截，永远盖不满全屏（图1 的根因）。
            //
            // 这里的宿主是 MainTabs + safeAreaInset 的整体，frame = 全屏，
            // 所以 PlayerView 才能真正铺满、盖住状态栏。
            .overlay {
                ExpandedPlayerLayer(store: store, isExpanded: $isPlayerExpanded)
            }
            .ignoresSafeArea(.keyboard)
    }
}

/// 展开态播放页 —— 挂在全屏 overlay 上的独立一层。
///
/// 订阅粒度与 MiniPlayerOverlay 相同：只订阅 mini（可见性/歌曲）与
/// playback（进度），不订阅整个 PlayerStore，避免 4fps 歌词重算风暴。
private struct ExpandedPlayerLayer: View {
    @ObservedObject private var mini: MiniPlayerState
    @ObservedObject private var playback: PlaybackProgress
    @Binding var isExpanded: Bool

    init(store: PlayerStore, isExpanded: Binding<Bool>) {
        self.mini = store.mini
        self.playback = store.playback
        self._isExpanded = isExpanded
    }

    var body: some View {
        if isExpanded, mini.isVisible {
            PlayerView(playback: playback, isExpanded: $isExpanded)
                .transition(.move(edge: .bottom))
                .ignoresSafeArea()
        }
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

/// 迷你播放条 —— 作为 TabView 的 bottom safeAreaInset 内容，不是浮层。
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
/// ## 现在的方案：布局，不是修饰器
///
/// 通过 `safeAreaInset(edge: .bottom)` 挂到 TabView 上，播放条成为
/// TabView 内容区的一部分 —— TabView 自动缩小、播放条自然落在 TabBar 上方。
/// 两者在布局上就不可能重叠，TabBar 也不可能被遮挡。
/// 命中测试由布局保证，不需要任何 allowsHitTesting 花招。
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
                    .padding(.bottom, 6)
                    .id("mini-player")
            }
        }
        .background(.ultraThinMaterial)
        // 播放页已移到 RootView 的全屏 overlay（ExpandedPlayerLayer）——
        // 挂在这里 frame 只有播放条高，永远盖不满全屏。
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
