import SwiftUI

/// 歌手主页：沉浸式横幅 + 歌曲列表 + 专辑板块 + 多选下载。
struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject private var store: PlayerStore
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @ObservedObject private var library = LibraryStore.shared

    // 多选模式
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                immersiveHeader
                albumSection
                songListSection
            }
        }
        .background(AppStyle.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isSelecting {
                    Text("已选 \(selectedIDs.count) 首")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button {
                        if selectedIDs.count == songs.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(songs.map(\.id))
                        }
                    } label: {
                        Text(selectedIDs.count == songs.count ? "取消全选" : "全选")
                            .font(.system(size: 14, weight: .medium))
                    }
                } else {
                    Button {
                        isSelecting = true
                        selectedIDs.removeAll()
                    } label: {
                        Label("多选", systemImage: "checkmark.circle")
                            .font(.system(size: 13))
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
    }

    // MARK: - 顶部沉浸式横幅

    private var immersiveHeader: some View {
        let screenW = UIScreen.main.bounds.width
        let bannerHeight: CGFloat = 240
        return ZStack(alignment: .bottomLeading) {
            // 歌手大图（不传 size 让 CoverImage 用 displayWidth 拉满）
            CoverImage(
                url: artist.coverURL,
                fallbackKeys: [artist.id],
                seed: artist.name,
                size: max(screenW, 720),  // 让 Kugou imgurl 的 {size} 替换成 720 拿高清图
                corner: 0,
                displayWidth: screenW,
                displayHeight: bannerHeight
            )
            .frame(width: screenW, height: bannerHeight)

            LinearGradient(colors: [.clear, Color.black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: screenW, height: bannerHeight)

            VStack(alignment: .leading, spacing: 12) {
                // 顶部：歌手名 + 粉丝
                VStack(alignment: .leading, spacing: 4) {
                    Text(artist.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if artist.fansCount > 0 {
                        Text("\(formatFans(artist.fansCount)) 粉丝")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }

                // 底部按钮行：小圆头像 + Spacer + 播放全部 + 收藏
                HStack(spacing: 12) {
                    CoverImage(
                        url: artist.coverURL,
                        fallbackKeys: [artist.id],
                        seed: artist.name,
                        size: 48,
                        corner: 24
                    )
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1.5))

                    Spacer()

                    Button {
                        Haptics.soft()
                        store.queueID = "artist:\(artist.id)"
                        store.play(songs, startAt: 0)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                            Text("播放全部").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(AppStyle.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(songs.isEmpty)

                    Button {
                        Haptics.soft()
                        library.toggleArtistFavorite(artist)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: library.isFavoriteArtist(artist) ? "heart.fill" : "heart")
                            Text(library.isFavoriteArtist(artist) ? "已收藏" : "收藏")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: screenW, height: bannerHeight)
    }

    // MARK: - 专辑板块

    @ViewBuilder
    private var albumSection: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("专辑")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    Spacer()
                    Text("\(albums.count) 张")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(albums) { album in
                            NavigationLink {
                                AlbumDetailView(album: album)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    CoverImage(
                                        url: album.coverURL,
                                        fallbackKeys: album.albumID.isEmpty ? [] : ["al:\(album.albumID)"],
                                        seed: album.name,
                                        size: 140,
                                        corner: 10
                                    )
                                    .frame(width: 140, height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                    Text(album.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(AppStyle.primaryText)
                                        .lineLimit(1)
                                        .frame(width: 140, alignment: .leading)
                                    Text(album.artist)
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppStyle.secondaryText)
                                        .lineLimit(1)
                                        .frame(width: 140, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 10)
            }
        }
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
                ProgressView().frame(maxWidth: .infinity, maxHeight: 60)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: 60).padding(.horizontal, 16)
            } else if songs.isEmpty {
                Text("暂时没找到歌曲")
                    .font(.system(size: 13)).foregroundStyle(AppStyle.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: 60)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
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
                                store.play(songs, startAt: index)
                            }
                            .padding(.leading, isSelecting ? 0 : 12)
                        }
                        Divider().padding(.leading, isSelecting ? 56 : 68)
                    }
                }
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - 多选底部操作条

    private var selectedActionBar: some View {
        let selected = songs.filter { selectedIDs.contains($0.id) }
        let downloads = DownloadManager.shared
        return HStack(spacing: 0) {
            Button {
                store.play(selected); Haptics.soft()
                isSelecting = false; selectedIDs.removeAll()
            } label: {
                VStack(spacing: 4) { Image(systemName: "play.fill").font(.system(size: 18)); Text("播放").font(.system(size: 11)) }
                    .foregroundStyle(AppStyle.primaryText).frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.plain)
            Divider().frame(height: 24)
            Button {
                Task { for song in selected { if song.isRemote { _ = try? await downloads.download(song) } } }
                Haptics.soft(); isSelecting = false; selectedIDs.removeAll()
            } label: {
                VStack(spacing: 4) { Image(systemName: "arrow.down.circle").font(.system(size: 18)); Text("下载").font(.system(size: 11)) }
                    .foregroundStyle(AppStyle.primaryText).frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.plain)
        }
        .background(AppStyle.surface)
        .overlay(Rectangle().fill(AppStyle.stroke).frame(height: 0.5), alignment: .top)
    }

    // MARK: - Load

    private func loadSongs() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // 拉 3 页 = 60 首，limit 100 全部显示
            async let p1 = try? await KugouClient.shared.searchSongs(keyword: artist.name, page: 1, limit: 30)
            async let p2 = try? await KugouClient.shared.searchSongs(keyword: artist.name, page: 2, limit: 30)
            var found: [Song] = []
            found.append(contentsOf: await p1 ?? [])
            found.append(contentsOf: await p2 ?? [])
            // 过滤放松：artist 名包含（多歌手用"、"分隔也能匹配）
            let cleaned = artist.name.trimmingCharacters(in: .whitespaces)
            songs = found.filter { song in
                let a = song.artist.trimmingCharacters(in: .whitespaces)
                return a == cleaned || a.contains(cleaned) || cleaned.contains(a)
            }
            // 从歌曲里聚合专辑（去重）
            var seen = Set<String>()
            albums = found
                .filter { !$0.album.isEmpty && $0.album != $0.title }
                .compactMap { song -> Album? in
                    let aid = song.kugouAlbumID
                    let key = aid.isEmpty ? "\(song.album)|\(song.artist)" : aid
                    guard !seen.contains(key) else { return nil }
                    seen.insert(key)
                    return Album(id: "al:\(key)",
                                 name: song.album,
                                 artist: song.artist,
                                 coverURL: song.artworkURL,
                                 albumID: aid)
                }
                .prefix(12)
                .map { $0 }
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

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.secondaryText)
                    .frame(width: 24, alignment: .center)

                CoverImage(
                    url: song.artworkURL,
                    fallbackKeys: song.kugouHash.isEmpty ? [] : ["kg:\(song.kugouHash)"],
                    seed: song.id,
                    size: 40,
                    corner: 6
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
