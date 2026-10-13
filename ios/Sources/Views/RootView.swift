import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: PlayerStore
    @State private var tab: Tab = .discover
    @State private var isPlayerExpanded = false
    @State private var showKugouLogin = false

    private enum Tab: Hashable {
        case discover, search, library, profile
    }

    /// 底部安全区（Home Indicator 高度），从 keyWindow 读取，避免全屏 GeometryReader 拦截点击
    private static var bottomSafeInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34
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
        // 🔴 终极方案：overlay(alignment:.bottom) + 纯 padding 上移
        //
        // SwiftUI hitTest 铁律：
        //  · padding 的空白区【不吃】点击（点在 padding 上会直接落到下层 TabView）
        //  · Color.clear【吃】点击（即使透明，是明确填充视图）
        //  · offset 改视觉但 hitTest 行为不稳定
        //
        // 所以这里：MiniPlayer 用 .padding(.bottom, TabBar+HomeIndicator) 视觉上移，
        // TabBar 区域只有 padding 空白，点击 100% 穿透到系统 TabBar；
        // MiniPlayer 自身 contentShape 是圆角矩形，只在条内吃点击。
        // 布局是静态的，播放/暂停完全一致，不存在“播放时挡住”。
        .overlay(alignment: .bottom) {
            if store.current != nil && !store.isAnyMultiSelecting {
                MiniPlayer(isExpanded: $isPlayerExpanded)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 49 + Self.bottomSafeInset + 4)
            }
        }
        .overlay {
            if isPlayerExpanded, store.current != nil {
                PlayerView(isExpanded: $isPlayerExpanded)
                    .transition(.move(edge: .bottom))
            }
        }
        .queueSheet()
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $showKugouLogin) { KugouLoginSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .auroraShowKugouLogin)) { _ in showKugouLogin = true }
        .tint(AppStyle.accent)
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
