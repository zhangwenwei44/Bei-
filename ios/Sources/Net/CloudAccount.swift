import Foundation
import Combine
import Supabase

/// Aurora 云账号 + 收藏 / 歌单云端同步（基于 Supabase）。
///
/// 与酷狗账号（KugouAuth）相互独立：本模块只认 Supabase 自己的 `auth.uid()`，
/// 同步的是 `LibraryStore.shared` 当前命名空间下的 `favorites` / `playlists`。
///
/// 行为：
/// - 邮箱注册 / 登录 / 登出；
/// - 登录成功后自动把云端数据拉回本地并合并（收藏按歌曲 id 并集，歌单按歌单 id 并集歌曲）；
/// - 本地收藏 / 歌单变化时，防抖后自动（fire-and-forget）推送到云端，实现跨设备同步。
final class CloudAccount: ObservableObject {
    static let shared = CloudAccount()

    @Published private(set) var isSignedIn = false
    @Published private(set) var userEmail: String?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var syncState: SyncState = .idle

    enum SyncState: Equatable {
        case idle
        case syncing
        case done(String)
        case failed(String)
    }

    private var client: SupabaseClient?
    private var userId: String?
    private var cancellables = Set<AnyCancellable>()
    /// 应用云端数据期间抑制本地变更的自动回推，避免回声推送。
    private var suppressPush = false

    private init() {}

    // MARK: 初始化

    /// 在 App 启动时调用一次。未配置时仅打日志，云功能保持关闭。
    func configure() {
        guard SupabaseConfig.isConfigured else {
            Log.warn("云端", "Supabase 未配置（请填写 SupabaseConfig.url / anonKey）")
            return
        }
        guard client == nil else { return }
        let client = SupabaseClient(
            supabaseURL: URL(string: SupabaseConfig.url)!,
            supabaseKey: SupabaseConfig.anonKey
        )
        self.client = client
        observeLocalChanges()
        // 监听登录态变化：启动时若本地有会话会自动触发 INITIAL_SESSION，
        // 登录 / 登出 / token 刷新都会走这里。
        // CloudAccount 是单例（shared 永生），这里强捕获 self 不会产生循环引用问题。
        Task { [self] in
            _ = await client.auth.onAuthStateChange { [self] _, session in
                Task { @MainActor in
                    if let session {
                        self.apply(session: session)
                        Task { await self.pullFromCloud() }
                    } else {
                        self.clearSession()
                    }
                }
            }
        }
    }

    // MARK: 会话

    private func apply(session: Session) {
        userId = String(describing: session.user.id)
        userEmail = session.user.email
        isSignedIn = true
        objectWillChange.send()
        Log.info("云端", "已登录 Supabase：\(session.user.email ?? userId ?? "")")
    }

    private func clearSession() {
        userId = nil
        userEmail = nil
        isSignedIn = false
        objectWillChange.send()
    }

    // MARK: 注册 / 登录 / 登出

    /// 注册。返回 true 表示已直接登录（项目关闭了邮箱验证）；
    /// 返回 false 表示需要去邮箱点验证链接后再登录。
    @discardableResult
    func signUp(email: String, password: String) async throws -> Bool {
        guard let client else { throw CloudError.notConfigured }
        isBusy = true
        defer { isBusy = false }
        let res = try await client.auth.signUp(email: email, password: password)
        if let session = res.session {
            await MainActor.run { apply(session: session) }
            await pullFromCloud()
            return true
        }
        await MainActor.run { message = "注册成功，请查收验证邮件后登录" }
        return false
    }

    func signIn(email: String, password: String) async throws {
        guard let client else { throw CloudError.notConfigured }
        isBusy = true
        defer { isBusy = false }
        let session = try await client.auth.signIn(email: email, password: password)
        await MainActor.run { apply(session: session) }
        await pullFromCloud()
    }

    func signOut() async throws {
        guard let client else { throw CloudError.notConfigured }
        isBusy = true
        defer { isBusy = false }
        try await client.auth.signOut(scope: .global)
        await MainActor.run { clearSession() }
    }

    // MARK: 云端同步

    /// 从云端拉取收藏 + 歌单并合并进本地（并集，不删本地已有）。
    func pullFromCloud() async {
        guard isSignedIn, let client, let userId else { return }
        await MainActor.run { syncState = .syncing }
        do {
            let favRows: [FavoriteRow] = try await client
                .from("favorites").select().execute().value
            let plRows: [PlaylistRow] = try await client
                .from("playlists").select().execute().value

            let remoteFavs = favRows.compactMap { $0.song }
            var playlistSongs: [String: [Song]] = [:]
            var remotePlaylists: [LibraryStore.UserPlaylist] = []
            for row in plRows {
                playlistSongs[row.id] = row.songs
                remotePlaylists.append(
                    LibraryStore.UserPlaylist(
                        id: row.id,
                        name: row.name,
                        songIDs: row.songs.map { $0.id },
                        createdAt: Date()
                    )
                )
            }
            // 用不可变副本传入 @Sendable 闭包，避免捕获可变 var（并发安全）
            let finalSongs = playlistSongs
            let finalPlaylists = remotePlaylists
            await MainActor.run {
                suppressPush = true
                LibraryStore.shared.mergeCloud(
                    favorites: remoteFavs,
                    playlists: finalPlaylists,
                    playlistSongs: finalSongs
                )
                suppressPush = false
            }
            await MainActor.run {
                syncState = .done("已从云端恢复 \(remoteFavs.count) 首收藏")
            }
        } catch {
            await MainActor.run { syncState = .failed(error.localizedDescription) }
        }
    }

    /// 把本地收藏 + 歌单推送到云端（增量 upsert，幂等）。
    func pushToCloud() async {
        guard isSignedIn, let client, let userId else { return }
        guard !suppressPush else { return }
        await MainActor.run { syncState = .syncing }
        do {
            let favorites = LibraryStore.shared.favorites
            let favRows = favorites.map {
                FavoriteRow(user_id: userId, song_id: $0.id, song: $0)
            }
            try await client.from("favorites")
                .upsert(favRows, onConflict: "user_id,song_id").execute()

            let playlists = LibraryStore.shared.playlists
            let plRows = playlists.map { pl -> PlaylistRow in
                let songs = LibraryStore.shared.songs(in: pl)
                return PlaylistRow(
                    id: pl.id,
                    user_id: userId,
                    name: pl.name,
                    songs: songs
                )
            }
            try await client.from("playlists")
                .upsert(plRows, onConflict: "user_id,id").execute()

            await MainActor.run { syncState = .done("已同步到云端") }
        } catch {
            await MainActor.run { syncState = .failed(error.localizedDescription) }
        }
    }

    /// 订阅本地收藏 / 歌单变化，防抖后自动推送（仅在已登录时）。
    /// CloudAccount 是单例，sink 强捕获 self 不会造成泄漏。
    private func observeLocalChanges() {
        let lib = LibraryStore.shared
        lib.$favorites
            .dropFirst()
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [self] _ in Task { await self.pushToCloud() } }
            .store(in: &cancellables)
        lib.$playlists
            .dropFirst()
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [self] _ in Task { await self.pushToCloud() } }
            .store(in: &cancellables)
    }

    // MARK: 云端行模型（与 Supabase 表列名一一对应）

    private struct FavoriteRow: Codable {
        // 注意：不声明 id —— favorites.id 是 uuid PK 且有 gen_random_uuid() 默认值，
        // 我们按 (user_id, song_id) upsert，插入时让数据库自动生成 id；
        // 若显式传 null 反而会让 Postgres 报「null 违反 not null 约束」。
        var user_id: String
        var song_id: String
        var song: Song
        var created_at: String?
    }

    private struct PlaylistRow: Codable {
        var id: String
        var user_id: String
        var name: String
        var songs: [Song]
        var created_at: String?
        var updated_at: String?
    }

    private enum CloudError: LocalizedError {
        case notConfigured
        var errorDescription: String? { "Supabase 未配置" }
    }
}
