import SwiftUI

private struct QueueSheetModifier: ViewModifier {
    @EnvironmentObject private var store: PlayerStore

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $store.isQueuePresented) {
                QueueView()
                    .environmentObject(store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }
}

extension View {
    func queueSheet() -> some View { modifier(QueueSheetModifier()) }
}

/// 当前播放队列。
struct QueueView: View {
    @EnvironmentObject private var store: PlayerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.queue.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "播放列表是空的")
                } else {
                    List {
                        Section {
                            ForEach(store.queue.indices, id: \.self) { offset in
                                let song = store.queue[offset]
                                SongRow(song: song,
                                        isCurrent: offset == store.currentIndex,
                                        isPlaying: store.isPlaying && offset == store.currentIndex)
                                    .songMenu(song)
                                    .listRowBackground(offset == store.currentIndex ? AppStyle.surface : Color.clear)
                                    .listRowSeparatorTint(Color.white.opacity(0.06))
                                    .onTapGesture {
                                        store.jump(to: offset)
                                        dismiss()
                                    }
                            }
                            .onDelete { store.remove(at: $0) }
                            .onMove { store.move(from: $0, to: $1) }
                        } header: {
                            HStack {
                                Text("\(store.queue.count) 首")
                                Spacer()
                                Text(store.mode.title)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.tertiaryText)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AppStyle.background)
            .navigationTitle("当前播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.queue.isEmpty {
                        Button("完成") { dismiss() }
                    } else {
                        Menu {
                            Button("列表循环") { store.mode = .order }
                            Button("单曲循环") { store.mode = .single }
                            Button("随机播放") { store.mode = .shuffle }
                            Divider()
                            Button("清空播放列表", role: .destructive) { store.clear() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
    }
}
