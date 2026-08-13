import Foundation

/// 轻量崩溃/运行日志：闪退时把异常与调用栈写入沙盒文件，
/// 下次启动由 App 界面直接展示，相当于"iOS 版 logcat + 崩溃报告"。
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

    // MARK: - 安装

    func setup() {
        installExceptionHandler()
        installSignalHandler()
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
        guard let url = logURL, (try? String(contentsOf: url)) != nil else { return nil }
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

    // MARK: - 异常捕获

    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exc in
            let stack = (exc.callStackSymbols as [String]).joined(separator: "\n")
            let text = """
            === UNCAUGHT EXCEPTION @ \(Self.ts()) ===
            Name : \(exc.name)
            Reason: \(exc.reason ?? "(无)")
            Thread: \(Thread.isMainThread ? "main" : "background")
            Call stack:
            \(stack)
            """
            CrashLogger.shared.writeCrash(text)
        }
    }

    private func installSignalHandler() {
        let signals: [(Int32, String)] = [
            (SIGABRT, "SIGABRT"), (SIGILL, "SIGILL"), (SIGSEGV, "SIGSEGV"),
            (SIGBUS, "SIGBUS"), (SIGTRAP, "SIGTRAP"), (SIGFPE, "SIGFPE")
        ]
        for (sig, _) in signals {
            signal(sig) { s in
                let n = signals.first(where: { $0.0 == s })?.1 ?? "signal \(s)"
                let text = "=== \(n) @ \(CrashLogger.ts()) ===\n\(CrashLogger.captureBacktrace())\n"
                CrashLogger.shared.writeCrash(text)
                signal(s, SIG_DFL)   // 恢复默认处理，避免无限递归
                kill(getpid(), s)     // 交还系统，保留标准崩溃报告
            }
        }
    }

    private func writeCrash(_ text: String) {
        guard let url = crashURL else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func captureBacktrace() -> String {
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = Darwin.backtrace(&frames, Int32(frames.count))
        guard let syms = backtrace_symbols(&frames, count) else { return "(无符号)" }
        defer { free(syms) }
        var out = ""
        for i in 0..<Int(count) {
            if let c = syms[i] { out += String(cString: c) + "\n" }
        }
        return out
    }

    private static func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
