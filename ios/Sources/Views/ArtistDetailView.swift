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

    // 🔴 v2.9.7(二)：大图是否已滚过（收起）—— 酷狗同款：
    // 收起后导航栏从透明变白底，显示歌手名 + 收藏按钮 + 更多。
    @State private var collapsed = false

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
        ScrollView {
            LazyVStack(spacing: 0) {
                // 🔴 v2.5.48：下拉时歌手图片拉伸铺满，顶部不留白空隙
                // 🔴 v2.9.7：头部整体上移一个状态栏高度，大图就盖住了通知栏（状态栏）
                // 那一块；外层用负 margin 把它挪回原位，不占额外滚动空间。
                GeometryReader { geo in
                    let pull = max(0, geo.frame(in: .named("artistScroll")).minY)
                    let minY = geo.frame(in: .named("artistScroll")).minY
                    immersiveHeader(height: headerBaseHeight + pull)
                        .offset(y: -pull)
                        // 🔴 v2.9.7(二)：把头部滚动偏移传出去，驱动导航栏收起状态
                        .preference(key: ArtistHeaderOffsetKey.self, value: minY)
                }
                // 🔴 v2.9.7：容器高度加一个状态栏 —— 头部整体上移了那么多，
                // 容器不跟着加高，底部就会漏出一段页面背景色。
                .frame(height: headerBaseHeight + statusBarHeight)
                tabBar
                if tab == 0 {
                    songListSection
                } else {
                    albumGridSection
                }
            }
        }
        .coordinateSpace(name: "artistScroll")
        .background(AppStyle.background)
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 v2.9.7(二)：酷狗同款「收起」—— 大图滚过之后导航栏变白底，
        // 显示歌手名 + 收藏；状态栏文字从白变黑。
        .onPreferenceChange(ArtistHeaderOffsetKey.self) { offset in
            let nowCollapsed = offset < -(headerBaseHeight - 60)
            if nowCollapsed != collapsed { collapsed = nowCollapsed }
        }
        // 状态栏：未收起 = 白字（压在深色大图上）；收起后白底栏 = 黑字。
        .compatToolbarDynamicScheme(dark: !collapsed)
        // 导航栏底色：未收起 = 完全透明（浮在大图上）；收起后 = 白色实底。
        // ⚠️ 走 navigationItem 逐项外观 + @State 驱动的 updateUIViewController 刷新，
        // 不用 toolbarBackground（run 534/535 的老坑）。
        .kugouNavigationBarBackground(collapsed ? AppStyle.plainNavigationBarBackgroundUIColor : .clear,
                                     transparent: !collapsed)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isSelecting {
                    Text("已选 \(selectedIDs.count) 首")
                        .font(.system(size: 16, weight: .semibold))
                } else if collapsed {
                    // 🔴 v2.9.7(二)：收起后导航栏中间显示歌手名（酷狗同款）
                    Text(artist.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppStyle.primaryText)
                        .lineLimit(1)
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
                    // 🔴 v2.9.7(二)：右上角 = ⋮ 更多（酷狗同款）；
                    // 收起后旁边多一个黄色收藏胶囊。
                    HStack(spacing: 12) {
                        if collapsed {
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
                        }
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
                                .foregroundStyle(collapsed ? AppStyle.primaryText : .white)
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
    private let headerBaseHeight: CGFloat = 400

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

    private func immersiveHeader(height: CGFloat) -> some View {
        let screenW = UIScreen.main.bounds.width
        // 🔴 v2.9.7：大图向上多铺一个状态栏高度，盖住通知栏（状态栏）那一块。
        // 整个头部容器跟着一起上移 + 加高 —— 图片、渐变、文字的相对位置不变，
        // 只是整块内容顶到了屏幕最上端。
        // 🔴 v2.9.8：大图向上铺到屏幕最顶端 —— 偏移量 = 状态栏 + 导航栏(44pt)。
        // 只加状态栏时，导航栏/状态栏那一块仍是页面白底，盖不满顶部（用户反馈顶部还是白）。
        let topInset = statusBarHeight + navBarHeight
        return ZStack(alignment: .bottom) {
            CoverImage(
                url: hiResCoverURL,
                fallbackKeys: [artist.id],
                seed: artist.name,
                size: max(screenW, 800),
                corner: 0,
                displayWidth: screenW,
                displayHeight: height + topInset
            )
            .frame(width: screenW, height: height + topInset)
            .clipped()

            // 底部压暗渐变（保证白字可读）
            LinearGradient(colors: [.clear, Color.black.opacity(0.05), Color.black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: screenW, height: height + topInset)

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

                    // 🔴 v2.9.7(二)：收藏改回黄色胶囊（酷狗同款，用户截图指定）
                    Button {
                        Haptics.soft()
                        library.toggleArtistFavorite(artist)
                    } label: {
                        Text(library.isFavoriteArtist(artist) ? "已收藏" : "收藏")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Self.collectYellow))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        // 🔴 v2.9.7：整体高度加一个状态栏 —— 大图向上多铺的那一截
        .frame(width: screenW, height: height + topInset)
        // 🔴 v2.9.7：整块头部向上平移一个状态栏高度 ——
        // 图片就顶到了屏幕最上端（盖住通知栏那一块），返回键浮在图片上。
        // 文字区（歌手名/收藏）也跟着上移，相对图片的位置不变。
        .offset(y: -topInset)
    }

    // MARK: - 歌曲列表（酷狗同款：全部播放行 + 最新/最热 + 扁平编号列表）

    private var songListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 全部播放行：金色播放圆钮 + 排序切换 + 多选下载
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

// MARK: - 🔴 v2.9.7(二) 头部滚动偏移（驱动导航栏「收起」状态）

private struct ArtistHeaderOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

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
