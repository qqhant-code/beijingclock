import UIKit
import AVKit
import AVFoundation
import CoreVideo
import CoreImage
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
        displayLink?.invalidate()
        displayLink = nil

        pipController?.stopPictureInPicture()
        pipController = nil
        sampleBufferDisplayLayer = nil

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
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        self.sampleBufferDisplayLayer = layer

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pipController = controller

        CrashLogger.shared.log("ClockPIPManager 已创建 PiPController")

        // 立即启动 PiP；若系统需要缓冲一帧，renderFrame 会在 displayLink 触发后立刻喂帧。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            CrashLogger.shared.log("ClockPIPManager 调用 startPictureInPicture")
            controller.startPictureInPicture()
        }
    }

    // MARK: - 持续渲染

    private func startRendering() {
        CrashLogger.shared.log("ClockPIPManager.startRendering 进入")
        renderFrame() // 先喂一帧，让 PiP 窗口能立即出现
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
    }

    // MARK: - 把时钟文字渲染成 CMSampleBuffer

    private func createSampleBuffer(with text: String) -> CMSampleBuffer? {
        let width = Self.videoWidth
        let height = Self.videoHeight

        // 1) 用 UIGraphicsImageRenderer 在 UIImage 里绘制时钟（UIKit 坐标系，无需手动翻转）
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
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

        // 2) 创建 CVPixelBuffer (BGRA，AVSampleBufferDisplayLayer 原生支持)
        let pixelAttrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
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

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                     | CGBitmapInfo.byteOrder32Little.rawValue
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
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 15),
            presentationTimeStamp: CMTimeMakeWithSeconds(CACurrentMediaTime(), preferredTimescale: 1000),
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
}
