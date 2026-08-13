import AVFoundation
import AVKit
import CoreMedia
import QuartzCore
import UIKit

/// 悬浮时钟核心控制器。
///
/// 原理（与"zk助手"一致的画中画悬浮方案）：
/// 1. 用一个 `AVSampleBufferDisplayLayer` 逐帧播放"北京时间"画面；
/// 2. 以它为源创建 `AVPictureInPictureController`，启动后画面变成系统级悬浮窗，盖在所有 App 之上；
/// 3. `Timer` 每秒推一帧 → 秒级跳动；
/// 4. 静音 `AVAudioEngine` 后台循环播放 + `UIBackgroundModes: audio` → App 在后台不被挂起，悬浮窗持续跳秒；
/// 5. 时间来自网络授时(TimeSync)，不受设备系统时间篡改影响。
final class FloatingClockManager: NSObject {

    static let shared = FloatingClockManager()

    /// PiP 状态变化通知（供 UI 显示）
    static let pipStateNotification = Notification.Name("BeijingClockPipStateChanged")

    private var pipController: AVPictureInPictureController?
    private var pumpTimer: Timer?
    private var previewTimer: Timer?
    /// 内联预览视图，同时也是 PiP 源。由 ContentView 通过 UIViewRepresentable 挂载到界面。
    private(set) lazy var sampleView: SampleBufferDisplayView = {
        let size = ClockFrameRenderer.frameSize
        let v = SampleBufferDisplayView(frame: CGRect(origin: .zero, size: size))
        v.isUserInteractionEnabled = false
        return v
    }()
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var resyncTimer: Timer?
    private var retryTimer: Timer?
    private var running = false

    /// 网络授时偏差，由外部/定时器刷新
    var offset: TimeInterval = 0

    /// PiP 当前是否在系统级悬浮态（用于 UI 反馈）
    private(set) var pipActive = false
    private(set) var pipError: String?
    private(set) var retryCount = 0

    var isRunning: Bool { running }

    // MARK: - 启停

    func start() {
        guard !running else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            pipError = "当前设备/系统不支持画中画(PiP)"
            postState()
            print("当前设备/系统不支持画中画(PiP)")
            return
        }

        startSilentAudio()
        setupPiP()
        running = true
        retryCount = 0
        pipError = nil
        postState()

        // 先推一帧（PiP 需要内联层已有可渲染内容）
        stopPreview()
        enqueueFrame()
        startPump()

        // 给 inline 预览层一点时间渲染，再启动 PiP
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.tryStartPiP()
        }

        // 每 5 分钟重新校时一次，修正漂移
        resyncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            TimeSync.fetchOffset { [weak self] off in
                if let off = off { self?.offset = off }
            }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        pipController?.stopPictureInPicture()
        stopPump()
        stopSilentAudio()
        resyncTimer?.invalidate()
        resyncTimer = nil
        // sampleView 由 ContentView 的 UIViewRepresentable 托管，不在这里移除/nil
        pipController = nil
        running = false
        pipActive = false
        retryCount = 0
        postState()
    }

    /// 手动重试启动 PiP（供 UI 按钮调用）
    func retryStartPiP() {
        guard running else {
            pipError = "请先点击「开启悬浮时钟」"
            postState()
            return
        }
        retryCount = 0
        pipError = nil
        postState()
        tryStartPiP()
    }

    // MARK: - 内联预览视图（也是 PiP 源）
    // sampleView 由 ContentView 通过 UIViewRepresentable 托管并显示在界面内，
    // 这是 PiP 能成功启动的关键：layer 必须在可见的 view hierarchy 里。

    // MARK: - PiP

    private func setupPiP() {
        let layer = sampleView.sampleBufferLayer
        layer.videoGravity = .resizeAspect
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.delegate = self
        pipController = pip
    }

    private func tryStartPiP() {
        guard let pip = pipController else { return }
        guard !pip.isPictureInPictureActive else {
            pipActive = true
            pipError = nil
            postState()
            return
        }

        // 很多情况下 isPictureInPicturePossible 为 false 只是 layer 还没 ready，
        // 直接调用 startPictureInPicture() 经常仍然能起来。
        pip.startPictureInPicture()

        if pip.isPictureInPicturePossible {
            pipError = nil
            postState()
            return
        }

        // 否则轮询重试
        retryCount += 1
        if retryCount <= 12 {
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.tryStartPiP()
            }
        } else {
            pipError = "自动启动失败，请点「重试悬浮窗」"
            postState()
        }
    }

    // MARK: - 逐帧推流

    private func startPump() {
        guard pumpTimer == nil else { return }
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.enqueueFrame()
        }
    }

    private func stopPump() {
        pumpTimer?.invalidate()
        pumpTimer = nil
    }

    /// App 内联预览的慢速推帧（1 秒 1 帧），不占用太多 CPU。
    func startPreview() {
        guard previewTimer == nil else { return }
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.enqueueFrame()
        }
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    func enqueueFrame() {
        let layer = sampleView.sampleBufferLayer
        let now = Date().addingTimeInterval(offset)
        if let sbuf = ClockFrameRenderer.makeSampleBuffer(text: TimeSync.formatBeijingPrecise(now)) {
            layer.enqueue(sbuf)
        }
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
}

// MARK: - PiP 播放回调（AVPictureInPictureController.ContentSource 必须提供）

extension FloatingClockManager: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {
        if playing { startPump() } else { stopPump() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setRate rate: Float) {}

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didRequestSampleBufferForPlaybackTime playbackTime: CMTime) {
        enqueueFrame()
    }
}

// MARK: - PiP 生命周期回调（诊断悬浮是否成功）

extension FloatingClockManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipActive = true
        pipError = nil
        retryTimer?.invalidate()
        retryTimer = nil
        postState()
    }

    func pictureInPictureControllerFailedToStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController, withError error: Error) {
        pipActive = false
        pipError = error.localizedDescription
        postState()
        print("PiP 启动失败: \(error)")
        // 失败后自动再试一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.retryCount = 0
            self?.tryStartPiP()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipActive = false
        postState()
    }
}
