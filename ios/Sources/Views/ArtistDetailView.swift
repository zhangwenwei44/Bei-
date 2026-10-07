import SwiftUI

/// 歌手主页：头像 + 名字 + 粉丝 + 歌曲列表。
struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject private var store: PlayerStore
    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                headerSection
                songListSection
            }
        }
        .background(AppStyle.background)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSongs() }
    }

    // MARK: - Header（歌手头像 + 名字 + 粉丝 + 收藏）

    private var headerSection: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 24)

            CoverImage(
                url: artist.coverURL,
                fallbackKeys: [],
                seed: artist.name,
                size: 120,
                corner: 60
            )
            .frame(width: 120, height: 120)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.3), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            Text(artist.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(AppStyle.primaryText)

            if artist.fansCount > 0 {
                Text("\(formatFans(artist.fansCount)) 粉丝")
                    .font(.system(size: 14))
                    .foregroundStyle(AppStyle.secondaryText)
            }

            HStack(spacing: 24) {
                Button {
                    Haptics.soft()
                    store.queueID = "artist:\(artist.id)"
                    store.play(songs, startAt: 0)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("播放全部")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(AppStyle.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(songs.isEmpty)

                Button {
                    Haptics.soft()
                    library.toggleArtistFavorite(artist)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: library.isFavoriteArtist(artist)
                              ? "heart.fill" : "heart")
                            .foregroundStyle(library.isFavoriteArtist(artist)
                                             ? .pink : AppStyle.primaryText)
                        Text(library.isFavoriteArtist(artist) ? "已收藏" : "收藏")
                            .foregroundStyle(AppStyle.primaryText)
                    }
                    .font(.system(size: 14))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(AppStyle.surface)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
                .frame(height: 12)
        }
        .frame(maxWidth: .infinity)
        .background(AppStyle.background)
    }

    // MARK: - Song List

    private var songListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("歌曲")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer()
                if !songs.isEmpty {
                    Text("\(songs.count) 首")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: 60)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: 60)
                    .padding(.horizontal, 16)
            } else if songs.isEmpty {
                Text("暂时没找到歌曲")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: 60)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(songs.prefix(50).enumerated()), id: \.element.id) { index, song in
                        ArtistSongRow(song: song, index: index + 1) {
                            Haptics.soft()
                            store.queueID = "artist:\(artist.id)"
                            store.play(songs, startAt: index)
                        }
                        Divider().padding(.leading, 56)
                    }
                }
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Load

    private func loadSongs() async {
        isLoading = true
        defer { isLoading = false }
        do {
            songs = try await KugouClient.shared.searchSongs(keyword: artist.name, limit: 30)
            // 过滤：只保留歌手匹配的（搜索接口可能混入别的歌手）
            songs = songs.filter { $0.artist == artist.name || $0.artist.contains(artist.name) }
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }

    private func formatFans(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
        return "\(n)"
    }
}

// MARK: - 歌手详情里的单行歌曲

private struct ArtistSongRow: View {
    let song: Song
    let index: Int
    let onPlay: () -> Void
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.secondaryText)
                    .frame(width: 24, alignment: .center)

                CoverImage(
                    url: song.artworkURL,
                    fallbackKeys: [],
                    seed: song.id,
                    size: 48,
                    corner: 8
                )
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 14))
                        .foregroundStyle(AppStyle.primaryText)
                        .lineLimit(1)
                    Text(song.album)
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.secondaryText)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}
