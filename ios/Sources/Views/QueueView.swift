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
                        // 🔴 只用 .large（全屏）—— 用户要求「当前播放」列表全屏显示，
                        // 不再提供半屏档位（之前 [.medium, .large] 默认半屏）。
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                } else {
                    QueueView()
                }
            }
    }
}

extension View {
    func queueSheet() -> some View { modifier(QueueSheetModifier()) }
}

/// 当前播放队列。
struct QueueView: View {
    /// 单例引用（**不建立订阅**）——只用于派发用户操作。
    private let store = PlayerStore.shared
    @ObservedObject private var snapshot = QueueSnapshot.shared
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        CompatNavigationStack {
            Group {
                if snapshot.songs.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "播放列表是空的")
                } else {
                    List {
                        Section {
                            // 🔴 用【稳定身份】的行模型，而不是 `indices, id: \.self`：
                            //    删一行 / 拖动排序时按下标做 diff 会整段错位，
                            //    iOS 27 上偶发 List 更新回环（表现为主线程卡死）。
                            //    同一首歌在队列里出现多次也能靠出现序号区分。
                            ForEach(entries) { entry in
                                SongRow(song: entry.song,
                                        isCurrent: entry.index == snapshot.currentIndex,
                                        isPlaying: snapshot.isPlaying && entry.index == snapshot.currentIndex,
                                        onPlay: {
                                            store.jump(to: entry.index)
                                            dismiss()
                                        })
                                    .equatable()
                                    .songMenu(entry.song)
                                    .listRowBackground(entry.index == snapshot.currentIndex ? AppStyle.surface : Color.clear)
                                    .listRowSeparatorTint(AppStyle.stroke)
                            }
                            .onDelete { store.remove(at: $0) }
                            .onMove { store.move(from: $0, to: $1) }
                        } header: {
                            HStack {
                                Text("\(snapshot.songs.count) 首")
                                Spacer()
                                Text(snapshot.mode.title)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.tertiaryText)
                        }
                    }
                    .listStyle(.plain)
                    .compatScrollContentBackground(.hidden)
                }
            }
            .background(AppStyle.background)
            // 🔴 v2.9.6(修正)：这个弹窗没有顶部的淡蓝渐变带，
            // 全局导航栏外观刷的淡蓝顶栏在这里很突兀 —— 用户要求改成白色。
            .kugouNavigationBarBackground()
            .navigationTitle("当前播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    if snapshot.songs.isEmpty {
                        Button("完成") { dismiss() }
                    } else {
                        Menu {
                            Button("列表循环") { setMode(.order) }
                            Button("单曲循环") { setMode(.single) }
                            Button("随机播放") { setMode(.shuffle) }
                            Divider()
                            Button("清空播放列表", role: .destructive) { store.clear() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        // 注入给可能需要的子视图；QueueView 自身不读 @EnvironmentObject，
        // 因此不会随 PlayerStore 的高频发布重算整表。
        .environmentObject(store)
        .onAppear { refresh() }
    }

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
}
