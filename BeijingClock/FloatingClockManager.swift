import AVFoundation
import CoreLocation
import UIKit

/// 悬浮时钟核心控制器（现改为画中画 PiP 方案）。
///
/// 关键认知修正：
/// 普通 App 用 `UIWindow(windowScene:)` 创建的窗口只属于本 App 的 Scene，切到别的 App 后会被系统隐藏，
/// 因此无法实现"跨 App 悬浮"。iOS 上能合法跨 App 悬浮的官方机制只有系统画中画（PiP）。
/// 本控制器现在把 BeijingClock 的时钟内容作为视频流喂给 PiP，得到系统级悬浮窗。
///
/// 同时保留后台音频 + 可选定位双保活，确保 PiP 持续刷新北京时间。
final class FloatingClockManager: NSObject, CLLocationManagerDelegate {

    static let shared = FloatingClockManager()

    /// 状态变化通知（供 UI 显示）
    static let pipStateNotification = Notification.Name("BeijingClockStateChanged")

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
    }

    private var resyncTimer: Timer?
    private var heartbeatTimer: Timer?

    /// 网络授时偏差
    var offset: TimeInterval = 0

    private(set) var floating = false
    private(set) var lastError: String?

    var isRunning: Bool { ClockPIPManager.shared.isRunning }

    // MARK: - 启停

    func start() {
        CrashLogger.shared.log("FloatingClockManager.start 进入")
        guard !isRunning else {
            CrashLogger.shared.log("FloatingClockManager.start 已在运行，忽略")
            return
        }

        floating = true
        lastError = nil
        postState()

        // 启动画中画悬浮窗
        ClockPIPManager.shared.start(offset: offset)

        // 启动定时器：每 5 分钟重新校时
        resyncTimer?.invalidate()
        resyncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            TimeSync.fetchOffset { [weak self] off in
                if let off = off {
                    self?.offset = off
                    ClockPIPManager.shared.setOffset(off)
                }
            }
        }

        // 心跳日志：每 5 秒记录一次存活状态
        startHeartbeat()

        // 若用户已授权定位，自动开启双保活
        startLocationUpdatesIfAuthorized()

        CrashLogger.shared.log("FloatingClockManager.start 完成")
    }

    func stop() {
        CrashLogger.shared.log("FloatingClockManager.stop 进入")
        resyncTimer?.invalidate(); resyncTimer = nil
        stopHeartbeat()
        locationManager.stopUpdatingLocation()
        locationKeepAlive = false
        ClockPIPManager.shared.stop()
        floating = false
        lastError = nil
        postState()
        CrashLogger.shared.log("FloatingClockManager.stop 完成")
    }

    // MARK: - 心跳日志

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let st = UIApplication.shared.applicationState
            CrashLogger.shared.log("heartbeat appState=\(st.rawValue) running=\(self.isRunning) floating=\(self.floating)")
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
    }

    // MARK: - 状态通知

    private func postState() {
        NotificationCenter.default.post(name: Self.pipStateNotification, object: nil)
    }

    /// 由 ClockPIPManager 在 PiP 实际开始/停止/失败时回调，用于同步 UI 状态。
    func pipStateDidChange() {
        floating = ClockPIPManager.shared.isPictureInPictureActive
        postState()
    }

    // MARK: - 定位保活（可选增强）

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

    // MARK: - 前后台

    @objc private func appDidEnterBackground() {
        let st = UIApplication.shared.applicationState
        CrashLogger.shared.log("进入后台: appState=\(st.rawValue) running=\(isRunning)")
    }

    @objc private func appWillEnterForeground() {
        let st = UIApplication.shared.applicationState
        CrashLogger.shared.log("回到前台: appState=\(st.rawValue) running=\(isRunning)")
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 仅用于保活，不处理位置数据
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 忽略定位错误，保持音频保活即可
    }
}
