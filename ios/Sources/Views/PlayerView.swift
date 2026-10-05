import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var store: PlayerStore
    @Binding var isExpanded: Bool
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    @State private var showToast: String?
    @State private var isLyricsPage = false

    private var displayTime: Double { isScrubbing ? scrubValue : store.currentTime }

    var body: some View {
        // 直接用窗口的真实物理尺寸。绝不能用 GeometryReader：
        // 内部背景的 .ignoresSafeArea() 会反向把 GeometryReader 撑成超屏宽，
        // 导致整页被居中后左右偏移。
        let size = Self.windowBounds
        return ZStack {
            immersiveBackground
            VStack(spacing: 0) {
                topBar
                    .frame(width: size.width - 36)
                artworkStage(width: size.width, height: size.height)
                meta(width: size.width)
            }
            // 关键：VStack 钉住屏宽 + 居中对齐。
            // immersiveBackground 里有 .ignoresSafeArea() 把 ZStack 隐式宽度撑成超屏宽，
            // VStack 只有屏宽，SwiftUI 默认把它在宽 ZStack 里居中 → 视觉右移。
            // 加 alignment: .center 是保险，关键是 VStack 自己要对齐到中心。
            .frame(width: size.width, alignment: .center)
            .clipped()
            if isLyricsPage {
                LyricsPageView(isShown: $isLyricsPage)
                    .transition(.opacity)
            }
        }
        // 根 ZStack 也钉住屏宽，否则背景的 ignoresSafeArea 会把整页撑宽
        .frame(width: size.width, height: size.height, alignment: .center)
        .ignoresSafeArea(edges: .bottom)
        .gesture(dragGesture)
        .overlay(alignment: .bottom) { toastLayer }
        .onAppear(perform: animateIn)
        .onDisappear(perform: animateOut)
    }

    /// 设备窗口尺寸（keyWindow.bounds），取不到时给 XS 的 375×812 兜底。
    private static var windowBounds: CGSize {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let window = ws.windows.first(where: { $0.isKeyWindow }) ?? ws.windows.first,
               window.bounds.width > 0 {
                return window.bounds.size
            }
            if ws.screen.bounds.width > 0 { return ws.screen.bounds.size }
        }
        return CGSize(width: 375, height: 812)
    }

    // MARK: - 背景（封面取色渐变 + 封面虚化，酷狗风格）

    private var immersiveBackground: some View {
        ZStack {
            LinearGradient(colors: store.currentPalette.gradient,
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
            LinearGradient(colors: [.black.opacity(0.22),
                                    .black.opacity(0.05),
                                    .clear,
                                    store.currentPalette.scrim.opacity(0.4),
                                    store.currentPalette.scrim.opacity(0.88)],
                           startPoint: .top,
                           endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: store.currentIndex)
        .animation(.easeInOut(duration: 0.5), value: store.currentPalette)
    }

    // MARK: - 封面大图（确定性尺寸：宽-88 与可用高度 42% 取小，信息区永远完整）

    private func artworkStage(width: CGFloat, height: CGFloat) -> some View {
        let side = max(140, min(width - 88, height * 0.42, 360))
        return Group {
            if let artwork = store.artwork {
                // 和 CoverImage 同理：Image 自身也要 frame+clipped，
                // 只靠外层 Group 的 clipShape 在 iOS 16 上不能保证 scaledToFill 居中。
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity) // 在剩余空间里居中（横向已被固定屏宽锁死）
        .animation(.easeInOut(duration: 0.4), value: store.currentIndex)
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
                .lineLimit(1)
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

    // MARK: - 信息区

    private func meta(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.current?.title ?? "")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: width - 36, alignment: .leading)
                .padding(.horizontal, 18)

            tagRow(width: width)
                .padding(.top, 10)

            currentLyricPill
                .padding(.top, 14)
                .frame(width: width - 36, alignment: .leading)
                .clipped()
                .padding(.horizontal, 18)

            actionRow(width: width)
                .padding(.top, 18)

            progressSection(width: width)
                .padding(.top, 20)
                .padding(.horizontal, 18)

            controls
                .padding(.top, 10)
                // 原来贴着 home indicator，上提一段让控制键落在拇指更顺手的位置
                .padding(.bottom, 30)
        }
        .frame(width: width, alignment: .leading)
        .layoutPriority(1) // 信息区（歌名/按钮/进度）优先于封面占空间，任何机型都完整显示
    }

    private func tagRow(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(store.current?.artist ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(1)

            qualityPill

            if let album = store.current?.album, !album.isEmpty {
                Text(album)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(.white.opacity(0.3)))
            }

            ForEach((store.current?.tags ?? []).prefix(2), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(.white.opacity(0.3)))
            }
            Spacer(minLength: 0)
        }
        .frame(width: width - 36)
        .clipped()
        .padding(.horizontal, 18)
    }

    /// 当前行歌词胶囊（酷狗式单行），点击进入全屏歌词页
    private var currentLyricPill: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { isLyricsPage = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10, weight: .semibold))
                Text(currentLyricText)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: currentLyricText)
    }

    private var currentLyricText: String {
        if store.isLoading { return "正在解析歌词…" }
        if let index = store.currentLyricIndex, store.lyrics.indices.contains(index) {
            return store.lyrics[index].text
        }
        return store.lyrics.isEmpty ? "纯音乐 · 暂无歌词" : "点击查看完整歌词"
    }

    private func actionRow(width: CGFloat) -> some View {
        // 六个按钮等分【显式指定的屏宽-28】，任何机型都一屏显示，不滚动、不裁切
        HStack(spacing: 0) {
            actionButton(icon: "arrow.down.to.line", label: downloadLabel) { download() }
            actionButton(icon: store.isLiked ? "heart.fill" : "heart",
                         label: "收藏",
                         tint: store.isLiked ? AppStyle.like : .white) {
                store.toggleFavorite()
            }
            actionButton(icon: "character.bubble", label: "翻译") {
                store.showTranslation.toggle()
            }
            actionButton(icon: "text.quote", label: "歌词") {
                withAnimation(.easeInOut(duration: 0.3)) { isLyricsPage = true }
            }
            actionButton(icon: "list.bullet", label: "队列") {
                store.isQueuePresented = true
            }
            actionButton(icon: store.mode.icon, label: modeLabel) {
                store.cycleMode()
            }
        }
        .frame(width: width - 28)
        .clipped()
        .padding(.horizontal, 14)
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
                        .minimumScaleFactor(0.75)
                }
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 进度

    private func progressSection(width: CGFloat) -> some View {
        // 直接用外层传入的确定宽度，不再用 preference 回传 @State
        // （旧方案形成「胶囊宽度→测量→state→更宽」的反馈环，会把进度条撑到屏外）。
        let trackWidth = width - 36
        return VStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(height: 2)
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: max(0, min(1, store.bufferedFraction)) * trackWidth, height: 2)
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, min(1, store.progress)) * trackWidth, height: 2)
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, min(1, store.progress)) * trackWidth - 5)
                    .opacity(isScrubbing ? 1 : 0)
            }
            .frame(width: trackWidth, height: 12, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard store.duration > 0, trackWidth > 0 else { return }
                    if !isScrubbing {
                        isScrubbing = true
                        scrubValue = store.currentTime
                        Haptics.light()
                    }
                    scrubValue = min(1, max(0, value.location.x / trackWidth)) * store.duration
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
            .frame(width: trackWidth)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: trackWidth)
        .clipped()
    }

    // MARK: - 控制

    private var controls: some View {
        // 整行居中，且控制键整体上提
        HStack(spacing: 0) {
            Button { store.step(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28))
                    .frame(width: 68, height: 68)
            }

            PlayButton()

            Button { store.step(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28))
                    .frame(width: 68, height: 68)
            }
        }
        .frame(maxWidth: .infinity)
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

// MARK: - 全屏歌词页

/// 酷狗那种整页大字滚动歌词。半透明黑底压住播放页的其他元素，
/// 点返回或下滑收起，翻译开关直接放在页内。
struct LyricsPageView: View {
    @EnvironmentObject private var store: PlayerStore
    @Binding var isShown: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                }

                Spacer()

                VStack(spacing: 3) {
                    Text(store.current?.title ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(store.current?.artist ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
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
                        .opacity(store.showTranslation ? 1 : 0.45)
                        .frame(width: 44, height: 44)
                }
            }
            .foregroundStyle(.white)
            .padding(.top, 6)

            BigLyricsView(lyrics: store.lyrics,
                          currentIndex: store.currentLyricIndex,
                          showsTranslation: store.showTranslation)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 26)
        }
        .padding(.top, 12)
        // 加深一点：太透的话底下播放页的歌词/控件会透出来，看着像重影
        .background { Color.black.opacity(0.62).ignoresSafeArea() }
        .highPriorityGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.height > 60 {
                    withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
                }
            }
        )
    }
}

/// 歌词页专用的大字歌词流。逻辑和小字 LyricsView 一致，只是字号更大、
/// 当前行加粗放大得更明显。
private struct BigLyricsView: View {
    let lyrics: [LyricLine]
    let currentIndex: Int?
    var showsTranslation: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 26) {
                    if lyrics.isEmpty {
                        Text("纯音乐 · 暂无歌词")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        ForEach(lyrics) { line in
                            VStack(spacing: 6) {
                                Text(line.text)
                                    .font(.system(size: isActive(line) ? 24 : 18,
                                                  weight: isActive(line) ? .bold : .medium))
                                    .foregroundStyle(isActive(line) ? .white : .white.opacity(0.42))
                                    .multilineTextAlignment(.center)
                                if showsTranslation, let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(.system(size: isActive(line) ? 15 : 12))
                                        .foregroundStyle(isActive(line) ? .white.opacity(0.8) : .white.opacity(0.35))
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity)
                            .id(line.id)
                        }
                    }
                }
                .padding(.vertical, 80)
            }
            .mask(LinearGradient(colors: [.clear, .black.opacity(0.9), .black, .black.opacity(0.9), .clear],
                                startPoint: .top,
                                endPoint: .bottom))
            .onChange(of: currentIndex) { _ in
                guard let id = activeId else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: lyrics) { _ in proxy.scrollTo(lyrics.first?.id, anchor: .center) }
        }
    }

    private func isActive(_ line: LyricLine) -> Bool {
        guard let index = currentIndex, lyrics.indices.contains(index) else { return false }
        return line.id == lyrics[index].id
    }

    private var activeId: UUID? {
        guard let index = currentIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }
}
