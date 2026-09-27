import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var store: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @Binding var isExpanded: Bool
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var isBuffering = false
    @State private var showToast: String?

    private var displayTime: Double { isScrubbing ? scrubValue : store.currentTime }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                bitrateChip
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
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
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: store.palette,
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.55), .black.opacity(0.8)],
                           startPoint: .top,
                           endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                animateOut()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 40, height: 40)
            }

            Button {} label: {
                HStack(spacing: 8) {
                    Text("免")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(LinearGradient(colors: [.cyan, .blue],
                                                                     startPoint: .top,
                                                                     endPoint: .bottom)))
                    Text("解锁你的专属音色")
                        .font(.subheadline)
                        .tracking(0.5)
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(.white.opacity(0.16), in: Capsule())
            }

            Button {} label: {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
            }
        }
        .padding(.top, 6)
    }

    private var bitrateChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down")
                .font(.system(size: 9, weight: .bold))
            Text(isBuffering ? "缓冲中 KB/s" : "320 KB/s")
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, 8)
        .onChange(of: store.bufferedFraction) { value in
            isBuffering = value < 0.05 && store.isPlaying
        }
    }

    private var lyrics: some View {
        LyricsView(lyrics: store.lyrics,
                   currentIndex: store.currentLyricIndex,
                   title: store.current?.title ?? "",
                   artist: store.current?.artist ?? "")
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.current?.title ?? "")
                .font(.system(size: 28, weight: .bold))
                .lineLimit(1)
                .padding(.horizontal, 22)

            artistRow
                .padding(.horizontal, 22)
                .padding(.top, 10)

            actionRow
                .padding(.top, 20)
                .padding(.horizontal, 14)

            progressSection
                .padding(.top, 8)
                .padding(.horizontal, 26)

            controls
                .padding(.top, 6)
                .padding(.bottom, 6)

            vipBar
        }
        .padding(.top, 6)
    }

    private var artistRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(store.current?.artist ?? "")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.75))

                Button {
                    store.isFollowed.toggle()
                    Haptics.light()
                } label: {
                    Text(store.isFollowed ? "已关注" : "关注")
                        .font(.footnote)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(store.isFollowed ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.08)),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(store.isFollowed ? .black : .white)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.white.opacity(store.isFollowed ? 0 : 0.35)))
                }

                ForEach(store.current?.tags ?? []) { tag in
                    Text(tag)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.white.opacity(0.35)))
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            actionButton(icon: "text.bubble", label: "评论", badge: nil) { show("评论区开发中") }
            actionButton(icon: "arrow.down.to.line", label: "下载", badge: "VIP") { download() }
            actionButton(icon: "bell.badge", label: "设铃声", badge: nil) { show("已设为铃声") }
            actionButton(icon: store.isLiked ? "heart.fill" : "heart",
                         label: store.isLiked ? "1.2w" : "421w",
                         badge: nil,
                         tint: store.isLiked ? .pink : .white) {
                store.toggleLike()
                Haptics.light()
            }
            actionButton(icon: "text.bubble.fill", label: "4K", badge: nil) { show("暂无 4K 视频") }
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
            VStack(spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 34, height: 30)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(tint, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.black)
                            .offset(x: 8, y: 6)
                    }
                }
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
    }

    private var progressSection: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : store.currentTime },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(1, store.duration),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        scrubValue = store.currentTime
                    } else {
                        store.seek(to: scrubValue)
                    }
                    Haptics.light()
                }
            )
            .tint(.white)

            HStack {
                Text(displayTime.clockString)
                Spacer()
                Text(store.duration.clockString)
            }
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var controls: some View {
        HStack {
            Button {
                store.cycleMode()
            } label: {
                Image(systemName: store.mode.icon)
                    .font(.system(size: 24, weight: .regular))
                    .frame(width: 56, height: 56)
                    .overlay(alignment: .topTrailing) {
                        if store.mode != .order {
                            Text(store.mode.title)
                                .font(.system(size: 8))
                                .offset(x: 16, y: 4)
                        }
                    }
            }

            Button { store.step(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
            }

            PlayButton()

            Button { store.step(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
            }

            Button {
                store.isQueuePresented = true
                Haptics.light()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 22))
                    .frame(width: 56, height: 56)
            }
        }
        .foregroundStyle(.white)
    }

    private var vipBar: some View {
        Button {
            show("会员功能演示版")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.96, green: 0.82, blue: 0.29))
                Text("会员歌曲限时免费试听")
                    .foregroundStyle(.white.opacity(0.75))
                Text("开会员无限畅享")
                    .foregroundStyle(Color(red: 0.96, green: 0.82, blue: 0.29))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.96, green: 0.82, blue: 0.29))
            }
            .font(.system(size: 13))
            .padding(.bottom, 4)
        }
    }

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
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            isExpanded = true
        }
    }

    private func animateOut() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
            isExpanded = false
        }
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
                    .fill(.white.opacity(0.22))
                    .frame(width: 74, height: 74)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18)))
                    .scaleEffect(pulse ? 1.12 : 1)
                    .opacity(pulse ? 0 : 0.6)

                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .offset(x: store.isPlaying ? 0 : 2)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onChange(of: store.isPlaying) { playing in
            pulse = playing
        }
    }
}
