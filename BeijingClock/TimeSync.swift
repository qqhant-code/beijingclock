import Foundation

/// 网络授时模块：从服务器的 HTTP `Date` 响应头读取权威 UTC 时间，
/// 计算与设备时钟的偏差(offset)，并把任意时刻格式化为北京时间(UTC+8)。
///
/// 设计目标：显示的时间"不受系统时间影响"——
/// 只要成功取过一次网络时间，之后显示 = 设备当前时间 + offset，
/// 即使设备时钟被手动改错、时区乱跳，显示的北京时间依然正确。
enum TimeSync {

    /// 多个备选端点，任意一个返回 `Date` 头即可。
    private static let endpoints = [
        "https://www.apple.com",
        "https://www.baidu.com",
        "https://www.cloudflare.com",
        "https://www.microsoft.com"
    ]

    /// 异步获取权威当前 UTC 时间；全部失败返回 nil。
    static func fetchNetworkDate(completion: @escaping (Date?) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var result: Date?

        for urlStr in endpoints {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 5
            group.enter()
            let task = URLSession.shared.dataTask(with: req) { _, response, _ in
                defer { group.leave() }
                guard let http = response as? HTTPURLResponse,
                      let raw = http.allHeaderFields["Date"] as? String,
                      let d = parseRFC1123(raw) else { return }
                lock.lock()
                if result == nil { result = d }
                lock.unlock()
            }
            task.resume()
        }

        group.notify(queue: .global()) { completion(result) }
    }

    /// 计算 offset = 网络UTC - 设备UTC。把 offset 加到 Date() 上即得到校准后的时间。
    static func fetchOffset(completion: @escaping (TimeInterval?) -> Void) {
        fetchNetworkDate { net in
            guard let net = net else { completion(nil); return }
            completion(net.timeIntervalSince(Date()))
        }
    }

    // MARK: - 格式化

    /// 格式化为北京时间 "yyyy-MM-dd HH:mm:ss"（UTC+8，无夏令时）。
    static func formatBeijing(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// 格式化为 "HH:mm:ss.S"（带 0.1 秒），更适合悬浮窗细长条显示。
    static func formatBeijingPrecise(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        var comp = cal.dateComponents(in: TimeZone(secondsFromGMT: 8 * 3600)!, from: date)
        let h = comp.hour ?? 0
        let m = comp.minute ?? 0
        let s = comp.second ?? 0
        // 取十分秒(0~9)
        let ms = Int((date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d:%02d.%d", h, m, s, ms)
    }

    // MARK: - 私有

    private static func parseRFC1123(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}
