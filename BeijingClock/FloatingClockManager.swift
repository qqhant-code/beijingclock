import AVFoundation
import CoreLocation
import UIKit

/// 悬浮时钟核心控制器（zk助手同款方案）。
///
/// 原理：
/// 1. 自建一个高 windowLevel 的 UIWindow（FloatingClockWindow），盖在所有 App 之上；
/// 2. 后台静音音频保活（`UIBackgroundModes: audio` + 循环静音 AVAudioEngine），
///    App 退到后台不被挂起，悬浮窗持续跳秒；
/// 3. `Timer` 每 0.1 秒刷新一次北京时间（来自网络授时 TimeSync，不受系统时间影响）。
final class FloatingClockManager: NSObject, CLLocationManagerDelegate {

    static let shared = FloatingClockManager()

    /// 状态变化通知（供 UI 显示）
    static let pipStateNotification = Notification.Name("BeijingClockStateChanged")

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
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
            floating = true
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

    private func startSilentAudio() {
        do {
            let sess = AVAudioSession.sharedInstance()
            try sess.setCategory(.playback, mode: .default,
                                 options: [.mixWithOthers, .duckOthers])
            try sess.setActive(true)
        } catch {
            print("audio session: \(error)")
        }

        let mixer = audioEngine.mainMixerNode
        let fmt = mixer.outputFormat(forBus: 0)
        guard fmt.commonFormat == .pcmFormatFloat32 || fmt.commonFormat == .pcmFormatInt16 else {
            print("audio mixer format 不是 PCM，放弃静音保活")
            return
        }
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: mixer, format: fmt)
        // 全 0 缓冲区 = 静音，循环播放以保活后台
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                        frameCapacity: AVAudioFrameCount(fmt.sampleRate)) else { return }
        playerNode.scheduleBuffer(buf, at: nil, options: .loops)
        do {
            try audioEngine.start()
            playerNode.play()
        } catch {
            print("audio engine: \(error)")
        }
    }

    private func stopSilentAudio() {
        playerNode.stop()
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
