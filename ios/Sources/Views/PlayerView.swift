import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var store: PlayerStore
    @Binding var isExpanded: Bool
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    @State private var showToast: String?
    @State private var isLyricsPage = false
    @AppStorage("aurora.vinylMode") private var vinylMode: Bool = true
    @State private var vinylStart: Date = Date()
    @State private var dominantColor: Color = .white

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

    // MARK: - 封面（黑胶 or 普通圆角矩形，由 aurora.vinylMode 控制）

    private func artworkStage(width: CGFloat, height: CGFloat) -> some View {
        // 封面固定占屏高的 ~45%，让 meta 自然占剩约 55%
        // 之前用 .frame(maxHeight: .infinity) → 封面无限撑开，meta 被挤到 home indicator 下面
        let targetHeight = height * 0.44
        return Group {
            if vinylMode {
                vinylArtwork(width: width, height: targetHeight)
            } else {
                roundedArtwork(width: width, height: targetHeight)
            }
        }
        .frame(maxWidth: .infinity, minHeight: targetHeight, idealHeight: targetHeight, maxHeight: targetHeight)
        .animation(.easeInOut(duration: 0.4), value: store.currentIndex)
        .animation(.easeInOut(duration: 0.3), value: vinylMode)
    }

    /// 黑胶版：TimelineView(.animation) 每帧驱动旋转，黑胶盘+封面一起转
    private func vinylArtwork(width: CGFloat, height: CGFloat) -> some View {
        // 封面尺寸：屏宽的 65%，最小 220 最大 300 — 和 stage 高度无关
        // 之前用 height * 0.38（整屏高度的 38%）→ 封面太大，挤占 meta 空间
        let vinylSide = max(220, min(width * 0.65, 300))
        let coverSide = vinylSide * 0.56

        return TimelineView(.animation(minimumInterval: 1/30)) { timeline in
            let angle = isSpinning
                ? (Date().timeIntervalSince(vinylStart) / 20.0) * 360
                : 0
            ZStack {
                vinylDisc(side: vinylSide)

                Group {
                    if let artwork = store.artwork {
                        Image(uiImage: artwork).resizable().scaledToFill()
                    } else {
                        ZStack {
                            LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.3)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "music.note")
                                .font(.system(size: coverSide * 0.3, weight: .light))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                .frame(width: coverSide, height: coverSide)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1.5))
                .overlay(alignment: .center) {
                    Circle()
                        .fill(.black.opacity(0.8))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 0.5))
                }
            }
            .rotationEffect(.degrees(angle))
        }
        .frame(width: vinylSide, height: vinylSide)
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .onChange(of: store.isPlaying) { playing in
            if playing { vinylStart = Date() }
        }
        .onChange(of: store.currentIndex) { _ in
            vinylStart = Date()
            extractDominantColor()
        }
        .onAppear { extractDominantColor() }
    }

    /// 从专辑封面提取主色调（CIAreaAverage 滤镜）
    private func extractDominantColor() {
        guard let image = store.artwork else { dominantColor = .white; return }
        DispatchQueue.global(qos: .utility).async {
            guard let cg = image.cgImage,
                  let filter = CIFilter(name: "CIAreaAverage") else { return }
            let ci = CIImage(cgImage: cg)
            let extent = CGRect(x: 0, y: 0, width: ci.extent.width, height: ci.extent.height)
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
            guard let out = filter.outputImage else { return }
            let ctx = CIContext(options: nil)
            guard let cgOut = ctx.createCGImage(out, from: out.extent) else { return }
            // 读 1x1 像素
            let width = 1, height = 1, bpp = 4
            var pixel = [UInt8](repeating: 0, count: width * height * bpp)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            guard let ctx2 = CGContext(data: &pixel, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: bpp,
                                       space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx2.draw(cgOut, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let r = Double(pixel[0]) / 255
            let g = Double(pixel[1]) / 255
            let b = Double(pixel[2]) / 255
            let color = Color(red: r, green: g, blue: b).opacity(0.92)
            DispatchQueue.main.async { dominantColor = color }
        }
    }

    /// 普通版：圆角矩形封面（原始样式）
    private func roundedArtwork(width: CGFloat, height: CGFloat) -> some View {
        // 和黑胶一致：屏宽的 65%，最小 180 最大 300
        let side = max(180, min(width * 0.65, 300))
        return Group {
            if let artwork = store.artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
                    .frame(width: side, height: side).clipped()
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                }.frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    /// 黑胶盘纹理：多层同心圆环 + 高光
    private func vinylDisc(side: CGFloat) -> some View {
        ZStack {
            // 底盘：深黑色
            Circle()
                .fill(LinearGradient(colors: [.black, .black.opacity(0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            // 唱针高光（顶部弧形反光）
            Circle()
                .fill(AngularGradient(colors: [
                    .clear,
                    .white.opacity(0.06),
                    .clear,
                    .white.opacity(0.04),
                    .clear
                ], center: .center))

            // 唱片纹理环（用 stroke 画多层同心圆）
            ForEach(0..<8, id: \.self) { i in
                Circle()
                    .stroke(.white.opacity(0.04), lineWidth: 1)
                    .frame(width: side - CGFloat(i) * (side / 14),
                           height: side - CGFloat(i) * (side / 14))
            }

            // 外圈金属质感边框
            Circle()
                .stroke(LinearGradient(colors: [
                    .white.opacity(0.3),
                    .white.opacity(0.05),
                    .white.opacity(0.25),
                    .white.opacity(0.05)
                ], startPoint: .top, endPoint: .bottom),
                        lineWidth: 2)
                .frame(width: side - 2, height: side - 2)

            // 中心挖空（放专辑封面）
            Circle()
                .fill(.clear)
                .frame(width: side * 0.56, height: side * 0.56)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: side, height: side)
    }

    private var isSpinning: Bool { store.isPlaying && !store.isLoading && !store.isBuffering }

    // MARK: - 顶栏

    private func topBar(safeTop: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { animateOut() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }

            VStack(spacing: 1) {
                Text(store.current?.title ?? "未播放")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(store.current?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)   // ← 顶栏剩余空间全部给它
            .padding(.horizontal, 8)     // ← 左右各留 8pt 缓冲

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

    /// 顶栏中间显示的专辑名（优先歌曲专辑，fallback 源名）
    private var albumDisplay: String {
        if let album = store.current?.album, !album.isEmpty { return album }
        return store.sourceName.isEmpty ? "在线播放" : store.sourceName
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
        // 顶栏已显示歌名+歌手，这里去掉重复的歌名和 tagRow
        VStack(alignment: .leading, spacing: 0) {
            currentLyricPill
                .padding(.top, 14)

            actionRow()
                .padding(.top, 18)

            progressSection()
                .padding(.top, 20)

            controls(safeBottom: safeBottom)
                .padding(.top, 10)
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.bottom, max(12, safeBottom + 4))   // ← 整体 meta 离 home indicator 留空间
        .layoutPriority(1)
    }

    private func tagRow() -> some View {
        HStack(spacing: 8) {
            Button {
                if let song = store.current {
                    NotificationCenter.default.post(name: .navigateToArtist, object: song)
                }
            } label: {
                HStack(spacing: 3) {
                    Text(store.current?.artist ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 120, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .buttonStyle(.plain)

            if let album = store.current?.album, !album.isEmpty {
                Text("·")
                    .foregroundStyle(.white.opacity(0.4))
                Text(album)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    /// 双行歌词（酷狗 PC 风格）：上一条左对齐 + 当前行右对齐
    private var currentLyricPill: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { isLyricsPage = true }
        } label: {
            VStack(spacing: 4) {
                // 第一行：上一条歌词 —— 左对齐、暗、小
                if let prev = previousLyricText {
                    Text(prev)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 第二行：当前歌词 —— 右对齐、亮、大
                Text(currentLyricText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: currentLyricText)
        .animation(.easeInOut(duration: 0.25), value: previousLyricText)
    }

    private var currentLyricText: String {
        if store.isLoading { return "正在解析歌词…" }
        if let index = store.currentLyricIndex, store.lyrics.indices.contains(index) {
            return store.lyrics[index].text
        }
        return store.lyrics.isEmpty ? "纯音乐 · 暂无歌词" : "点击查看完整歌词"
    }

    private var previousLyricText: String? {
        guard let index = store.currentLyricIndex, index > 0,
              store.lyrics.indices.contains(index - 1) else { return nil }
        let text = store.lyrics[index - 1].text
        return text.isEmpty ? nil : text
    }

    private func actionRow() -> some View {
        HStack(spacing: 0) {
            actionButton(icon: "arrow.down.to.line", label: downloadLabel) { download() }
            Spacer(minLength: 0)
            actionButton(icon: store.isLiked ? "heart.fill" : "heart",
                         label: "收藏",
                         tint: store.isLiked ? AppStyle.like : .white) {
                store.toggleFavorite()
            }
            Spacer(minLength: 0)
            actionButton(icon: "character.bubble", label: "翻译") {
                store.showTranslation.toggle()
            }
            Spacer(minLength: 0)
            actionButton(icon: "text.quote", label: "歌词") {
                withAnimation(.easeInOut(duration: 0.3)) { isLyricsPage = true }
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

    private func progressSection() -> some View {
        let progressFrac = max(0, min(1, store.progress))
        let bufferedFrac = max(0, min(1, store.bufferedFraction))

        return VStack(spacing: 6) {
            GeometryReader { geo in
                let trackWidth = geo.size.width
                let progressX = progressFrac * trackWidth

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: 3)

                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(width: bufferedFrac * trackWidth, height: 3)

                    Capsule()
                        .fill(LinearGradient(colors: [
                            dominantColor,
                            dominantColor.opacity(0.7)
                        ], startPoint: .leading, endPoint: .trailing))
                        .frame(width: progressX, height: 3)
                        .animation(.easeInOut(duration: 0.3), value: dominantColor)

                    if store.isPlaying {
                        GlowDot()
                            .frame(width: 10, height: 10)
                            .offset(x: progressX - 5)
                            .animation(.linear(duration: 0.2), value: progressX)
                    }

                    Circle()
                        .fill(dominantColor)
                        .frame(width: 14, height: 14)
                        .offset(x: progressX - 7)
                        .opacity(isScrubbing ? 1 : 0)
                        .shadow(color: dominantColor.opacity(0.6), radius: 8)
                        .animation(.easeInOut(duration: 0.3), value: dominantColor)
                }
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
            }
            .frame(height: 16)

            HStack {
                Text(displayTime.clockString)
                Spacer()
                Text(store.duration.clockString)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - 控制

    private func controls(safeBottom: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { store.cycleMode() } label: {
                Image(systemName: store.mode.icon)
                    .font(.system(size: 20))
                    .frame(width: 44, height: 56)
            }

            Spacer(minLength: 0)

            Button { store.step(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
            }

            Spacer(minLength: 0)

            PlayButton()

            Spacer(minLength: 0)

            Button { store.step(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
            }

            Spacer(minLength: 0)

            Button { store.isQueuePresented = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 56)
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
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

/// 进度条光点：跟着进度跑的脉冲白色光点 + 发光光晕
private struct GlowDot: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            // 外层光晕（脉冲放大淡出）
            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: 20, height: 20)
                .scaleEffect(pulse ? 1.4 : 0.7)
                .opacity(pulse ? 0 : 0.8)

            // 中层发光
            Circle()
                .fill(.white.opacity(0.6))
                .frame(width: 14, height: 14)
                .blur(radius: 3)

            // 核心白点
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulse = true
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
/// 性能关键：LazyVStack（只渲染可见行）+ index 直接比较（干掉 O(n²) firstIndex）+ 每行无 .animation（全局动画容器）。
private struct BigLyricsView: View {
    let lyrics: [LyricLine]
    let currentIndex: Int?
    var showsTranslation: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // LazyVStack：只渲染屏幕可见的几行 —— 100 行歌词 ≈ 同时渲染 8-10 行，
                // 对比 VStack 全量渲染 100 行，滚动时 body 重建量直接砍到 1/10。
                LazyVStack(spacing: 40) {
                    if lyrics.isEmpty {
                        Text("纯音乐 · 暂无歌词")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        // enumerated() 让每行持有自己的 index —— isActive/isNearActive 直接比较 index，
                        // 干掉原来的 firstIndex(where:) O(n) 扫描。ForEach × firstIndex = O(n²)。
                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { idx, line in
                            let activeIdx = currentIndex
                            let isActive = activeIdx == idx
                            let isNear = activeIdx != nil && abs(idx - activeIdx!) <= 1
                            VStack(spacing: 7) {
                                Text(line.text)
                                    .font(.system(size: isActive ? 30 : 20,
                                                  weight: isActive ? .bold : .medium))
                                    .foregroundStyle(isActive ? .white : .white.opacity(isNear ? 0.45 : 0.28))
                                    .multilineTextAlignment(.center)
                                if showsTranslation, let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(.system(size: isActive ? 15 : 12))
                                        .foregroundStyle(isActive ? .white.opacity(0.78) : .white.opacity(0.3))
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity)
                            .id(line.id)
                            // 关键：每行不单独加 .animation —— 以前每行都 .animation(.easeInOut(0.3), value: isActive)
                            // 导致 currentIndex 一变 100 行全部做 transition 动画。
                            // 只在容器级统一加一次 animation，SwiftUI 自动处理可见行的样式过渡。
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
        // 容器级统一动画 —— 只有一个 animation 作用在 LazyVStack 上，
        // 可见行的 active 状态样式变化会自动过渡，不可见行不渲染就不参与。
        .animation(.easeInOut(duration: 0.3), value: currentIndex)
    }

    private var activeId: UUID? {
        guard let index = currentIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }
}
