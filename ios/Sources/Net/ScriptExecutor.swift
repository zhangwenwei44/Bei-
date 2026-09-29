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
        /// 任务队列。之前是单个 pending 槽位：上一条还没被取走时再提交
        /// 会直接丢弃新任务且只写 NSLog（App 日志里看不到），
        /// invoke 的任务就可能这样凭空消失。
        private var tasks: [() -> Void] = []

        /// 线程主体：取一个任务执行，再等下一个，严格串行。
        func runLoop() {
            while true {
                ready.wait()
                while let task = takeNext() { task() }
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
}
