import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// 🔴 2026-11-09：酷狗大歌单后台补齐时的「上屏节流器」。
/// 576 首歌单每反查完一小批（4~6 首）都会回调一次 onBatch，若每批都整体替换
/// `songs`，主线程会在几分钟内被反复打断 → 滚动掉帧。用时间戳把上屏频率压到
/// 每 interval 一次；缓存仍每批都写，结果不丢。
/// NSLock 保护（回调可能来自任意并发上下文），标 @unchecked Sendable。
private final class BatchThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFlush: Date = .distantPast

    func shouldFlush(interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastFlush) >= interval else { return false }
        lastFlush = now
        return true
    }
}

/// 曲库页 —— 🔴 v2.7.7：顶栏「我的音乐」板块已按需求移除，只保留酷狗音乐；
/// 「下载歌曲」入口挪到歌单列表后面。
struct LibraryView: View {
    @ObservedObject private var kugouAuth = KugouAuth.shared

    var body: some View {
        KugouLibraryPage()
            .background(AppStyle.background)
            .navigationTitle("")  // 不要大字标题，保持顶栏简洁
            .navigationBarTitleDisplayMode(.inline)
            .kugouNavigationBarTint()
            // 🔴 v2.8.0：顶栏右上角的账号头像移除（和页内账号卡片重复），
            // 登录入口改由页内账号卡片承担（未登录时点卡片弹出扫码登录）。
    }
}

// MARK: - 酷狗账号卡片（🔴 v2.7.7：默认收藏上面加的用户信息卡）

private struct KugouProfileCard: View {
    @ObservedObject private var kugouAuth = KugouAuth.shared
    // 🔴 v2.8.3：今日听歌统计（首数 + 时长），独立对象、低频发布，不会拖累主页面
    @ObservedObject private var today = TodayListenStats.shared

    var body: some View {
        // 🔴 v2.8.0：未登录时点卡片直接弹扫码登录（顶栏登录按钮已移除，这里是登录入口）
        if kugouAuth.isLoggedIn {
            NavigationLink {
                KugouAccountCenter()
            } label: {
                cardLabel
            }
            .buttonStyle(.plain)
        } else {
            Button {
                NotificationCenter.default.post(name: .auroraShowKugouLogin, object: nil)
            } label: {
                cardLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var cardLabel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头像 + 昵称 + VIP + 副标题 + 箭头
            HStack(spacing: 12) {
                // 🔴 v2.9.3：未登录也展示酷狗品牌图标（之前 fallback 成通用音符占位）。
                if kugouAuth.isLoggedIn {
                    CoverImage(url: kugouAuth.avatarURL,
                               fallbackKeys: ["kg-avatar"],
                               seed: kugouAuth.nickname.isEmpty ? kugouAuth.userId : kugouAuth.nickname,
                               size: 54, corner: 12)
                } else {
                    Image("KugouLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .background(Color.white.opacity(0.001)) // 透明底，避免 clip 露出背景
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(kugouAuth.isLoggedIn ? (kugouAuth.nickname.isEmpty ? kugouAuth.userId : kugouAuth.nickname) : "登录酷狗账号")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AppStyle.primaryText)
                            .lineLimit(1)
                        if kugouAuth.isVip {
                            Text("VIP")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color(red: 1.0, green: 0.72, blue: 0.18), in: Capsule())
                        }
                    }
                    Text(kugouAuth.isLoggedIn ? "已登录酷狗 · 音乐随行" : "点这里扫码登录，同步酷狗歌单")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.tertiaryText)
            }

            // 🔴 v2.8.3：今日听歌统计 + 标签
            if kugouAuth.isLoggedIn {
                Divider()
                HStack(spacing: 12) {
                    statItem(icon: "music.note", value: "\(today.songs)", unit: "首")
                    statItem(icon: "clock", value: today.formattedDuration, unit: "")
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        if kugouAuth.isVip { tagChip("会员") }
                        tagChip("今日 \(today.songs) 首")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            LinearGradient(colors: [AppStyle.accent.opacity(0.18), AppStyle.accent.opacity(0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppStyle.accent.opacity(0.15), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func statItem(icon: String, value: String, unit: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppStyle.primaryText)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.secondaryText)
            }
        }
    }

    private func tagChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(AppStyle.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(AppStyle.accent.opacity(0.12), in: Capsule())
    }
}

// MARK: - 🔴 v2.8.3 曲库板块（自建歌单 / 收藏歌单 / 下载歌曲）

private enum KugouSection: String, CaseIterable, Identifiable {
    case created = "自建歌单"
    case fav = "收藏歌单"
    case download = "下载歌曲"
    var id: String { rawValue }
    var title: String { rawValue }
}

// MARK: - 下载歌曲列表（🔴 v2.8.3：从独立页面改为可内嵌的列表，供「下载歌曲」板块直接展示）

/// 下载歌曲按首字母分组（A–Z；非字母归到 #）。
private struct SongGroup: Identifiable {
    let letter: String
    let songs: [Song]
    var id: String { letter }
}

private struct DownloadsList: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var downloads = DownloadManager.shared

    /// 外部传入已分好组的歌曲（由 KugouLibraryPage 计算，便于 A–Z 索引导航）。
    let groups: [SongGroup]
    /// 🔴 2026-11-09：搜索无结果时不能用「还没有下载」这个文案。
    var emptyTitle: String = "还没有下载"
    var emptyMessage: String = "在歌曲菜单里选「下载」"

    init(groups: [SongGroup], emptyTitle: String = "还没有下载", emptyMessage: String = "在歌曲菜单里选「下载」") {
        self.groups = groups
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
    }

    var body: some View {
        if groups.isEmpty {
            EmptyStateView(icon: "arrow.down.circle", title: emptyTitle, message: emptyMessage)
                .padding(.top, 60)
        } else {
            // 🔴 v2.9.9：按用户要求改成「搜索歌曲列表样式」——每首歌是独立的白色圆角卡片、
            // 卡片之间留间距，漂浮在页面淡蓝渐变背景上（不再是一整块灰面板）。
            // A–Z 分组、带 id 的分组抬头（供右侧字母索引 scrollTo 定位）、当前播放声波全部保留。
            LazyVStack(spacing: 0) {
                ForEach(groups) { group in
                    // 🔴 v2.9.11：左侧不再显示分组字母抬头（用户要求），
                    // 仅保留右侧 A–Z 索引（id 锚点供 scrollTo 定位）。
                    VStack(spacing: 0) {
                        ForEach(group.songs) { song in
                            downloadRow(song)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                        }
                    }
                    .id("sec-\(group.letter)")
                    .padding(.top, 8)
                }
            }
        }
    }

    private func downloadRow(_ song: Song) -> some View {
        // 左滑删除（删本地文件 + 移出下载列表）
        SwipeToDeleteRow(onDelete: {
            downloads.delete(song)
            Haptics.light()
        }) {
            HStack(spacing: 12) {
                // 🔴 v2.9.8：播放只绑在「封面 + 歌名」这一块上，
                // 收藏 / 三点作为兄弟按钮（不是嵌套在播放按钮里），
                // 三者点击区域互不重叠 → 彻底杜绝误触整行播放。
                Button {
                    guard let index = library.downloads.firstIndex(where: { $0.id == song.id }) else { return }
                    store.play(library.downloads, startAt: index); Haptics.soft()
                } label: {
                    HStack(spacing: 12) {
                        CoverImage(url: song.artworkURL,
                                   fallbackKeys: song.coverFallbackKeys,
                                   seed: "\(song.artist)-\(song.title)",
                                   size: 56)
                        // 🔴 当前播放的歌显示与其他列表一致的动态声波（PlayingBarsIndicator）
                        .overlay(alignment: .bottomTrailing) {
                            if store.current?.id == song.id {
                                PlayingBarsIndicator(isPlaying: store.isPlaying)
                                    .padding(3)
                                    .background(AppStyle.accent, in: Circle())
                                    .offset(x: 3, y: 3)
                            }
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(song.cleanTitle)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(store.current?.id == song.id ? AppStyle.accent : AppStyle.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // 🔴 3.0.0：「本地」标签换成与播放页 VIP / 音质标签同款的灰色胶囊，
                            //    并真正紧跟歌手名字后面（歌手名不再用 maxWidth 把标签推到行尾）。
                            //    这一页本来全是已下载歌曲，直接显示，不再只认 source == .local。
                            HStack(spacing: 6) {
                                Text(song.artist)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppStyle.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                                LocalTag()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)

                // 收藏（独立按钮，绝不触发播放）
                Button {
                    _ = library.toggleFavorite(song)
                    Haptics.light()
                } label: {
                    Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart")
                        .font(.system(size: 16))
                        .foregroundStyle(library.isFavorite(song) ? AppStyle.like : AppStyle.tertiaryText)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)

                // 🔴 2026-11-08：和其它歌曲列表统一的三点竖「更多」菜单
                //（加入酷狗歌单 / 下载 / 下一首播放；已下载的歌带「删除下载」）。
                SongMoreMenu(song: song, buttonSize: 40, tint: AppStyle.secondaryText)
            }
            // 🔴 v2.9.9：每行是一张独立的白色圆角卡片（搜索歌曲列表样式），
            // 卡片间距由外层 .padding(.vertical, 3) 控制；圆角卡片铺满宽度，盖住身后红色删除按钮。
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppStyle.surface)
            )
        }
    }

    // MARK: 分组

    /// 按首字母分组并组内按歌名排序。
    static func makeGroups(_ songs: [Song]) -> [SongGroup] {
        var map: [String: [Song]] = [:]
        for song in songs {
            let key = Self.letter(for: song.cleanTitle)
            map[key, default: []].append(song)
        }
        let letters = map.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
        return letters.map { letter in
            let sorted = map[letter]!.sorted {
                $0.cleanTitle.localizedStandardCompare($1.cleanTitle) == .orderedAscending
            }
            return SongGroup(letter: letter, songs: sorted)
        }
    }

    /// 取首字母用于分组：拉丁字母取其大写；中文等用**拼音首字母**，
    /// 这样 A–Z 索引导航对中文歌也生效（如「大花轿」归到 D、「红日」归到 H）。
    /// 数字 / 符号 / 无法转拼音的字符才归到 #。
    static func letter(for title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return "#" }
        let s = String(first).uppercased()
        let isLatinLetter = s.rangeOfCharacter(from: .letters) != nil
            && s >= "A" && s <= "Z"
        if isLatinLetter { return s }
        // 非拉丁（中文等）：转拼音后取首字母
        let mutable = NSMutableString(string: t) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let latin = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
        if let pf = latin.first {
            let ps = String(pf).uppercased()
            if ps >= "A" && ps <= "Z" { return ps }
        }
        return "#"
    }
}

/// 下载列表右侧的 A–Z 快速索引（点击跳到对应分组）。
private struct DownloadIndex: View {
    let letters: [String]
    let proxy: ScrollViewProxy

    var body: some View {
        VStack(spacing: 2) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    withAnimation { proxy.scrollTo("sec-\(letter)", anchor: .top) }
                    Haptics.light()
                } label: {
                    Text(letter)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppStyle.tertiaryText)
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 酷狗音乐页面

private struct KugouLibraryPage: View {
    @ObservedObject private var kugouAuth = KugouAuth.shared
    @ObservedObject private var library = LibraryStore.shared
    @State private var playlists: [KugouClient.KugouPlaylist] = []
    @State private var isLoading = false
    @State private var errorMsg: String?
    // 🔴 v2.6.3：扫码登录的免责声明弹窗已移除（用户要求），
    // 点「扫码登录」直接拉起扫码页。
    // 🔴 v2.6.4：已加载标记 —— 之前每次切到「酷狗音乐」Tab 都会重新拉一遍歌单，
    // 用户反馈"每次进都刷新"。现在只有首次进入 / 登录成功 / 下拉刷新才请求。
    @State private var hasLoaded = false
    /// 🔴 v2.7.6：新建歌单（弹窗输入歌单名）
    @State private var showCreate = false
    @State private var newPlaylistName = ""
    /// 待删除的歌单（点了删除先确认）
    @State private var pendingDelete: KugouClient.KugouPlaylist?
    /// 新建/删除失败的提示
    @State private var actionError: String?
    @State private var isWorking = false
    /// 🔴 v2.7.7：重命名歌单
    @State private var renameID: String?
    @State private var renameName = ""
    /// 🔴 v2.8.3：曲库板块滑块（自建歌单 / 收藏歌单 / 下载歌曲）
    @State private var section: KugouSection = .created

    /// 下载歌曲分组：开关开启时按首字母（拼音首字母）分组 + A–Z 索引；
    /// 关闭时按下载顺序平铺（单组、无索引）。
    /// 开关只留在「设置」页；「我的音乐」这一行已按用户要求改成搜索框（2026-11-09）。
    @AppStorage("aurora.downloadAlphabeticalSort") private var downloadAlphabeticalSort = true
    /// 🔴 2026-11-09：只搜索**当前下载列表**的关键词（不触发网络搜索、不影响其它板块）。
    @State private var downloadQuery = ""

    private var downloadSearchText: String {
        downloadQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按歌名 / 歌手 / 专辑过滤本地下载列表。
    private var filteredDownloads: [Song] {
        let q = downloadSearchText
        guard !q.isEmpty else { return library.downloads }
        return library.downloads.filter { song in
            song.cleanTitle.localizedCaseInsensitiveContains(q)
            || song.artist.localizedCaseInsensitiveContains(q)
            || song.album.localizedCaseInsensitiveContains(q)
        }
    }

    private var downloadGroups: [SongGroup] {
        let source = filteredDownloads
        guard !source.isEmpty else { return [] }
        // 搜索时平铺结果（不再按首字母分组，右侧索引也隐藏）；清空后恢复原排序设置。
        if !downloadSearchText.isEmpty {
            return [SongGroup(letter: "", songs: source)]
        }
        if downloadAlphabeticalSort {
            return DownloadsList.makeGroups(source)
        }
        return [SongGroup(letter: "", songs: source)]
    }

    var body: some View {
        Group {
            if kugouAuth.needsRelogin {
                // 🔴 登录态失效（旧域签发的 token / 服务端返回 20017）：
                // 不走歌单列表 —— 否则用户只会看到空列表，以为是歌单丢了。
                EmptyStateView(icon: "exclamationmark.arrow.triangle.2.circlepath",
                               title: "登录已失效",
                               message: "登录已失效，点上方卡片重新扫码，登录后这里会显示你的酷狗歌单")
                    .padding(.top, 60)
            } else {
                VStack(spacing: 0) {
                    // 🔴 v2.8.1/v2.8.4：固定顶栏（账号卡片 + 板块滑块）放在 ScrollView 外面，
                    // 不随歌单列表一起上滑，始终钉在页面顶部。
                    // 🔴 v2.9.6(修正)：整页固定渐变挂在下面这个 VStack 的背景上（kugouPinnedTopFade），
                    // 顶栏就是这一层的一部分，蓝色渐变从顶部一直铺下来、上滑不消失。
                    VStack(spacing: 0) {
                        // 🔴 v2.8.1：账号卡片改为固定顶栏 —— 放在 ScrollView 外面，
                        // 这样它不会随歌单列表一起上滑，始终钉在页面顶部。
                        KugouProfileCard()
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                        // 🔴 v2.8.4：板块滑块挪到固定顶栏（ScrollView 外）——
                        // 之前放在滚动内容顶部，上滑列表时手指起点压在滑块上很容易误触切换板块；
                        // 固定后滑块不参与滚动，滑动手势不会再误触发。
                        Picker("板块", selection: $section) {
                            ForEach(KugouSection.allCases) { s in
                                Text(s.title).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    }

                    // 🔴 ScrollViewReader 包一层，供下载列表右侧 A–Z 索引 scrollTo 定位
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                kugouContent
                            }
                        }
                        .refreshable { await reloadPlaylists() }
                        // 🔴 下载列表右侧的 A–Z 快速索引（仅「下载歌曲」板块、开启字母排序、
                        //    且未在搜索时显示 —— 搜索结果是平铺的单组，没有字母可跳）。
                        .overlay(alignment: .trailing) {
                            if section == .download && downloadAlphabeticalSort
                                && downloadSearchText.isEmpty && !downloadGroups.isEmpty {
                                DownloadIndex(letters: downloadGroups.map(\.letter), proxy: proxy)
                                    .padding(.trailing, 4)
                            }
                        }
                    }
                }
                // 🔴 v2.9.6(修正)：整页固定渐变（与主页/搜索/设置一致），上滑不消失。
                // 顶栏（账号卡+板块滑块）仍是固定的、不参与滚动，蓝色渐变带从顶部一直铺下来。
                .kugouPinnedTopFade(height: 280)
                // 删除歌单的确认弹窗挂在这里（和新建弹窗挂在不同节点上，
                // 同一层叠多个 alert 会出现「只有一个弹得出来」的问题）
                .alert("删除歌单",
                       isPresented: Binding(get: { pendingDelete != nil },
                                            set: { if !$0 { pendingDelete = nil } }),
                       presenting: pendingDelete) { playlist in
                    Button("删除", role: .destructive) {
                        let target = playlist
                        Task { await confirmDelete(target) }
                    }
                    Button("取消", role: .cancel) { }
                } message: { playlist in
                    Text("确定删除「\(playlist.name)」吗？歌单里的歌曲会一起移除，且不可撤销。")
                }
            }
        }
        .alert("新建歌单", isPresented: $showCreate) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") { Task { await submitCreate() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("在你的酷狗账号下创建一个新的云歌单")
        }
        .alert("重命名歌单", isPresented: Binding(get: { renameID != nil },
                                               set: { if !$0 { renameID = nil } })) {
            TextField("歌单名称", text: $renameName)
            Button("保存") {
                let id = renameID
                let name = renameName
                Task { await submitRename(listid: id, name: name) }
            }
            Button("取消", role: .cancel) { }
        }
        .alert("操作失败", isPresented: Binding(get: { actionError != nil },
                                               set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task(id: kugouAuth.isLoggedIn) {
            // 🔴 v2.6.4：只在「还没加载过」时拉一次 —— 反复切 Tab 不再重新请求。
            guard kugouAuth.isLoggedIn else {
                playlists = []
                hasLoaded = false
                return
            }
            if !hasLoaded { await reloadPlaylists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .auroraKugouLoginSuccess)) { _ in
            // 刚登录成功：强制重拉一次
            hasLoaded = false
            Task { await reloadPlaylists() }
        }
    }

    // MARK: 歌单列表

    @ViewBuilder
    private var kugouContent: some View {
        if isLoading {
            // 🔴 2026-11-10：加载菊花 → 列表骨架 + 匀速扫光。
            ListRowsSkeleton(rows: 6).padding(.top, 20)
        } else if let err = errorMsg {
            EmptyStateView(icon: "exclamationmark.triangle", title: "加载失败", message: err).padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // 🔴 v2.8.4：板块滑块已挪到固定顶栏（ScrollView 外），这里不再重复放
                switch section {
                case .created:
                    createdSection
                case .fav:
                    favSection
                case .download:
                    downloadSection
                }
            }
            // 🔴 v2.7.7：底部留出迷你播放条的高度 —— 之前最后一行歌单被迷你播放条挡住
            .padding(.bottom, 110)
        }
    }

    /// 🔴 2026-11-09：原来的「按英文字母排序」开关行改成搜索框，
    /// 只过滤本页「下载歌曲」列表（歌名 / 歌手 / 专辑），不触发全局搜索。
    /// 排序开关统一收到「设置」页；开关仍决定清空搜索后的分组方式。
    @ViewBuilder
    private var downloadSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(AppStyle.tertiaryText)
            TextField("搜索下载的歌曲", text: $downloadQuery)
                .font(.system(size: 14))
                .foregroundStyle(AppStyle.primaryText)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !downloadQuery.isEmpty {
                Button {
                    downloadQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)

        DownloadsList(groups: downloadGroups,
                      emptyTitle: downloadSearchText.isEmpty ? "还没有下载" : "没有找到相关歌曲",
                      emptyMessage: downloadSearchText.isEmpty ? "在歌曲菜单里选「下载」" : "换个歌名或歌手试试")
    }

    // MARK: 🔴 v2.8.3 三个板块

    @ViewBuilder
    private var createdSection: some View {
        if !kugouAuth.isLoggedIn {
            // 🔴 v2.8.6：未登录不再整页空白 —— 顶栏卡片就是扫码入口，
            // 下载歌曲板块不登录也能用，自建/收藏板块给登录引导。
            EmptyStateView(icon: "person.crop.circle",
                           title: "未登录酷狗",
                           message: "点上方卡片扫码登录，登录后这里会显示你的酷狗歌单")
                .padding(.top, 40)
        } else {
            let created = playlists.filter { !$0.isFav }
            if created.isEmpty {
                EmptyStateView(icon: "music.note.list",
                               title: "还没有自建歌单",
                               message: "点下方「新建歌单」创建一个吧").padding(.top, 40)
            } else {
                ForEach(created) { playlist in
                    playlistRow(playlist)
                    Divider().padding(.leading, 82)
                }
            }
            // 🔴 v2.8.6：新建歌单入口从顶部标题行挪到列表底部
            newPlaylistButton
        }
    }

    @ViewBuilder
    private var favSection: some View {
        if !kugouAuth.isLoggedIn {
            EmptyStateView(icon: "person.crop.circle",
                           title: "未登录酷狗",
                           message: "点上方卡片扫码登录，登录后这里会显示你的酷狗歌单")
                .padding(.top, 40)
        } else {
            let favs = playlists.filter { $0.isFav }
            if favs.isEmpty {
                EmptyStateView(icon: "heart",
                               title: "还没有收藏歌单",
                               message: "在酷狗里收藏喜欢的歌单，会显示在这里").padding(.top, 40)
            } else {
                ForEach(favs) { playlist in
                    playlistRow(playlist)
                    Divider().padding(.leading, 82)
                }
            }
        }
    }

    /// 🔴 v2.8.6：新建歌单按钮（列表底部整行，替代原顶部标题行里的 +）
    private var newPlaylistButton: some View {
        Button {
            newPlaylistName = ""
            showCreate = true
            Haptics.light()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppStyle.accent)
                    .frame(width: 40, height: 40)
                    .background(AppStyle.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("新建歌单")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private func playlistRow(_ playlist: KugouClient.KugouPlaylist) -> some View {
        NavigationLink {
            KugouPlaylistDetail(listid: playlist.id, name: playlist.name, coverURL: playlist.coverURL)
        } label: {
            HStack(spacing: 12) {
                // 🔴 之前硬编码 url: nil —— 歌单列表全是灰色占位块。
                CoverImage(url: playlist.coverURL.flatMap { URL(string: $0) },
                           fallbackKeys: ["kg-list:\(playlist.id)"],
                           seed: playlist.name, size: 54, corner: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppStyle.primaryText).lineLimit(1)
                    Text(playlist.songCount > 0 ? "酷狗歌单 · \(playlist.songCount) 首" : "酷狗歌单")
                        .font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppStyle.tertiaryText)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 🔴 v2.7.6：长按删除歌单（列表是 ScrollView，没有 List 的 swipeActions，用长按菜单）
        .contextMenu {
            Button {
                renameID = playlist.id
                renameName = playlist.name
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingDelete = playlist
            } label: {
                Label("删除歌单", systemImage: "trash")
            }
        }
    }

    private func reloadPlaylists() async {
        isLoading = true
        errorMsg = nil
        defer { isLoading = false }
        do {
            // 🔴 v2.8.2：网络请求放进**非结构化** Task —— .refreshable 的任务在刷新
            // 控件被收起（刷新中途滚动列表）时会被 SwiftUI 取消，取消顺着结构化并发
            // 传进 URLSession，请求被掐断报 URLError.cancelled → 页面「加载失败：已取消」。
            // 非结构化 Task 不受影响：就算刷新动画被收起，结果也照常落地。
            let task = Task { try await KugouClient.shared.userPlaylists() }
            playlists = try await task.value
            hasLoaded = true
        } catch {
            // 🔴 v2.8.2：取消类错误（用户主动收起刷新/切页）不算失败，静默处理
            let cancelled = (error as? URLError)?.code == .cancelled || error is CancellationError
            if !cancelled, !Task.isCancelled {
                errorMsg = error.localizedDescription
            }
        }
    }

    // MARK: 🔴 v2.7.6 新建 / 删除歌单

    private func submitCreate() async {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await KugouClient.shared.createPlaylist(name: name)
            newPlaylistName = ""
            Haptics.light()
            await reloadPlaylists()
        } catch {
            actionError = error.localizedDescription
            Log.error("酷狗", "新建歌单失败：\(error.localizedDescription)")
        }
    }

    private func submitRename(listid: String?, name: String) async {
        guard let listid else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await KugouClient.shared.renamePlaylist(listid, name: trimmed)
            Haptics.light()
            await reloadPlaylists()
        } catch {
            actionError = error.localizedDescription
            Log.error("酷狗", "重命名歌单失败：\(error.localizedDescription)")
        }
    }

    private func confirmDelete(_ playlist: KugouClient.KugouPlaylist) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await KugouClient.shared.deletePlaylist(playlist.id)
            Haptics.light()
            await reloadPlaylists()
        } catch {
            actionError = error.localizedDescription
            Log.error("酷狗", "删除歌单失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 酷狗歌单详情

struct KugouPlaylistDetail: View {
    let listid: String
    let name: String
    /// 🔴 从列表页传进来 —— 之前详情页封面硬编码 nil，一直是灰色占位块。
    var coverURL: String? = nil
    @EnvironmentObject private var store: PlayerStore
    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var errorMsg: String?
    /// 🔴 v2.6.4：把这首歌加入我的其它酷狗歌单
    @State private var showKugouPicker = false
    /// 🔴 v2.6.4：移出歌单失败的提示
    @State private var removeError: String?
    /// 🔴 v2.7.6：歌单内「下载全部」
    @State private var isDownloading = false
    @State private var downloadDone = 0
    @State private var downloadTotal = 0
    @State private var downloadFinished = false
    @State private var downloadResult: String?

    // 🔴 2026-11-08：与「新歌推荐」共用沉浸式头部。
    @StateObject private var headerState = ImmersiveHeaderState()
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

    /// 歌单自己的封面；没有就用第一首歌的封面放大（歌曲是异步加载的，靠 heroKey 刷新浮层）。
    private var heroURL: URL? {
        if let coverURL, let url = URL(string: coverURL) { return url }
        return songs.first?.artworkURL
    }

    var body: some View {
        ImmersiveSongListContainer(
            state: headerState,
            heroKey: "\(heroURL?.absoluteString ?? "-")|\(name)|\(songs.count)",
            hero: {
                ImmersiveCoverHero(
                    url: heroURL,
                    fallbackKeys: ["kg-list:\(listid)"],
                    seed: name,
                    title: name,
                    subtitle: "酷狗歌单",
                    detail: songs.isEmpty ? nil : "\(songs.count) 首",
                    headerHeight: headerState.headerHeight
                )
            },
            sticky: { actionBar },
            content: { content }
        )
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 系统返回按钮的 chevron 取全局 tintColor，逐页改不了色 → 隐藏后自绘。
        .navigationBarBackButtonHidden(true)
        .compatToolbarDynamicScheme(dark: headerState.navFrostOpacity < 0.5)
        .kugouNavigationBarBackground(.clear, transparent: true)
        .task { await load() }
        .sheet(isPresented: $showKugouPicker) {
            KugouPlaylistPicker(songs: songs, title: "加入我的酷狗歌单")
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !selectedIDs.isEmpty {
                selectedActionBar
            }
        }
        .onChange(of: isSelecting) { newValue in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                store.isAnyMultiSelecting = newValue
            }
        }
        .onDisappear { store.isAnyMultiSelecting = false }
        // 🔴 v2.9.5：歌单详情页开着时又存了歌进来 —— 直接插到列表顶部，
        // 不用退出重进（否则要等缓存过期才能看到刚存的那首）。
        .onReceive(NotificationCenter.default.publisher(for: .auroraKugouSongsAdded)) { note in
            guard let listID = note.userInfo?["listID"] as? String, listID == listid,
                  let added = note.userInfo?["songs"] as? [Song] else { return }
            let existing = Set(songs.map(\.id))
            let fresh = added.filter { !existing.contains($0.id) }
            guard !fresh.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                // 🔴 2026-11-08：后加入的歌排第一（一次加多首时最后加的排最前），
                //    与 KugouRecentAdditions 的记录顺序保持一致。
                songs = Array(fresh.reversed()) + songs
                Self.detailCache[listid] = songs
            }
            Haptics.light()
        }
        .alert("移出歌单失败", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("好", role: .cancel) { removeError = nil }
        } message: {
            Text(removeError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isSelecting {
                    Text("已选 \(selectedIDs.count) 首")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(headerState.navContentColor)
                } else {
                    ImmersiveNavTitle(title: name,
                                      color: headerState.navContentColor,
                                      opacity: headerState.navFrostOpacity)
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button { isSelecting = false; selectedIDs.removeAll() } label: {
                        Text("完成")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(headerState.navContentColor)
                    }
                } else {
                    ImmersiveBackButton(color: headerState.navContentColor)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button {
                        if selectedIDs.count == songs.count { selectedIDs.removeAll() }
                        else { selectedIDs = Set(songs.map(\.id)) }
                    } label: {
                        Text(selectedIDs.count == songs.count ? "取消全选" : "全选")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(headerState.navContentColor)
                    }
                } else {
                    Menu {
                        Button { Task { await downloadAll() } } label: {
                            Label("下载全部", systemImage: "arrow.down.circle")
                        }
                        Button { showKugouPicker = true } label: {
                            Label("加入我的酷狗歌单", systemImage: "icloud.and.arrow.up")
                        }
                        Button { isSelecting = true; selectedIDs.removeAll() } label: {
                            Label("多选下载", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .rotationEffect(.degrees(90))
                            .foregroundStyle(headerState.navContentColor)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    /// 🔴 吸顶行：与「新歌推荐」一致 —— 蓝色圆钮 ▶ + 播放全部 + 数量 + 右侧多选按钮。
    private var actionBar: some View {
        HStack(spacing: 12) {
            ImmersivePlayAllButton(count: songs.count) {
                guard !songs.isEmpty else { return }
                Haptics.soft()
                store.queueID = "kugou-list:\(listid)"
                store.play(songs, startAt: 0)
            }
            Spacer(minLength: 0)
            Button {
                isSelecting = true
                selectedIDs.removeAll()
            } label: {
                ImmersiveMultiSelectIcon(color: AppStyle.primaryText)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        // 下载结果提示挂在吸顶行（和「移出歌单失败」的 alert 挂在不同节点上）
        .alert("下载全部", isPresented: Binding(get: { downloadResult != nil },
                                               set: { if !$0 { downloadResult = nil } })) {
            Button("好", role: .cancel) { downloadResult = nil }
        } message: {
            Text(downloadResult ?? "")
        }
    }

    /// 多选底部条：播放 / 下载 / 加歌单（统一走酷狗账号歌单）。
    private var selectedActionBar: some View {
        let selected = songs.filter { selectedIDs.contains($0.id) }
        return HStack(spacing: 0) {
            Button {
                store.queueID = "kugou-list:\(listid)"
                store.play(selected); Haptics.soft()
                isSelecting = false; selectedIDs.removeAll()
            } label: {
                VStack(spacing: 4) { Image(systemName: "play.fill").font(.system(size: 18)); Text("播放").font(.system(size: 11)) }
                    .foregroundStyle(AppStyle.primaryText).frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.plain)
            Divider().frame(height: 24)
            Button {
                Task { for song in selected { if song.isRemote { _ = try? await DownloadManager.shared.download(song) } } }
                Haptics.soft(); isSelecting = false; selectedIDs.removeAll()
            } label: {
                VStack(spacing: 4) { Image(systemName: "arrow.down.circle").font(.system(size: 18)); Text("下载").font(.system(size: 11)) }
                    .foregroundStyle(AppStyle.primaryText).frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.plain)
            Divider().frame(height: 24)
            AddSelectedToKugouButton(songs: selected) {
                VStack(spacing: 4) { Image(systemName: "text.badge.plus").font(.system(size: 18)); Text("加歌单").font(.system(size: 11)) }
                    .foregroundStyle(AppStyle.primaryText).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        }
        .background(AppStyle.surface)
        .overlay(Rectangle().fill(AppStyle.stroke).frame(height: 0.5), alignment: .top)
    }

    /// 🔴 v2.7.6：顺序下载歌单里的全部歌曲（已在本地的跳过）。
    /// 一首一首来，不并发 —— 酷狗的下载接口并发高了会直接拒，
    /// 而且几十首同时下会把播放的带宽抢光。
    private func downloadAll() async {
        guard !isDownloading else { return }
        let snapshot = songs
        guard !snapshot.isEmpty else { return }
        isDownloading = true
        downloadFinished = false
        downloadDone = 0
        downloadTotal = snapshot.count
        defer { isDownloading = false }

        var failures = 0
        for song in snapshot {
            if DownloadManager.shared.isDownloaded(song) {
                downloadDone += 1
                continue
            }
            do {
                _ = try await DownloadManager.shared.download(song)
                downloadDone += 1
            } catch {
                failures += 1
                Log.error("下载", "《\(song.cleanTitle)》下载失败：\(error.localizedDescription)")
            }
        }
        downloadFinished = failures == 0
        Haptics.light()
        downloadResult = failures == 0
            ? "已下载 \(snapshot.count) 首歌，可在「本地音乐 → 下载」里查看。"
            : "下载完成：成功 \(snapshot.count - failures) 首，失败 \(failures) 首（多为无版权或需要会员）。"
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ListRowsSkeleton(rows: 6).padding(.top, 20)
        } else if let err = errorMsg {
            EmptyStateView(icon: "exclamationmark.triangle", title: "加载失败", message: err).padding(.top, 60)
        } else if songs.isEmpty {
            EmptyStateView(icon: "music.note.list", title: "歌单是空的").padding(.top, 60)
        } else {
            // 🔴 2026-11-09：VStack → LazyVStack。576 首的「我喜欢」之前一进页面就把
            //    576 行全部构建出来（还带 SwipeToDeleteRow / contextMenu），主线程直接卡死。
            //    Lazy 后只构建可见的十几行；占位 / 分隔线随行一起懒加载。
            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    let selected = selectedIDs.contains(song.id)
                    // 🔴 v2.6.4：左滑删除 = 把这首歌移出酷狗歌单
                    SwipeToDeleteRow(onDelete: {
                        Task { await removeSong(song) }
                    }, title: "移除") {
                        HStack(spacing: 0) {
                            if isSelecting {
                                Button {
                                    if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                } label: {
                                    MultiSelectCheckbox(isSelected: selected)
                                }
                                .buttonStyle(.plain)
                            }
                            SongRow(song: song,
                                    isCurrent: store.current?.id == song.id,
                                    isPlaying: store.isPlaying,
                                    artistFontSize: 11,
                                    trailing: nil,
                                    onPlay: {
                                        if isSelecting {
                                            if selected { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                                        } else {
                                            store.queueID = "kugou-list:\(listid)"
                                            store.play(songs, startAt: index); Haptics.soft()
                                        }
                                    })
                                .equatable().songMenu(song)
                        }
                        // 不透明底：盖住身后的红色删除按钮（页面背景同色）
                        .background(AppStyle.background)
                    }
                    .padding(.horizontal, 16)
                    // 长按也可以移出歌单
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await removeSong(song) }
                        } label: {
                            Label("移出歌单", systemImage: "trash")
                        }
                    }
                    if index < songs.count - 1 {
                        Divider().padding(.leading, 16 + 48 + 12 + 44)
                    }
                }
                // 🔴 底部留白：让最后一首歌能滚到迷你播放条上方（与其它沉浸式列表一致）。
                Color.clear.frame(height: ImmersiveStyle.listBottomInset)
            }
        }
    }

    /// 🔴 v2.6.4：把歌曲从酷狗歌单移出（删除歌单内歌曲）。
    private func removeSong(_ song: Song) async {
        do {
            try await KugouClient.shared.removeSongFromPlaylist(listid, song: song)
            withAnimation(.easeOut(duration: 0.2)) {
                songs.removeAll { $0.id == song.id }
                // 🔴 v2.8.3：同步进详情缓存，否则重进页面又会看到被删的歌
                Self.detailCache[listid] = songs
            }
            Haptics.light()
        } catch {
            removeError = error.localizedDescription
            Log.error("酷狗", "移出歌单失败：\(error.localizedDescription)")
        }
    }

    // MARK: 🔴 v2.8.3 详情缓存：退出再进不再重新加载

    /// listid → 已解析+补齐的歌曲。详情页退出再进直接秒显，不再转圈重拉。
    private static var detailCache: [String: [Song]] = [:]
    private static var cacheTime: [String: Date] = [:]
    /// 缓存有效期：超过这个时间，下次进入时旧数据先显示、再在后台静默刷新
    private static let cacheTTL: TimeInterval = 300

    private func load() async {
        let cached = Self.detailCache[listid] ?? []
        if !cached.isEmpty {
            songs = cached
            isLoading = false
            // 缓存还新鲜 → 直接用，完全不重新加载
            if let at = Self.cacheTime[listid], Date().timeIntervalSince(at) < Self.cacheTTL { return }
        } else {
            isLoading = true
        }
        defer { isLoading = false }
        do {
            // 🔴 v2.8.2：网络请求放进**非结构化** Task —— .task 在用户快速退出页面时
            // 会被取消，取消传进 URLSession 会把请求掐断报「已取消」→ 详情页变加载失败。
            let task = Task { try await KugouClient.shared.playlistSongs(listid: listid) }
            let parsed = try await task.value
            // 🔴 2026-11-08：用户要求歌单歌曲改成**倒叙**（后加入的歌排前面），
            //    所以先把服务端返回的整体反转，后面每一步（补齐快照 / 缓存）都必须
            //    沿用同一个倒序基准，不能有一环把顺序打回正序。
            let reversed = Array(parsed.reversed())
            // 🔴 v2.8.2：二次进入/刷新时保留已补齐的歌手/封面，不把之前的反查成果打回占位
            let merged = mergePreservingEnriched(reversed)
            // 🔴 v2.9.5：刚存进来的歌排到第一位（其余保持上面的倒序）
            let ordered = KugouRecentAdditions.shared.ordered(merged, forListID: listid)
            songs = ordered
            Self.detailCache[listid] = ordered
            Self.cacheTime[listid] = Date()
            // 🔴 v2.8.1/v2.8.2：歌手/封面在后台补齐，`onBatch` 逐批随到随填。
            // 🔴 2026-11-09：大歌单（「我喜欢」576 首）每批都整体替换 songs 会让主线程
            //    在整个补齐期间被反复打断（一次 diff 576 行），滚动明显卡顿。
            //    这里对**上屏**做 1.2s 节流：缓存每批都写（便宜），UI 最多 1.2s 刷一次，
            //    补齐结束后再强制刷最后一次，保证结果不丢。
            // ⚠️ 快照必须再过一次 ordered()，否则会把「刚加入的歌置顶」冲掉。
            Task { [merged] in
                let throttle = BatchThrottle()
                let final = await KugouClient.shared.enrichPlaylistSongs(merged) { snapshot in
                    let snapped = KugouRecentAdditions.shared.ordered(snapshot, forListID: listid)
                    Self.detailCache[listid] = snapped
                    guard throttle.shouldFlush(interval: 1.2) else { return }
                    songs = snapped
                }
                let finalOrdered = KugouRecentAdditions.shared.ordered(final, forListID: listid)
                Self.detailCache[listid] = finalOrdered
                Self.cacheTime[listid] = Date()
                // 强制补最后一次（节流可能吞掉末尾批次）；保留补齐期间用户刚存进来的歌。
                let finalIDs = Set(finalOrdered.map(\.id))
                let fresh = songs.filter { !finalIDs.contains($0.id) }
                songs = fresh + finalOrdered
            }
        } catch {
            // 🔴 v2.8.2：取消类错误不显示成「加载失败：已取消」
            let cancelled = (error as? URLError)?.code == .cancelled || error is CancellationError
            if !cancelled {
                errorMsg = error.localizedDescription
            }
        }
    }

    /// 🔴 v2.8.2：拿「裸解析」覆盖列表时，保留旧条目里已反查到的字段。
    private func mergePreservingEnriched(_ parsed: [Song]) -> [Song] {
        guard !songs.isEmpty, songs.count == parsed.count else { return parsed }
        let oldByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return parsed.map { p in
            guard let old = oldByID[p.id] else { return p }
            var m = p
            if m.artist.trimmingCharacters(in: .whitespaces).isEmpty { m.artist = old.artist }
            if m.title.isEmpty { m.title = old.title }
            if m.album.isEmpty { m.album = old.album }
            if m.artworkURL == nil { m.artworkURL = old.artworkURL }
            if m.kugouAlbumID.isEmpty { m.kugouAlbumID = old.kugouAlbumID }
            return m
        }
    }
}

// MARK: - 酷狗账号中心

struct KugouAccountCenter: View {
    @ObservedObject private var kugouAuth = KugouAuth.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        // 🔴 v2.8.4：头像改方形（圆角矩形底），之前是圆形
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppStyle.accent.opacity(0.12)).frame(width: 80, height: 80)
                        CoverImage(url: kugouAuth.avatarURL,
                                   fallbackKeys: ["kg-user:\(kugouAuth.userId)"],
                                   seed: kugouAuth.nickname, size: 64, corner: 14)
                    }
                    Text(kugouAuth.nickname.isEmpty ? "酷狗用户 \(kugouAuth.userId)" : kugouAuth.nickname)
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(AppStyle.primaryText)
                    if kugouAuth.isVip {
                        Text("酷狗 VIP").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Color(red: 1.0, green: 0.85, blue: 0.2), in: Capsule())
                    }
                }
                .padding(.top, 30).padding(.bottom, 16)

                VStack(spacing: 0) {
                    HStack {
                        Text("用户 ID").foregroundStyle(AppStyle.secondaryText)
                        Spacer()
                        Text(kugouAuth.userId).foregroundStyle(AppStyle.primaryText)
                            .font(.system(size: 13, design: .monospaced))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().padding(.leading, 16)
                    HStack {
                        Text("登录状态").foregroundStyle(AppStyle.secondaryText)
                        Spacer()
                        Text("已连接酷狗").foregroundStyle(.green).font(.system(size: 13))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)

                Button(role: .destructive) {
                    kugouAuth.logout()
                    dismiss()
                } label: {
                    Text("退出酷狗登录").frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                Text("退出后不会删除本地歌曲和下载记录")
                    .font(.system(size: 11)).foregroundStyle(AppStyle.tertiaryText)
            }
        }
        .navigationTitle("酷狗账号")
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 v2.9.6(修正)：二级页/弹窗的导航栏统一改成白色（主页那四个保持淡蓝渐变）
        .kugouNavigationBarBackground()
    }
}

// MARK: - 首次登录免责声明
// 🔴 v2.6.3：KugouDisclaimerView 已整体移除（用户要求点「扫码登录」不再弹声明页），
// 扫码入口直接 post .auroraShowKugouLogin 拉起 KugouLoginSheet。

// MARK: - 左滑删除行（ScrollView + LazyVStack 里用；List 的 onDelete 只适用 List）

/// 左滑露出红色删除按钮的行容器。
/// 拖动超过阈值吸附显示按钮，点按钮执行 onDelete；再点行内容或往右滑回收。
/// 不用 List/onDelete：本地音乐页是 ScrollView + LazyVStack 自绘列表。
/// 🔴 2026-11-09：去掉 private —— 歌单 / 专辑详情页也要用同一套左滑删除。
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    /// 按钮文案：曲库页用「删除」，歌单页用「移除」。
    var title: String = "删除"
    let content: Content

    /// 显式 init：保留 `SwipeToDeleteRow { ... } content: { ... }` 这种既有调用写法
    /// （加了带默认值的 title 之后，memberwise init 的参数顺序会变）。
    init(onDelete: @escaping () -> Void,
         title: String = "删除",
         @ViewBuilder content: () -> Content) {
        self.onDelete = onDelete
        self.title = title
        self.content = content()
    }

    /// 按钮宽度 + 余量 = 最大左滑距离
    private let revealWidth: CGFloat = 76
    @State private var offsetX: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                withAnimation(.easeOut(duration: 0.22)) { offsetX = 0 }
                onDelete()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(title).font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(width: 60, height: 56)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            // 未滑动时完全不出现（也不占命中区）
            .opacity(offsetX < -6 ? 1 : 0)
            .allowsHitTesting(offsetX < -6)

            content
                .offset(x: offsetX)
                // 🔴 横向优先：|dx| > |dy| 才跟手，避免和页面纵向滚动打架
                .gesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            offsetX = min(0, max(-revealWidth, v.translation.width))
                        }
                        .onEnded { v in
                            withAnimation(.easeOut(duration: 0.22)) {
                                offsetX = (v.translation.width < -40 || v.predictedEndTranslation.width < -60)
                                    ? -revealWidth : 0
                            }
                        }
                )
        }
    }
}

// MARK: - 通知名扩展

extension Notification.Name {
    /// 全局请求弹酷狗登录 Sheet（LibraryView 顶栏按钮 / TabBar 按钮）
    static let auroraShowKugouLogin = Notification.Name("aurora.showKugouLogin")
    /// 酷狗登录成功，各页面刷新歌单
    static let auroraKugouLoginSuccess = Notification.Name("aurora.kugouLoginSuccess")
    /// 服务端拒绝 token（20017/20006）—— 需要重新扫码登录
    static let auroraKugouTokenRejected = Notification.Name("aurora.kugouTokenRejected")
    /// 🔴 v2.9.5：有歌曲被存进某个酷狗歌单，userInfo = ["listID": String, "songs": [Song]]
    static let auroraKugouSongsAdded = Notification.Name("aurora.kugouSongsAdded")
}
