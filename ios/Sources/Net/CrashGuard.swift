import Foundation
import UIKit

/// 崩溃现场记录。
///
/// 之前播放闪退只在系统日志里留一行，App 内什么都看不到，
/// 导出的运行日志也停在崩溃前最后一条，只能靠猜。
/// 这里把未捕获的异常和信号写进运行日志，下次导出就能直接看到崩在哪。
enum CrashGuard {
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        // ObjC / Swift 运行时抛出的未捕获异常
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "无原因"
            let stack = exception.callStackSymbols.prefix(25).joined(separator: "\n    ")
            let message = """
            未捕获异常 \(name)：\(reason)
                调用栈：
                    \(stack)
            """
            Log.error("崩溃", message)
            // 同步再写一份，Task 来不及调度
            LogStore.emergencyWrite(message)
        }

        // 内存访问违例等信号。能走到这里的进程本来就要死了，
        // 但至少把现场写进文件。
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
            signal(signalNumber, SIG_IGN)
            signal(signalNumber) { received in
                let name = Self.signalName(received)
                Log.error("崩溃", "收到信号 \(received)（\(name)）")
                LogStore.emergencyWrite("收到信号 \(received)：\(name)")
                // 交回系统默认处理，保留原有的崩溃表现
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    private static func signalName(_ number: Int32) -> String {
        switch number {
        case SIGSEGV: return "SIGSEGV 内存访问违例"
        case SIGBUS: return "SIGBUS 总线错误"
        case SIGILL: return "SIGILL 非法指令"
        case SIGABRT: return "SIGABRT 主动中止"
        case SIGTRAP: return "SIGTRAP 断点"
        case SIGFPE: return "SIGFPE 算术错误"
        default: return "未知信号"
        }
    }
}
