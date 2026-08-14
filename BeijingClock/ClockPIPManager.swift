import UIKit
import AVKit
import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// 画中画悬浮时钟管理器。
///
/// iOS 上普通 App 自建 UIWindow 只能盖在自己 App 的 Scene 里，切到别的 App 后会被系统隐藏。
/// 唯一能合法跨 App 悬浮的机制是系统画中画（PiP）。
/// 本类把时钟渲染成视频帧，持续喂给 AVSampleBufferDisplayLayer，再交给 AVPictureInPictureController，
/// 从而得到一个系统级悬浮窗，切 App、锁屏后仍可显示。
final class ClockPIPManager: NSObject {

    static let shared = ClockPIPManager()

    private var pipController: AVPictureInPictureController?
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    private var displayLink: CADisplayLink?
    private var offset: TimeInterval = 0
    private var running = false
    /// sample buffer 的 presentationTimeStamp 基准：第一帧记为 0，之后单调递增。
    private var presentationTimeBase: CFTimeInterval = 0

    /// sample buffer 模式的 PiP 要求 layer 必须在一个可见的 view hierarchy 里，
    /// 否则 startPictureInPicture() 不会调用任何 delegate。这里用一个 1x1 的隐藏宿主 view。
    private var hostView: UIView?

    /// 视频帧尺寸：细长条，类似 zk 助手顶部条。
    /// 宽度 > 高度，PiP 窗口会呈现为横向条。
    static let videoWidth: Int = 640
    static let videoHeight: Int = 160

    /// 用户是否要求运行（不等于 PiP 实际已显示，后者看 isPictureInPictureActive）
    private(set) var isRunning = false
    /// PiP 窗口是否真正在屏幕上（系统回调更新）
    private(set) var isPictureInPictureActive = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    // MARK: - 启停

    func start(offset: TimeInterval) {
        CrashLogger.shared.log("ClockPIPManager.start 进入 offset=\(offset)")
        guard !isRunning else {
            CrashLogger.shared.log("ClockPIPManager.start 已在运行，忽略")
            return
        }
        self.offset = offset
        running = true
        isRunning = true

        setupAudioSession()
        setupDisplayLayerAndPIP()
        startRendering()

        CrashLogger.shared.log("ClockPIPManager.start 完成")
    }

    func stop() {
        CrashLogger.shared.log("ClockPIPManager.stop 进入")
        running = false
        isRunning = false
        presentationTimeBase = 0
        displayLink?.invalidate()
        displayLink = nil

        pipController?.stopPictureInPicture()
        pipController = nil
        sampleBufferDisplayLayer?.removeFromSuperlayer()
        sampleBufferDisplayLayer = nil
        hostView?.removeFromSuperview()
        hostView = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        CrashLogger.shared.log("ClockPIPManager.stop 完成")
    }

    func setOffset(_ offset: TimeInterval) {
        self.offset = offset
    }

    // MARK: - 音频会话（后台保活）

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            CrashLogger.shared.log("ClockPIPManager.setupAudioSession 成功")
        } catch {
            CrashLogger.shared.log("ClockPIPManager.setupAudioSession 失败: \(error)")
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        if type == .began {
            CrashLogger.shared.log("ClockPIPManager 音频中断开始")
        } else if type == .ended {
            guard let optionRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
            CrashLogger.shared.log("ClockPIPManager 音频中断结束 options=\(options.rawValue)")
            if options.contains(.shouldResume) {
                setupAudioSession()
            }
        }
    }

    // MARK: - PiP 初始化

    private func setupDisplayLayerAndPIP() {
        CrashLogger.shared.log("ClockPIPManager.setupDisplayLayerAndPIP 进入")

        // 0) 先确认系统是否支持 PiP
        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        CrashLogger.shared.log("PiP isPictureInPictureSupported=\(supported)")
        guard supported else {
            CrashLogger.shared.log("设备/系统不支持 PiP，无法启动悬浮窗")
            return
        }

        // 1) 准备一个**可见**的 host view（极小、几乎透明），把 sample buffer layer 挂上去。
        //    sample buffer 模式的 PiP 要求 layer 实际在屏幕上渲染内容，hidden 状态不会触发任何回调。
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let keyWindow = scene.windows.first else {
            CrashLogger.shared.log("ClockPIPManager 找不到 keyWindow，无法启动 PiP")
            return
        }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        host.isHidden = false          // 必须可见，否则 PiP 认为没有内容在播放
        host.alpha = 0.001             // 几乎全透明，用户看不到
        keyWindow.addSubview(host)
        self.hostView = host

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = host.bounds
        host.layer.addSublayer(layer)
        self.sampleBufferDisplayLayer = layer

        CrashLogger.shared.log("ClockPIPManager 已把 sampleBufferDisplayLayer 加入 view hierarchy (host visible)")

        // 2) 创建 PiP controller
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        // 我们是手动 start，不需要 inline 自动进入
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.pipController = controller

        CrashLogger.shared.log("ClockPIPManager 已创建 PiPController")

        // 3) 先喂一帧，再启动 PiP，给系统一个可渲染的内容
        renderFrame()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let possible = controller.isPictureInPicturePossible
            CrashLogger.shared.log("PiP isPictureInPicturePossible=\(possible)，调用 startPictureInPicture")
            if possible {
                controller.startPictureInPicture()
            } else {
                CrashLogger.shared.log("PiP 仍不可启动，可能 delegate 未实现必需的 shouldProcedeToPlayAfterApplyingBufferingHint")
            }
        }
    }

    // MARK: - 持续渲染

    private func startRendering() {
        CrashLogger.shared.log("ClockPIPManager.startRendering 进入")
        displayLink = CADisplayLink(target: self, selector: #selector(renderFrame))
        displayLink?.preferredFramesPerSecond = 15 // 15fps 足够让秒级时钟流畅跳动
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func renderFrame() {
        let now = Date().addingTimeInterval(offset)
        let text = TimeSync.formatBeijingPrecise(now)
        guard let sampleBuffer = createSampleBuffer(with: text) else {
            CrashLogger.shared.log("ClockPIPManager.renderFrame 生成 sampleBuffer 失败")
            return
        }
        sampleBufferDisplayLayer?.enqueue(sampleBuffer)
        sampleBufferDisplayLayer?.setNeedsDisplay()
    }

    // MARK: - 把时钟文字渲染成 CMSampleBuffer

    private func createSampleBuffer(with text: String) -> CMSampleBuffer? {
        let width = Self.videoWidth
        let height = Self.videoHeight

        // 1) 用 UIGraphicsImageRenderer 在 UIImage 里绘制时钟（UIKit 坐标系，无需手动翻转）
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            // 背景：深灰半透明圆角条
            let barRect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: barRect, cornerRadius: 22)
            UIColor(white: 0.05, alpha: 0.9).setFill()
            path.fill()

            // 时间文字：白色等宽，居中
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 72, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let attributed = NSAttributedString(string: text, attributes: attrs)
            let textSize = attributed.boundingRect(with: size, options: .usesLineFragmentOrigin, context: nil).size
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            attributed.draw(in: textRect)
        }

        // 2) 创建 CVPixelBuffer (ARGB，与 CGContext 默认 bitmap 匹配)
        let pixelAttrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            pixelAttrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBuffer else {
            CrashLogger.shared.log("ClockPIPManager 创建 pixelBuffer 失败 status=\(status)")
            return nil
        }

        // 3) 把 UIImage 绘制到 PixelBuffer
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            CrashLogger.shared.log("ClockPIPManager 创建 CGContext 失败")
            return nil
        }
        context.draw(image.cgImage!, in: CGRect(origin: .zero, size: size))

        // 4) 包装成 CMSampleBuffer
        var formatDescription: CMFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let formatDescription = formatDescription else {
            CrashLogger.shared.log("ClockPIPManager 创建 formatDescription 失败 status=\(fmtStatus)")
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        // presentationTimeStamp 从 0 开始单调递增，配合 timeRange [0, +inf) 让 PiP 播放控制稳定。
        if presentationTimeBase == 0 { presentationTimeBase = CACurrentMediaTime() }
        let ptsSeconds = CACurrentMediaTime() - presentationTimeBase
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 15),
            presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 600),
            decodeTimeStamp: CMTime.invalid
        )
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer = sampleBuffer else {
            CrashLogger.shared.log("ClockPIPManager 创建 sampleBuffer 失败 status=\(sbStatus)")
            return nil
        }
        return sampleBuffer
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension ClockPIPManager: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStart(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActive = true
        CrashLogger.shared.log("PiP 已开始显示")
        FloatingClockManager.shared.pipStateDidChange()
    }

    func pictureInPictureControllerDidStop(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActive = false
        CrashLogger.shared.log("PiP 已停止")
        FloatingClockManager.shared.pipStateDidChange()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActive = false
        CrashLogger.shared.log("PiP 启动失败: \(error)")
        FloatingClockManager.shared.pipStateDidChange()
    }

    func pictureInPictureControllerWillStart(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        CrashLogger.shared.log("PiP willStart")
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension ClockPIPManager: AVPictureInPictureSampleBufferPlaybackDelegate {

    // 必需：告诉 PiP 当前可播放的时间范围。时钟是实时流，返回无限范围。
    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        return CMTimeRange(start: .zero, end: .positiveInfinity)
    }

    // 必需：告诉 PiP 当前是否处于暂停状态。时钟永远播放。
    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        return false
    }

    // 必需：用户点击 PiP 的播放/暂停按钮时调用。时钟始终播放，忽略暂停请求。
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        CrashLogger.shared.log("PiP setPlaying=\(playing)，忽略并保持播放")
    }

    // 可选：PiP 窗口尺寸变化
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        CrashLogger.shared.log("PiP 尺寸变化: \(newRenderSize.width)x\(newRenderSize.height)")
    }

    // 可选：用户拖动 PiP 进度条时调用。时钟没有进度，直接 completion。
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) {
        completion()
    }

    // 必需（很多人漏掉）：PiP 在缓冲后询问是否继续播放。必须返回 true，
    // 否则系统判定"不可进入 PiP"，isPictureInPicturePossible 一直为 false，start 无回调。
    func pictureInPictureControllerShouldProcedeToPlayAfterApplyingBufferingHint(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        return true
    }
}
