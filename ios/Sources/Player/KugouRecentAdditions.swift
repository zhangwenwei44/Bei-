import Foundation

/// 🔴 v2.9.5：记住「用户手动存进酷狗歌单的歌」，让它们在歌单里排到最前面。
///
/// ## 为什么要这份本地记录
/// 酷狗服务端把新加的歌放在歌单**末尾**，用户每次「添加到酷狗歌单」之后，
/// 都要一路滑到列表最底下才能看到刚才存的那首歌 —— 存了跟没存一样。
///
/// 这里在 App 本地记一份 `listid → 最近存进去的歌曲 id`（最新的排最前），
/// 歌单详情页拉完列表后用这份记录把歌提到顶部，其余歌曲保持服务端原顺序不变。
///
/// ## 只影响排序，不影响数据
/// 这份记录纯本地（UserDefaults），不参与任何网络请求，
/// 删了它最多是「新存的歌又落到末尾」，不会有别的问题。
@MainActor
final class KugouRecentAdditions {
    static let shared = KugouRecentAdditions()

    private let storageKey = "aurora.kugou.recentAdditions"
    /// listid → 歌曲 id 列表（最新的排在最前）
    private var storage: [String: [String]] = [:]

    private init() { reload() }

    private func reload() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        storage = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// 记录一批刚存进去的歌（同一批里后存的排更前，和酷狗的添加顺序一致）
    func add(listID: String, songIDs: [String]) {
        var list = storage[listID] ?? []
        list = Array(songIDs.reversed()) + list
        var seen = Set<String>()
        list = list.filter { seen.insert($0).inserted }
        storage[listID] = Array(list.prefix(500))
        persist()
    }

    /// 把最近存进去的歌排到最前面，其余保持服务端返回的原顺序。
    func ordered(_ songs: [Song], forListID listID: String) -> [Song] {
        guard let recent = storage[listID], !recent.isEmpty else { return songs }
        var rank: [String: Int] = [:]
        for (offset, id) in recent.enumerated() { rank[id] = offset }

        var head: [Song] = []
        var rest: [Song] = []
        for song in songs {
            if rank[song.id] != nil { head.append(song) } else { rest.append(song) }
        }
        // head 内部按「最近添加」倒序（最新存的排第一行）
        head.sort { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
        return head + rest
    }
}
