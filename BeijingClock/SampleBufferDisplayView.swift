import AVFoundation
import UIKit

/// 承载 AVSampleBufferDisplayLayer 的 UIView，作为画中画(PiP)的内联源。
final class SampleBufferDisplayView: UIView {

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var sampleBufferLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    /// 当 layer 真正进入 window 并 ready 后调用
    var onDidMoveToWindow: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        sampleBufferLayer.videoGravity = .resizeAspect
        sampleBufferLayer.backgroundColor = UIColor.black.cgColor
        sampleBufferLayer.isOpaque = true
        // 让 layer 使用 host time 作为时间基准，避免 sample buffer 时间戳对不上
        if let hostClock = CMClockGetHostTimeClock() {
            let tb = CMTimebase(sourceClock: hostClock)
            try? tb.setTime(.zero)
            sampleBufferLayer.controlTimebase = tb
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // 稍微延迟，等 layer 与 render server 建立连接
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.onDidMoveToWindow?()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
