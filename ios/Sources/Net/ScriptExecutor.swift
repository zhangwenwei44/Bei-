import Foundation

/// 脚本执行线程。
///
/// 为什么不用 DispatchQueue：libdispatch 的工作线程栈只有 512KB，
/// 而聚合类音源脚本（洛雪那类）在请求签名时会跑混淆解密、MD5/AES，
/// 递归一深就撞栈保护页，表现为 SIGTRAP 直接把进程打死。
/// 换成显式创建、栈给到 16MB 的线程后，这类崩溃就消失了。
final class ScriptExecutor {
    /// 执行器的全部状态放在独立对象里。
    ///
    /// 之所以多这一层：Thread 的初始化闭包里不能碰 self——那时成员还没全部
    /// 初始化完，哪怕写 [weak self] 也会报「used before being initialized」。
    /// 让闭包只捕获这个 Box，就彻底绕开了初始化顺序问题。
    private final class Box {
        private let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var pending: (() -> Void)?

        /// 线程主体：取一个任务执行，再等下一个，严格串行。
        func runLoop() {
            while true {
                ready.wait()
                if let task = takePending() { task() }
            }
        }

        /// 提交任务。保证对 JSContext 的访问严格串行。
        ///
        /// 如果上一条任务还没被取走就再提交，旧任务会被丢弃并记一条警告。
        /// 正常使用时每条都会被取走，这里只是防止任务被静默丢掉。
        func submit(_ work: @escaping () -> Void) {
            lock.lock()
            if pending != nil {
                lock.unlock()
                NSLog("[ScriptExecutor] 上一个任务还没被取走，新任务被丢弃")
                return
            }
            pending = work
            lock.unlock()
            ready.signal()
        }

        private func takePending() -> (() -> Void)? {
            lock.lock()
            defer { pending = nil }
            return pending
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
}
