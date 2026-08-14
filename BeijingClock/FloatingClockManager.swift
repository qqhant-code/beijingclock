import AVFoundation
import CoreLocation
import UIKit

/// 悬浮时钟核心控制器（zk助手同款方案）。
///
/// 原理：
/// 1. 自建一个高 windowLevel 的 UIWindow（FloatingClockWindow），盖在所有 App 之上；
/// 2. 后台静音音频保活（`UIBackgroundModes: audio` + 循环静音 AVAudioPlayer），
///    App 退到后台不被挂起，悬浮窗持续跳秒；
/// 3. `Timer` 每 0.1 秒刷新一次北京时间（来自网络授时 TimeSync，不受系统时间影响）。
final class FloatingClockManager: NSObject, CLLocationManagerDelegate {

    static let shared = FloatingClockManager()

    /// 状态变化通知（供 UI 显示）
    static let pipStateNotification = Notification.Name("BeijingClockStateChanged")

    private var silentPlayer: AVAudioPlayer?
    private let locationManager = CLLocationManager()
    private var locationKeepAlive = false

    private override init() {
        super.init()
        locationManager.delegate = self
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioSessionInterrupted(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
    }
    private var pumpTimer: Timer?
    private var resyncTimer: Timer?
    private var heartbeatTimer: Timer?
    private var running = false

    /// 网络授时偏差
    var offset: TimeInterval = 0

    private(set) var floating = false
    private(set) var lastError: String?

    var isRunning: Bool { running }

    // MARK: - 启停

    func start() {
        CrashLogger.shared.log("start() 进入")
        guard !running else {
            CrashLogger.shared.log("start() 已 running，直接返回")
            return
        }
        guard FloatingClockWindow.shared == nil else {
            FloatingClockWindow.shared?.showFloating()
            running = true
            floating = true
            lastError = nil
            postState()
            return
        }

        // 1) 先创建并显示悬浮窗（与音频保活解耦，便于定位崩溃来源）
        CrashLogger.shared.log("start() 取 foregroundActive scene")
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            CrashLogger.shared.log("start() 未获取到 foregroundActive scene，0.5s 后重试")
            lastError = "未能获取窗口场景，0.5 秒后重试"
            postState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.start()
            }
            return
        }

        CrashLogger.shared.log("start() 创建 FloatingClockWindow")
        let win = FloatingClockWindow(scene: scene)
        CrashLogger.shared.log("start() FloatingClockWindow 创建成功，showFloating")
        win.showFloating()
        FloatingClockWindow.shared = win
        floating = true
        running = true
        lastError = nil
        postState()

        updateTime()
        startPump()
        startHeartbeat()

        // 2) 立即启动静音音频保活（约束崩溃已定位修复，不再需要延迟）
        CrashLogger.shared.log("start() 立即启动音频保活")
        startSilentAudio()

        // 若用户已授权定位，自动开启双保活（与 zk 助手一致）
        startLocationUpdatesIfAuthorized()

        // 每 5 分钟重新校时一次
        resyncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            TimeSync.fetchOffset { [weak self] off in
                if let off = off { self?.offset = off; self?.updateTime() }
            }
        }
    }

    func stop() {
        pumpTimer?.invalidate(); pumpTimer = nil
        resyncTimer?.invalidate(); resyncTimer = nil
        stopHeartbeat()
        stopSilentAudio()
        locationManager.stopUpdatingLocation()
        locationKeepAlive = false
        FloatingClockWindow.shared?.hideFloating()
        FloatingClockWindow.shared = nil   // 必须清掉，否则下次 start 只 show 不重启定时器/音频
        floating = false
        running = false
        postState()
    }

    // MARK: - 逐帧推流

    private func startPump() {
        guard pumpTimer == nil else { return }
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateTime()
        }
    }

    /// 每 5 秒记录一次存活状态，用于诊断"切到别的 App 后是否仍活着"。
    /// 若切后台后日志不再出现 heartbeat，说明进程已被系统挂起（保活失败）。
    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let st = UIApplication.shared.applicationState
            let playing = self.silentPlayer?.isPlaying ?? false
            let hidden = FloatingClockWindow.shared?.isHidden ?? true
            CrashLogger.shared.log("heartbeat appState=\(st.rawValue) playing=\(playing) windowHidden=\(hidden) running=\(self.running)")
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
    }

    func updateTime() {
        let now = Date().addingTimeInterval(offset)
        FloatingClockWindow.shared?.setTime(TimeSync.formatBeijingPrecise(now))
    }

    // MARK: - 状态通知

    private func postState() {
        NotificationCenter.default.post(name: Self.pipStateNotification, object: nil)
    }

    // MARK: - 静音后台音频保活

    /// 用 AVAudioPlayer 循环播放内存中的静音 WAV。
    /// 比 AVAudioEngine 稳得多，且只要 .playback 后台模式开启即可保活。
    private func startSilentAudio() {
        CrashLogger.shared.log("startSilentAudio 进入")
        do {
            let sess = AVAudioSession.sharedInstance()
            // 只混音，不 duck，避免被系统或其它 App 的行为中断
            try sess.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try sess.setActive(true)
            CrashLogger.shared.log("startSilentAudio AVAudioSession.setActive 成功")
        } catch {
            CrashLogger.shared.log("startSilentAudio AVAudioSession 失败: \(error)")
        }

        guard let data = Self.makeSilentWav() else {
            CrashLogger.shared.log("startSilentAudio 生成静音 WAV 失败")
            return
        }
        CrashLogger.shared.log("startSilentAudio 静音 WAV 已生成，准备 AVAudioPlayer")
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1   // 无限循环
            player.volume = 1           // 数据本身极弱，放大后仍听不到；必须是 1 才能驱动后台保活
            player.play()
            silentPlayer = player
            CrashLogger.shared.log("startSilentAudio AVAudioPlayer 已播放")
        } catch {
            CrashLogger.shared.log("startSilentAudio AVAudioPlayer 失败: \(error)")
        }
    }

    private func stopSilentAudio() {
        silentPlayer?.stop()
        silentPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 生成 5 秒 16-bit PCM WAV（避免打包外部音频文件）。
    ///
    /// 关键修复：数据**不能是全 0**。iOS 不会对"零输出"音频给予后台保活，
    /// 因此这里写入极低幅度（≈0.012%）的 60Hz 正弦波——人耳几乎听不到，
    /// 但系统会判定为"正在播放音频"，从而让 App 在后台持续运行、悬浮窗不消失。
    private static func makeSilentWav() -> Data? {
        let sampleRate: UInt32 = 8000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let duration: UInt32 = 5
        let numSamples: UInt32 = sampleRate * duration
        let blockAlign = numChannels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = numSamples * UInt32(blockAlign)
        let chunkSize = 36 + dataSize

        var d = Data()
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46])          // "RIFF"
        d.append(withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45])          // "WAVE"
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])          // "fmt "
        d.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // PCM
        d.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61])          // "data"
        d.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        var samples = Data(count: Int(dataSize))
        samples.withUnsafeMutableBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            let amp = Double(4)   // 极小幅度，听不到但非静音
            for i in 0..<Int(numSamples) {
                let t = Double(i) / Double(sampleRate)
                ints[i] = Int16(sin(2 * Double.pi * 60 * t) * amp)
            }
        }
        d.append(samples)
        return d
    }

    // MARK: - 定位保活（可选增强，与 zk助手一致：audio + location 双保活）

    /// 请求"使用时"定位授权并启动后台位置更新。仅当用户主动开启，不强制。
    func enableLocationKeepAlive() {
        locationManager.requestWhenInUseAuthorization()
        startLocationUpdates()
    }

    private func startLocationUpdates() {
        let status = locationManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = CLLocationDistanceMax
        locationManager.startUpdatingLocation()
        locationKeepAlive = true
    }

    private func startLocationUpdatesIfAuthorized() {
        let status = locationManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        startLocationUpdates()
    }

    // MARK: - 前后台 & 音频中断恢复

    @objc private func appDidEnterBackground() {
        let st = UIApplication.shared.applicationState
        let playing = silentPlayer?.isPlaying ?? false
        let hidden = FloatingClockWindow.shared?.isHidden ?? true
        CrashLogger.shared.log("进入后台: appState=\(st.rawValue) playing=\(playing) windowHidden=\(hidden) running=\(running)")
        guard running else { return }
        startSilentAudio()
    }

    @objc private func appWillEnterForeground() {
        let st = UIApplication.shared.applicationState
        let playing = silentPlayer?.isPlaying ?? false
        CrashLogger.shared.log("回到前台: appState=\(st.rawValue) playing=\(playing)")
        guard running else { return }
        startSilentAudio()
    }

    @objc private func audioSessionInterrupted(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        if type == .began {
            CrashLogger.shared.log("音频会话被中断")
        } else if type == .ended {
            if let optionRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionRaw).contains(.shouldResume) {
                CrashLogger.shared.log("音频中断结束，尝试恢复")
                guard running else { return }
                startSilentAudio()
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 仅用于保活，不处理位置数据
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 忽略定位错误，保持音频保活即可
    }
}
