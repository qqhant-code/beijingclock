import UIKit
import AVKit
import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// 画中画悬浮时钟管理器（严格对齐 zk 助手实测机制）。
///
/// 关键结论（反编译 zk IPA 确认）：
/// 1) zk 跨 App 悬浮用的是 AVPlayer + AVPlayerViewController + 系统 PiP。
///    二进制里实锤有 AVPlayerViewController 类、setAllowsPictureInPicturePlayback:、
///    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:（AVPlayerViewControllerDelegate 专属方法）。
/// 2) **iPhone 上裸 AVPictureInPictureController(playerLayer:) 的 isPictureInPicturePossible 永远 false**，
///    只有经由 AVPlayerViewController 托管的 PiP 才被系统允许。这是我们前两次失败的统一根因。
/// 3) GitHub Actions 构建机 SDK 较旧，没有 AVPlayerViewController.pictureInPictureController 成员，
///    故用 KVC（value(forKey:)）在运行时取出，设备上 iOS 15+ 该属性真实存在。
///
/// 实现：
/// - 把“当前这一分钟”的北京时间用 AVAssetWriter 渲染成 640x160 循环视频；
/// - AVPlayer 播放，交给 AVPlayerViewController 托管，呈现后取 pictureInPictureController 启动 PiP；
/// - 每分钟交界重生成视频，保证时钟永远对齐北京时间。
///
/// 注意：视频生成须在后台队列执行，绝不能用“主线程 DispatchQueue.main.async{绘制} + sem.wait()”
/// 这种主线程等主线程的写法，否则死锁冻屏。
final class ClockPIPManager: NSObject {

    static let shared = ClockPIPManager()

    /// 视频帧尺寸：细长条，类似 zk 助手顶部条。宽:高 = 4:1。
    static let videoWidth: Int = 640
    static let videoHeight: Int = 160

    /// 视频生成专用串行队列（必须在后台，否则主线程被 sem 阻塞会死锁）。
    private let genQueue = DispatchQueue(label: "com.beijingclock.videogen")

    private var pipController: AVPictureInPictureController?
    private var player: AVPlayer?
    private var playerVC: AVPlayerViewController?
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

        pipController?.stopPictureInPicture()
        pipController = nil
        // 关闭呈现中的 AVPlayerViewController，避免遮挡 App
        playerVC?.dismiss(animated: false)
        playerVC = nil

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil

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

    // MARK: - 生成“当前分钟”的时钟视频并启动

    private func buildVideoAndStart() {
        let (minuteStart, key, currentSecond) = Self.currentBeijingMinuteInfo(offset: offset)
        currentMinuteKey = key
        CrashLogger.shared.log("ClockPIPManager 生成视频 for minute key=\(key) startAtSecond=\(currentSecond)")
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
                    self.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
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

    /// 核心：用 AVPlayerViewController 托管 AVPlayer，呈现后取 pictureInPictureController 启动 PiP。
    /// iPhone 上只有这条路径 isPictureInPicturePossible 才会变 true。
    private func setupPlayer(url: URL, startAtSecond: Int) {
        CrashLogger.shared.log("ClockPIPManager.setupPlayer 进入 startAtSecond=\(startAtSecond)")
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        player.isMuted = true
        self.player = player

        let pvc = AVPlayerViewController()
        pvc.player = player
        pvc.showsPlaybackControls = false
        pvc.allowsPictureInPicturePlayback = true
        pvc.modalPresentationStyle = .fullScreen
        self.playerVC = pvc

        guard let root = Self.topViewController() else {
            CrashLogger.shared.log("ClockPIPManager 找不到可呈现的 VC，无法启动 PiP")
            return
        }
        CrashLogger.shared.log("ClockPIPManager 呈现 AVPlayerViewController（iPhone PiP 必经路径）")
        root.present(pvc, animated: false) { [weak self] in
            guard let self = self else { return }
            // 呈现完成后，系统才会创建 pictureInPictureController
            guard let pip = pvc.value(forKey: "pictureInPictureController") as? AVPictureInPictureController else {
                CrashLogger.shared.log("ClockPIPManager 取不到 pictureInPictureController（KVC 失败）")
                return
            }
            pip.delegate = self
            self.pipController = pip
            CrashLogger.shared.log("ClockPIPManager 已拿到 PiPController (via AVPlayerViewController)")
            let t = CMTime(value: Int64(startAtSecond), timescale: 1)
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            self.startPictureInPictureWhenPossible()
        }
    }

    /// 轮询 isPictureInPicturePossible：AVPlayerViewController 呈现 + 播放后很快就会变 true，
    /// 一旦 true 立即 startPictureInPicture。
    private func startPictureInPictureWhenPossible() {
        pollingTimer?.invalidate()
        var elapsed: TimeInterval = 0
        let interval: TimeInterval = 0.3
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            elapsed += interval
            guard let controller = self.pipController else {
                timer.invalidate(); self.pollingTimer = nil
                CrashLogger.shared.log("PiP controller 为空，停止轮询")
                return
            }
            let possible = controller.isPictureInPicturePossible
            CrashLogger.shared.log("PiP 轮询 isPictureInPicturePossible=\(possible) elapsed=\(String(format: "%.1f", elapsed))s")
            if possible {
                timer.invalidate(); self.pollingTimer = nil
                CrashLogger.shared.log("PiP possible=true，调用 startPictureInPicture")
                controller.startPictureInPicture()
            } else if elapsed >= 15 {
                timer.invalidate(); self.pollingTimer = nil
                CrashLogger.shared.log("PiP 15s 内仍不可启动，关闭呈现防止遮挡 App（可能该设备/iOS 限制 PiP）")
                self.playerVC?.dismiss(animated: false)
                self.playerVC = nil
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

    /// 找到当前最上层的 VC（用于呈现 AVPlayerViewController）
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return nil }
        var vc = scene.windows.first?.rootViewController
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }

    static func cachesVideoURL() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("clock_loop.mp4")
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension ClockPIPManager: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerWillStart(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        CrashLogger.shared.log("PiP willStart")
    }

    func pictureInPictureControllerDidStart(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActive = true
        CrashLogger.shared.log("PiP 已开始显示")
        // PiP 已接管播放，关闭呈现中的 AVPlayerViewController 以免遮挡 App
        playerVC?.dismiss(animated: false)
        playerVC = nil
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
        playerVC?.dismiss(animated: false)
        playerVC = nil
        FloatingClockManager.shared.pipStateDidChange()
    }
}
