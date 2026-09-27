import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var store: PlayerStore
    @State private var isPlayerExpanded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: store.currentPalette.gradient,
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: store.index)

            library

            if store.current != nil {
                miniPlayer
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .overlay {
            if isPlayerExpanded {
                PlayerView(isExpanded: $isPlayerExpanded)
                    .transition(.move(edge: .bottom))
            }
        }
        .ignoresSafeArea(.keyboard)
        .queueSheet()
    }

    private var library: some View {
        List {
            Section {
                ForEach(Array(store.songs.enumerated()), id: \.element.id) { offset, song in
                    Button {
                        store.load(index: offset, autoplay: true)
                        isPlayerExpanded = true
                        Haptics.soft()
                    } label: {
                        LibraryRow(song: song,
                                   isCurrent: store.index == offset && isPlayerExpanded)
                    }
                    .listRowBackground(Color.white.opacity(0.06))
                }
            } header: {
                Text("我的音乐")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private var miniPlayer: some View {
        HStack(spacing: 12) {
            ArtworkView(song: store.current, size: 44, image: store.artwork)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.current?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(store.current?.artist ?? "")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                store.toggle()
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 36, height: 36)
            }

            Button {
                store.isQueuePresented = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12)))
        .onTapGesture { isPlayerExpanded = true }
    }
}

struct LibraryRow: View {
    let song: Song
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(song: song, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
    }
}

struct ArtworkView: View {
    let song: Song?
    var size: CGFloat
    var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
            .fill(
                LinearGradient(colors: ArtworkPaletteEngine.palette(for: image,
                                                                    seed: "\(song?.artist ?? "-")-\(song?.title ?? "-")").gradient,
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            )
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle()
                        .fill(.white.opacity(0.14))
                        .frame(width: size * 0.48, height: size * 0.48)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}
