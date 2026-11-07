import SwiftUI
import UIKit

/// 歌手主页：酷狗同款大图头部（歌手名 + 粉丝 + 黄色收藏）+ 金色下划线分段
/// 「单曲 / 专辑」+ 全部播放行（最新/最热排序）+ 扁平化编号歌曲列表 + 多选下载。
struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject private var store: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @ObservedObject private var library = LibraryStore.shared

    // 顶部 Tab：歌曲 / 专辑
    @State private var tab: Int = 0

    // 🔴 v2.5.46：排序（最热=接口原序 / 最新=倒序）
    @State private var sortNewest = false

    // 多选模式
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

    // 🔴 v2.9.8：滚动量 = **实测**的内容上移距离（>=0），由 ScrollViewOffsetTracker 通过 KVO 写入，
    // 驱动大图收缩 / 锁定 / 毛玻璃渐入 / 歌手名转入导航栏标题。
    // 🔴 2026-11-07：改成实测值（原来是裸的 contentOffset.y，静止时可能是负数 → 吸顶位置算错）。
    @State private var headerScroll: CGFloat = 0

    /// 🔴 实测：静止时「滚动内容 y=0」在 window 坐标系里的 y（探针直接量）。
    /// 顶部内边距抵消后它应该 = 0；不为 0 说明滚动容器的 frame 没延伸到屏幕顶端，
    /// 这时用它把大图和列表精确对位（安全网）。
    @State private var contentOriginYRest: CGFloat = 0

    /// 🔴 吸顶头（分段 Tab + 全部播放）的高度：由 PreferenceKey 实测，
    /// 用来给滚动内容预留占位，使列表从吸顶头下方开始。
    @State private var stickyHeaderHeight: CGFloat = 100

    /// 酷狗同款收藏按钮的黄色
    private static let collectYellow = Color(red: 0.98, green: 0.87, blue: 0.20)

    // 歌曲分页
    @State private var songPage = 1
    @State private var hasMoreSongs = true
    @State private var isLoadingMore = false

    /// 排序后的展示列表（最热=原序，最新=倒序）
    private var displaySongs: [Song] { sortNewest ? songs.reversed() : songs }

    /// 🔴 v2.5.47：歌手封面高清化 —— 酷狗 singer/list 的 imgurl 是 200px 小图，
    /// 全屏大图直接放大发糊。softhead 支持 400px，kugouicon 支持 400px，
    /// stdmusic 支持 500px，显示时统一升到最大档。
    private var hiResCoverURL: URL? {
        guard let raw = artist.coverURL?.absoluteString else { return nil }
        var s = raw
        for sz in ["90", "100", "120", "150", "165", "200", "240"] {
            s = s.replacingOccurrences(of: "softhead/\(sz)/", with: "softhead/400/")
            s = s.replacingOccurrences(of: "kugouicon/\(sz)/", with: "kugouicon/400/")
            s = s.replacingOccurrences(of: "stdmusic/\(sz)/", with: "stdmusic/500/")
            s = s.replacingOccurrences(of: "simg/\(sz)/", with: "simg/400/")
        }
        return URL(string: s)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // ① 滚动内容：大图是**内容第一项**，列表紧随其后，一起上滑。
            //
            // 🔴 大图能盖住透明导航栏的前提：「滚动内容原点」精确落在屏幕 y=0。
            //    SwiftUI 默认给内容加一段顶部内边距（导航栏那截 ≈91pt），内容原点会掉到
            //    导航栏下沿 → 顶部露出页面底色 = **白顶**（实测白区 179pt）。
            //    探针 ScrollViewOffsetTracker 会把 adjustedContentInset.top 抵消成 0，
            //    内容原点就落在 y=0，这里的大图**零偏移**即可盖住导航栏。
            ScrollView {
                VStack(spacing: 0) {
                    // 🔴 滚动几何探针：必须放进滚动内容内部（不能放 .background），
                    // 否则 superview 链上找不到 UIScrollView，KVO 拿不到 contentOffset（经验教训）。
                    ScrollViewOffsetTracker { m in
                        DispatchQueue.main.async {
                            headerScroll = m.scrolled
                            contentOriginYRest = m.contentOriginYRest
                        }
                    }
                    .frame(height: 0)

                    // 大图本体：内容第一项 → 必然随列表一起上滑（不会冻在顶部），
                    // 静止时从屏幕 y=0 开始，正好盖住透明导航栏。
                    // 安全网：万一滚动容器的 frame 没延伸到屏幕顶端（实测内容原点 > 0），
                    // 就用实测值把它提上去，精确落在 y=0。
                    heroImageContent
                        .offset(y: -contentOriginYRest)

                    // 吸顶头占位：预留「分段 Tab + 全部播放」的高度，列表从它下方开始。
                    Color.clear.frame(height: stickyHeaderHeight)

                    // 列表主体（不含 全部播放 / 分段 Tab，那些已提到吸顶头）。
                    if tab == 0 {
                        songListBody
                    } else {
                        albumGridSection
                    }
                }
            }
            .background(AppStyle.background)
            .ignoresSafeArea(edges: .top)

            // ② 毛玻璃导航栏背景：大图滚走后渐入，系统工具栏（返回 / 歌手名 / 收藏）浮在其上。
            //    用 offset 把它从「导航栏下沿」提到屏幕最顶端（0 ~ topInset）。
            navbarFrostedBackground
                .offset(y: -topInset)

            // ③ 吸顶头（分段 Tab + 全部播放）：钉在顶栏下方，不随列表滚走；
            //    大图未收起时贴着大图底边一起走，收起后固定在顶栏正下方。
            stickyHeader
                .offset(y: stickyY)
                .background(AppStyle.background)
        }
        .onPreferenceChange(StickyHeaderHeightKey.self) { stickyHeaderHeight = $0 }
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 v2.9.8：导航栏一直浮在大图上 → 永远透明、白字，大图始终盖住顶栏。
        .compatToolbarDynamicScheme(dark: true)
        .kugouNavigationBarBackground(.clear, transparent: true)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isSelecting {
                    Text("已选 \(selectedIDs.count) 首")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    // 🔴 用户要求：大图随滚动收起，歌手名从大图中央渐隐、转入导航栏标题（与毛玻璃同步渐显）。
                    Text(artist.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .lineLimit(1)
                        .opacity(navFrostOpacity)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button {
                        if selectedIDs.count == displaySongs.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(songs.map(\.id))
                        }
                    } label: {
                        Text(selectedIDs.count == displaySongs.count ? "取消全选" : "全选")
                            .font(.system(size: 14, weight: .medium))
                    }
                } else {
                    // 🔴 v2.9.8：导航栏浮在大图上 → 图标统一白字；
                    // 黄色收藏胶囊一直显示（大图钉在顶部，随时都能收藏）。
                    HStack(spacing: 12) {
                        Button {
                            Haptics.soft()
                            library.toggleArtistFavorite(artist)
                        } label: {
                            Text(library.isFavoriteArtist(artist) ? "已收藏" : "收藏")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Self.collectYellow))
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button {
                                Haptics.soft()
                                library.toggleArtistFavorite(artist)
                            } label: {
                                Label(library.isFavoriteArtist(artist) ? "取消收藏" : "收藏歌手",
                                      systemImage: library.isFavoriteArtist(artist) ? "heart.slash" : "heart")
                            }
                            Button {
                                isSelecting = true
                                selectedIDs.removeAll()
                            } label: {
                                Label("多选下载", systemImage: "checkmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .semibold))
                                .rotationEffect(.degrees(90))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button {
                        isSelecting = false
                        selectedIDs.removeAll()
                    } label: {
                        Text("完成").font(.system(size: 14, weight: .medium))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !selectedIDs.isEmpty {
                selectedActionBar
            }
        }
        .task { await loadSongs() }
        .onChange(of: isSelecting) { newValue in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                store.isAnyMultiSelecting = newValue
            }
        }
        .onDisappear { store.isAnyMultiSelecting = false }
    }

    // MARK: - 分段 Tab 条（酷狗同款：文字 + 金色下划线）

    private var tabBar: some View {
        HStack(spacing: 26) {
            tabButton(title: "单曲", count: songs.count, selected: tab == 0) {
                withAnimation(.easeOut(duration: 0.2)) { tab = 0 }
            }
            tabButton(title: "专辑", count: albums.count, selected: tab == 1) {
                withAnimation(.easeOut(duration: 0.2)) { tab = 1 }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func tabButton(title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: selected ? .bold : .regular))
                        .foregroundStyle(selected ? AppStyle.primaryText : AppStyle.secondaryText)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppStyle.secondaryText)
                    }
                }
                // 🔴 v2.5.47：下划线改蓝色（原金色）
                Capsule()
                    .fill(selected ? AppStyle.accent : Color.clear)
                    .frame(width: 22, height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 顶部大图头部（酷狗同款；height 由拉伸效果动态传入）

    /// 头部基础高度（下拉时由 body 里的 GeometryReader 拉伸放大）
    /// 🔴 用户要求：大图整块上移一点 —— 从 400 降到 350，图片下边界上移、列表更早出现。
    private let headerBaseHeight: CGFloat = 350

    /// 导航栏高度（inline 导航栏 = 状态栏下方 44pt 的 bar）。
    /// 大图要盖满整个顶部（连导航栏那一块），偏移量需额外加上这一截。
    private let navBarHeight: CGFloat = 44

    /// 🔴 v2.9.7：状态栏（通知栏）高度。
    /// 大图要一直铺到屏幕最上端，所以要把状态栏那一块也算进头部高度里。
    ///
    /// 用 keyWindow 的 `safeAreaInsets.top` —— 它就是状态栏高度，
    /// 比 `statusBarManager` 稳（后者在多窗口/未激活时可能返回 0）。
    private var statusBarHeight: CGFloat {
        let inset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
        return inset > 0 ? inset : 20
    }

    /// 🔴 v2.9.8：大图要盖满顶部整条（状态栏 + 导航栏），偏移量 = 二者之和。
    private var topInset: CGFloat { statusBarHeight + navBarHeight }

    /// 🔴 用户要求：大图随滚动收起的进度（0=完全展开，1=完全收起锁定），
    /// 用于毛玻璃平滑渐入，避免折叠完成才突然出现的生硬切换。
    private var collapseProgress: CGFloat {
        // 大图底边从 headerBaseHeight 滑到导航栏底边（topInset）时收起完成。
        let maxDrag = max(1.0, headerBaseHeight - topInset)
        // headerScroll 现在是**实测的内容上移距离**（>=0，静止时为 0）。
        let drag = max(0, headerScroll)
        return min(1, drag / maxDrag)
    }

    /// 🔴 列表顶部占位高度。
    ///
    /// 大图虽然用 offset 提到了屏幕顶端，但 **offset 不改变布局**——它在内容流里仍占
    /// headerBaseHeight 高度，所以列表的内容位置 = 内容原点 + 大图高 + 本占位。
    /// 列表要落在「大图底边 + 吸顶头高度」= 350 + 吸顶头高，
    /// 于是占位 = 吸顶头高 − 实测内容原点。
    private var listTopSpacer: CGFloat {
        max(0, stickyHeaderHeight - contentOriginYRest)
    }

    /// 🔴 用户要求：毛玻璃导航栏背景只在「滚到图片底部、图片快滚完」时才渐显，
    /// 不要提前出现。collapseProgress=1 表示图片底部已抵达导航栏（图片完全收起），
    /// 这里从 0.8 才开始渐入、1.0 完全不透明，与导航栏标题同步。
    private var navFrostOpacity: CGFloat {
        max(0, min(1, (collapseProgress - 0.8) / 0.2))
    }

    /// 🔴 吸顶头（分段 Tab + 全部播放）相对 ZStack 顶部的偏移。
    /// ZStack 顶部 = 导航栏底边（screen y = topInset）。
    /// 静止时吸顶头贴在大图底边（screen y = headerBaseHeight），
    /// 即相对根原点偏移 = headerBaseHeight - topInset = maxDrag；
    /// 上滑时与大图底边 1:1 同步上移，大图滚完后钉在导航栏底边（offset 0）。
    private var stickyY: CGFloat {
        // 🔴 静止时吸顶头贴在大图底边（window y = headerBaseHeight），滚到大图完全收起后
        //    钉在导航栏底边（window y = topInset）。两者之间线性过渡。
        let maxDrag = headerBaseHeight - topInset
        // 🔴 系数 1：吸顶头与大图底边 1:1 同步上滑（贴着大图底边），大图完全滚走后才钉在顶栏下方；
        // 之前系数 2 让吸顶头以 2× 速度甩开大图、提前冲到顶栏，视觉上"按钮比图片飞得快"。
        return max(0, maxDrag - headerScroll)
    }

    /// 🔴 吸顶头：分段 Tab（单曲/专辑）+ 全部播放行。钉在顶栏下方，不随列表滚走。
    /// 仅单曲 Tab 显示「全部播放」；专辑 Tab 只显示分段 Tab（高度随内容自适应）。
    /// 背景用 GeometryReader 实测高度，写入 StickyHeaderHeightKey 供滚动占位使用。
    private var stickyHeader: some View {
        VStack(spacing: 0) {
            tabBar
            if tab == 0 {
                allPlayRow
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: StickyHeaderHeightKey.self, value: geo.size.height)
            }
        )
    }

    // MARK: - 顶部大图（滚动内容第一项，随列表上滑）

    /// 大图本体：作为**滚动容器的 overlay**（不是滚动内容的第一项），位置由实测坐标算出、
    /// 静止时精确落在屏幕 y=0（盖住透明导航栏），上滑时按 1:1 与列表同步上移。
    ///
    /// 🔴 为什么不做成滚动内容的第一项：那样「ScrollView 的 ignoresSafeArea」和
    /// 「大图自己的 ignoresSafeArea」会叠加计算，把大图整体下推 2 个安全区（实测 180pt），
    /// 顶部就露出页面底色 = 白顶。改成 overlay 后彻底没有这个叠加点。
    private var heroImageContent: some View {
        let screenW = UIScreen.main.bounds.width
        return ZStack(alignment: .bottom) {
            // 🔴 深色兜底背板：CoverImage 的 .fill 兜底是浅灰近白，图未加载时会露白；
            // 垫一层深色，任何情况下顶部（含导航栏区域）都不会是白色。
            Color(red: 0.07, green: 0.07, blue: 0.09)
                .frame(width: screenW, height: headerBaseHeight)

            // 🔴 大图：.fill 铺满整框（不露白边/白顶）；.top 顶部对齐把歌手头部顶到导航栏，
            // 既盖住顶栏不露白，又避免居中填充把头部裁掉（用户最早反馈"图片显示不全"的根因）。
            // fallbackColor 同步深色，图未加载瞬间也不露白。
            CoverImage(
                url: hiResCoverURL,
                fallbackKeys: [artist.id],
                seed: artist.name,
                size: max(screenW, 800),
                corner: 0,
                displayWidth: screenW,
                displayHeight: headerBaseHeight,
                contentMode: .fill,
                imageAlignment: .top,
                fallbackColor: Color(red: 0.07, green: 0.07, blue: 0.09)
            )
            .frame(width: screenW, height: headerBaseHeight)
            .clipped()

            LinearGradient(colors: [.clear, Color.black.opacity(0.05), Color.black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: screenW, height: headerBaseHeight)

            VStack(alignment: .leading, spacing: 10) {
                Text(artist.name)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)

                if artist.fansCount > 0 {
                    Text("粉丝\(formatFans(artist.fansCount))")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                }

                HStack(spacing: 12) {
                    CoverImage(
                        url: hiResCoverURL,
                        fallbackKeys: [artist.id],
                        seed: artist.name,
                        size: 40,
                        corner: 20
                    )
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1.5))

                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            // 上滑时整块文案淡出，名字交给导航栏标题显示，避免和顶栏按钮叠在一起。
            .opacity(1 - collapseProgress)
        }
        .frame(width: screenW, height: headerBaseHeight)
        .clipped()
        // 🔴 构建标识：CI 把本次 commit 写进 Info.plist（GitCommit），显示在大图右下角，
        // 避免"装了旧包却以为是新包"导致反复误判。确认修复后即可移除。
        .overlay(alignment: .bottomTrailing) {
            if let buildTag = Bundle.main.infoDictionary?["GitCommit"] as? String,
               !buildTag.isEmpty {
                Text(buildTag)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.black.opacity(0.22)))
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    /// 钉在顶部的固定导航栏背景：展示大图顶部切片 + 深色渐变 + 毛玻璃。
    /// 大图随列表滑走后，它渐入成为「毛玻璃导航栏背景」；渐入进度由收起后段驱动，避免与正在滑动的大图重影。
    private var navbarFrostedBackground: some View {
        let screenW = UIScreen.main.bounds.width
        // 🔴 毛玻璃只在滚到图片底部（collapseProgress→1）才渐显，复用 navFrostOpacity 计算属性。
        return ZStack(alignment: .top) {
            CoverImage(
                url: hiResCoverURL,
                fallbackKeys: [artist.id],
                seed: artist.name,
                size: max(screenW, 800),
                corner: 0,
                displayWidth: screenW,
                displayHeight: headerBaseHeight,
                contentMode: .fill,
                imageAlignment: .top,
                fallbackColor: Color(red: 0.07, green: 0.07, blue: 0.09)
            )
            .frame(width: screenW, height: headerBaseHeight)
            .clipped()

            LinearGradient(colors: [.clear, Color.black.opacity(0.05), Color.black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: screenW, height: headerBaseHeight)

            Rectangle()
                .fill(.regularMaterial)
        }
        .frame(width: screenW, height: topInset)
        .clipped()
        // 🔴 位置由外层的 .offset(y: -topInset) 决定（提到屏幕最顶端），
        //    这里**不能再加** ignoresSafeArea(edges:.top)——那会再往上提一个安全区，
        //    毛玻璃条就错位了（安全区叠加是之前"白顶"的同类坑）。
        .allowsHitTesting(false)
        .opacity(navFrostOpacity)
    }

    // MARK: - 歌曲列表（酷狗同款：全部播放行 + 最新/最热 + 扁平编号列表）

    /// 🔴 全部播放行（蓝色播放圆钮 + 排序切换 + 多选下载）—— 提到「吸顶头」，不随列表滚走。
    private var allPlayRow: some View {
        HStack(spacing: 10) {
            Button {
                guard !songs.isEmpty else { return }
                Haptics.soft()
                store.queueID = "artist:\(artist.id)"
                store.play(songs, startAt: 0)
            } label: {
                HStack(spacing: 8) {
                    // 🔴 v2.5.47：播放圆钮改蓝色（原金色）
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(AppStyle.accent))
                    Text("全部播放")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppStyle.primaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(songs.isEmpty)

            Spacer(minLength: 0)

            // 最新 / 最热 胶囊切换
            HStack(spacing: 0) {
                sortButton("最新", selected: sortNewest) { sortNewest = true }
                sortButton("最热", selected: !sortNewest) { sortNewest = false }
            }
            .background(AppStyle.surface.opacity(0.9), in: Capsule())
            .overlay(Capsule().stroke(AppStyle.stroke, lineWidth: 0.5))

            // 多选（下载用）
            if !isSelecting {
                Button {
                    isSelecting = true
                    selectedIDs.removeAll()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(AppStyle.secondaryText)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// 🔴 歌曲列表主体（不含 全部播放行 / 分段 Tab，那些已提到吸顶头）。
    private var songListBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: 60)
                    .padding(.horizontal, 16)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: 60).padding(.horizontal, 16)
            } else if songs.isEmpty {
                Text("暂时没找到歌曲")
                    .font(.system(size: 13)).foregroundStyle(AppStyle.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: 60)
            } else {
                // 🔴 v2.5.46：扁平化列表（去掉卡片底），酷狗同款编号行
                LazyVStack(spacing: 0) {
                    ForEach(Array(displaySongs.enumerated()), id: \.element.id) { index, song in
                        let selected = selectedIDs.contains(song.id)
                        HStack(spacing: 0) {
                            if isSelecting {
                                Button {
                                    if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                } label: {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 24))
                                        .foregroundStyle(selected ? AppStyle.accent : AppStyle.tertiaryText)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                            }
                            ArtistSongRow(song: song, index: index + 1) {
                                Haptics.soft()
                                store.queueID = "artist:\(artist.id)"
                                store.play(songs, startAt: songs.firstIndex(where: { $0.id == song.id }) ?? 0)
                            }
                            .padding(.leading, isSelecting ? 0 : 4)
                        }
                        .onAppear {
                            if index == displaySongs.count - 5 {
                                Task { await loadMoreSongs() }
                            }
                        }
                        Divider().padding(.leading, isSelecting ? 56 : 60)
                    }
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            ProgressView().controlSize(.small)
                            Text("加载中...").font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText)
                        } else if !hasMoreSongs && songs.count > 0 {
                            Text("— 到底了 —").font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 14)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
    }

    private func sortButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            withAnimation(.easeOut(duration: 0.18)) { action() }
            Haptics.light()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AppStyle.primaryText : AppStyle.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? AppStyle.surface : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 专辑列表（统一和歌曲列表一样的卡片样式）

    private var albumGridSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if albums.isEmpty {
                // 专辑为空，底部留点空间让布局对齐
                EmptyView()
            } else {
                HStack {
                    Text("全部专辑")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppStyle.primaryText)
                    Spacer()
                    Text("共 \(albums.count) 张")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

                VStack(spacing: 0) {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            HStack(spacing: 14) {
                                CoverImage(
                                    url: album.coverURL,
                                    fallbackKeys: album.albumID.isEmpty ? [] : ["al:\(album.albumID)"],
                                    seed: album.name,
                                    size: 52,
                                    corner: 8
                                )
                                .frame(width: 52, height: 52)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(album.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(AppStyle.primaryText)
                                        .lineLimit(2)
                                    Text(album.artist)
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppStyle.secondaryText)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 78)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .background(AppStyle.surface.opacity(albums.isEmpty ? 0 : 0.45))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 20)
    }

    // MARK: - 多选底部操作条（美化播放/下载）

    private var selectedActionBar: some View {
        let selected = songs.filter { selectedIDs.contains($0.id) }
        let downloads = DownloadManager.shared
        return HStack(spacing: 0) {
            // 🔴 播放全部：主色调大按钮
            Button {
                store.play(selected); Haptics.soft()
                isSelecting = false; selectedIDs.removeAll()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 20, weight: .bold))
                    Text("播放").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 8)
            }.buttonStyle(.plain)

            // 🔴 下载：次色调
            Button {
                Task { for song in selected { if song.isRemote { _ = try? await downloads.download(song) } } }
                Haptics.soft(); isSelecting = false; selectedIDs.removeAll()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 20))
                    Text("下载").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(AppStyle.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppStyle.stroke, lineWidth: 0.5))
                .padding(.horizontal, 8)
            }.buttonStyle(.plain)

            // 加歌单
            Menu {
                if library.playlists.isEmpty { Text("还没有歌单") }
                ForEach(library.playlists) { pl in
                    Button(pl.name) {
                        for song in selected { library.add(song, toPlaylist: pl.id) }
                        Haptics.soft(); isSelecting = false; selectedIDs.removeAll()
                    }
                }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "text.badge.plus").font(.system(size: 20))
                    Text("加歌单").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(AppStyle.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppStyle.background)
        .overlay(Rectangle().fill(AppStyle.stroke).frame(height: 0.5), alignment: .top)
    }

    // MARK: - Load

    private func loadSongs() async {
        isLoading = true
        defer { isLoading = false }
        songPage = 1; hasMoreSongs = true
        await fetchSongPage(1)
    }

    private func loadMoreSongs() async {
        guard !isLoadingMore, hasMoreSongs else { return }
        isLoadingMore = true; defer { isLoadingMore = false }
        await fetchSongPage(songPage + 1, append: true)
    }

    private func fetchSongPage(_ page: Int, append: Bool = false) async {
        do {
            let client = KugouClient.shared
            let cleaned = artist.name.trimmingCharacters(in: .whitespaces)
            let pageSongs = try await client.searchSongs(keyword: cleaned, page: page, limit: 30)

            var filtered = pageSongs.filter { song in
                let a = song.artist.trimmingCharacters(in: .whitespaces)
                return a == cleaned || a.contains(cleaned) || cleaned.contains(a)
            }

            let existingIDs = Set(songs.map(\.id))
            filtered.removeAll { existingIDs.contains($0.id) }

            if append {
                songs.append(contentsOf: filtered)
            } else {
                songs = filtered
                var seen = Set<String>()
                albums = pageSongs
                    .filter { !$0.album.isEmpty && $0.album != $0.title }
                    .compactMap { song -> Album? in
                        let aid = song.kugouAlbumID
                        let key = aid.isEmpty ? "\(song.album)|\(song.artist)" : aid
                        guard !seen.contains(key) else { return nil }
                        seen.insert(key)
                        return Album(id: "al:\(key)", name: song.album, artist: song.artist,
                                     coverURL: song.artworkURL, albumID: aid)
                    }
            }
            songPage = page
            hasMoreSongs = pageSongs.count >= 30
            Log.info("歌手", "加载 page=\(page) filtered=\(filtered.count) total=\(songs.count) hasMore=\(hasMoreSongs)")
        } catch {
            if !append { errorMessage = "加载失败：\(error.localizedDescription)" }
        }
    }

    private func formatFans(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
        return "\(n)"
    }
}

// 🔴 2026-11-07：已删除 `ArtistTransparentNavBar`（SwiftUI 原生 toolbarBackground(.hidden)）。
// 本项目红线：**别用 toolbarBackground**（.hidden 丢安全区 / .visible 出黑线）——
// 它会改动安全区计算，正是之前歌手页「大图被顶到 180pt、白顶」的帮凶之一。
// 沉浸式导航栏统一走 `kugouNavigationBarBackground(.clear, transparent:)`（逐 navigationItem appearance）。
// MARK: - 歌手详情里的单行歌曲（酷狗同款：编号 + 歌名 + 歌手·专辑，无封面）

private struct ArtistSongRow: View {
    let song: Song
    let index: Int
    let onPlay: () -> Void
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    // 🔴 v2.5.47：编号改回歌曲封面小图（用户要求）
                    CoverImage(
                        url: song.artworkURL,
                        fallbackKeys: song.kugouHash.isEmpty ? [] : ["kg:\(song.kugouHash)"],
                        seed: song.id,
                        size: 44,
                        corner: 6
                    )
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AppStyle.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 5) {
                            Text(song.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(AppStyle.secondaryText)
                                .lineLimit(1)
                            if !song.album.isEmpty && song.album != song.title {
                                Text("· \(song.album)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppStyle.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 2) {
                Button {
                    _ = library.toggleFavorite(song); Haptics.light()
                } label: {
                    Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart")
                        .font(.system(size: 14))
                        .foregroundStyle(library.isFavorite(song) ? AppStyle.like : AppStyle.tertiaryText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button {
                    if song.isRemote { Haptics.light(); Task { _ = try? await downloads.download(song) } }
                } label: {
                    Image(systemName: song.source == .local ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(song.source == .local ? AppStyle.tertiaryText.opacity(0.4) : AppStyle.tertiaryText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(song.source == .local)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 🔴 吸顶头高度（PreferenceKey，实测「分段 Tab + 全部播放」高度供滚动占位）

private struct StickyHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 🔴 滚动几何实测（UIKit contentOffset + KVO，替代不可靠的 GeometryReader/preference）

/// 🔴 滚动容器的实测滚动量。
///
/// 「大图盖住透明导航栏」不再靠推断，而是靠 UIKit：**把 adjustedContentInset.top 抵消成 0**
/// （见 ScrollViewOffsetTracker.cancelTopContentInset），滚动内容原点就精确落在屏幕 y=0，
/// 大图作为内容第一项、零偏移即可盖住导航栏；列表占位 / 吸顶位置也都是常量推导，不再有换算。
struct ScrollMetrics: Equatable {
    /// 内容已上移的距离（>=0）：滚动量。毛玻璃渐入 / 吸顶 / 大图上移都用它。
    var scrolled: CGFloat = 0
    /// **静止时**「滚动内容 y=0」在 window 坐标系里的 y（探针直接量）。
    /// 主机制是「抵消顶部内边距」把内容原点压到 y=0；这个值只作安全网
    /// （万一滚动容器的 frame 没延伸到屏幕顶端，就用它把大图/列表精确对位）。
    var contentOriginYRest: CGFloat = 0
}

/// 透明探针视图：嵌在 ScrollView 层级里，找到所在 UIScrollView 并 KVO 监听其 contentOffset，
/// 把实测几何（滚动量 + 容器原点 + 静止内容原点）回传给 SwiftUI。
/// 比 GeometryReader + preference 可靠——后者在 ScrollView 滚动时不保证重算并上报偏移，
/// 会导致 headerScroll 恒为 0、毛玻璃 opacity 永远 0、毛玻璃从不出现。
private struct ScrollViewOffsetTracker: UIViewRepresentable {
    let onMetricsChange: (ScrollMetrics) -> Void

    func makeUIView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.backgroundColor = .clear
        view.onMetricsChange = onMetricsChange
        return view
    }

    func updateUIView(_ uiView: TrackerView, context: Context) {
        uiView.onMetricsChange = onMetricsChange
        uiView.attachToScrollViewIfNeeded()
        uiView.report()
    }

    final class TrackerView: UIView {
        var onMetricsChange: ((ScrollMetrics) -> Void)?
        private weak var observed: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var last: ScrollMetrics?
        func attachToScrollViewIfNeeded() {
            guard observed == nil else { return }
            var candidate: UIView? = self
            while let node = candidate {
                if let scrollView = node as? UIScrollView {
                    observed = scrollView
                    observation = scrollView.observe(\.contentOffset, options: [.new, .initial]) { [weak self] _, _ in
                        self?.report()
                    }
                    return
                }
                candidate = node.superview
            }
        }

        /// 🔴 把滚动容器的**顶部内边距抵消成 0** —— 这是「大图盖住透明导航栏」的前提。
        ///
        /// SwiftUI 会给 ScrollView 的内容加一段顶部内边距（导航栏那一截 ≈91pt），
        /// 于是「滚动内容原点」落在导航栏下沿而不是屏幕顶端 → 顶部露出页面底色 = **白顶**。
        /// （实测白区 179pt = 91(内边距) + 88(又一次叠加)。）
        ///
        /// 之前用 `.offset()` 去补偿大图位置，基准（内容原点）本身就带着这段内边距 → 补错位置。
        /// 现在直接把内边距抵消掉：内容原点精确落在屏幕 y=0，大图作为内容第一项、**零偏移**。
        ///
        /// 做法：`adjustedContentInset.top` 是 UIKit 调整后的最终值，
        /// 把 contentInset.top 减去它就能抵消成 0（不关心 SwiftUI 是用安全区还是 contentInset 加的）。
        private func cancelTopContentInset() {
            guard let sv = observed else { return }
            let adj = sv.adjustedContentInset.top
            if abs(adj) > 0.5 {
                sv.contentInset.top -= adj
            }
        }

        /// 实测并上报几何信息。
        func report() {
            guard let sv = observed else { return }
            cancelTopContentInset()
            let offsetY = sv.contentOffset.y

            // 已上滑距离 = contentOffset.y + adjustedContentInset.top
            //（顶部内边距已被抵消成 0，所以这里就等于 contentOffset.y；
            //   保留 +insetTop 是为了在抵消失败时也不会算错。下拉回弹时为负 → 夹到 0。）
            let scrolled = max(0, offsetY + sv.adjustedContentInset.top)
            // 探针自身在 window 里的 y（**直接测量**，不做坐标系换算）：
            // 探针是滚动内容的第一项 → 它就是「内容原点」的实体。
            // 静止时 = 内容原点的 window y；滚动时它跟着内容上移，所以要加回 scrolled。
            let trackerY = convert(CGPoint.zero, to: nil).y
            let m = ScrollMetrics(scrolled: scrolled, contentOriginYRest: trackerY + scrolled)
            guard m != last else { return }
            last = m
            onMetricsChange?(m)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                attachToScrollViewIfNeeded()
                report()
            }
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachToScrollViewIfNeeded()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 布局变化（旋转、安全区变化、内容插入）后重新实测一次。
            report()
        }

        deinit {
            observation?.invalidate()
        }
    }
}
