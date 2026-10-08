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
        let win = Self.windowInfo
        return ZStack {
            immersiveBackground
            VStack(spacing: 0) {
                topBar(safeTop: win.safeTop)
                    .frame(width: win.size.width - 36)
                artworkStage(width: win.size.width, height: win.size.height)
                meta(width: win.size.width, safeBottom: win.safeBottom)
            }
            // 关键：VStack 钉住屏宽 + 居中对齐。
            // immersiveBackground 里有 .ignoresSafeArea() 把 ZStack 隐式宽度撑成超屏宽，
            // VStack 只有屏宽，SwiftUI 默认把它在宽 ZStack 里居中 → 视觉右移。
            // 加 alignment: .center 是保险，关键是 VStack 自己要对齐到中心。
            .frame(width: win.size.width, alignment: .center)
            .clipped()
            if isLyricsPage {
                LyricsPageView(isShown: $isLyricsPage)
                    .transition(.opacity)
            }
        }
        // 根 ZStack 也钉住屏宽，否则背景的 ignoresSafeArea 会把整页撑宽
        .frame(width: win.size.width, height: win.size.height, alignment: .center)
        .ignoresSafeArea(edges: .bottom)
        .gesture(dragGesture)
        .overlay(alignment: .bottom) { toastLayer }
        .onAppear(perform: animateIn)
        .onDisappear(perform: animateOut)
    }

    /// 设备窗口尺寸 + safeAreaInsets（keyWindow），取不到时给 XS 兜底。
    private static var windowInfo: (size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let window = ws.windows.first(where: { $0.isKeyWindow }) ?? ws.windows.first,
               window.bounds.width > 0 {
                return (window.bounds.size, window.safeAreaInsets.top, window.safeAreaInsets.bottom)
            }
            if ws.screen.bounds.width > 0 {
                return (ws.screen.bounds.size, 0, 0)
            }
        }
        return (CGSize(width: 375, height: 812), 44, 34)
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
        // 注意：不在 blur 外层加 .drawingGroup() —— SwiftUI blur 在 iOS 16+ 走 Metal vImage GPU 管线，
        // 外层 .drawingGroup() 会强制分配一张 ~12MB 全屏 backing store 做二次光栅化，产生双倍显存峰值。
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
        // 优化：用轻微 shadow 代替重阴影 —— 减少离屏渲染开销
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.4), value: store.currentIndex)
    }

    // MARK: - 顶栏

    private func topBar(safeTop: CGFloat) -> some View {
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
        // safeAreaInsets.top 在 XS 上是 44，刘海已经占了，再加 8pt 让按键完全不贴刘海
        .padding(.top, max(12, safeTop + 4))
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
        if store.isBuffering { return "缓冲中" }
        if store.isLoading { return "解析中" }
        if store.playbackError != nil { return "无法播放" }
        return store.bitrateLabel.isEmpty ? SourceStore.shared.quality.title : store.bitrateLabel
    }

    // MARK: - 信息区

    private func meta(width: CGFloat, safeBottom: CGFloat) -> some View {
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

            controls(safeBottom: safeBottom)
                .padding(.top, 10)
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
        // 四个按钮等分【显式指定的屏宽-28】，任何机型都一屏显示
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

    private func controls(safeBottom: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 左：顺序模式（紧贴上一首）
            Button { store.cycleMode() } label: {
                Image(systemName: store.mode.icon)
                    .font(.system(size: 20))
                    .frame(width: 44, height: 56)
            }

            Spacer().frame(width: 12)

            Button { store.step(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28))
                    .frame(width: 60, height: 56)
            }

            PlayButton()

            Button { store.step(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28))
                    .frame(width: 60, height: 56)
            }

            Spacer().frame(width: 12)

            // 右：队列（紧贴下一首）
            Button { store.isQueuePresented = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 56)
            }
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        // 底部间距：safeAreaInsets.bottom 在 XS 上是 34（home indicator），再加 6pt
        .padding(.bottom, max(12, safeBottom + 6))
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

                if store.isLoading || store.isBuffering {
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

/// 深色沉浸式全屏歌词，背景与播放页同款取色 + 专辑图模糊。
/// 词曲/编曲/制作人等简介信息独立为顶部折叠模块，滚动区只保留正文歌词。
struct LyricsPageView: View {
    @EnvironmentObject private var store: PlayerStore
    @Binding var isShown: Bool
    @State private var isMetaExpanded = false

    private var safeTop: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene,
               let w = ws.windows.first(where: { $0.isKeyWindow }) ?? ws.windows.first {
                return max(12, w.safeAreaInsets.top + 6)
            }
        }
        return 50
    }

    var body: some View {
        ZStack {
            // 沉浸式取色背景（专辑图模糊 + 渐变）
            ZStack {
                LinearGradient(colors: store.currentPalette.gradient,
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                    .opacity(0.96)

                if let artwork = store.artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 72)
                        .opacity(0.42)
                        .scaleEffect(1.3)
                        .clipped()
                }

                LinearGradient(colors: [.black.opacity(0.35),
                                        .black.opacity(0.18),
                                        .black.opacity(0.3),
                                        .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶栏：降低存在感
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
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(store.current?.artist ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
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
                            .opacity(store.showTranslation ? 1 : 0.4)
                            .frame(width: 44, height: 44)
                    }
                }
                .foregroundStyle(.white)
                .padding(.top, safeTop)
                .opacity(0.5)  // 顶栏低存在感

                // 折叠简介模块（只在有 metadata 时显示）
                metaSection
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .opacity(store.lyricMetadata.isEmpty ? 0 : 0.85)

                // 纯正文歌词滚动区
                BigLyricsView(lyrics: store.lyrics,
                              currentIndex: store.currentLyricIndex,
                              showsTranslation: store.showTranslation)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 26)
                    .padding(.top, 12)
            }
        }
        .ignoresSafeArea()
        .highPriorityGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.height > 60 {
                    withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
                }
            }
        )
    }

    // MARK: - 折叠简介

    private var metaSection: some View {
        let meta = store.lyricMetadata
        let orderedKeys: [(String, String)] = [
            ("词", "词"), ("曲", "曲"), ("作曲", "作曲"), ("编曲", "编曲"),
            ("制作人", "制作人"), ("监制", "监制"), ("混音", "混音"),
            ("录音", "录音"), ("和声", "和声"), ("发行", "发行")
        ]
        .filter { meta[$0.1] != nil }

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isMetaExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text("词曲编曲")
                        .font(.system(size: 11))
                    Spacer()
                    Image(systemName: isMetaExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            if isMetaExpanded && !orderedKeys.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(orderedKeys, id: \.0) { pair in
                        HStack(alignment: .top, spacing: 0) {
                            Text(pair.1 + "：")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 48, alignment: .leading)
                            Text(meta[pair.1] ?? "")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// 全屏歌词页专用大字歌词流。当前行 30pt 纯白垂直居中，其他行 20pt 浅灰，行间距拉大到 40pt。
private struct BigLyricsView: View {
    let lyrics: [LyricLine]
    let currentIndex: Int?
    var showsTranslation: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 40) {
                    if lyrics.isEmpty {
                        Text("纯音乐 · 暂无歌词")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        ForEach(lyrics) { line in
                            VStack(spacing: 7) {
                                Text(line.text)
                                    .font(.system(size: isActive(line) ? 30 : 20,
                                                  weight: isActive(line) ? .bold : .medium))
                                    .foregroundStyle(isActive(line) ? .white : .white.opacity(isNearActive(line) ? 0.45 : 0.28))
                                    .multilineTextAlignment(.center)
                                if showsTranslation, let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(.system(size: isActive(line) ? 15 : 12))
                                        .foregroundStyle(isActive(line) ? .white.opacity(0.78) : .white.opacity(0.3))
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity)
                            .id(line.id)
                            .animation(.easeInOut(duration: 0.3), value: isActive(line))
                        }
                    }
                }
                .padding(.vertical, 120)
            }
            .mask(LinearGradient(colors: [.clear, .black.opacity(0.85), .black, .black.opacity(0.85), .clear],
                                startPoint: .top,
                                endPoint: .bottom))
            .onChange(of: currentIndex) { _ in
                guard let id = activeId else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
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

    /// 当前行相邻的上下两行用稍深的浅灰（0.45），再远的更浅（0.28）。
    private func isNearActive(_ line: LyricLine) -> Bool {
        guard let index = currentIndex, lyrics.indices.contains(index) else { return false }
        guard let lineIndex = lyrics.firstIndex(where: { $0.id == line.id }) else { return false }
        return abs(lineIndex - index) <= 1
    }

    private var activeId: UUID? {
        guard let index = currentIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }
}
