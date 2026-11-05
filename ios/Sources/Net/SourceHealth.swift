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

    /// id → 状态。
    ///
    /// 🔴 v2.9.22（**音源页卡死的最终根因**）：这个字典**完全不用锁**。
    /// 之前读写共用一把 NSLock，而且写的时候是「**持着锁写 @Published**」——
    /// 写 @Published 会同步触发 objectWillChange → SwiftUI 立刻重算 body
    /// → body 里又调 `status(for:)` 取**同一把锁** → NSLock 不可重入 →
    /// **永久死锁**，主线程在渲染列表行时被彻底冻住
    /// （看门狗实测停在「取健康状态（等锁）」：UI 无响应、App 进程还活着、后台线程照跑）。
    ///
    /// 现在：写入全部在主线程、且永远是「复制 → 改 → 整体替换」。
    /// Swift 数组/字典是写时复制，读者只会看到旧值或新值、绝不会读到半个字典，
    /// 所以读写都不需要锁 —— 主线程永远不会被这把锁卡住。
    @Published private(set) var status: [String: Status] = [:]

    /// 结果缓存有效期：10 分钟内不重复联网检测。
    private let ttl: TimeInterval = 10 * 60
    private var checkedAt: [String: Date] = [:]
    private var inflight = Set<String>()
    /// 🔴 只保护 checkedAt / inflight 这两个后台线程也会碰的状态。
    /// ⚠️ 绝不能在这把锁的保护范围内写 @Published（会引发上面说的递归死锁）。
    private let lock = NSLock()

    /// 🔴 用户要求：音源自动检测总开关（默认开）。
    /// 关掉后「启动检测」+「进音源页全量体检」都跳过，但「重新检测全部音源」手动按钮仍可用。
    static var autoDetectEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "aurora.source.autoDetectDisabled") }
        set { UserDefaults.standard.set(!newValue, forKey: "aurora.source.autoDetectDisabled") }
    }

    // MARK: 读取

    /// 读状态。**不取锁** —— 状态字典的写入全在主线程、读可能在后台
    /// （SourceResolver 过滤无用音源时会读），写时复制保证读到的一定是完整快照。
    func status(for id: String) -> Status {
        MainThreadTrace.set("读健康状态")
        return status[id] ?? .unknown
    }

    /// 某个音源刚被用户编辑/开关，清掉旧结论重新检测。
    func reset(_ id: String) {
        lock.lock()
        checkedAt.removeValue(forKey: id)
        inflight.remove(id)
        lock.unlock()
        // @Published 的写统一走 set()（回主线程），绝不在锁的保护范围内写。
        set(.unknown, for: id)
    }

    // MARK: 检测

    /// 检测单个音源：直接走脚本运行器（忽略 providerCode 限制），用酷狗探针歌曲试解析。
    @discardableResult
    func check(_ source: ThirdPartySource) async -> Status {
        guard source.enabled, source.isUsable else {
            set(.unknown, for: source.id)
            return .unknown
        }
        // 脚本线程池已被坏脚本耗尽：没有健康线程可用，这条音源标「未检测」跳过，
        // 不要误判成「无用」自动关掉（重启 App 即可重置池）。
        if ScriptSourceRunner.shared.isExecutorsExhausted() {
            set(.unknown, for: source.id)
            return .unknown
        }
        lock.lock()
        let alreadyRunning = inflight.contains(source.id)
        if !alreadyRunning { inflight.insert(source.id) }
        lock.unlock()
        if alreadyRunning {
            return status[source.id] ?? .unknown
        }
        // 🔴 必须先解锁再 set()：set() 内部会改 status，而 status 的写入绝不能
        // 发生在锁的保护范围内（见上面 status 的说明：持锁写 @Published 会死锁）。
        set(.checking, for: source.id)
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
        guard SourceHealth.autoDetectEnabled else { return }
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

    /// 进入音源页时全量体检：逐个检测**所有可用音源**（含未启用的），
    /// 可用 → 自动开启，无用（连探针都解析不出） → 自动关闭（红关绿开）。
    /// 不可用的源（脚本空 / 配置不完整）跳过，不强行开关。
    func detectAllAndApply() async {
        guard SourceHealth.autoDetectEnabled else { return }
        let targets = SourceStore.shared.sources.filter { $0.isUsable }
        // 先统一标成「检测中」：否则刚进页面时一个绿/红点都没有，用户会以为页面卡死。
        for source in targets { set(.checking, for: source.id) }
        Log.info("音源", "开始全量体检 \(targets.count) 个音源")

        // 总预算：坏脚本每个最多吃满 5s(构建)+12s(调用) 超时，几十个源逐个来会非常久。
        // 设一个上限，超时的源不再死等，标回「未检测」即可（下次进页面或手动检测再补）。
        let budget: TimeInterval = 60
        let start = Date()

        for source in targets {
            if Date().timeIntervalSince(start) > budget {
                // 预算耗尽：把还没轮到的源从「检测中」转回「未检测」，避免一直转圈像卡死。
                set(.unknown, for: source.id)
                continue
            }
            if ScriptSourceRunner.shared.isExecutorsExhausted() {
                // 脚本线程池已被坏脚本耗尽（新建额度用尽）。此时没有健康线程可用，
                // 剩下的音源直接标「未检测」跳过，绝不要误判成「无用」把它们自动关掉。
                Log.warn("音源", "脚本线程池已耗尽，剩余音源跳过检测：\(source.name)")
                set(.unknown, for: source.id)
                continue
            }
            // 先记一条「开始检测」，这样万一卡住，日志最后一行就能指出卡在哪个音源
            Log.info("音源", "开始检测「\(source.name)」")
            let ok = await resolveProbe(source)
            let result: Status = ok ? .ok : .bad
            set(result, for: source.id)
            lock.lock()
            checkedAt[source.id] = Date()
            lock.unlock()
            // 先只改内存（UI 立刻反映开关变化），整批跑完再统一落盘一次。
            // 🔴 @Published 只能在主线程写，所以用 MainActor.run 同步等它落定，
            // 否则后面 persistNow 可能把「开关还没改」的旧值写进磁盘。
            let sourceID = source.id
            let shouldEnable = ok
            await MainActor.run {
                SourceStore.shared.setEnabled(shouldEnable, id: sourceID, save: false)
            }
            Log.info("音源", "「\(source.name)」体检结果：\(ok ? "可用" : "无用")")
        }
        SourceStore.shared.persistNow()
        Log.info("音源", "全量体检完成")
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

    /// 写状态。
    ///
    /// 🔴 统一在主线程执行，且**绝不持锁**：写 @Published 会触发 objectWillChange，
    /// SwiftUI 可能当场重算 body（body 里会再读 status）。如果此刻还持着 lock，
    /// 就会同线程二次取锁 → NSLock 不可重入 → 永久死锁。
    /// 写法是「复制 → 改 → 整体替换」：写时复制保证后台读者看到的是完整快照。
    private func set(_ newStatus: Status, for id: String) {
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            var next = self.status
            next[id] = newStatus
            self.status = next
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
