import SwiftUI

/// 🔴 2026-11-13：播放列表的呈现状态独立成**只有一个 @Published** 的轻量对象。
///
/// 旧实现把 sheet 绑在 `PlayerStore.isQueuePresented` 上，而 PlayerStore 有 30+ 个
/// @Published（封面、歌词、缓冲、网络状态……）。播放中任何一次发布都会让 SwiftUI
/// 重新评估 sheet 的 isPresented 绑定；同时 `queueSheet()` 还挂在 RootView 迷你条
/// 与播放页**两处**，同一个 bool 会驱动两个 sheet 一起 present。
/// iOS 27.0.1 上打开队列正撞上这类发布 → presenting 冲突 / 主线程卡死，
/// 表现为「卡住几秒后整页退回推荐页」。
///
/// 现在：① sheet 只订阅这个 bool；② 全 App 只在播放页挂一处；③ 呈现放到下一帧，
/// 避开按钮点击那一次的 body 更新。
final class QueuePresentation: ObservableObject {
    static let shared = QueuePresentation()

    @Published private(set) var isPresented = false

    /// 下一帧再呈现，避免在 SwiftUI 更新视图的过程中改 binding 造成重复 present。
    func present() {
        DispatchQueue.main.async {
            guard !self.isPresented else { return }
            self.isPresented = true
        }
    }

    func dismiss() {
        if isPresented { isPresented = false }
    }
}

/// 🔴 2026-11-13：队列内容的低频快照。
/// `QueueView` 不再 `@EnvironmentObject PlayerStore`（那会随 30+ @Published
/// 把整张 List 反复重建），只订阅这里。PlayerStore 在队列 / 索引 / 播放态 /
/// 模式变化时同步一次（见 PlayerStore.syncQueueSnapshot）。
final class QueueSnapshot: ObservableObject {
    static let shared = QueueSnapshot()

    @Published private(set) var songs: [Song] = []
    @Published private(set) var currentIndex: Int = -1
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var mode: PlaybackMode = .order

    /// 逐项比较 + 整体替换：值没变就不发布，别让 List 空转。
    func update(songs: [Song], currentIndex: Int, isPlaying: Bool, mode: PlaybackMode) {
        if songs != self.songs { self.songs = songs }
        if currentIndex != self.currentIndex { self.currentIndex = currentIndex }
        if isPlaying != self.isPlaying { self.isPlaying = isPlaying }
        if mode != self.mode { self.mode = mode }
    }
}

private struct QueueSheetModifier: ViewModifier {
    @ObservedObject private var presentation = QueuePresentation.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { presentation.isPresented },
                                        set: { presented in
                                            if !presented { presentation.dismiss() }
                                        })) {
                if #available(iOS 16.0, *) {
                    QueueView()
                        // 🔴 2026-11-14 第十一轮：按酷狗截图改成「覆盖约 2/3 屏的白色
                        //    圆角上拉面板」，上半截仍能看见竖屏播放器（原来固定 .large 全屏）。
                        .presentationDetents([.fraction(0.68), .large])
                        .presentationDragIndicator(.hidden)
                } else {
                    // iOS 15 没有 SwiftUI detents，走系统默认卡片 sheet。
                    QueueView()
                }
            }
    }
}

extension View {
    func queueSheet() -> some View { modifier(QueueSheetModifier()) }
}

private enum QueueTab: Int, CaseIterable, Identifiable {
    case playing, songFootprint, playlistFootprint
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .playing: return "正在播放"
        case .songFootprint: return "单曲足迹"
        case .playlistFootprint: return "歌单足迹"
        }
    }
}

/// 🔴 2026-11-14：竖屏播放器的歌曲列表面板。
///
/// 按酷狗截图重做：三段标签（选中蓝色下划线）→ 浅蓝信息条 → 来源行
/// → 方封面歌曲行（收藏心形 / 移除 ×）→ 底部四格工具栏。
/// 全白圆角面板，不再用 NavigationStack + List + 编辑按钮那一套。
///
/// ⚠️ 性能红线不变：只订阅 `QueueSnapshot`（4 个低频字段），不订阅整个 PlayerStore；
///    行身份用 `song.id#出现序号`，队列里重复歌曲也不会 diff 错位（iOS 27 卡死根因）。
struct QueueView: View {
    /// 单例引用（**不建立订阅**）——只用于派发用户操作。
    private let store = PlayerStore.shared
    @ObservedObject private var snapshot = QueueSnapshot.shared
    /// 收藏状态 + 单曲足迹 / 歌单足迹的真实数据来源。
    @ObservedObject private var library = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var tab: QueueTab = .playing
    @State private var editing = false
    @State private var showClearConfirm = false

    /// 稳定身份的行：`song.id + 该 id 在队列里第几次出现`。
    private struct Entry: Identifiable {
        let id: String
        let index: Int
        let song: Song
    }

    private var entries: [Entry] {
        var seen: [String: Int] = [:]
        return snapshot.songs.enumerated().map { offset, song in
            let n = seen[song.id, default: 0]
            seen[song.id] = n + 1
            return Entry(id: "\(song.id)#\(n)", index: offset, song: song)
        }
    }

    private var playedCount: Int {
        snapshot.currentIndex >= 0 ? snapshot.currentIndex + 1 : 0
    }

    private var currentEntryID: String? {
        entries.first(where: { $0.index == snapshot.currentIndex })?.id
    }

    var body: some View {
        // 🔴 ScrollViewReader 提到最外层：底部「最近」按钮要能 scrollTo 当前歌曲。
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                tabBar
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar(proxy: proxy)
            }
            .background(AppStyle.surface)
            // 🔴 不自己 clipShape：系统 sheet 本身就带顶部圆角，自己裁会把底部工具栏
            //    两个角也削圆（截图里工具栏是贴底直角）。
        }
        .environmentObject(store)
        .onAppear { refresh() }
        .alert("清空播放列表", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                store.clear()
                refresh()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将移除当前队列里的全部歌曲。")
        }
    }

    // MARK: - 顶部三段标签（正在播放 / 单曲足迹 / 歌单足迹）

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(QueueTab.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { tab = item }
                } label: {
                    VStack(spacing: 7) {
                        Text(item.title)
                            .font(.system(size: 16, weight: tab == item ? .semibold : .regular))
                            .foregroundStyle(tab == item ? AppStyle.primaryText : AppStyle.secondaryText)
                        Capsule()
                            .fill(tab == item ? AppStyle.accent : Color.clear)
                            .frame(width: 24, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 56)
        .padding(.top, 8)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .playing: playingList
        case .songFootprint: songFootprintList
        case .playlistFootprint: albumFootprintList
        }
    }

    private var playingList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // 🔴 2026-11-14 第十二轮：用户要求删掉「队列共 N 首」那栏，
                //    只保留下面这一行来源信息（来自：播放队列 / 随机 / 清空）。
                sourceRow
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                if snapshot.songs.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "播放列表是空的")
                        .padding(.top, 36)
                } else {
                    ForEach(entries) { entry in
                        queueRow(entry)
                            .id(entry.id)
                        Divider().padding(.leading, 80).padding(.trailing, 28)
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    /// 🔴 2026-11-14 第十二轮：原「队列共 N 首 + 切模式」浅蓝信息条已按用户要求删除，
    ///    只保留这一行来源信息；切模式改由底部工具栏的「顺序 / 单曲 / 随机」承担。

    /// 来源行：左侧「来自 / 已播」，右侧两个细线圆按钮（随机 / 清空）。
    private var sourceRow: some View {
        HStack(spacing: 8) {
            Text("来自：播放队列  已播 \(playedCount)/\(max(1, snapshot.songs.count))")
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.tertiaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            circleButton("shuffle", active: snapshot.mode == .shuffle) { setMode(.shuffle) }
            circleButton("trash") { showClearConfirm = true }
        }
    }

    private func circleButton(_ name: String, active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? AppStyle.accent : AppStyle.tertiaryText)
                .frame(width: 26, height: 26)
                .background(Circle().stroke(AppStyle.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 歌曲行：52pt 方封面 + 歌名（当前蓝色 + 跳动音量柱） + 歌手 + 心形 / ×。
    private func queueRow(_ entry: Entry) -> some View {
        let current = entry.index == snapshot.currentIndex
        let liked = library.isFavorite(entry.song)
        return HStack(spacing: 12) {
            // 🔴 整行点击只挂在「封面 + 文字」这一块，物理上避开右侧两个按钮，
            //    不然 SwiftUI 的父级 onTapGesture 会和子 Button 抢点击（iOS 15 上尤其明显）。
            HStack(spacing: 12) {
                ZStack {
                    // 🔴 2026-11-14：必须传 coverFallbackKeys —— 队列里的 Song 常常只带
                    //    一个失效的 artworkURL，没 fallback 时 CoverImage.load() 会直接
                    //    `guard !fallbackKeys.isEmpty else { return }`，封面永远是灰音符。
                    CoverImage(url: entry.song.artworkURL,
                               fallbackKeys: entry.song.coverFallbackKeys,
                               seed: entry.song.title,
                               size: 52, corner: 5)
                    if current && snapshot.isPlaying {
                        // 🔴 2026-11-15：抽成全 App 共用组件，其它歌曲列表现在也是这一套动效。
                        NowPlayingCoverBars()
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.song.cleanTitle)
                        .font(.system(size: 15, weight: current ? .semibold : .regular))
                        .foregroundStyle(current ? AppStyle.accent : AppStyle.primaryText)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(entry.song.artist.isEmpty ? "未知歌手" : entry.song.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.secondaryText)
                            .lineLimit(1)
                        if let tag = entry.song.tags.first, !tag.isEmpty {
                            Text(tag)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color(red: 0.16, green: 0.70, blue: 0.36))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color(red: 0.16, green: 0.70, blue: 0.36).opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                store.jump(to: entry.index)
                dismiss()
            }

            Button {
                _ = library.toggleFavorite(entry.song)
                Haptics.light()
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(liked ? AppStyle.like : AppStyle.tertiaryText)
                    .frame(width: 30, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.remove(at: IndexSet(integer: entry.index))
                refresh()
            } label: {
                if editing {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(AppStyle.like)
                        .frame(width: 28, height: 40)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppStyle.tertiaryText)
                        .frame(width: 28, height: 40)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 单曲足迹 / 歌单足迹（都用 LibraryStore 的真实历史，不造假数据）

    /// 🔴 不用 `Array(enumerated()) + id: \.offset`：Swift key path 不支持元组元素，
    ///    必须用 Identifiable 包装（项目里踩过这个编译坑）。
    private struct HistoryEntry: Identifiable {
        var id: Int { index }
        let index: Int
        let song: Song
    }

    private var historySongs: [Song] { Array(library.history.prefix(60)) }

    private var historyEntries: [HistoryEntry] {
        historySongs.enumerated().map { HistoryEntry(index: $0.offset, song: $0.element) }
    }

    private var songFootprintList: some View {
        let songs = historySongs
        let items = historyEntries
        return Group {
            if items.isEmpty {
                EmptyStateView(icon: "clock", title: "暂无单曲足迹")
                    .padding(.top, 50)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            footprintSongRow(item.song) {
                                store.play(songs, startAt: item.index)
                                dismiss()
                            }
                            Divider().padding(.leading, 80).padding(.trailing, 28)
                        }
                    }
                }
            }
        }
    }

    private func footprintSongRow(_ song: Song, onPlay: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: song.artworkURL,
                       fallbackKeys: song.coverFallbackKeys,
                       seed: song.title, size: 52, corner: 5)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(song.cleanTitle)
                    .font(.system(size: 15))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(song.artist.isEmpty ? "未知歌手" : song.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
    }

    private struct AlbumFootprint: Identifiable {
        let id: String
        let name: String
        let count: Int
        let songs: [Song]
    }

    /// 按专辑名聚合最近播放，得到「歌单足迹」。没专辑名的歌不强行编一个分组。
    private var albumFootprints: [AlbumFootprint] {
        var order: [String] = []
        var buckets: [String: [Song]] = [:]
        for song in library.history {
            let key = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(song)
        }
        return order.prefix(20).compactMap { key in
            guard let songs = buckets[key] else { return nil }
            return AlbumFootprint(id: key, name: key, count: songs.count, songs: songs)
        }
    }

    private var albumFootprintList: some View {
        let items = albumFootprints
        return Group {
            if items.isEmpty {
                EmptyStateView(icon: "square.stack", title: "暂无歌单足迹")
                    .padding(.top, 50)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            HStack(spacing: 12) {
                                CoverImage(url: item.songs.first?.artworkURL,
                                           fallbackKeys: item.songs.first?.coverFallbackKeys ?? [],
                                           seed: item.name, size: 52, corner: 5)
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name)
                                        .font(.system(size: 15))
                                        .foregroundStyle(AppStyle.primaryText)
                                        .lineLimit(1)
                                    Text("\(item.count) 首 · 最近播放")
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppStyle.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.play(item.songs, startAt: 0)
                                dismiss()
                            }
                            Divider().padding(.leading, 80).padding(.trailing, 28)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 底部工具栏（顺序 / 编辑 / 最近 / 收起）

    private var shortMode: String {
        switch snapshot.mode {
        case .order: return "顺序"
        case .single: return "单曲"
        case .shuffle: return "随机"
        }
    }

    private func bottomBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            // 🔴 显式写出两个闭包标签，不用多 trailing closure 简写（避免歧义编译错误）。
            toolButton(title: shortMode, icon: {
                PlayerModeIcon(mode: snapshot.mode, size: 20)
            }, action: {
                cycleMode()
            })
            toolButton(title: editing ? "完成" : "编辑", icon: {
                Image(systemName: editing ? "checkmark.square" : "square.and.pencil")
                    .font(.system(size: 19, weight: .regular))
            }, action: {
                editing.toggle()
            })
            toolButton(title: "最近", icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 19, weight: .regular))
            }, action: {
                if let id = currentEntryID {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            })
            toolButton(title: "收起", icon: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .regular))
            }, action: {
                dismiss()
            })
        }
        .frame(height: 58)
        .overlay(alignment: .top) { Divider() }
        .background(AppStyle.surface)
    }

    private func toolButton<Icon: View>(title: String,
                                        @ViewBuilder icon: () -> Icon,
                                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                icon()
                    .foregroundStyle(AppStyle.primaryText)
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(AppStyle.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    /// 打开时先对齐一次（覆盖 App 刚启动、队列由会话恢复但还没走过 didSet 的情况）。
    private func refresh() {
        snapshot.update(songs: store.queue,
                        currentIndex: store.currentIndex,
                        isPlaying: store.isPlaying,
                        mode: store.mode)
    }

    private func setMode(_ m: PlaybackMode) {
        store.mode = m
        refresh()
    }

    private func cycleMode() {
        let all = PlaybackMode.allCases
        let idx = all.firstIndex(of: snapshot.mode) ?? 0
        setMode(all[(idx + 1) % all.count])
    }
}

/// 🔴 2026-11-15：队列的播放动效已抽到 Components.swift 的 `NowPlayingCoverBars`，
///    歌单 / 歌手 / 下载 / 搜索等所有歌曲列表共用同一套视觉（不再有蓝色圆点角标）。
