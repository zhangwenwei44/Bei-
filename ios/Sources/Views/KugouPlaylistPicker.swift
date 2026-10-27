import SwiftUI

/// 🔴 v2.6.4：酷狗歌单选择器 —— 把歌曲（单曲 / 整个收藏）存进用户的酷狗云歌单。
///
/// 场景：
/// - 歌曲菜单「添加到酷狗歌单」
/// - 「我的音乐 → 收藏」右上角「存到酷狗歌单」
/// - 歌单详情页「加入我的酷狗歌单」
struct KugouPlaylistPicker: View {
    @Environment(\.dismiss) private var dismiss

    /// 要保存的歌曲（一首或多首）。
    let songs: [Song]
    /// 标题（如「添加到酷狗歌单」/「把收藏存到酷狗歌单」）。
    var title: String = "添加到酷狗歌单"

    @State private var playlists: [KugouClient.KugouPlaylist] = []
    @State private var isLoading = true
    @State private var workingID: String?
    @State private var message: String?

    var body: some View {
        CompatNavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView().tint(AppStyle.accent)
                        Text("正在读取你的酷狗歌单…")
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if playlists.isEmpty {
                    EmptyStateView(icon: "music.note.list",
                                   title: "还没有酷狗歌单",
                                   message: "先在酷狗 App 里建一个歌单再来保存")
                        .padding(.top, 50)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(playlists) { playlist in
                                Button {
                                    Task { await save(to: playlist) }
                                } label: {
                                    HStack(spacing: 12) {
                                        CoverImage(url: playlist.coverURL.flatMap { URL(string: $0) },
                                                   fallbackKeys: ["kg-list:\(playlist.id)"],
                                                   seed: playlist.name, size: 46, corner: 8)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(playlist.name)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(AppStyle.primaryText)
                                                .lineLimit(1)
                                            Text(playlist.songCount > 0 ? "酷狗歌单 · \(playlist.songCount) 首" : "酷狗歌单")
                                                .font(.system(size: 12))
                                                .foregroundStyle(AppStyle.tertiaryText)
                                        }
                                        Spacer()
                                        if workingID == playlist.id {
                                            ProgressView().tint(AppStyle.accent)
                                        } else {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 19))
                                                .foregroundStyle(AppStyle.accent)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(workingID != nil)
                                Divider().padding(.leading, 74)
                            }
                        }
                    }
                }

                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(AppStyle.surface)
                }
            }
            .background(AppStyle.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // 🔴 v2.9.6(修正)：二级页/弹窗的导航栏统一改成白色（主页那四个保持淡蓝渐变）
            .kugouNavigationBarBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard KugouAuth.shared.isLoggedIn else {
            message = "请先登录酷狗"
            return
        }
        do {
            playlists = try await KugouClient.shared.userPlaylists()
        } catch {
            message = error.localizedDescription
        }
    }

    /// 逐首加入目标歌单（酷狗接口一次一首）。
    private func save(to playlist: KugouClient.KugouPlaylist) async {
        workingID = playlist.id
        message = nil
        var failed = 0
        for song in songs {
            do {
                try await KugouClient.shared.addSongToPlaylist(playlist.id, song: song)
            } catch {
                failed += 1
                Log.error("酷狗", "加入歌单失败：\(error.localizedDescription)")
            }
        }
        workingID = nil
        let ok = songs.count - failed
        if ok > 0 {
            let added = Array(songs.prefix(ok))
            // 🔴 v2.9.5：记下来，歌单详情页据此把刚存的歌排到第一位
            //（酷狗服务端一律追加到末尾，不记就只能滑到最底下才看得到）
            await KugouRecentAdditions.shared.add(listID: playlist.id,
                                                  songIDs: added.map(\.id))
            // 已经打开着的歌单详情页收到通知后立刻把歌插到顶部
            NotificationCenter.default.post(
                name: .auroraKugouSongsAdded,
                object: nil,
                userInfo: ["listID": playlist.id, "songs": added])
        }
        if failed == 0 {
            Haptics.light()
            dismiss()
        } else {
            message = "已加入 \(ok) 首，\(failed) 首失败"
        }
    }
}
