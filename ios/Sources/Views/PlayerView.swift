import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var store: PlayerStore
    @Binding var isExpanded: Bool
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var isBuffering = false
    @State private var showToast: String?

    private var displayTime: Double { isScrubbing ? scrubValue : store.currentTime }

    var body: some View {
        ZStack {
            immersiveBackground
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                bitrateChip
                lyrics
                    .frame(maxHeight: .infinity)
                meta
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .gesture(dragGesture)
        .overlay(alignment: .bottom) { toastLayer }
        .onAppear(perform: animateIn)
        .onDisappear(perform: animateOut)
        .onChange(of: store.bufferedFraction) { value in
            isBuffering = value < 0.05 && store.isPlaying
        }
    }

    // MARK: - 背景（由封面取色驱动）

    private var immersiveBackground: some View {
        ZStack {
            if let artwork = store.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 18)
                    .scaleEffect(1.12)
                    .clipped()
            } else {
                LinearGradient(colors: store.currentPalette.gradient,
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            }
            LinearGradient(colors: [.black.opacity(0.28),
                                    .clear,
                                    .clear,
                                    store.currentPalette.scrim.opacity(0.55),
                                    store.currentPalette.scrim.opacity(0.9)],
                           startPoint: .top,
                           endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: store.index)
        .animation(.easeInOut(duration: 0.5), value: store.currentPalette)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 0) {
            Button { animateOut() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }

            Spacer()

            pageIndicator
                .frame(maxWidth: .infinity)

            Spacer()

            HStack(spacing: 18) {
                Button {} label: {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                Button {} label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 40, height: 40)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 4)
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(index == 0 ? 0.9 : 0.4))
                    .frame(width: index == 0 ? 16 : 6, height: 6)
            }
        }
        .overlay(alignment: .trailing) {
            singerBadge
                .offset(x: 34)
        }
    }

    private var singerBadge: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                }
            Text("正在唱")
                .font(.system(size: 9))
                .foregroundStyle(.white)
        }
    }

    private var bitrateChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down")
                .font(.system(size: 8, weight: .bold))
            Text(isBuffering ? "缓冲中" : "320 KB/s")
                .font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.leading, 10)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lyrics: some View {
        LyricsView(lyrics: store.lyrics, currentIndex: store.currentLyricIndex)
            .padding(.horizontal, 18)
    }

    // MARK: - 信息区

    private var meta: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.current?.title ?? "")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 18)

            tagRow
                .padding(.top, 10)
                .padding(.horizontal, 18)

            actionRow
                .padding(.top, 18)
                .padding(.horizontal, 14)

            progressSection
                .padding(.top, 20)
                .padding(.horizontal, 18)

            controls
                .padding(.top, 12)
                .padding(.bottom, 4)

            vipBar
        }
    }

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(store.current?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)

                Button {
                    store.isFollowed.toggle()
                    Haptics.light()
                } label: {
                    Text(store.isFollowed ? "已关注" : "关注")
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(store.isFollowed ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.08)),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(store.isFollowed ? .black : .white)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(.white.opacity(store.isFollowed ? 0 : 0.3)))
                }

                ForEach(Array((store.current?.tags ?? []).enumerated()), id: \.offset) { _, tag in
                    Text(tag)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(.white.opacity(0.3)))
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            actionButton(icon: "text.bubble", label: "", badge: nil) { show("评论区开发中") }
            actionButton(icon: "arrow.down.to.line", label: "", badge: "VIP") { download() }
            actionButton(icon: "bell", label: "设铃声", badge: nil) { show("已设为铃声") }
            actionButton(icon: store.isLiked ? "heart.fill" : "heart",
                         label: store.isLiked ? "1.2w" : "623w",
                         badge: nil,
                         tint: store.isLiked ? .pink : .white) {
                store.toggleLike()
                Haptics.light()
            }
            actionButton(icon: "text.bubble.fill", label: "2w", badge: nil) { show("暂无 MV") }
            actionButton(icon: "ellipsis", label: "", badge: nil) { show("更多操作") }
        }
    }

    private func actionButton(icon: String,
                              label: String,
                              badge: String?,
                              tint: Color = .white,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.light()
        } label: {
            ZStack(alignment: .top) {
                VStack(spacing: 4) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: icon)
                            .font(.system(size: 21, weight: .regular))
                            .frame(width: 34, height: 30)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color(red: 0.96, green: 0.82, blue: 0.29),
                                            in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.black)
                                .offset(x: 10, y: 6)
                        }
                    }
                    if !label.isEmpty {
                        Text(label)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 进度

    private var progressSection: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(height: 2)
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: max(0, min(1, store.bufferedFraction)) * geometryWidth, height: 2)
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, min(1, store.progress)) * geometryWidth, height: 2)
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, min(1, store.progress)) * geometryWidth - 5)
                    .opacity(isScrubbing ? 1 : 0)
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard store.duration > 0 else { return }
                    if !isScrubbing {
                        isScrubbing = true
                        scrubValue = store.currentTime
                        Haptics.light()
                    }
                    scrubValue = min(1, max(0, value.location.x / max(1, geometryWidth))) * store.duration
                }
                .onEnded { _ in
                    store.seek(to: scrubValue)
                    isScrubbing = false
                })

            HStack {
                Text(displayTime.clockString)
                Spacer()
                Text(store.duration.clockString)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: TrackWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(TrackWidthKey.self) { geometryWidth = $0 }
    }

    @State private var geometryWidth: CGFloat = 0

    // MARK: - 控制

    private var controls: some View {
        HStack {
            Button { store.cycleMode() } label: {
                Image(systemName: store.mode.icon)
                    .font(.system(size: 22, weight: .regular))
                    .frame(width: 52, height: 52)
            }

            Button { store.step(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 26))
                    .frame(width: 52, height: 52)
            }

            PlayButton()

            Button { store.step(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 26))
                    .frame(width: 52, height: 52)
            }

            Button {
                store.isQueuePresented = true
                Haptics.light()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20))
                    .frame(width: 52, height: 52)
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private var vipBar: some View {
        Button { show("会员功能演示版") } label: {
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.96, green: 0.82, blue: 0.29))
                Text("会员歌曲限时免费试听")
                    .foregroundStyle(.white.opacity(0.72))
                Text("开通会员无限畅享")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.96, green: 0.82, blue: 0.29))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.96, green: 0.82, blue: 0.29))
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 反馈

    @ViewBuilder
    private var toastLayer: some View {
        if let showToast {
            Text(showToast)
                .font(.footnote)
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

    private func download() {
        guard let url = store.current?.url else { return show("本地音频无法下载") }
        UIApplication.shared.open(url)
    }
}

private struct TrackWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PlayButton: View {
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

                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .offset(x: store.isPlaying ? 0 : 2)
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onChange(of: store.isPlaying) { playing in pulse = playing }
    }
}
