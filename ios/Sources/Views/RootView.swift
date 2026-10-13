import SwiftUI

struct RootView: View {
    var body: some View {
        ZStack {
            // 🔴 MainTabs【不订阅 PlayerStore】——播放时 currentTime 每 0.5s 变化，
            // 只会重算下面的 MiniPlayerLayer，TabView 及 4 个重页面完全不重算，
            // 彻底解决“播放时底部 TabBar 卡死点不动、暂停就正常”。
            MainTabs()
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
        // VStack + Spacer 布局：
        //  · Spacer 是弹性占位，不绘制内容、【不参与命中测试】→ 大片空白区点击穿透到 MainTabs
        //  · 只有 MiniPlayer 本体（圆角条）吃点击
        //  · 底部 padding 把 MiniPlayer 抬到系统 TabBar(49) + HomeIndicator 之上，padding 也不吃命中
        VStack {
            Spacer(minLength: 0)
            if store.current != nil && !store.isAnyMultiSelecting {
                MiniPlayer(isExpanded: $isPlayerExpanded)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 49 + ScreenMetric.bottomSafeInset + 4)
                    .id("mini-player")
            }
        }
        // 全屏播放页
        .overlay {
            if isPlayerExpanded, store.current != nil {
                PlayerView(isExpanded: $isPlayerExpanded)
                    .transition(.move(edge: .bottom))
            }
        }
        .queueSheet()
    }
}

// MARK: - 迷你播放条

struct MiniPlayer: View {
    @EnvironmentObject private var store: PlayerStore
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
            MiniPlayerProgressBar()
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

/// MiniPlayer 底部 2pt 进度条 —— 独立订阅 progress，播放时只重绘它自己，
/// 避免每 0.5s 把整个 MiniPlayer（material/封面/按钮）全部重建。
private struct MiniPlayerProgressBar: View {
    @EnvironmentObject private var store: PlayerStore

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(AppStyle.accent)
                .frame(width: geo.size.width * max(0, min(1, store.progress)), height: 2)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
