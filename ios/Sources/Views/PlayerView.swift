import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var store: PlayerStore
    @Binding var isExpanded: Bool
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var geometryWidth: CGFloat = 0
    @State private var showToast: String?

    private var displayTime: Double { isScrubbing ? scrubValue : store.currentTime }

    var body: some View {
        ZStack {
            immersiveBackground
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
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
        .animation(.easeInOut(duration: 0.5), value: store.currentIndex)
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

            VStack(spacing: 2) {
                Text(store.sourceName.isEmpty ? "在线播放" : store.sourceName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 18, height: 5)
            }
            .frame(maxWidth: .infinity)

            Spacer()

            HStack(spacing: 18) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 40, height: 40)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 4)
    }

    private var shareText: String {
        let song = store.current
        return "\(song?.title ?? "") - \(song?.artist ?? "")"
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
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(AppStyle.gold.opacity(0.22), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(AppStyle.gold.opacity(0.45), lineWidth: 0.5))
    }

    private var qualityText: String {
        if store.isLoading { return "解析中" }
        if store.playbackError != nil { return "无法播放" }
        return store.bitrateLabel.isEmpty ? SourceStore.shared.quality.title : store.bitrateLabel
    }

    private var lyrics: some View {
        LyricsView(lyrics: store.lyrics,
                   currentIndex: store.currentLyricIndex,
                   showsTranslation: store.showTranslation)
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
        }
    }

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(store.current?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)

                qualityPill

                if let album = store.current?.album, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(.white.opacity(0.3)))
                }

                ForEach(store.current?.tags ?? [], id: \.self) { tag in
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
            actionButton(icon: "arrow.down.to.line", label: downloadLabel) { download() }
            actionButton(icon: "bell", label: "铃声") { setRingtone() }
            actionButton(icon: store.isLiked ? "heart.fill" : "heart",
                         label: "收藏",
                         tint: store.isLiked ? AppStyle.like : .white) {
                store.toggleFavorite()
            }
            actionButton(icon: "character.bubble", label: "翻译") {
                store.showTranslation.toggle()
            }
            actionButton(icon: "list.bullet", label: "队列") {
                store.isQueuePresented = true
            }
            actionButton(icon: store.mode.icon, label: modeLabel) {
                store.cycleMode()
            }
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
                        .fixedSize()
                }
            }
            .foregroundStyle(tint)
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
                    guard store.duration > 0, geometryWidth > 0 else { return }
                    if !isScrubbing {
                        isScrubbing = true
                        scrubValue = store.currentTime
                        Haptics.light()
                    }
                    scrubValue = min(1, max(0, value.location.x / geometryWidth)) * store.duration
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

    // MARK: - 控制

    private var controls: some View {
        HStack {
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

    private func setRingtone() {
        guard let song = store.current else { return }
        // 下载目录开了文件共享，用户可以在「文件 - 我的 iPhone」里长按设为铃声。
        guard DownloadManager.shared.localURL(for: song) != nil else {
            return show("先把歌下载下来，再设为铃声")
        }
        show("在「文件 - 我的 iPhone - Aurora Downloads」里长按设为铃声")
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

                if store.isLoading {
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
