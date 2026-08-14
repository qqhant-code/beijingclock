import UIKit
import AVKit
import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// 画中画悬浮时钟管理器。
///
/// 采用 iOS 官方标准方案（对齐用户提供的阿里云/掘金资料）：
/// 用 AVPlayer 播放一段“北京时间”视频，通过 AVPictureInPictureController(playerLayer:)
/// 把画面投射成系统画中画小窗（iPhone 上唯一合法的真·跨 App 悬浮方式）。
///
/// 关键修正（对比前几版）：
/// 1) 直接 AVPictureInPictureController(playerLayer:) 创建控制器，不再依赖
///    AVPlayerViewController.pictureInPictureController 这个取不到的懒加载属性。
/// 2) playerLayer 必须挂在一个真正可见、在窗口层级里的宿主 view 上，PiP 才可能 possible。
/// 3) 视频用 Core Graphics 后台一次性批量生成，去掉在你设备上崩溃的 AVAssetExportSession。
/// 4) 预览层始终带“悬浮窗 / 关闭”两个按钮，PiP 启动失败也不会卡死，可手动触发。
final class ClockPIPManager: NSObject {

    static let shared = ClockPIPManager()

    /// 视频帧尺寸：细长条，宽:高 = 4:1。
    static let videoWidth: Int = 640
    static let videoHeight: Int = 160

    /// 视频生成专用串行队列。
    private let genQueue = DispatchQueue(label: "com.beijingclock.videogen")

    private var pipController: AVPictureInPictureController?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var hostView: UIView?
    private var itemObserver: NSKeyValueObservation?
    private var pollTimer: Timer?
    private var regenTimer: Timer?
    private var hintTimer: Timer?

    private var offset: TimeInterval = 0
    private var running = false
    private var triedStart = false
    private var currentMinuteKey: String = ""

    private(set) var isRunning = false
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
        triedStart = false

        setupAudioSession()

        // 异步（快速）生成“当前分钟”视频，不阻塞按钮手势。
        let (minuteStart, key, currentSecond) = Self.currentBeijingMinuteInfo(offset: offset)
        currentMinuteKey = key
        CrashLogger.shared.log("ClockPIPManager 生成视频 for minute key=\(key) startAtSecond=\(currentSecond)")

        genQueue.async { [weak self] in
            guard let self = self, self.running else { return }
            self.generateClockVideo(minuteStart: minuteStart) { [weak self] url in
                guard let self = self else { return }
                guard let url = url else {
                    CrashLogger.shared.log("ClockPIPManager 视频生成失败，无法启动 PiP")
                    DispatchQueue.main.async { FloatingClockManager.shared.stop() }
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.running else { return }
                    self.setupPlayerAndPiP(with: url, startAtSecond: currentSecond)
                }
            }
        }
        startRegenTimer()
    }

    func stop() {
        CrashLogger.shared.log("ClockPIPManager.stop 进入")
        running = false
        isRunning = false
        isPictureInPictureActive = false
        pollTimer?.invalidate(); pollTimer = nil
        regenTimer?.invalidate(); regenTimer = nil
        hintTimer?.invalidate(); hintTimer = nil
        itemObserver?.invalidate(); itemObserver = nil

        pipController?.stopPictureInPicture()
        pipController?.delegate = nil
        pipController = nil

        removeHostView()

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerLayer = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        CrashLogger.shared.log("ClockPIPManager.stop 完成")
    }

    func setOffset(_ offset: TimeInterval) {
        self.offset = offset
        rebuildIfNeeded(force: true)
    }

    // MARK: - 音频会话（后台保活，让 PiP 视频继续驱动）

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
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

    // MARK: - 创建播放器 + 宿主视图 + 直接 PiP 控制器

    private func setupPlayerAndPiP(with url: URL, startAtSecond: Int) {
        guard running else { return }

        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none
        self.player = player

        // 1) 宿主 view：放在主窗口根 VC 的视图上，真实可见，PiP 才 possible。
        let host = makeHostView()
        let layer = AVPlayerLayer(player: player)
        layer.frame = host.bounds
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
        host.layer.insertSublayer(layer, at: 0)
        self.playerLayer = layer
        self.hostView = host

        // 2) 直接创建 PiP 控制器（标准方案，不依赖 AVPlayerViewController 懒加载属性）。
        guard let pip = AVPictureInPictureController(playerLayer: layer) else {
            CrashLogger.shared.log("ClockPIPManager 创建 AVPictureInPictureController 失败（playerLayer）")
            FloatingClockManager.shared.stop()
            return
        }
        pipController = pip
        pip.delegate = self
        CrashLogger.shared.log("ClockPIPManager 已创建 PiPController(playerLayer:)")

        // 3) 观察播放状态，ready 后 seek + play，然后轮询 possible。
        itemObserver?.invalidate()
        itemObserver = player.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self = self else { return }
            CrashLogger.shared.log("AVPlayerItem status=\(item.status.rawValue)")
            if item.status == .readyToPlay {
                let t = CMTime(value: Int64(startAtSecond), timescale: 1)
                self.player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                self.player?.play()
                CrashLogger.shared.log("AVPlayerItem readyToPlay，开始播放并尝试 PiP")
                self.startPoll()
            } else if item.status == .failed {
                CrashLogger.shared.log("AVPlayerItem failed: \(item.error?.localizedDescription ?? "unknown")")
            }
        }

        startPoll()
        startHintTimer()
        CrashLogger.shared.log("ClockPIPManager.setupPlayerAndPiP 完成")
    }

    /// 创建可见的预览宿主 view（顶部细长条），并加上“悬浮窗 / 关闭”两个按钮。
    private func makeHostView() -> UIView {
        let screen = UIScreen.main.bounds
        let w = min(screen.width - 40, 320)
        let h = w / 4.0
        let x = (screen.width - w) / 2
        let y: CGFloat = 70
        let host = UIView(frame: CGRect(x: x, y: y, width: w, height: h))
        host.backgroundColor = UIColor.black.withAlphaComponent(0.001)
        host.layer.cornerRadius = 14
        host.layer.masksToBounds = true
        host.isUserInteractionEnabled = true

        // 悬浮窗按钮（用户手势内调用 startPictureInPicture，最可靠）
        let floatBtn = UIButton(type: .system)
        floatBtn.setTitle("悬浮窗", for: .normal)
        floatBtn.setTitleColor(.white, for: .normal)
        floatBtn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        floatBtn.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        floatBtn.layer.cornerRadius = 12
        floatBtn.translatesAutoresizingMaskIntoConstraints = false
        floatBtn.addTarget(self, action: #selector(floatTapped), for: .touchUpInside)
        host.addSubview(floatBtn)

        // 关闭按钮
        let closeBtn = UIButton(type: .system)
        closeBtn.setTitle("关闭", for: .normal)
        closeBtn.setTitleColor(.white, for: .normal)
        closeBtn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        closeBtn.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        closeBtn.layer.cornerRadius = 12
        closeBtn.translatesAutoresizingMaskToConstraints = false
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        host.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            floatBtn.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 10),
            floatBtn.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),
            floatBtn.widthAnchor.constraint(equalToConstant: 70),
            floatBtn.heightAnchor.constraint(equalToConstant: 30),
            closeBtn.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            closeBtn.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),
            closeBtn.widthAnchor.constraint(equalToConstant: 70),
            closeBtn.heightAnchor.constraint(equalToConstant: 30)
        ])

        // 挂到主窗口根 VC 的 view 上（确保可见、在窗口层级里）
        if let rootView = Self.rootView() {
            rootView.addSubview(host)
        }
        return host
    }

    private func removeHostView() {
        hostView?.removeFromSuperview()
        hostView = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    @objc private func floatTapped() {
        CrashLogger.shared.log("用户点击“悬浮窗”按钮（手势内启动 PiP）")
        guard let pip = pipController else { return }
        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            CrashLogger.shared.log("PiP 尚未 possible，稍候自动重试")
        }
    }

    @objc private func closeTapped() {
        CrashLogger.shared.log("用户点击“关闭”按钮，停止")
        FloatingClockManager.shared.stop()
    }

    // MARK: - 轮询 PiP 是否 possible

    private func startPoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self, self.running else { return }
            guard let pip = self.pipController else { return }
            let possible = pip.isPictureInPicturePossible
            if possible && !self.triedStart {
                self.triedStart = true
                pip.startPictureInPicture()
                CrashLogger.shared.log("PiP isPictureInPicturePossible=true，已自动 startPictureInPicture()")
            }
        }
    }

    /// 启动后若 6s 仍未进入 PiP，仅打日志提示（不再自动停止，避免卡死；用户可点“悬浮窗”按钮手动触发）。
    private func startHintTimer() {
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard !self.isPictureInPictureActive else { return }
            CrashLogger.shared.log("PiP 6s 内未自动接管：可点击预览上的“悬浮窗”按钮手动启动（iPhone 有时要求手势触发）")
        }
    }

    // MARK: - 视频重生成

    private func rebuildIfNeeded(force: Bool) {
        let (minuteStart, key, _) = Self.currentBeijingMinuteInfo(offset: offset)
        if !force, key == currentMinuteKey { return }
        CrashLogger.shared.log("ClockPIPManager 重生成视频 (key \(currentMinuteKey) -> \(key), force=\(force))")
        currentMinuteKey = key
        genQueue.async { [weak self] in
            guard let self = self, self.running else { return }
            self.generateClockVideo(minuteStart: minuteStart) { [weak self] url in
                guard let self = self else { return }
                guard let url = url else { return }
                DispatchQueue.main.async {
                    guard self.running else { return }
                    let item = AVPlayerItem(url: url)
                    self.player?.replaceCurrentItem(with: item)
                    self.itemObserver?.invalidate()
                    self.itemObserver = item.observe(\.status, options: [.new]) { [weak self] it, _ in
                        guard let self = self, it.status == .readyToPlay else { return }
                        self.player?.play()
                        CrashLogger.shared.log("ClockPIPManager 已替换 playerItem 为最新分钟并开始播放")
                    }
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

    @objc private func itemDidPlayToEnd(_ notification: Notification) {
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - 生成时钟视频（Core Graphics 后台一次性批量画 60 帧）

    private func generateClockVideo(minuteStart: Date, completion: @escaping (URL?) -> Void) {
        let outURL = Self.cachesVideoURL()
        try? FileManager.default.removeItem(at: outURL)

        guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .mp4) else {
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

        // 在主线程一次性画出 60 帧（UIKit 绘制必须在主线程，但只往返一次，速度快）。
        var buffers: [CVPixelBuffer] = []
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { sem.signal(); return }
            for second in 0..<60 {
                let fd = minuteStart.addingTimeInterval(TimeInterval(second))
                let text = TimeSync.formatBeijingPrecise(fd)
                if let pb = self.makeFrame(text: text) {
                    buffers.append(pb)
                }
            }
            sem.signal()
        }
        sem.wait()
        guard buffers.count == 60 else {
            CrashLogger.shared.log("ClockPIPManager 帧数不足（\(buffers.count)），生成失败")
            writer.cancelWriting()
            completion(nil)
            return
        }

        var frameTime = CMTime.zero
        let frameDuration = CMTime(value: 1, timescale: 1)
        for pb in buffers {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            if !adaptor.append(pb, withPresentationTime: frameTime) {
                CrashLogger.shared.log("ClockPIPManager 写入帧失败")
                writer.cancelWriting()
                completion(nil)
                return
            }
            frameTime = CMTimeAdd(frameTime, frameDuration)
        }

        input.markAsFinished()
        writer.finishWriting {
            if writer.status == .completed {
                CrashLogger.shared.log("ClockPIPManager 视频生成完成: \(outURL.lastPathComponent)")
                completion(outURL)
            } else {
                CrashLogger.shared.log("ClockPIPManager 视频生成失败 status=\(writer.status.rawValue)")
                completion(nil)
            }
        }
    }

    /// 用 Core Graphics 把时钟文字画进 CVPixelBuffer（后台主线程调用，无翻转变换）。
    private func makeFrame(text: String) -> CVPixelBuffer? {
        let width = Self.videoWidth
        let height = Self.videoHeight
        let size = CGSize(width: width, height: height)

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

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        guard let ctx = CGContext(
            data: base,
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

        ctx.clear(CGRect(origin: .zero, size: size))
        // 圆角深色背景
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: size),
                          cornerWidth: 22, cornerHeight: 22, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(UIColor(white: 0.05, alpha: 0.92).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        // 文字
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 72, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()
        let textRect = CGRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attrs)
        return pixelBuffer
    }

    // MARK: - 计算“北京时间当前分钟”的起点与秒偏移

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

    static func rootView() -> UIView? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return nil }
        guard let root = scene.windows.first?.rootViewController else { return nil }
        var vc: UIViewController? = root
        while let presented = vc?.presentedViewController { vc = presented }
        return vc?.view
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
        pollTimer?.invalidate(); pollTimer = nil
        hintTimer?.invalidate(); hintTimer = nil
        // 隐藏预览宿主，系统 PiP 已接管；保留 player 继续播放。
        hostView?.isHidden = true
        FloatingClockManager.shared.pipStateDidChange()
    }

    func pictureInPictureControllerDidStop(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActive = false
        CrashLogger.shared.log("PiP 已停止")
        FloatingClockManager.shared.pipStateDidChange()
        // 用户关闭了 PiP，整体停止。
        FloatingClockManager.shared.stop()
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
