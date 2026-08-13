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
    }
    private var pumpTimer: Timer?
    private var resyncTimer: Timer?
    private var running = false

    /// 网络授时偏差
    var offset: TimeInterval = 0

    private(set) var floating = false
    private(set) var lastError: String?

    var isRunning: Bool { running }

    // MARK: - 启停

    func start() {
        guard !running else { return }
        guard FloatingClockWindow.shared == nil else {
            FloatingClockWindow.shared?.showFloating()
            running = true
            floating = true
            lastError = nil
            postState()
            return
        }

        startSilentAudio()

        // 取当前活跃的 UIWindowScene 来创建悬浮窗
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            lastError = "未能获取窗口场景，0.5 秒后重试"
            postState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.start()
            }
            return
        }

        let win = FloatingClockWindow(scene: scene)
        win.showFloating()
        FloatingClockWindow.shared = win
        floating = true
        running = true
        lastError = nil
        postState()

        updateTime()
        startPump()

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
        stopSilentAudio()
        FloatingClockWindow.shared?.hideFloating()
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
        do {
            let sess = AVAudioSession.sharedInstance()
            try sess.setCategory(.playback, mode: .default,
                                 options: [.mixWithOthers, .duckOthers])
            try sess.setActive(true)
        } catch {
            print("audio session: \(error)")
        }

        guard let data = Self.makeSilentWav() else {
            print("生成静音 WAV 失败，放弃音频保活（悬浮窗仍会显示）")
            return
        }
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1   // 无限循环
            player.volume = 0
            player.play()
            silentPlayer = player
        } catch {
            print("audio player: \(error)")
        }
    }

    private func stopSilentAudio() {
        silentPlayer?.stop()
        silentPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 生成一段极短的静音 16-bit PCM WAV（约 0.1 秒），避免打包外部音频文件。
    private static func makeSilentWav() -> Data? {
        let sampleRate: UInt32 = 8000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let numSamples: UInt32 = sampleRate / 10
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
        d.append(Data(count: Int(dataSize)))                     // 全 0 = 静音
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

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 仅用于保活，不处理位置数据
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 忽略定位错误，保持音频保活即可
    }
}
