import Foundation

/// 主线程当前在做什么。
///
/// 卡死时主线程停在哪儿，光看日志是猜不出来的 —— 冻结往往正好发生在「该写日志之前」，
/// 导出的日志全是恢复之后的。这里由关键代码点写入一个短标签，
/// 看门狗发现主线程无响应时把标签一起报出来，下一次就能直接定位到具体位置。
enum MainThreadTrace {
    /// 状态放在实例里（和 LogStore 同样写法）：可变静态变量会触发
    /// 「nonisolated global shared mutable state」警告，而 CI 是零警告即失败。
    private static let store = Store()

    static func set(_ what: String) {
        store.set(what)
    }

    static var snapshot: String {
        store.snapshot
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var current = "启动"

        func set(_ what: String) {
            // 只接受主线程的调用：后台线程改这个值会污染追踪结果。
            guard Thread.isMainThread else { return }
            lock.lock()
            current = what
            lock.unlock()
        }

        var snapshot: String {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }
}

/// 主线程看门狗。
///
/// 背景：App 出现过「点进某个页面就彻底冻住、连点按钮都没反应、只能杀进程重进」的情况。
/// 这种冻结光看日志极难定位——冻结发生的那一刻往往正好是**该写日志之前**，
/// 导出的日志全是"恢复正常后"的，完全看不出卡在哪。
///
/// 这里在后台起一个定时器，每 2 秒 ping 一次主线程；主线程连续 5 秒没回应就记一条警告。
/// 下次再卡死，日志里会直接出现「主线程疑似卡住 XX 秒（停在：xxx）」，配合当时的业务日志一起看，
/// 至少能确定「是主线程被冻住」还是「只是某一步慢」。
///
/// ⚠️ 刻意不采主线程调用栈（iOS 上拿栈要私有 API，容易被拒），只报卡住时长 + 当前动作标签。
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "Aurora.MainThreadWatchdog")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    /// 主线程还没回 pong（= 主线程正卡着）
    private var waitingReply = false
    /// 本轮 ping 的发出时间
    private var pingSentAt = Date()
    /// 上次报警时间，避免每 2 秒报一次刷屏
    private var lastReportAt = Date.distantPast

    private let pingInterval: TimeInterval = 2
    private let stallThreshold: TimeInterval = 5
    /// 两次报警的最小间隔
    private let reportInterval: TimeInterval = 15

    private init() {}

    /// 启动看门狗（App 启动时调一次）。
    func start() {
        lock.lock()
        if timer != nil {
            lock.unlock()
            return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = t
        lock.unlock()
        t.resume()
        Log.info("看门狗", "主线程看门狗已启动：每 \(Int(pingInterval)) 秒探一次，连续 \(Int(stallThreshold)) 秒无响应即报警")
    }

    private func tick() {
        let now = Date()
        lock.lock()
        if waitingReply {
            // 上一轮的 pong 一直没回来 → 主线程卡住了
            let stalled = now.timeIntervalSince(pingSentAt)
            let shouldReport = stalled >= stallThreshold && now.timeIntervalSince(lastReportAt) >= reportInterval
            if shouldReport { lastReportAt = now }
            lock.unlock()
            if shouldReport {
                Log.error("看门狗", "主线程疑似卡住 \(String(format: "%.1f", stalled)) 秒（停在：\(MainThreadTrace.snapshot)；UI 无响应，App 进程还活着）")
            }
        } else {
            waitingReply = true
            pingSentAt = now
            lock.unlock()
        }
        // 每轮都发一个 pong 请求：主线程恢复后会把 waitingReply 置回 false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.waitingReply = false
            self.lock.unlock()
        }
    }
}
