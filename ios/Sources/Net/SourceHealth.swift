import Foundation
import SwiftUI

/// 音源健康检测：启动后逐一尝试解析一首探针歌曲，标记每个音源「可用 / 无用」。
///
/// 设计要点：
/// - 检测结果以圆点展示在「第三方音源」列表里（绿=可用，红=无用，灰=未检测/不适用）。
/// - 解析时跳过标记为「无用」的音源，避免把 20 秒预算浪费在已死的源上。
/// - `@Published` 的写入统一回到主线程，避免后台写触发 SwiftUI 警告（CI 零警告即失败）。
final class SourceHealth: ObservableObject {
    static let shared = SourceHealth()

    enum Status: Equatable {
        case unknown
        case checking
        case ok
        case bad
    }

    /// id → 状态。只读副本，避免外部直接改。
    @Published private(set) var status: [String: Status] = [:]

    /// 结果缓存有效期：10 分钟内不重复联网检测。
    private let ttl: TimeInterval = 10 * 60
    private var checkedAt: [String: Date] = [:]
    private var inflight = Set<String>()
    private let lock = NSLock()

    // MARK: 读取

    func status(for id: String) -> Status {
        lock.lock()
        let value = status[id] ?? .unknown
        lock.unlock()
        return value
    }

    /// 某个音源刚被用户编辑/开关，清掉旧结论重新检测。
    func reset(_ id: String) {
        lock.lock()
        status[id] = .unknown
        checkedAt.removeValue(forKey: id)
        inflight.remove(id)
        lock.unlock()
    }

    // MARK: 检测

    /// 检测单个音源：直接走脚本运行器（忽略 providerCode 限制），用酷狗探针歌曲试解析。
    @discardableResult
    func check(_ source: ThirdPartySource) async -> Status {
        guard source.enabled, source.isUsable else {
            set(.unknown, for: source.id)
            return .unknown
        }
        lock.lock()
        if inflight.contains(source.id) {
            let current = status[source.id] ?? .unknown
            lock.unlock()
            return current
        }
        inflight.insert(source.id)
        set(.checking, for: source.id)
        lock.unlock()
        defer {
            lock.lock()
            inflight.remove(source.id)
            lock.unlock()
        }

        let ok = await resolveProbe(source)
        let result: Status = ok ? .ok : .bad
        set(result, for: source.id)
        lock.lock()
        checkedAt[source.id] = Date()
        lock.unlock()
        return result
    }

    /// 启动后整批检测（带总预算，避免卡太久）。
    func checkAll() async {
        let start = Date()
        let budget: TimeInterval = 90
        for source in SourceStore.shared.sources where source.enabled && source.isUsable {
            if Date().timeIntervalSince(start) > budget { break }
            _ = await check(source)
        }
    }

    /// 只检测过期的音源（进入音源设置页时调用）。
    func checkStale() async {
        let now = Date()
        for source in SourceStore.shared.sources where source.enabled && source.isUsable {
            lock.lock()
            let at = checkedAt[source.id]
            let running = inflight.contains(source.id)
            lock.unlock()
            if running { continue }
            if let at, now.timeIntervalSince(at) < ttl { continue }
            _ = await check(source)
        }
    }

    // MARK: 内部

    /// 用一首大众酷狗歌曲做探针，直接解析（不经过 providerCode 过滤）。
    private func resolveProbe(_ source: ThirdPartySource) async -> Bool {
        let audio = await ScriptSourceRunner.shared.resolve(
            source: source,
            song: SourceHealth.probeSong,
            quality: .standard,
            excludedHosts: []
        )
        return audio != nil
    }

    private func set(_ newStatus: Status, for id: String) {
        let apply: () -> Void = { [weak self] in
            self?.lock.lock()
            self?.status[id] = newStatus
            self?.lock.unlock()
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
    }

    /// 探针歌曲：酷狗《晴天》，用来检测音源能否解析出播放地址。
    static let probeSong = Song(
        title: "晴天",
        artist: "周杰伦",
        album: "叶惠美",
        duration: 269,
        source: .kugou,
        kugouHash: "B3A52A7A958BF0AED0EBFBA2E9A818B7",
        kugouAudioID: "20505418",
        kugouAlbumID: "966846"
    )
}
