import SwiftUI

struct RootView: View {
    var body: some View {
        ZStack {
            // 🔴 MainTabs 在下层，负责真正的 TabBar 点击
            MainTabs()

            // 🔴 播放条浮层在上层，但它自身不铺满屏参与命中测试
            // （详见 MiniPlayerLayer 的注释）。ZStack 上层不吃触摸时，
            // 触摸会落到下层的 MainTabs，TabBar 才能正常点击。
            MiniPlayerLayer()
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
    @EnvironmentObject private var store: PlayerStore
    @State private var isPlayerExpanded = false

    var body: some View {
        // 🔴 播放时 TabBar 点不动，与性能无关，是【触摸命中被拦截】：
        //
        // 旧写法 VStack { Spacer(); MiniPlayer } 把这层撑满全屏。
        // SwiftUI 命中测试自顶向下，上层命中就不再传给下层 TabView ——
        // 播放条一出现（store.current != nil），底部 TabBar 就点不动。
        // 旧注释写的「Spacer 不参与命中测试所以能穿透」是错的：
        // 不绘制内容 ≠ 不占命中区域，撑满的布局照样吃触摸。
        //
        // 🔴 allowsHitTesting 是【继承】的：父级 false 会连子级一起禁，子级 true 覆盖不了。
        // 所以正确做法是把播放条做成【尺寸就等于播放条本身】的兄弟节点，
        // 用 alignment: .bottom 贴到屏幕底部，而不是用 Spacer 撑满。
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)   // 背景不吃触摸 → 穿透给下层 TabBar
            .overlay(alignment: .bottom) {
                // 播放条：只有这个矩形参与命中，周围的空白穿透到 TabBar
                if store.current != nil && !store.isAnyMultiSelecting {
                    MiniPlayer(playback: store.playback, isExpanded: $isPlayerExpanded)
                        .padding(.horizontal, 10)
                        // 抬到系统 TabBar(49) + HomeIndicator 之上
                        .padding(.bottom, 49 + ScreenMetric.bottomSafeInset + 4)
                        .id("mini-player")
                }
            }
            // 全屏播放页：覆盖全屏且需要吃全部触摸
            .overlay {
                if isPlayerExpanded, store.current != nil {
                    PlayerView(playback: store.playback, isExpanded: $isPlayerExpanded)
                        .transition(.move(edge: .bottom))
                }
            }
            .queueSheet()
    }
}

// MARK: - 迷你播放条

struct MiniPlayer: View {
    @EnvironmentObject private var store: PlayerStore
    /// 进度条专用的高频订阅对象 —— 见 PlaybackProgress 文档。
    @ObservedObject var playback: PlaybackProgress
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            CoverImage(url: store.current?.artworkURL,
                       fallbackKeys: store.current?.coverFallbackKeys ?? [],
                       seed: "\(store.current?.artist ?? "")-\(store.current?.title ?? "")",
                       size: 40,
                       corner: 8)

            VStack(alignment: .leading, spacing: 2) {
                // 歌名单独一行占满宽度：音源名原来跟歌名挤在同一行，
                // 音源名一长就把歌名截没了
                Text(store.current?.title ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(store.current?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !store.sourceName.isEmpty {
                        Text(store.sourceName)
                            .font(.system(size: 9))
                            .foregroundStyle(AppStyle.accent)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: 0)

            if store.isLoading {
                ProgressView()
                    .tint(AppStyle.accent)
                    .frame(width: 26, height: 26)
            } else {
                Button {
                    store.toggle()
                } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
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
