import Foundation
import Darwin

/// 轻量崩溃/运行日志：闪退时把异常与调用栈写入沙盒文件，
/// 下次启动由 App 界面直接展示，相当于"iOS 版 logcat + 崩溃报告"。
///
/// 关键修复：
/// - NSException 会先被 exceptionHandler 抓住并写入"异常报告"，
///   随后系统 abort() 又触发 SIGABRT；信号处理器发现"异常报告已存在"
///   就**不再覆盖**，保留最有价值的堆栈。
/// - 用 dladdr 把地址符号化成 函数名+偏移，配合构建时保留符号表，
///   能直接看到是哪个 Swift 函数崩溃。
final class CrashLogger {

    static let shared = CrashLogger()

    private let crashURL: URL? = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("crash.log")
    }()

    private let logURL: URL? = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("app.log")
    }()

    private let q = DispatchQueue(label: "crashlogger")

    /// 标记：NSException 已写入报告，信号处理器据此避免覆盖。
    fileprivate static var exceptionReported = false

    // MARK: - 安装

    func setup() {
        // 必须是"非捕获上下文"的函数才能转成 C 函数指针（signal/异常系统要求）。
        NSSetUncaughtExceptionHandler(exceptionHandler)
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGTRAP, SIGFPE] {
            signal(sig, bcSignalHandler)
        }
    }

    // MARK: - 运行日志（类 logcat）

    func log(_ msg: String) {
        guard let url = logURL else { return }
        let line = "[\(Self.ts())] \(msg)\n"
        q.async {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(line.data(using: .utf8) ?? Data())
                try? fh.closeFile()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    func lastLog() -> String? {
        guard let url = logURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 崩溃日志

    func lastCrash() -> String? {
        guard let url = crashURL,
              let s = try? String(contentsOf: url, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    func clearCrash() {
        if let url = crashURL { try? FileManager.default.removeItem(at: url) }
    }

    fileprivate func writeCrash(_ text: String) {
        guard let url = crashURL else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    fileprivate static func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// 把一组返回地址符号化成「序号 镜像 函数名 + 偏移」，便于定位。
    fileprivate static func symbolicate(_ addresses: [NSNumber]) -> String {
        var out = ""
        for (i, addr) in addresses.enumerated() {
            let v = addr.uintValue
            guard let ptr = UnsafeRawPointer(bitPattern: v) else {
                out += String(format: "%-3d 0x%lx\n", i, v)
                continue
            }
            var info = Dl_info()
            if dladdr(ptr, &info) != 0 {
                let fname = info.dli_fname.map { String(cString: $0) } ?? "?"
                let sname = info.dli_sname.map { String(cString: $0) } ?? "?"
                let base = UInt(bitPattern: info.dli_fbase)
                let off = v - base
                let short = (fname as NSString).lastPathComponent
                out += String(format: "%-3d %@  %@ + 0x%x\n", i, short, sname, off)
            } else {
                out += String(format: "%-3d 0x%lx\n", i, v)
            }
        }
        return out
    }
}

// MARK: - 文件级崩溃处理器（非捕获函数，才能转 C 函数指针）

private func exceptionHandler(_ exc: NSException) {
    // 用返回地址符号化，能直接看到崩溃所在的 Swift 函数
    let stack = CrashLogger.symbolicate(exc.callStackReturnAddresses)
    let text = """
    === UNCAUGHT EXCEPTION @ \(CrashLogger.ts()) ===
    Name : \(exc.name)
    Reason: \(exc.reason ?? "(无)")
    Thread: \(Thread.isMainThread ? "main" : "background")
    Symbolicated call stack:
    \(stack)
    """
    CrashLogger.exceptionReported = true
    CrashLogger.shared.writeCrash(text)
    // 不在此 re-raise：系统会在 exceptionHandler 返回后自动 abort()
}

private func bcSignalHandler(_ sig: Int32) {
    // 若 NSException 已写过报告，保留它，不要再覆盖成信号处理器自己的栈
    if CrashLogger.exceptionReported {
        signal(sig, SIG_DFL)
        kill(getpid(), sig)
        return
    }
    let name: String
    switch sig {
    case SIGABRT: name = "SIGABRT"
    case SIGILL:  name = "SIGILL"
    case SIGSEGV: name = "SIGSEGV"
    case SIGBUS:  name = "SIGBUS"
    case SIGTRAP: name = "SIGTRAP"
    case SIGFPE:  name = "SIGFPE"
    default:      name = "signal \(sig)"
    }
    // 当前线程栈（含信号处理器自身），只能作为补充参考
    let stack = CrashLogger.symbolicate(Thread.callStackReturnAddresses)
    let text = """
    === \(name) @ \(CrashLogger.ts()) ===
    (注：此栈含信号处理器自身，真正的崩溃点请看 UNCAUGHT EXCEPTION 报告)
    \(stack)
    """
    CrashLogger.shared.writeCrash(text)
    signal(sig, SIG_DFL)
    kill(getpid(), sig)
}
