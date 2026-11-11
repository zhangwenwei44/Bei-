import SwiftUI
import Foundation

// MARK: - 🔴 2026-11-11 歌单列表排序（酷狗同款）
//
// 用户要求：吸顶行「多选」按钮前面加一个列表顺序排列按钮，点开半屏白色弹窗，
// 提供 7 种排序方式：自定义排序(默认) / 从新到旧 / 从旧到新 / 按歌曲名A–Z /
// 按歌手名A–Z / 按播放量高–低 / 按播放量低–高。
//
// 🔴 用自定义 overlay 而不是 .sheet：
//    ① iOS 15 链式多个 .sheet(isPresented:) 只有最后一个生效（项目既有红线），
//       而酷狗歌单详情页已经有一个「加入我的酷狗歌单」sheet；
//    ② 半屏白色圆角面板 + 半透明遮罩要能盖住沉浸式大图，且不切走整页。
// 🔴 排序结果统一由 `PlaylistSorter.sorted` 给出，页面里所有「播放全部 / 点歌播放 /
//    多选全选 / 下载」都必须用排序后的 displaySongs，不能一处排了一处没排。
// 🔴 每个选项都真的改变列表顺序（含播放量全为 0 时的稳定次序），不做假菜单。

// MARK: - 排序方式

enum PlaylistSortMode: String, CaseIterable, Identifiable {
    case custom
    case newestFirst
    case oldestFirst
    case titleAZ
    case artistAZ
    case playCountDesc
    case playCountAsc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: return "自定义排序"
        case .newestFirst: return "从新到旧排序"
        case .oldestFirst: return "从旧到新排序"
        case .titleAZ: return "按歌曲名A–Z排序"
        case .artistAZ: return "按歌手名A–Z排序"
        case .playCountDesc: return "按播放量高–低排序"
        case .playCountAsc: return "按播放量低–高排序"
        }
    }

    /// 🔴 全部是 iOS 13+ 就存在的 SF Symbol，绝不写 iOS 16 才有的符号名
    ///    （项目红线：不存在的 systemImage 会静默渲染空白）。
    var symbol: String {
        switch self {
        case .custom: return "list.bullet"
        case .newestFirst: return "arrow.down"
        case .oldestFirst: return "arrow.up"
        case .titleAZ: return "textformat"
        case .artistAZ: return "person"
        case .playCountDesc: return "chart.bar.fill"
        case .playCountAsc: return "chart.bar"
        }
    }
}

// MARK: - 本地播放次数（让「按播放量」有真实数据）
//
// 酷狗接口在歌单/专辑里并不给单曲播放量（Song.playCount 基本恒为 0），
// 只在榜单卡片上给 play_times。这里在 App 本地累计每首歌的播放次数，
// 排序键 = 接口给的播放量 + 本地累计次数，用户点这两个选项能看出真实差异。
// 🔴 切歌时只做一次内存自增 + 1s 去抖写盘，绝不在主线程同步写 UserDefaults。

final class PlayCountTracker {
    static let shared = PlayCountTracker()

    private static let storageKey = "aurora.song.playCounts"
    private let lock = NSLock()
    private var counts: [String: Int]
    private var pendingSave: DispatchWorkItem?

    private init() {
        counts = (UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: Int]) ?? [:]
    }

    /// 由 PlayerStore.currentIndex 的 didSet 调用（切歌即记一次，主线程）。
    func record(_ songID: String) {
        lock.lock()
        counts[songID, default: 0] += 1
        lock.unlock()
        // 🔴 播放量排序要跟着播放次数变：清空排序缓存，下次 body 重算时重排一次。
        PlaylistSortMemo.shared.invalidateAll()
        scheduleSave()
    }

    func count(_ songID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[songID] ?? 0
    }

    private func scheduleSave() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.counts
            self.lock.unlock()
            UserDefaults.standard.set(snapshot, forKey: Self.storageKey)
        }
        pendingSave?.cancel()
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}

// MARK: - 自定义顺序（「编辑」拖拽后保存到本地）

enum PlaylistCustomOrder {
    private static func storageKey(_ listKey: String) -> String {
        "aurora.playlist.customOrder.\(listKey)"
    }

    static func ids(_ listKey: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: storageKey(listKey)) ?? []
    }

    static func save(_ listKey: String, ids: [String]) {
        UserDefaults.standard.set(ids, forKey: storageKey(listKey))
        // 🔴 自定义顺序变了但歌曲数组和 mode 都没变 → 必须主动让缓存失效。
        PlaylistSortMemo.shared.invalidate(listKey)
    }
}

// MARK: - 排序结果缓存
//
// 🔴 displaySongs 是计算属性，又被 content / actionBar / toolbar / safeAreaInset /
//    overlay 多处引用；而播放器 @Published 每秒都在变 → 父 View 的 body 会频繁重算。
//    576 首的「我喜欢」要是每处都重新 O(n log n) 排一次，滚动会明显卡（项目已踩过
//    「一进页面构建 576 行卡死主线程」的坑）。这里按 listKey 记住上一次的
//    (歌曲数组, 排序方式) 组合，命中就直接复用，只有数据或方式真的变了才重排。

final class PlaylistSortMemo {
    static let shared = PlaylistSortMemo()

    private struct Entry {
        let songs: [Song]
        let mode: PlaylistSortMode
        let newestFirst: Bool
        let result: [Song]
        /// 字母索引（仅 A–Z 排序有效，其余方式为空）。跟着排序结果一起缓存，
        /// 避免播放器每秒刷新 body 时对几百首歌反复做拼音转换。
        let letters: [String]
        let anchors: [String: String]
    }

    /// 只在主线程访问（SwiftUI body / 切歌回调均在主线程）。
    private var entries: [String: Entry] = [:]
    private init() {}

    func result(songs: [Song],
                mode: PlaylistSortMode,
                listKey: String,
                originalIsNewestFirst: Bool) -> [Song] {
        if let e = entries[listKey],
           e.mode == mode,
           e.newestFirst == originalIsNewestFirst,
           e.songs == songs {
            return e.result
        }
        let sorted = PlaylistSorter.sorted(songs, mode: mode, listKey: listKey,
                                           originalIsNewestFirst: originalIsNewestFirst)
        let index = PlaylistLetterIndex.isActive(mode)
            ? PlaylistLetterIndex.build(sorted, mode: mode)
            : (letters: [String](), anchors: [String: String]())
        entries[listKey] = Entry(songs: songs, mode: mode,
                                 newestFirst: originalIsNewestFirst, result: sorted,
                                 letters: index.letters, anchors: index.anchors)
        return sorted
    }

    /// 供页面右侧字母条 / 行锚点读取。命中缓存是 O(1)，不做任何重新排序。
    func index(songs: [Song], mode: PlaylistSortMode, listKey: String)
        -> (letters: [String], anchors: [String: String]) {
        if let e = entries[listKey], e.mode == mode {
            return (e.letters, e.anchors)
        }
        return PlaylistLetterIndex.build(songs, mode: mode)
    }

    func invalidate(_ listKey: String) { entries.removeValue(forKey: listKey) }
    func invalidateAll() { entries.removeAll(keepingCapacity: true) }
}

// MARK: - 排序器

enum PlaylistSorter {
    /// - Parameter originalIsNewestFirst: 传入的原始数组本身是否已经是「新歌在前」。
    ///   酷狗账号歌单（KugouPlaylistDetail）加载时已把服务端顺序整体反转成新在前 → true；
    ///   在线歌单 / 推荐板块 / 专辑保持服务端原序（后加入的在末尾）→ false。
    ///   这样「从新到旧 / 从旧到新」在两个页面里语义一致，且都能看到顺序变化。
    static func sorted(_ songs: [Song],
                       mode: PlaylistSortMode,
                       listKey: String,
                       originalIsNewestFirst: Bool = false) -> [Song] {
        switch mode {
        case .custom:
            let order = PlaylistCustomOrder.ids(listKey)
            guard !order.isEmpty else { return songs }
            var rank: [String: Int] = [:]
            for (offset, id) in order.enumerated() where rank[id] == nil { rank[id] = offset }
            return songs.enumerated().sorted { a, b in
                let ra = rank[a.element.id] ?? Int.max
                let rb = rank[b.element.id] ?? Int.max
                return ra == rb ? a.offset < b.offset : ra < rb
            }.map { $0.element }

        case .newestFirst:
            return originalIsNewestFirst ? songs : Array(songs.reversed())

        case .oldestFirst:
            return originalIsNewestFirst ? Array(songs.reversed()) : songs

        case .titleAZ:
            return songs.enumerated().sorted { a, b in
                let cmp = a.element.cleanTitle.localizedStandardCompare(b.element.cleanTitle)
                return cmp == .orderedSame ? a.offset < b.offset : cmp == .orderedAscending
            }.map { $0.element }

        case .artistAZ:
            return songs.enumerated().sorted { a, b in
                let cmp = a.element.artist.localizedStandardCompare(b.element.artist)
                return cmp == .orderedSame ? a.offset < b.offset : cmp == .orderedAscending
            }.map { $0.element }

        case .playCountDesc:
            return songs.enumerated().sorted { a, b in
                let ca = heat(a.element), cb = heat(b.element)
                return ca == cb ? a.offset < b.offset : ca > cb
            }.map { $0.element }

        case .playCountAsc:
            return songs.enumerated().sorted { a, b in
                let ca = heat(a.element), cb = heat(b.element)
                // 🔴 播放量相同时倒置原序，保证「高–低」与「低–高」在全都 0 的情况下
                //    也能看出差别，而不是两个选项都长得跟默认一样。
                return ca == cb ? a.offset > b.offset : ca < cb
            }.map { $0.element }
        }
    }

    private static func heat(_ song: Song) -> Int {
        song.playCount + PlayCountTracker.shared.count(song.id)
    }
}

// MARK: - 弹窗期间的浮层隐藏开关
//
// 🔴 歌单页的沉浸式大图是 UIKit 浮层（挂在 UINavigationController.view 上、
//    navigationBar 之下），层级【高于】SwiftUI 内容层。排序弹窗从底部升起时，
//    若浮层还显示，会盖住弹窗顶部那条（标题区）。弹窗打开期间把它临时隐藏，
//    关闭后由容器 0.2s 的可见性轮询自动恢复，不影响已验证的白顶修复。
// 🔴 按项目红线用 @unchecked Sendable 的 store 单例，不用可变全局静态变量。
final class PlaylistSortOverlayState: @unchecked Sendable {
    static let shared = PlaylistSortOverlayState()
    private let lock = NSLock()
    private var presented = false

    var isPresented: Bool {
        lock.lock(); defer { lock.unlock() }
        return presented
    }

    func set(_ value: Bool) {
        lock.lock(); presented = value; lock.unlock()
    }
}

/// 🔴 2026-11-12：排序弹窗是页面内的 overlay，而迷你播放条挂在导航栈【外层】，
///    层级更高，会把弹窗最后一行（按播放量高-低排序）压住。弹窗打开期间通知
///    RootView 临时收起播放条，关闭后恢复。
extension Notification.Name {
    static let auroraPlaylistSortSheetVisibility =
        Notification.Name("aurora.playlistSortSheetVisibility")
}

// MARK: - 吸顶行图标
//
// 🔴 2026-11-12：`ImmersiveSortIcon` / `ImmersiveMultiSelectIcon` / `ImmersiveNewPlaylistIcon`
//    全部移到 `PlaylistActionIcons.swift`，按用户给的三张截图 1:1 自绘。
//    这里只保留排序弹窗与排序逻辑，避免同名类型重复定义。

// MARK: - 排序方式弹窗

struct PlaylistSortSheet: View {
    let current: PlaylistSortMode
    /// 当前歌单的原始歌曲列表（「编辑」自定义顺序用）。
    let songs: [Song]
    let listKey: String
    /// 选中某个排序方式：页面写入偏好并关闭弹窗。
    let onSelect: (PlaylistSortMode) -> Void
    let onClose: () -> Void

    @State private var isEditingCustom = false
    @State private var draftIDs: [String] = []

    private let blue = Color(red: 0.13, green: 0.56, blue: 0.98)
    private let ink = Color(red: 0.10, green: 0.11, blue: 0.13)
    private let muted = Color(red: 0.62, green: 0.64, blue: 0.68)
    private let line = Color(red: 0.91, green: 0.92, blue: 0.94)

    var body: some View {
        ZStack(alignment: .bottom) {
            // 🔴 半透明遮罩：酷狗打开排序面板时上方内容会压暗。
            //    只在【独立 overlay 层】加一次 ignoresSafeArea，页面内容层一层都不加
            //    （项目红线：每层 .ignoresSafeArea(.top) 会把内容下推一个安全区 → 白顶）。
            Color.black.opacity(0.34)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            panel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .all)
        .onAppear {
            PlaylistSortOverlayState.shared.set(true)
            NotificationCenter.default.post(name: .auroraPlaylistSortSheetVisibility,
                                            object: nil, userInfo: ["presented": true])
        }
        .onDisappear {
            PlaylistSortOverlayState.shared.set(false)
            NotificationCenter.default.post(name: .auroraPlaylistSortSheetVisibility,
                                            object: nil, userInfo: ["presented": false])
        }
    }

    @ViewBuilder
    private var panel: some View {
        VStack(spacing: 0) {
            if isEditingCustom {
                customEditorHeader
                customEditorList
            } else {
                Text("排序方式")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)

                ForEach(Array(PlaylistSortMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    sortRow(mode)
                    if index < PlaylistSortMode.allCases.count - 1 {
                        Divider().background(line).padding(.leading, 22)
                    }
                }

                Divider().background(line)
                Button(action: onClose) {
                    Text("取消")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // 🔴 2026-11-12：底部多留 34pt。弹窗期迷你播放条会被 RootView 收起，
        //    这里再兜一层 home indicator / 播放条残留，保证最后一项完整可点。
        //    整体高度 ≈502pt，顶部落在屏幕 350pt 之下 —— 即使大图浮层没来得及隐藏，
        //    也压不到弹窗标题（大图浮层固定 350pt 高）。
        .padding(.bottom, 34)
        .background(Color.white)
        .clipShape(PlaylistSortTopCorners(radius: 18))
    }

    private func sortRow(_ mode: PlaylistSortMode) -> some View {
        let selected = mode == current
        return HStack(spacing: 14) {
            Image(systemName: mode.symbol)
                .font(.system(size: 19, weight: .light))
                .foregroundColor(selected ? blue : ink.opacity(0.75))
                .frame(width: 30, alignment: .leading)

            Text(mode.title)
                .font(.system(size: 16, weight: selected ? .medium : .regular))
                .foregroundColor(selected ? blue : ink)

            if mode == .custom {
                Text("默认")
                    .font(.system(size: 11))
                    .foregroundColor(muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(muted.opacity(0.7), lineWidth: 0.7))
            }

            Spacer(minLength: 0)

            if mode == .custom {
                Text("编辑")
                    .font(.system(size: 13))
                    .foregroundColor(ink)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.94, green: 0.95, blue: 0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    // 🔴 子视图手势优先，别让「编辑」同时触发整行的选中。
                    .highPriorityGesture(TapGesture().onEnded { startEditingCustom() })
            } else if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(blue)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(mode) }
    }

    // MARK: 自定义排序编辑（List + onMove 真拖拽）

    private var customEditorHeader: some View {
        HStack {
            Button("取消") { isEditingCustom = false }
                .font(.system(size: 15))
                .foregroundColor(muted)
            Spacer(minLength: 0)
            Text("自定义排序")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(ink)
            Spacer(minLength: 0)
            Button("完成") { saveCustomOrder() }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(blue)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private var customEditorList: some View {
        let map = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = draftIDs.compactMap { map[$0] }
        return List {
            ForEach(rows, id: \.id) { song in
                HStack(spacing: 12) {
                    Image(systemName: "line.horizontal.3")
                        .font(.system(size: 15))
                        .foregroundColor(muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.cleanTitle)
                            .font(.system(size: 14))
                            .foregroundColor(ink)
                            .lineLimit(1)
                        Text(song.artist.isEmpty ? "未知歌手" : song.artist)
                            .font(.system(size: 11))
                            .foregroundColor(muted)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }
            .onMove { offsets, destination in
                draftIDs.move(fromOffsets: offsets, toOffset: destination)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
        .frame(height: 400)
    }

    private func startEditingCustom() {
        var saved = PlaylistCustomOrder.ids(listKey)
        let allIDs = songs.map(\.id)
        let all = Set(allIDs)
        saved.removeAll { !all.contains($0) }
        let known = Set(saved)
        saved.append(contentsOf: allIDs.filter { !known.contains($0) })
        draftIDs = saved
        isEditingCustom = true
    }

    private func saveCustomOrder() {
        PlaylistCustomOrder.save(listKey, ids: draftIDs)
        isEditingCustom = false
        onSelect(.custom)
    }
}

/// 只有上方两个角是圆角，底部保持直角铺到屏幕底（避免底角露出遮罩黑底）。
private struct PlaylistSortTopCorners: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: radius))
        p.addQuadCurve(to: CGPoint(x: radius, y: 0), control: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width - radius, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.width, y: radius),
                       control: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.closeSubpath()
        return p
    }
}
