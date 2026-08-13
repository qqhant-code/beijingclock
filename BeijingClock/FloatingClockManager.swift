import AVFoundation
import AVKit
import CoreMedia
import UIKit

/// 悬浮时钟核心控制器。
///
/// 原理（与"zk助手"一致的画中画悬浮方案）：
/// 1. 用一个 `AVSampleBufferDisplayLayer` 逐帧播放"北京时间"画面；
/// 2. 以它为源创建 `AVPictureInPictureController`，启动后画面变成系统级悬浮窗，盖在所有 App 之上；
/// 3. `CADisplayLink` 每秒推一帧 → 秒级跳动；
/// 4. 静音 `AVAudioEngine` 后台循环播放 + `UIBackgroundModes: audio` → App 在后台不被挂起，悬浮窗持续跳秒；
/// 5. 时间来自网络授时(TimeSync)，不受设备系统时间篡改影响。
final class FloatingClockManager: NSObject {

    static let shared = FloatingClockManager()

    private var pipController: AVPictureInPictureController?
    private var displayLink: CADisplayLink?
    private var sampleView: SampleBufferDisplayView?
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var resyncTimer: Timer?
    private var running = false

    /// 网络授时偏差，由外部/定时器刷新
    var offset: TimeInterval = 0

    var isRunning: Bool { running }

    // MARK: - 启停

    func start() {
        guard !running else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("当前设备/系统不支持画中画(PiP)")
            return
        }

        startSilentAudio()
        setupSampleView()
        setupPiP()
        running = true

        // 先推一帧再启动 PiP（PiP 需要内联层已有可渲染内容）
        enqueueFrame()
        pipController?.startPictureInPicture()

        // 每 5 分钟重新校时一次，修正漂移
        resyncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            TimeSync.fetchOffset { [weak self] off in
                if let off = off { self?.offset = off }
            }
        }
    }

    func stop() {
        pipController?.stopPictureInPicture()
        stopPump()
        stopSilentAudio()
        resyncTimer?.invalidate()
        resyncTimer = nil
        sampleView?.removeFromSuperview()
        sampleView = nil
        pipController = nil
        running = false
    }

    // MARK: - 内联预览视图（也是 PiP 源）

    private func setupSampleView() {
        let size = ClockFrameRenderer.frameSize
        let v = SampleBufferDisplayView(frame: .zero)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false

        if let window = keyWindow {
            window.addSubview(v)
            NSLayoutConstraint.activate([
                v.widthAnchor.constraint(equalToConstant: size.width),
                v.heightAnchor.constraint(equalToConstant: size.height),
                v.centerXAnchor.constraint(equalTo: window.centerXAnchor),
                v.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 12)
            ])
        }
        sampleView = v
    }

    private var keyWindow: UIWindow? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: { $0.isKeyWindow })
    }

    // MARK: - PiP

    private func setupPiP() {
        guard let layer = sampleView?.sampleBufferLayer else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = pip
    }

    // MARK: - 逐帧推流

    private func startPump() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(mode: .common, preferredFramesPerSecond: 1) { [weak self] _ in
            self?.enqueueFrame()
        }
        displayLink = link
    }

    private func stopPump() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func enqueueFrame() {
        guard let layer = sampleView?.sampleBufferLayer else { return }
        let now = Date().addingTimeInterval(offset)
        if let sbuf = ClockFrameRenderer.makeSampleBuffer(text: TimeSync.formatBeijing(now)) {
            layer.enqueue(sbuf)
        }
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
    func pictureInPictureController(_ pip: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing { startPump() } else { stopPump() }
    }

    func pictureInPictureController(_ pip: AVPictureInPictureController, setRate rate: Float) {}

    func pictureInPictureControllerTimeRange(forPlayback pip: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: CMTime.zero, duration: CMTime.positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pip: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pip: AVPictureInPictureController,
                                    didRequestSampleBufferForPlaybackTime playbackTime: CMTime) {
        enqueueFrame()
    }
}
