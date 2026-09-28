import Foundation
import UIKit
#if canImport(execinfo)
import execinfo
#endif

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

    /// 抓取当前线程的原生调用栈。
    ///
    /// 这是把「我猜是栈溢出」变成「栈上真的有 JavaScriptCore 帧」的关键。
    /// SIGTRAP 本身不会留下任何日志，只有这里主动抓才看得到。
    private static func backtrace() -> String {
        #if canImport(execinfo)
        var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let count = backtrace(&addresses, Int32(addresses.count))
        guard count > 0 else { return "(取不到调用栈)" }
        let symbols = addresses[0..<Int(count)].map { pointer -> String in
            guard let pointer else { return "???" }
            var info = Dl_info()
            if dladdr(pointer, &info) != 0, let name = info.dli_fname {
                let base = info.dli_fnameOffset
                // 去掉地址偏移里的 ASLR 噪声，只留偏移量便于对照
                return "\(URL(fileURLWithPath: name).lastPathComponent)+0x\(String(format: "%lx", base))"
            }
            return "???"
        }
        return symbols.prefix(40).joined(separator: "\n    ")
        #else
        return "(当前平台不支持)"
        #endif
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
