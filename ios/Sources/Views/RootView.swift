import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: PlayerStore
    @State private var tab: Tab = .discover
    @State private var isPlayerExpanded = false

    private enum Tab: Hashable {
        case discover, search, library, profile
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $tab) {
                NavigationStack {
                    DiscoverView()
                }
                .tabItem { Label("主页", systemImage: "safari.fill") }
                .tag(Tab.discover)

                NavigationStack {
                    SearchView()
                }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(Tab.search)

                NavigationStack {
                    LibraryView()
                }
                .tabItem { Label("我的音乐", systemImage: "music.note.list") }
                .tag(Tab.library)

                NavigationStack {
                    ProfileView()
                }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(Tab.profile)
            }

            if store.current != nil {
                MiniPlayer(isExpanded: $isPlayerExpanded)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
        // TabBar 与选中态统一走品牌蓝
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
        .overlay(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Capsule()
                    .fill(AppStyle.accent)
                    .frame(width: proxy.size.width * store.progress, height: 2)
            }
            .frame(height: 2)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppStyle.stroke, lineWidth: 1)
        )
        // 浮在 TabBar 之上，给一点投影把层次拉开
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
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
