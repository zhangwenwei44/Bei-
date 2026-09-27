import SwiftUI
import UniformTypeIdentifiers

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

struct QueueView: View {
    @EnvironmentObject private var store: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var isImporterPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(store.songs.enumerated()), id: \.element.id) { offset, song in
                        Button {
                            store.load(index: offset, autoplay: true)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(song: song, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(song.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if offset == store.index {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(.green)
                                } else {
                                    Text(song.duration.clockString)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .listRowBackground(offset == store.index ? Color.white.opacity(0.12) : nil)
                    }
                    .onDelete { offsets in store.remove(at: offsets) }
                } header: {
                    HStack {
                        Text("播放列表（\(store.songs.count)）")
                        Spacer()
                        Button("清空") { store.removeAll() }
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("当前播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("添加本地音频", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result {
                    for url in urls {
                        let secured = url.startAccessingSecurityScopedResource()
                        store.add(url: url)
                        if secured { url.stopAccessingSecurityScopedResource() }
                    }
                }
            }
        }
    }
}
