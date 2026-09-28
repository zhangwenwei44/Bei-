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
            LogStore.emergencyWrite(message)
        }

        // 内存访问违例等信号。能走到这里的进程本来就要死了，
        // 但至少把现场写进文件。
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
            signal(signalNumber, SIG_IGN)
            signal(signalNumber) { received in
                let name = Self.signalName(received)
                let frames = Self.backtrace()
                let message = """
                收到信号 \(received)：\(name)
                    崩溃线程调用栈：
                    \(frames)
                """
                Log.error("崩溃", message)
                LogStore.emergencyWrite(message)
                // 交回系统默认处理，保留原有的崩溃表现
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    /// 抓取当前线程的调用栈。
    ///
    /// 这是把「我猜是某个原因」变成「栈上真的有那些帧」的关键。
    /// SIGTRAP 本身不留下任何日志，只有这里主动抓才看得到。
    ///
    /// 注意：之前用 `#if canImport(execinfo)` + backtrace()，在 iOS 上
    /// canImport(execinfo) 判定为假，导出的日志里全是「当前平台不支持」，
    /// 等于白写。Thread.callStackSymbols 内部就是 backtrace 的封装，
    /// 所有 Apple 平台都可用，信号处理器里也能安全调用。
    private static func backtrace() -> String {
        let symbols = Thread.callStackSymbols
        // 跳过最前面几帧（backtrace 自身、信号处理器、崩溃上报），
        // 剩下的才是真正要看的业务调用链
        let useful = symbols.dropFirst(4).prefix(36)
        guard !useful.isEmpty else { return "(调用栈为空)" }
        return useful.joined(separator: "\n    ")
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
