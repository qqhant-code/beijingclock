import UIKit
import AVKit
import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// 画中画悬浮时钟管理器（严格对齐 zk 助手实测机制）。
///
/// 关键结论（反编译 zk IPA 确认 + 多轮真机实测）：
/// 1) zk 跨 App 悬浮靠的是 AVPlayer + AVPlayerViewController + 系统 PiP。
/// 2) iPhone 上裸 AVPictureInPictureController(playerLayer:) 的 isPictureInPicturePossible 永远 false，
///    只有经由 AVPlayerViewController 托管的 PiP 才被系统允许。
/// 3) AVPlayerViewController 的 pictureInPictureController 是懒加载的，present（animated）后 view 上屏才创建。
///    必须用 KVC/responds 取出；若 present 用 animated:false，懒加载可能尚未发生，取不到。
/// 4) zk 视频用 AVAssetExportSession 导出为 fast-start 标准 MP4（shouldOptimizeForNetworkUse），
///    这样 isPictureInPicturePossible 才会变 true。裸 AVAssetWriter 默认 moov 在尾部（非 fast-start），
///    PiP 资格检查会判定“不可 PiP”。
/// 5) zk 直接 startPictureInPicture()（在用户点开浮窗的手势栈内）。我们也尽量在手势内 present，
///    并在 item readyToPlay 后直接 startPictureInPicture()；同时保留 canStartPictureInPictureAutomaticallyFromInline
///    + dismiss 作为手势缺失时的兜底（系统自动 PiP 不要求手势）。
/// 6) GitHub Actions 构建机 SDK 较旧，没有 AVPlayerViewController.pictureInPictureController 成员，
///    故用 Objective-C runtime（responds + perform / KVC）在运行时取出。
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
    private var itemObserver: NSKeyValueObservation?
    private var pollingTimer: Timer?
    private var regenTimer: Timer?
    private var watchdogTimer: Timer?

    /// present 是否已完成（viewDidAppear 后）。present 与 readyToPlay 都是异步。
    private var presentDone = false
    /// AVPlayerItem 是否已 readyToPlay。
    private var itemReady = false
    /// 是否已经尝试启动过 PiP（避免重复 start）。
    private var triedStart = false

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
        presentDone = false
        itemReady = false
        triedStart = false

        setupAudioSession()
        // 在按钮手势栈内立即 present playerVC（animated:true 触发 lazy PiP controller 创建）
        setupPlayerVC()
        // 后台生成 fast-start 视频，完成后替换 player item
        buildVideoAndStart()
        startRegenTimer()

        CrashLogger.shared.log("ClockPIPManager.start 完成")
    }

    func stop() {
        CrashLogger.shared.log("ClockPIPManager.stop 进入")
        running = false
        isRunning = false
        isPictureInPictureActive = false
        pollingTimer?.invalidate(); pollingTimer = nil
        regenTimer?.invalidate(); regenTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
        itemObserver?.invalidate(); itemObserver = nil

        pipController?.stopPictureInPicture()
        pipController?.delegate = nil
        pipController = nil

        if let pvc = playerVC {
            if pvc.presentingViewController != nil {
                pvc.dismiss(animated: false, completion: nil)
            }
            pvc.willMove(toParent: nil)
            pvc.view.removeFromSuperview()
            pvc.removeFromParent()
        }
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

    // MARK: - present AVPlayerViewController（手势栈内，animated 触发 lazy controller）

    private func setupPlayerVC() {
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        self.player = player

        let pvc = AVPlayerViewController()
        pvc.player = player
        pvc.showsPlaybackControls = false
        pvc.allowsPictureInPicturePlayback = true
        // 兜底：允许“离开内联时自动进入 PiP”，不要求手势
        pvc.canStartPictureInPictureAutomaticallyFromInline = true
        pvc.delegate = self
        pvc.view.backgroundColor = .clear
        self.playerVC = pvc

        guard let root = Self.topViewController() else {
            CrashLogger.shared.log("ClockPIPManager 找不到可呈现的 VC，无法启动 PiP")
            return
        }
        pvc.modalPresentationStyle = .overFullScreen
        root.present(pvc, animated: true) { [weak self] in
            guard let self = self else { return }
            self.presentDone = true
            CrashLogger.shared.log("ClockPIPManager present 完成（viewDidAppear）")
            self.retrieveControllerWithRetry(attempt: 0)
            self.tryStartPiP()
        }
        CrashLogger.shared.log("ClockPIPManager 已 present AVPlayerViewController（手势栈内）")
    }

    /// 通过 Objective-C runtime 取出内部懒加载的 PiP controller（带重试）。
    private func retrieveControllerWithRetry(attempt: Int) {
        guard let pvc = playerVC else { return }
        if let c = Self.obtainControllerOnce(from: pvc) {
            pipController = c
            CrashLogger.shared.log("ClockPIPManager 已拿到 PiPController (runtime, 尝试 \(attempt))")
            tryStartPiP()
            return
        }
        if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.running else { return }
                self.retrieveControllerWithRetry(attempt: attempt + 1)
            }
        } else {
            CrashLogger.shared.log("ClockPIPManager 10 次重试仍未拿到 PiPController（可能该设备/iOS 不支持）")
        }
    }

    /// 单次尝试取出 pictureInPictureController（perform/KVC，统一在 responds 守卫内，避免 KVC 抛异常）。
    private static func obtainControllerOnce(from pvc: AVPlayerViewController) -> AVPictureInPictureController? {
        let sel = NSSelectorFromString("pictureInPictureController")
        guard pvc.responds(to: sel) else { return nil }
        // perform 取出
        if let res = pvc.perform(sel) {
            if let c = res.takeUnretainedValue() as? AVPictureInPictureController {
                return c
            }
        }
        // KVC 兜底（同样在 responds 守卫内，不会抛异常）
        if let c = pvc.value(forKey: "pictureInPictureController") as? AVPictureInPictureController {
            return c
        }
        return nil
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
                    let item = AVPlayerItem(url: url)
                    self.player?.replaceCurrentItem(with: item)
                    self.observeItemAndPlay(item: item, startAtSecond: currentSecond)
                    CrashLogger.shared.log("ClockPIPManager 已设置 playerItem（fast-start 视频）")
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
                    self.observeItemAndPlay(item: item, startAtSecond: 0)
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

    private func observeItemAndPlay(item: AVPlayerItem, startAtSecond: Int) {
        itemObserver?.invalidate()
        itemReady = false
        itemObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self = self else { return }
            CrashLogger.shared.log("AVPlayerItem status=\(item.status.rawValue)")
            if item.status == .readyToPlay {
                self.itemReady = true
                let t = CMTime(value: Int64(startAtSecond), timescale: 1)
                self.player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                self.player?.play()
                CrashLogger.shared.log("AVPlayerItem readyToPlay，准备启动 PiP")
                self.tryStartPiP()
            } else if item.status == .failed {
                CrashLogger.shared.log("AVPlayerItem failed: \(item.error?.localizedDescription ?? "unknown")")
            }
        }
    }

    /// 尝试启动 PiP：需要 controller + presentDone + itemReady 三者就绪。
    /// 优先直接 startPictureInPicture()（zk 同款，手势内直调）；
    /// 若 isPictureInPicturePossible=false，则用 dismiss 触发系统自动 PiP（canStartPictureInPictureAutomaticallyFromInline）。
    private func tryStartPiP() {
        guard let controller = pipController, presentDone, itemReady else {
            CrashLogger.shared.log("tryStartPiP 跳过：controller/present/item 未就绪 (controller=\(pipController != nil), present=\(presentDone), item=\(itemReady))")
            return
        }
        guard !triedStart else { return }
        triedStart = true

        let possible = controller.isPictureInPicturePossible
        CrashLogger.shared.log("PiP isPictureInPicturePossible=\(possible)")

        if possible {
            controller.startPictureInPicture()
            CrashLogger.shared.log("PiP startPictureInPicture() 已调用（直接启动）")
        } else if let pvc = playerVC, pvc.presentingViewController != nil {
            // 兜底：dismiss 触发系统自动 PiP（不要求手势）
            CrashLogger.shared.log("PiP possible=false，dismiss playerVC 触发系统自动 PiP")
            pvc.dismiss(animated: false, completion: nil)
        } else {
            CrashLogger.shared.log("PiP possible=false 且 playerVC 未 present，无法触发")
        }
        startWatchdog()
    }

    /// 启动一个 watchdog：若 12s 内 PiP 仍未接管，则 dismiss 全屏恢复 App，避免卡在“启动中”。
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard !self.isPictureInPictureActive else { return }
            CrashLogger.shared.log("PiP watchdog 12s 未接管，dismiss 全屏恢复 App")
            self.playerVC?.dismiss(animated: false, completion: nil)
            self.playerVC?.willMove(toParent: nil)
            self.playerVC?.view.removeFromSuperview()
            self.playerVC?.removeFromParent()
            self.playerVC = nil
        }
    }

    @objc private func itemDidPlayToEnd(_ notification: Notification) {
        // 手动循环
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - 生成时钟视频（在 genQueue 后台执行；UIKit 绘制仍回主线程，但等待的是后台线程，不会死锁）

    private func generateClockVideo(minuteStart: Date, completion: @escaping (URL?) -> Void) {
        let rawURL = Self.cachesVideoRawURL()
        try? FileManager.default.removeItem(at: rawURL)

        guard let writer = try? AVAssetWriter(outputURL: rawURL, fileType: .mp4) else {
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
                CrashLogger.shared.log("ClockPIPManager 原始视频生成完成: \(rawURL.lastPathComponent)")
                // 用 AVAssetExportSession 重新导出为 fast-start 标准 MP4（对齐 zk，提升 PiP 兼容性）
                Self.exportFastStart(source: rawURL) { finalURL in
                    CrashLogger.shared.log("ClockPIPManager 视频导出完成: \(finalURL?.lastPathComponent ?? "nil")")
                    completion(finalURL)
                }
            } else {
                CrashLogger.shared.log("ClockPIPManager 视频生成失败 status=\(writer.status.rawValue)")
                completion(nil)
            }
        }
    }

    /// 把 AVAssetWriter 产物用 AVAssetExportSession 重新导出为 fast-start MP4（moov 前置），
    /// 这是 PiP 资格检查能认可的关键（zk 也用 AVAssetExportSession）。
    private static func exportFastStart(source: URL, completion: @escaping (URL?) -> Void) {
        let asset = AVAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            CrashLogger.shared.log("ClockPIPManager 创建 AVAssetExportSession 失败，使用原始文件")
            completion(source)
            return
        }
        let finalURL = Self.cachesVideoURL()
        try? FileManager.default.removeItem(at: finalURL)
        session.outputURL = finalURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
            if session.status == .completed {
                completion(finalURL)
            } else {
                CrashLogger.shared.log("ClockPIPManager 导出失败 status=\(session.status.rawValue)，回退原始文件")
                completion(source)
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
        // 不要做 Y 轴翻转，否则播放时上下镜像。
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

    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return nil }
        var vc = scene.windows.first?.rootViewController
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }

    static func cachesVideoRawURL() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("clock_raw.mp4")
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
        triedStart = true
        CrashLogger.shared.log("PiP 已开始显示（系统浮窗接管）")
        watchdogTimer?.invalidate(); watchdogTimer = nil
        // PiP 已接管播放，playerVC 此时应已被系统 dismiss，确保清理引用
        if let pvc = playerVC, pvc.presentingViewController == nil {
            pvc.willMove(toParent: nil)
            pvc.view.removeFromSuperview()
            pvc.removeFromParent()
            playerVC = nil
        }
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
        watchdogTimer?.invalidate(); watchdogTimer = nil
        FloatingClockManager.shared.pipStateDidChange()
    }
}

// MARK: - AVPlayerViewControllerDelegate

extension ClockPIPManager: AVPlayerViewControllerDelegate {

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        CrashLogger.shared.log("PiP restoreUserInterfaceForPictureInPictureStop")
        completionHandler(true)
    }
}
