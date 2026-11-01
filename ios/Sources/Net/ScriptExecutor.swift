import Foundation

/// 脚本执行线程。
///
/// 为什么不用 DispatchQueue：libdispatch 的工作线程栈只有 512KB，
/// 而聚合类音源脚本（洛雪那类）在请求签名时会跑混淆解密、MD5/AES，
/// 递归一深就撞栈保护页，表现为 SIGTRAP 直接把进程打死。
/// 换成显式创建、栈给到 16MB 的线程后，这类崩溃就消失了。
final class ScriptExecutor: @unchecked Sendable {
    /// 执行器的全部状态放在独立对象里。
    ///
    /// 之所以多这一层：Thread 的初始化闭包里不能碰 self——那时成员还没全部
    /// 初始化完，哪怕写 [weak self] 也会报「used before being initialized」。
    /// 让闭包只捕获这个 Box，就彻底绕开了初始化顺序问题。
    private final class Box {
        private let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        /// 任务队列。之前是单个 pending 槽位：上一条还没被取走时再提交
        /// 会直接丢弃新任务且只写 NSLog（App 日志里看不到），
        /// invoke 的任务就可能这样凭空消失。
        private var tasks: [() -> Void] = []
        /// 已请求停止：runLoop 取完手头任务后退出，线程随之结束，避免泄漏。
        private var cancelled = false
        /// 已被坏脚本（死循环/卡死）拖垮：标记后不再分配任务，调用方改用其它健康线程。
        /// 卡死的线程杀不掉，但数量受 ScriptSourceRunner 的池上限约束，保证内存有界。
        private var poisoned = false
        func markPoisoned() { lock.lock(); poisoned = true; lock.unlock() }
        func isPoisoned() -> Bool { lock.lock(); defer { lock.unlock() }; return poisoned }

        /// 线程主体：取一个任务执行，再等下一个，严格串行。
        func runLoop() {
            while true {
                ready.wait()
                while let task = takeNext() { task() }
                lock.lock()
                let shouldStop = cancelled
                lock.unlock()
                if shouldStop { break }
            }
        }

        /// 提交任务。保证对 JSContext 的访问严格串行。
        func submit(_ work: @escaping () -> Void) {
            lock.lock()
            tasks.append(work)
            lock.unlock()
            ready.signal()
        }

        /// 同步执行并等待完成。用于初始化阶段：JSContext 的所有访问
        /// （构造、调用、回调）都必须落在同一条线程上。
        func submitAndWait(_ work: @escaping () -> Void) {
            let done = DispatchSemaphore(value: 0)
            submit {
                work()
                done.signal()
            }
            done.wait()
        }

        /// 带超时的同步执行。返回 true 表示任务在超时前完成；返回 false 表示超时——
        /// 此时任务仍在后台线程上运行（例如脚本死循环），调用方应放弃等待，
        /// 避免被一条卡死的 worker 线程永久阻塞。
        @discardableResult
        func submitAndWait(timeout: TimeInterval, _ work: @escaping () -> Void) -> Bool {
            let done = DispatchSemaphore(value: 0)
            submit {
                work()
                done.signal()
            }
            return done.wait(timeout: .now() + timeout) != .timedOut
        }

        /// 请求停止：标记 cancelled 并唤醒 runLoop，使其取完手头任务后退出。
        func stop() {
            lock.lock()
            cancelled = true
            lock.unlock()
            ready.signal()
        }

        private func takeNext() -> (() -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return tasks.isEmpty ? nil : tasks.removeFirst()
        }
    }

    private let box: Box
    /// 工作线程。持有引用以免线程被过早回收。
    private let worker: Thread

    init(label: String, stackSize: Int = 16 * 1024 * 1024) {
        let b = Box()
        // 闭包只捕获局部变量 b，完全不引用 self
        let thread = Thread { b.runLoop() }
        thread.name = label
        thread.stackSize = stackSize
        box = b
        worker = thread
        thread.start()
    }

    func async(_ work: @escaping () -> Void) {
        box.submit(work)
    }

    /// 同步执行并等待。JSContext 的所有访问都必须走这里，
    /// 保证始终在同一条线程上。
    func sync(_ work: @escaping () -> Void) {
        box.submitAndWait(work)
    }

    /// 带超时的同步执行（秒）。返回 false 表示任务超时仍在跑，调用方应放弃等待。
    /// 用于拦截初始化阶段就死循环的脚本，避免把串行调用方（buildQueue）永久卡死。
    @discardableResult
    func sync(timeout: TimeInterval, _ work: @escaping () -> Void) -> Bool {
        box.submitAndWait(timeout: timeout, work)
    }

    /// 主动停止 worker 线程。运行时被释放/淘汰时调用，避免 16MB 栈线程永久泄漏
    /// （之前每次进音源页都为每个音源各拉一条永不退出的线程，内存累积把 App 挤爆）。
    func stop() {
        box.stop()
    }

    /// 标记该执行器被坏脚本拖垮（卡死的线程杀不掉）。之后 acquireExecutor 不再分配任务给它。
    func markPoisoned() { box.markPoisoned() }
    var isPoisoned: Bool { box.isPoisoned() }

    deinit {
        box.stop()
    }
}
