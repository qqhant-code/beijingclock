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
/// 3. `Timer` 每 0.1 秒推一帧 → 秒级跳动；
/// 4. 静音 `AVAudioEngine` 后台循环播放 + `UIBackgroundModes: audio` → App 在后台不被挂起，悬浮窗持续跳秒；
/// 5. 时间来自网络授时(TimeSync)，不受设备系统时间篡改影响。
final class FloatingClockManager: NSObject {

    static let shared = FloatingClockManager()

    /// PiP 状态变化通知（供 UI 显示）
    static let pipStateNotification = Notification.Name("BeijingClockPipStateChanged")

    private var pipController: AVPictureInPictureController?
    private var pipPossibleObserver: NSKeyValueObservation?
    private var pumpTimer: Timer?
    private var previewTimer: Timer?
    /// 内联预览视图，同时也是 PiP 源。由 ContentView 通过 UIViewRepresentable 挂载到界面。
    private(set) lazy var sampleView: SampleBufferDisplayView = {
        let size = ClockFrameRenderer.frameSize
        let v = SampleBufferDisplayView(frame: CGRect(origin: .zero, size: size))
        v.isUserInteractionEnabled = false
        v.onDidMoveToWindow = { [weak self] in
            self?.onInlineViewMovedToWindow()
        }
        return v
    }()
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var resyncTimer: Timer?
    private var retryTimer: Timer?
    private var running = false
    private var pendingPiPStart = false

    /// 网络授时偏差，由外部/定时器刷新
    var offset: TimeInterval = 0

    /// PiP 当前是否在系统级悬浮态（用于 UI 反馈）
    private(set) var pipActive = false
    private(set) var pipError: String?
    private(set) var retryCount = 0
    private(set) var inlineViewReady = false

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

        // 等内联视图真正进入 window 后再启动 PiP
        pendingPiPStart = true
        schedulePiPStartAttempt()

        // 每 5 分钟重新校时一次，修正漂移
        resyncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            TimeSync.fetchOffset { [weak self] off in
                if let off = off { self?.offset = off }
            }
        }
    }

    func stop() {
        pendingPiPStart = false
        retryTimer?.invalidate()
        retryTimer = nil
        pipPossibleObserver?.invalidate()
        pipPossibleObserver = nil
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

    /// ContentView 的内联视图已就位后调用
    func notifyInlineViewReady() {
        inlineViewReady = true
        onInlineViewMovedToWindow()
    }

    private func onInlineViewMovedToWindow() {
        guard pendingPiPStart else { return }
        guard sampleView.window != nil else {
            print("内联视图尚未进入 window，继续等待")
            return
        }
        // 视图已进入 window，给 layer 一帧时间建立连接
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.tryStartPiP()
        }
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
        pendingPiPStart = true
        postState()
        tryStartPiP()
    }

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

        // 监听 isPictureInPicturePossible，一旦变为 true 立即启动
        pipPossibleObserver?.invalidate()
        pipPossibleObserver = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, change in
            guard let self = self, let possible = change.newValue, possible else { return }
            DispatchQueue.main.async {
                self.tryStartPiP()
            }
        }
    }

    private func schedulePiPStartAttempt() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.tryStartPiP()
        }
    }

    private func tryStartPiP() {
        guard let pip = pipController else { return }
        guard running else { return }

        guard sampleView.window != nil else {
            pipError = "内联预览层尚未显示，请稍后再试"
            postState()
            return
        }

        guard !pip.isPictureInPictureActive else {
            pipActive = true
            pipError = nil
            pendingPiPStart = false
            postState()
            return
        }

        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
            pipError = nil
            pendingPiPStart = false
            postState()
            return
        }

        // 如果当前不可能，自动轮询重试（layer 可能还没准备好）
        retryCount += 1
        if retryCount <= 20 {
            pipError = "PiP 尚未就绪，正在等待系统准备 (\(retryCount)/20)"
            postState()
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.tryStartPiP()
            }
        } else {
            pipError = "自动启动失败，请点「重试悬浮窗」；或检查系统设置是否允许画中画"
            pendingPiPStart = false
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
        guard layer.isReadyForMoreMediaData else {
            print("AVSampleBufferDisplayLayer 未准备好接收数据，跳过本帧")
            return
        }
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
        pendingPiPStart = false
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
            self?.pendingPiPStart = true
            self?.tryStartPiP()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipActive = false
        postState()
    }
}
