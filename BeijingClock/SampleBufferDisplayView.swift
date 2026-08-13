import AVFoundation
import UIKit

/// 承载 AVSampleBufferDisplayLayer 的 UIView，作为画中画(PiP)的内联源。
final class SampleBufferDisplayView: UIView {

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var sampleBufferLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        sampleBufferLayer.videoGravity = .resizeAspect
        sampleBufferLayer.backgroundColor = UIColor.black.cgColor
        sampleBufferLayer.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
