import SwiftUI
import UIKit

/// 歌手主页：酷狗同款大图头部（歌手名 + 粉丝 + 蓝色收藏）+ 金色下划线分段
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

    /// 🔴 2026-11-08：歌手简介（异步拉取，失败/为空时不占位置）。
    @State private var artistIntro: String = ""
    @State private var introExpanded = false
    @State private var showIntroSheet = false

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
            // ① 滚动容器：**只放占位 + 列表**（大图不在这里）。
            //
            // 🔴 2026-11-07 第 N+3 轮实锤：HUD 三行调试文字位于 306~338pt、紧贴大图底边 350pt，
            //    证明大图一直**画在屏幕 0~350pt**；0~180pt 的白块是盖在它上面的
            //    UIKit 导航栏/容器背景层。换 ZStack 独立层、GeometryReader 绝对坐标、
            //    ScrollView background 都改不了这一点 —— 它们在层级里都排在那个 UIKit 层之下。
            //    正解见 ②：把大图挂到 UINavigationController.view、UINavigationBar 之下。
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

                    // 🔴 占位：让列表静止时正好从「大图底边 + 吸顶头高度」开始。
                    //    列表屏幕 y = 实测内容原点 p + 本占位，目标 = 350 + 吸顶头高。
                    Color.clear.frame(height: listPlaceholder)

                    // 🔴 2026-11-08：歌手简介（放在滚动内容里，不动已验证的大图/吸顶几何）。
                    if !artistIntro.isEmpty {
                        artistIntroSection
                    }

                    // 列表主体（不含 全部播放 / 分段 Tab，那些已提到吸顶头）。
                    if tab == 0 {
                        songListBody
                    } else {
                        albumGridSection
                    }
                }
            }
            .background(AppStyle.background)
            // 🔴 绝不给 ScrollView 本体加 ignoresSafeArea(edges:.top)：
            //    每加一层都会再下推一个安全区（180pt 白顶正是两层叠加的结果）。

            // ② 大图：UIKit 浮层（挂在导航控制器 view 里、UINavigationBar 之下），
            //    由 ArtistHeroLayer 管理。屏幕上 0~350pt 那截被 UIKit 导航栏/容器背景盖住，
            //    无论把大图放在 ZStack 哪一层、ScrollView 内容还是 background，都会被盖；
            //    只有提到 UIKit 层级、且仍在 bar 之下（返回/收藏按钮照常可见可点）才盖得住。
            ArtistHeroLayer(scrolled: headerScroll,
                            headerHeight: headerBaseHeight,
                            hideThreshold: headerBaseHeight - topInset,
                            hero: AnyView(heroImageContent))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            // ③ 毛玻璃导航栏背景：大图滚走后渐入，系统工具栏（返回 / 收藏）浮在其上。
            //    用 offset 把它从「导航栏下沿」提到屏幕最顶端（0 ~ topInset）。
            navbarFrostedBackground
                .offset(y: -topInset)

            // ④ 吸顶头（分段 Tab + 全部播放）：钉在顶栏下方，不随列表滚走；
            //    大图未收起时贴着大图底边一起走，收起后固定在顶栏正下方。
            stickyHeader
                .offset(y: stickyY)
                .background(AppStyle.background)
        }
        .onPreferenceChange(StickyHeaderHeightKey.self) { stickyHeaderHeight = $0 }
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 2026-11-07：系统返回按钮的 chevron 用全局 tintColor（蓝色），无法逐页改色。
        //    隐藏它、改由 .topBarLeading 自绘「‹ 返回」，颜色才能跟右侧三点一起动态切换。
        .navigationBarBackButtonHidden(true)
        // 🔴 状态栏文字：大图在顶（深色）用白字；大图收起、毛玻璃浅底后改黑字。
        .compatToolbarDynamicScheme(dark: navFrostOpacity < 0.5)
        .kugouNavigationBarBackground(.clear, transparent: true)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isSelecting {
                    Text("已选 \(selectedIDs.count) 首")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(navBarContentColor)
                } else {
                    // 🔴 用户要求：大图随滚动收起，歌手名从大图中央渐隐、转入导航栏标题（与毛玻璃同步渐显）。
                    Text(artist.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(navBarContentColor)
                        // 收起后是浅色毛玻璃，深色投影反而脏，随毛玻璃渐入淡出。
                        .shadow(color: .black.opacity(0.3 * (1 - navFrostOpacity)), radius: 2, y: 1)
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
                    // 🔴 2026-11-08：收藏蓝胶囊移除，右上角只留三点竖。
                    // 收藏歌手 / 多选下载都收进菜单，功能不丢。
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
                        if !artistIntro.isEmpty {
                            Button { presentIntroSheet() } label: {
                                Label("歌手简介", systemImage: "info.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .rotationEffect(.degrees(90))
                            .foregroundStyle(navBarContentColor)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
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
                } else {
                    // 🔴 自绘返回：颜色与右侧三点一致（展开白 / 收起黑），替代系统蓝色返回按钮。
                    Button { dismiss() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                            Text("返回")
                                .font(.system(size: 16, weight: .regular))
                        }
                        .foregroundStyle(navBarContentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !selectedIDs.isEmpty {
                selectedActionBar
            }
        }
        // 🔴 简介是可选增强：用非结构化 Task 并行发起（只发起不等待），
        //    既不拖住歌曲加载，也不会因 .task 随视图消失被取消而拿不到结果。
        .task {
            Task {
                let intro = await KugouClient.shared.artistIntro(name: artist.name, artistID: artist.id)
                guard !intro.isEmpty else { return }
                await applyArtistIntro(intro)
            }
            await loadSongs()
        }
        .sheet(isPresented: $showIntroSheet) {
            ArtistIntroSheet(name: artist.name, intro: artistIntro)
        }
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

    /// 🔴 列表顶部占位高度（大图已移出滚动流，这里要连大图那 350pt 一起让出来）。
    ///
    /// 列表静止时的屏幕 y = 实测内容原点 p + 本占位；
    /// 目标 = 大图底边(350) + 吸顶头高 H → 占位 = 350 + H − p。
    /// p 实测不到时至少按 topInset 兜底（ScrollView 落在安全区内时 p ≈ topInset）。
    private var listPlaceholder: CGFloat {
        // 🔴 HUD 实测 p=0 / adj=0 / inset=0：归一化后内容原点就是 0。
        //    不能再拿 topInset(88) 兜底 —— 那样占位少 88pt，吸顶头会和列表重叠
        //    （本轮截图里「全部播放」压在「晴天/发如雪」上就是这个原因）。
        let p = max(0, contentOriginYRest)
        return max(0, headerBaseHeight + stickyHeaderHeight - p)
    }

    /// 🔴 用户要求：毛玻璃导航栏背景只在「滚到图片底部、图片快滚完」时才渐显，
    /// 不要提前出现。collapseProgress=1 表示图片底部已抵达导航栏（图片完全收起），
    /// 这里从 0.8 才开始渐入、1.0 完全不透明，与导航栏标题同步。
    private var navFrostOpacity: CGFloat {
        max(0, min(1, (collapseProgress - 0.8) / 0.2))
    }

    /// 🔴 2026-11-07：顶栏文字/图标色 —— 展开时大图深色 → 白色（与右侧三点同色）；
    /// 大图收起、毛玻璃（浅色）渐入后线性转黑，避免白字在浅底上看不见。
    /// 与 `navbarFrostedBackground` 共用 `navFrostOpacity`，颜色切换和底色切换严格同步。
    private var navBarContentColor: Color {
        let whiteness = 1 - navFrostOpacity   // 0=纯黑（收起）/ 1=纯白（展开）
        return Color(uiColor: UIColor(white: whiteness, alpha: 1))
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

    // MARK: - 顶部大图（UIViewRepresentable 挂到 UINavigationController.view，随列表上滑）

    /// 大图本体：由 `ArtistHeroLayer` 作为 UIKit 浮层承载（不是 SwiftUI ZStack 的任何一层）。
    ///
    /// 🔴 为什么必须提到 UIKit 层：像素剖析证实大图一直画在屏幕 0~350pt（HUD 三行文字
    ///    紧贴 350pt 底边），但 0~180pt 被一个不透明的 UIKit 导航栏/容器背景盖住 ——
    ///    换 ZStack 独立层、换 GeometryReader 绝对坐标、换 ScrollView background 都改不了这一点，
    ///    因为它们在视图层级里都排在那个 UIKit 层之下。
    ///    浮层插到 `UINavigationBar` 之下：盖住它的背景，但返回/收藏按钮仍在 bar 内、正常可见可点。
    private var heroImageContent: some View {
        let screenW = UIScreen.main.bounds.width
        return ZStack(alignment: .bottom) {
            // 🔴 深蓝灰兜底背板（不再是近黑色）：图未加载时不露白，
            // 也不会出现「先过一下黑色图片」的闪屏。
            ImmersiveStyle.heroFallback
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
                fallbackColor: ImmersiveStyle.heroFallback,
                // 🔴 首帧先用列表里已缓存的歌手图顶上，高清到位后无感替换。
                prefillCached: true
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
                        corner: 20,
                        prefillCached: true
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
        // 🔴 2026-11-08：白顶/几何自检用的 GitCommit 数字标签已移除（用户要求）。
        //    确认装的是哪个包仍可拆 IPA 读 Info.plist 的 GitCommit，不再污染界面。
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
                fallbackColor: ImmersiveStyle.heroFallback,
                prefillCached: true
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

    // MARK: - 🔴 2026-11-08 歌手简介

    /// 列表顶部的简介卡片：默认 3 行，点「展开」看全文，点「全文」进独立弹窗。
    private var artistIntroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("歌手简介")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer(minLength: 0)
                Button { presentIntroSheet() } label: {
                    Text("全文")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.accent)
                }
                .buttonStyle(.plain)
            }

            Text(artistIntro)
                .font(.system(size: 13))
                .foregroundStyle(AppStyle.secondaryText)
                .lineSpacing(4)
                .lineLimit(introExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { introExpanded.toggle() } }

            Button {
                withAnimation(.easeOut(duration: 0.2)) { introExpanded.toggle() }
            } label: {
                Text(introExpanded ? "收起" : "展开")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// 菜单里点「歌手简介」时，等菜单消失动画走完再弹 sheet，否则会被吞掉。
    private func presentIntroSheet() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showIntroSheet = true }
    }

    @MainActor
    private func applyArtistIntro(_ text: String) {
        artistIntro = text
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
            // 🔴 2026-11-08：最新/最热后面的下载（多选）按钮已移除（用户要求）。
            //    多选下载入口保留在顶栏三点竖菜单里。
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// 🔴 歌曲列表主体（不含 全部播放行 / 分段 Tab，那些已提到吸顶头）。
    private var songListBody: some View {
        // 🔴 2026-11-12：一次取好列表。原来 ForEach 里物化
        //    `Array(displaySongs.enumerated())`，而 displaySongs 每次访问都要
        //    `songs.reversed()` 重建整个数组 —— 几百首时 body 每次重算都是 O(n) 风暴。
        //    改成 Range 型的 ForEach（LazyVStack 才能真正懒加载）+ 单次快照。
        let list = displaySongs
        return VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                ListRowsSkeleton(rows: 5)
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
                    // 🔴 2026-11-12：只物化一次 enumerated，且 id 用【歌曲 id】而不是行号，
                    //    「最新/最旧」切换倒序时 SwiftUI 才不会把行视图错配。
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, song in
                        let selected = selectedIDs.contains(song.id)
                        HStack(spacing: 0) {
                            if isSelecting {
                                Button {
                                    if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                } label: {
                                    MultiSelectCheckbox(isSelected: selected)
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
                            if index == list.count - 5 {
                                Task { await loadMoreSongs() }
                            }
                        }
                        Divider()
                            .padding(.leading, isSelecting ? 100 : 80)
                            .padding(.trailing, 28)
                    }
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            SkeletonInlineRow()
                        } else if !hasMoreSongs && songs.count > 0 {
                            Text("— 到底了 —").font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 14)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                // 🔴 迷你播放条 + TabBar 的留白：最后一首别被压住（2026-11-08）。
                .padding(.bottom, ImmersiveStyle.listBottomInset)
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
        // 🔴 专辑 tab 也要留出迷你播放条的高度。
        .padding(.bottom, ImmersiveStyle.listBottomInset)
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

            // 🔴 2026-11-08：加歌单 → 加入酷狗账号歌单（不再提示「还没有歌单」）。
            AddSelectedToKugouButton(songs: selected) {
                VStack(spacing: 6) {
                    Image(systemName: "text.badge.plus").font(.system(size: 20))
                    Text("加歌单").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(AppStyle.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
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
                        corner: 5
                    )
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

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

                // 🔴 2026-11-08：下载箭头换成三点竖「更多」，与其它歌曲列表统一。
                SongMoreMenu(song: song, iconSize: 14, buttonSize: 32, tint: AppStyle.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 🔴 2026-11-08 歌手简介全文弹窗

/// 二级页/弹窗统一白色导航栏，正文可滚动，长简介（上千字）也能完整读完。
private struct ArtistIntroSheet: View {
    let name: String
    let intro: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                Text(intro)
                    .font(.system(size: 15))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
            .background(AppStyle.background)
            .navigationTitle("\(name) · 简介")
            .navigationBarTitleDisplayMode(.inline)
            .kugouNavigationBarBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 🔴 吸顶头高度（PreferenceKey，实测「分段 Tab + 全部播放」高度供滚动占位）

private struct StickyHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 🔴 大图 UIKit 浮层（插到 UINavigationBar 之下，绕过所有 SwiftUI 遮盖层）

/// 0 尺寸锚点：自己不绘制，只负责把一个 UIHostingController（大图）挂到
/// UINavigationController.view 里、`UINavigationBar` 的正下方。
///
/// 这样大图在视图层级里**高于 SwiftUI 内容容器、低于导航栏按钮**：
/// - 盖住 UIKit 导航栏/容器那层不透明背景（0~180pt 白块的元凶）；
/// - 返回 / 收藏 / 歌手名 仍是 UINavigationBar 的子视图，正常显示、正常点击；
/// - frame 用屏幕绝对坐标，不受 SwiftUI 安全区 / contentInset / clipsToBounds 影响；
/// - 滚动只改 frame.origin.y，不重建 SwiftUI 视图树（封面 @State 不会被重置、不闪图）。
private struct ArtistHeroLayer: UIViewRepresentable {
    let scrolled: CGFloat
    let headerHeight: CGFloat
    let hideThreshold: CGFloat
    let hero: AnyView

    func makeUIView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.headerHeight = headerHeight
        v.hideThreshold = hideThreshold
        v.buildHero = { [hero] in
            let host = UIHostingController(rootView: hero)
            let view = host.view!
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.clipsToBounds = true
            return (view, host)
        }
        return v
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        uiView.scrolled = scrolled
        uiView.applyFrame()
    }

    /// 🔴 2026-11-14：与 ImmersiveHeroLayer 同款 —— SwiftUI 把 Representable 移出
    ///    视图树时【立刻】拆掉 UIKit 浮层。歌手页原来只靠 didMoveToWindow(window==nil)，
    ///    pop 返回后 SwiftUI 可能隔几秒才真正释放 destination 视图 → 周杰伦大图会一直
    ///    盖在推荐页的歌手头像横排上（用户实测截图「退出后还显示」）。
    static func dismantleUIView(_ uiView: AnchorView, coordinator: Void) {
        uiView.removeHeroLayer()
    }

    final class AnchorView: UIView {
        var scrolled: CGFloat = 0
        var headerHeight: CGFloat = 350
        var hideThreshold: CGFloat = 262
        var buildHero: (() -> (UIView, UIHostingController<AnyView>))?

        private var heroView: UIView?
        private var hosting: UIHostingController<AnyView>?
        private weak var container: UIView?
        private weak var hostVC: UIViewController?
        /// 🔴 hostVC 是 weak，pop 后页面 VC 可能立刻被释放 → 变 nil。
        ///    必须另外记住导航控制器本身（它随整条栈存活），否则栈顶判断会漏掉。
        private weak var navController: UINavigationController?
        private var retry = 0
        private var monitoring = false
        /// 已拆除（页面 pop / Representable 被移除）：重试闭包不得再把大图装回来。
        private var tornDown = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                removeHeroLayer()
                return
            }
            installIfNeeded()
            startVisibilityMonitoring()
        }

        /// 沿响应链找本页所在的导航控制器，同时记住页面 VC（用于栈顶判断）。
        private func resolveNavContext() -> (UINavigationBar, UIViewController)? {
            var node: UIResponder? = self
            while let cur = node {
                if let vc = cur as? UIViewController, let nav = vc.navigationController {
                    return (nav.navigationBar, vc)
                }
                node = cur.next
            }
            return nil
        }

        /// 🔴 本页是否仍是导航栈顶。浮层挂在 UINavigationController.view 上（整条栈共用），
        ///    pop / push 到别的页时必须立刻隐藏，否则旧歌手大图会一直盖在下一页内容上。
        private var isHostOnTop: Bool {
            guard let nav = navController else { return true }
            if let host = hostVC, nav.viewControllers.contains(where: { $0 === host }),
               nav.topViewController === host { return true }
            guard let topView = nav.topViewController?.view else { return true }
            return isDescendant(of: topView)
        }

        /// 低频轮询（0.12s）：pop 转场期间就把旧大图藏掉，用户完全看不到残留。
        private func startVisibilityMonitoring() {
            guard !monitoring, !tornDown else { return }
            monitoring = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let anchor = self, anchor.window != nil, !anchor.tornDown else {
                    self?.monitoring = false
                    return
                }
                let target = anchor
                if let view = target.heroView {
                    view.isHidden = target.scrolled >= target.hideThreshold || !target.isHostOnTop
                }
                target.monitoring = false
                target.startVisibilityMonitoring()
            }
        }

        /// 立即从 nav.view 上摘掉大图（页面被 pop / SwiftUI 视图销毁时调用）。
        func removeHeroLayer() {
            tornDown = true
            heroView?.removeFromSuperview()
            heroView = nil
            hosting = nil
            container = nil
            hostVC = nil
        }

        private func installIfNeeded() {
            guard !tornDown, heroView == nil, let build = buildHero else { return }
            // 🔴 绝不 fallback 到 rootView.addSubview —— 那会把大图盖在返回/收藏按钮上。
            //    首帧响应链可能还没连到导航控制器，稍后重试即可。
            guard let (bar, pageHost) = resolveNavContext(), let parent = bar.superview else {
                if retry < 6 {
                    retry += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.installIfNeeded()
                    }
                }
                return
            }
            let (view, host) = build()
            hosting = host
            heroView = view
            container = parent
            hostVC = pageHost
            navController = pageHost.navigationController
            view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: headerHeight)
            parent.insertSubview(view, belowSubview: bar)
            applyFrame()
        }

        func applyFrame() {
            guard let view = heroView else { return }
            // window 原点换算到容器坐标，容器不是全屏时也不会错位。
            var origin = CGPoint.zero
            if let win = window, let parent = container {
                origin = parent.convert(CGPoint.zero, from: win)
            }
            view.frame.origin = CGPoint(x: origin.x, y: origin.y - scrolled)
            // 与 SwiftUI 侧毛玻璃的渐入区间（collapseProgress 0.8→1）同步淡出，
            // 浮层在 bar 之下、SwiftUI 毛玻璃之上，不淡出会把渐入的材质压住。
            let fadeStart = hideThreshold * 0.8
            if scrolled <= fadeStart {
                view.alpha = 1
            } else {
                view.alpha = max(0, 1 - (scrolled - fadeStart) / max(1, hideThreshold - fadeStart))
            }
            // 🔴 页面已不在栈顶（被 pop 回推荐页 / push 到别的页）也必须隐藏，
            //    否则这块大图会一直浮在下一页内容之上。
            view.isHidden = scrolled >= hideThreshold || !isHostOnTop
        }
    }
}

// MARK: - 🔴 滚动几何实测（UIKit contentOffset + KVO，替代不可靠的 GeometryReader/preference）

/// 🔴 滚动容器的实测几何（UIKit 直读，不做任何坐标系换算）。
///
/// 大图已移出滚动流、用屏幕绝对坐标定位，这些数值只用于：
/// ① `scrolled` 驱动大图上滑 / 吸顶 / 毛玻璃；
/// ② `contentOriginYRest` 计算列表顶部占位；
/// ③④ 内边距归一化的自检值（白顶修复期间用于 HUD，现已不再显示，保留字段备查）。
struct ScrollMetrics: Equatable {
    /// 内容已上移的距离（>=0）：滚动量。毛玻璃渐入 / 吸顶 / 大图上移都用它。
    var scrolled: CGFloat = 0
    /// **静止时**「滚动内容 y=0」在 window 坐标系里的 y（探针直接量）。
    var contentOriginYRest: CGFloat = 0
    /// adjustedContentInset.top（自检用；归一化后应为 0）
    var adjustedTop: CGFloat = 0
    /// contentInset.top（自检用；归一化后应为 0）
    var contentInsetTop: CGFloat = 0
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

        /// 静止时的 contentOffset.y 基准（滚动量按相对首帧计算）。
        private var restOffsetY: CGFloat?

        /// 🔴 2026-11-08：不再手动改 UIScrollView 的 inset。
        ///
        /// 之前为把「内容原点」压到 y=0 设了 `.never` + `contentInset.top = 0` +
        /// `contentInset.bottom = safeAreaInsets.bottom`，真机带来两个 bug：
        ///   ① SwiftUI 仍按自己的 safeArea 布局、UIKit 按被改过的 inset 绘制 →
        ///      绘制与命中测试错开约一行（第一首点不到、点第二首播第一首）；
        ///   ② 迷你播放条的 bottom safeAreaInset 被手动覆盖 → 最后一首被遮挡。
        /// 大图已改走 UIKit 浮层，白顶不再依赖「内容原点=0」；inset 交还 UIKit 自动管理，
        /// `listPlaceholder = 350 + 吸顶头高 − 实测内容原点` 对任意原点都成立。
        func report() {
            // 🔴 每次都尝试 attach：首帧 superview 链可能还没连到 UIScrollView，
            //    旧版只在 updateUIView / didMoveToWindow 里试一次，失败就永久拿不到任何数值
            //    （真机表现就是所有测量值恒为初始值 0）。
            attachToScrollViewIfNeeded()
            guard let sv = observed else { return }
            let offsetY = sv.contentOffset.y
            if let base = restOffsetY {
                // UIKit 可能因 safeArea 变化把起点调小，同步下调基准，别误判成已滚动。
                if offsetY < base { restOffsetY = offsetY }
            } else {
                restOffsetY = offsetY
            }
            // 已上滑距离 = 相对静止基准的增量（下拉回弹为负 → 夹到 0）。
            let scrolled = max(0, offsetY - (restOffsetY ?? offsetY))
            // 探针自身在 window 里的 y（**直接测量**，不做坐标系换算）：
            // 探针是滚动内容的第一项 → 它就是「内容原点」的实体。
            // 静止时 = 内容原点的 window y；滚动时它跟着内容上移，所以要加回 scrolled。
            let trackerY = convert(CGPoint.zero, to: nil).y
            let m = ScrollMetrics(scrolled: scrolled,
                                  contentOriginYRest: trackerY + scrolled,
                                  adjustedTop: sv.adjustedContentInset.top,
                                  contentInsetTop: sv.contentInset.top)
            guard m != last else { return }
            last = m
            onMetricsChange?(m)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                attachToScrollViewIfNeeded()
                report()
                // 🔴 首帧 safeArea / contentInset 往往还没定，稍后再量两次拿到最终值
                //    （不在 report 里递归派发，避免无限循环）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.report() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.report() }
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
