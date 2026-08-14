import UIKit
import AVKit
import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// 画中画悬浮时钟管理器（对齐 zk 助手实测机制：AVPlayerViewController + AVPlayer + AVPictureInPictureController）。
///
/// iOS 上普通 App 自建 UIWindow 只能盖在自己 App 的 Scene 里，切到别的 App 后会被系统隐藏。
/// 唯一能合法跨 App 悬浮的机制是系统画中画（PiP）。本类采用 zk 助手同款做法：
/// 1) 把“当前这一分钟”的北京时间用 AVAssetWriter 渲染成一段循环视频（640x160 细长条）；
/// 2) 用 AVPlayerViewController 托管播放（allowsPictureInPicturePlayback=true），由它管理 PiP；
/// 3) 每分钟交界重生成视频，保证时钟永远对齐北京时间。
///
/// 重要：视频生成必须在后台队列执行，绝不能在主线程用
/// `DispatchQueue.main.async { 绘制 } + sem.wait()` 这种“主线程等主线程”的写法，否则会死锁冻屏。
final class ClockPIPManager: NSObject {

    static let shared = ClockPIPManager()

    /// 视频帧尺寸：细长条，类似 zk 助手顶部条。宽:高 = 4:1，PiP 窗口呈现为横向细条。
    static let videoWidth: Int = 640
    static let videoHeight: Int = 160

    /// 视频生成专用串行队列（必须在后台，否则主线程被 sem 阻塞会死锁）。
    private let genQueue = DispatchQueue(label: "com.beijingclock.videogen")

    private var playerVC: AVPlayerViewController?
    private var player: AVPlayer?
    private var hostView: UIView?
    private var pollingTimer: Timer?
    private var regenTimer: Timer?

    private var offset: TimeInterval = 0
    private var running = false
    /// 当前已生成视频对应的“分钟”标识（yyyyMMddHHmm），用于检测是否需要重生成。
    private var currentMinuteKey: String = ""

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
        // 手动循环：item 播完后跳回 0
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidPlayToEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
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
        setupHostAndPlayerVC()
        buildVideoAndStart()
        startRegenTimer()

        CrashLogger.shared.log("ClockPIPManager.start 完成")
    }

    func stop() {
        CrashLogger.shared.log("ClockPIPManager.stop 进入")
        running = false
        isRunning = false
        pollingTimer?.invalidate(); pollingTimer = nil
        regenTimer?.invalidate(); regenTimer = nil

        playerVC?.pictureInPictureController?.stopPictureInPicture()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerVC?.player = nil
        playerVC?.view.removeFromSuperview()
        playerVC = nil
        hostView?.removeFromSuperview()
        hostView = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        CrashLogger.shared.log("ClockPIPManager.stop 完成")
    }

    func setOffset(_ offset: TimeInterval) {
        self.offset = offset
        // 授时偏移变化后，立即按新偏移重建视频，让时钟马上对齐
        rebuildIfNeeded(force: true)
    }

    // MARK: - 音频会话（后台保活，让 PiP 视频继续驱动）

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
        if type == .ended {
            guard let optionRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
            if options.contains(.shouldResume) {
                setupAudioSession()
            }
        }
    }

    // MARK: - 宿主视图 + AVPlayerViewController（必须挂在可见的 view hierarchy 里）

    private func setupHostAndPlayerVC() {
        CrashLogger.shared.log("ClockPIPManager.setupHostAndPlayerVC 进入")
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let keyWindow = scene.windows.first else {
            CrashLogger.shared.log("ClockPIPManager 找不到 keyWindow，无法启动 PiP")
            return
        }
        // host 必须可见（alpha=1、不 hidden），否则 AVPlayer PiP 不认为有可播内容。
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        host.isHidden = false
        host.alpha = 1.0
        host.clipsToBounds = true
        keyWindow.addSubview(host)
        self.hostView = host

        // zk 助手同款：用 AVPlayerViewController 托管 PiP（它内部创建并管理 AVPictureInPictureController）
        let pvc = AVPlayerViewController()
        pvc.showsPlaybackControls = false
        pvc.allowsPictureInPicturePlayback = true
        pvc.delegate = self
        pvc.view.frame = host.bounds

        // 关键：AVPlayerViewController 必须处于视图控制器层级中，pictureInPictureController 才会非 nil。
        // 把它作为 keyWindow 的 rootViewController 的子控制器挂入，最稳妥。
        if let rootVC = keyWindow.rootViewController {
            rootVC.addChild(pvc)
            host.addSubview(pvc.view)
            pvc.didMove(toParent: rootVC)
        } else {
            host.addSubview(pvc.view)
        }
        self.playerVC = pvc
        CrashLogger.shared.log("ClockPIPManager 已创建 AVPlayerViewController (host alpha=1 clear)")
    }

    // MARK: - 生成“当前分钟”的时钟视频并启动

    private func buildVideoAndStart() {
        let (minuteStart, key, currentSecond) = Self.currentBeijingMinuteInfo(offset: offset)
        currentMinuteKey = key
        CrashLogger.shared.log("ClockPIPManager 生成视频 for minute key=\(key) startAtSecond=\(currentSecond)")
        // 关键：生成在后台队列执行，避免主线程死锁
        genQueue.async { [weak self] in
            guard let self = self else { return }
            self.generateClockVideo(minuteStart: minuteStart) { [weak self] url in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    guard self.running else { return }
                    guard let url = url else {
                        CrashLogger.shared.log("ClockPIPManager 生成视频失败，无法启动 PiP")
                        return
                    }
                    self.setupPlayer(url: url, startAtSecond: currentSecond)
                }
            }
        }
    }

    /// 每分钟交界重生成；force=true 用于授时偏移变化后立即重建。
    private func rebuildIfNeeded(force: Bool) {
        let (minuteStart, key, _) = Self.currentBeijingMinuteInfo(offset: offset)
        if !force, key == currentMinuteKey { return }
        CrashLogger.shared.log("ClockPIPManager 重生成视频 (key \(currentMinuteKey) -> \(key), force=\(force))")
        currentMinuteKey = key
        genQueue.async { [weak self] in
            guard let self = self else { return }
            self.generateClockVideo(minuteStart: minuteStart) { [weak self] url in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    guard self.running, let url = url else { return }
                    let item = AVPlayerItem(url: url)
                    self.player?.replaceCurrentItem(with: item)
                    self.player?.seek(to: .zero)
                    self.player?.play()
                    CrashLogger.shared.log("ClockPIPManager 已替换 playerItem 为最新分钟")
                }
            }
        }
    }

    private func startRegenTimer() {
        regenTimer?.invalidate()
        regenTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.rebuildIfNeeded(force: false)
        }
    }

    private func setupPlayer(url: URL, startAtSecond: Int) {
        CrashLogger.shared.log("ClockPIPManager.setupPlayer 进入 startAtSecond=\(startAtSecond)")
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        player.isMuted = true
        self.player = player
        self.playerVC?.player = player

        let t = CMTime(value: Int64(startAtSecond), timescale: 1)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()

        startPictureInPictureWhenPossible()
    }

    /// 轮询 isPictureInPicturePossible：AVPlayer PiP 在 item 就绪、layer 在窗口里后很快就会变 true，
    /// 一旦 true 立即 startPictureInPicture。
    private func startPictureInPictureWhenPossible() {
        pollingTimer?.invalidate()
        var elapsed: TimeInterval = 0
        let interval: TimeInterval = 0.3
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            elapsed += interval
            guard let pip = self.playerVC?.pictureInPictureController else {
                timer.invalidate(); self.pollingTimer = nil
                CrashLogger.shared.log("PiP controller 为空，停止轮询（检查 playerVC.view 是否在窗口中）")
                return
            }
            let possible = pip.isPictureInPicturePossible
            CrashLogger.shared.log("PiP 轮询 isPictureInPicturePossible=\(possible) elapsed=\(String(format: "%.1f", elapsed))s")
            if possible {
                timer.invalidate(); self.pollingTimer = nil
                CrashLogger.shared.log("PiP possible=true，调用 startPictureInPicture")
                pip.startPictureInPicture()
            } else if elapsed >= 15 {
                timer.invalidate(); self.pollingTimer = nil
                CrashLogger.shared.log("PiP 15s 内仍不可启动，停止轮询（检查 AVPlayer item 是否就绪）")
            }
        }
    }

    @objc private func itemDidPlayToEnd(_ notification: Notification) {
        // 手动循环
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - 生成时钟视频（在 genQueue 后台执行；UIKit 绘制仍回主线程，但等待的是后台线程，不会死锁）

    private func generateClockVideo(minuteStart: Date, completion: @escaping (URL?) -> Void) {
        let url = Self.cachesVideoURL()
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            CrashLogger.shared.log("ClockPIPManager 创建 AVAssetWriter 失败")
            completion(nil)
            return
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.videoWidth,
            AVVideoHeightKey: Self.videoHeight
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.mediaTimeScale = 1
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            CrashLogger.shared.log("ClockPIPManager AVAssetWriterInput 不可用")
            completion(nil)
            return
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Self.videoWidth,
                kCVPixelBufferHeightKey as String: Self.videoHeight
            ]
        )

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frameTime = CMTime.zero
        let frameDuration = CMTime(value: 1, timescale: 1)
        var success = true

        for second in 0..<60 {
            guard running else { success = false; break }
            let frameDate = minuteStart.addingTimeInterval(TimeInterval(second))
            let text = TimeSync.formatBeijingPrecise(frameDate)
            // UIKit 绘制必须在主线程：把绘制排到主线程，当前（后台）线程等待信号。
            // 注意：等待的是后台线程，主线程能正常执行绘制并 signal，不会死锁。
            var pb: CVPixelBuffer?
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                pb = self.pixelBuffer(with: text)
                sem.signal()
            }
            sem.wait()
            guard let pb = pb else { success = false; break }
            while !input.isReadyForMoreMediaData { usleep(2000) }
            if !adaptor.append(pb, withPresentationTime: frameTime) {
                CrashLogger.shared.log("ClockPIPManager 写入第 \(second) 帧失败")
                success = false
                break
            }
            frameTime = CMTimeAdd(frameTime, frameDuration)
        }

        input.markAsFinished()
        writer.finishWriting {
            if success && writer.status == .completed {
                CrashLogger.shared.log("ClockPIPManager 视频生成完成: \(url.lastPathComponent)")
                completion(url)
            } else {
                CrashLogger.shared.log("ClockPIPManager 视频生成失败 status=\(writer.status.rawValue)")
                completion(nil)
            }
        }
    }

    // MARK: - 把时钟文字画进 CVPixelBuffer（供视频帧使用）

    private func pixelBuffer(with text: String) -> CVPixelBuffer? {
        let width = Self.videoWidth
        let height = Self.videoHeight
        let size = CGSize(width: width, height: height)

        // 1) 用 UIKit 把背景条 + 时间文字画成 UIImage
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let barRect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: barRect, cornerRadius: 22).addClip()
            UIColor(white: 0.05, alpha: 0.92).setFill()
            UIRectFill(barRect)

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

        // 2) 创建 CVPixelBuffer (ARGB)
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

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            CrashLogger.shared.log("ClockPIPManager 创建 CGContext 失败")
            return nil
        }
        // UIImage 的 cgImage 是 y-down，画进 y-up 的 CGBitmapContext 需翻转
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image.cgImage!, in: CGRect(origin: .zero, size: size))
        return pixelBuffer
    }

    // MARK: - 计算“北京时间当前分钟”的起点与秒偏移

    /// 返回（当前分钟起点, 分钟标识, 当前处于该分钟的第几秒）
    static func currentBeijingMinuteInfo(offset: TimeInterval) -> (Date, String, Int) {
        let beijingNow = Date().addingTimeInterval(offset)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: beijingNow)
        var minuteComps = DateComponents()
        minuteComps.year = comps.year
        minuteComps.month = comps.month
        minuteComps.day = comps.day
        minuteComps.hour = comps.hour
        minuteComps.minute = comps.minute
        minuteComps.second = 0
        let minuteStart = cal.date(from: minuteComps) ?? beijingNow
        let key = String(format: "%04d%02d%02d%02d%02d",
                         comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
                         comps.hour ?? 0, comps.minute ?? 0)
        return (minuteStart, key, comps.second ?? 0)
    }

    static func cachesVideoURL() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("clock_loop.mp4")
    }
}

// MARK: - AVPlayerViewControllerDelegate（zk 同款 PiP 回调）

extension ClockPIPManager: AVPlayerViewControllerDelegate {

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        CrashLogger.shared.log("PiP willStart")
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActive = true
        CrashLogger.shared.log("PiP 已开始显示")
        FloatingClockManager.shared.pipStateDidChange()
    }

    func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActive = false
        CrashLogger.shared.log("PiP 已停止")
        FloatingClockManager.shared.pipStateDidChange()
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
