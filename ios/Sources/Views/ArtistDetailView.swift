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
            VStack(spacing: 0) {
                immersiveHeader
                songListSection
            }
        }
        .background(AppStyle.background)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSongs() }
    }

    // MARK: - 顶部沉浸式横幅（大图 + 渐变遮罩 + 底部浮层信息）

    private var immersiveHeader: some View {
        let screenW = UIScreen.main.bounds.width
        let bannerHeight: CGFloat = 260
        return ZStack(alignment: .bottomLeading) {
            // 歌手大图，铺满整个横幅
            CoverImage(
                url: artist.coverURL,
                fallbackKeys: [],
                seed: artist.name,
                size: screenW,
                corner: 0,
                displayWidth: screenW,
                displayHeight: bannerHeight
            )
            .frame(width: screenW, height: bannerHeight)

            // 底部渐变遮罩（让文字可读）
            LinearGradient(colors: [.clear, Color.black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: screenW, height: bannerHeight)

            // 歌手信息 + 按钮（浮在底部）
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 14) {
                    // 小圆头像（横幅里缩成圆形小头像）
                    CoverImage(
                        url: artist.coverURL,
                        fallbackKeys: [],
                        seed: artist.name,
                        size: 64,
                        corner: 32
                    )
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(artist.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if artist.fansCount > 0 {
                            Text("\(formatFans(artist.fansCount)) 粉丝")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }

                    Spacer()

                    // 收藏按钮
                    Button {
                        Haptics.soft()
                        library.toggleArtistFavorite(artist)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: library.isFavoriteArtist(artist)
                                  ? "heart.fill" : "heart")
                            Text(library.isFavoriteArtist(artist) ? "已收藏" : "收藏")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(.white.opacity(0.22))
                        )
                    }
                    .buttonStyle(.plain)
                }

                // 播放全部按钮
                Button {
                    Haptics.soft()
                    store.queueID = "artist:\(artist.id)"
                    store.play(songs, startAt: 0)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("播放全部")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(AppStyle.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(songs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: screenW, height: bannerHeight)
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
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
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
            songs = try await KugouClient.shared.searchSongs(keyword: artist.name, limit: 100)
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
