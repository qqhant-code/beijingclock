import AVFoundation
import CoreGraphics
import CoreVideo
import UIKit

/// 把一段文字（北京时间）画进 CVPixelBuffer，再包成 CMSampleBuffer，
/// 供 AVSampleBufferDisplayLayer 逐帧播放，最终由画中画(PiP)悬浮显示。
enum ClockFrameRenderer {

    /// 画中画帧尺寸（决定悬浮窗默认比例）。
    /// 细长条 720x120，类似 zk 助手顶部悬浮条比例。
    static let frameSize = CGSize(width: 720, height: 120)

    /// 画面是否垂直翻转。若 PiP 里字是倒的，在 App 内点「画面翻转」即可，无需重新编译。
    static var flipVertical = false

    static func makeSampleBuffer(text: String) -> CMSampleBuffer? {
        guard let buf = pixelBuffer(from: renderImage(text: text)) else { return nil }
        return sampleBuffer(from: buf)
    }

    // MARK: - 用 UIKit 渲染文字（朝向 100% 正确，避开手动翻转坐标的坑）

    private static func renderImage(text: String) -> UIImage {
        let size = frameSize
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            // 深色背景，PiP 窗口本身会带圆角/阴影
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            // 细长条适配：字高约占画布 55%，完整显示
            let font = UIFont.monospacedSystemFont(ofSize: 30, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let textSize = str.size()
            let point = CGPoint(x: (size.width - textSize.width) / 2,
                                y: (size.height - textSize.height) / 2)
            str.draw(at: point)
        }
    }

    // MARK: - UIImage -> CVPixelBuffer（标准翻转绘制，匹配 AVSampleBufferDisplayLayer 朝向）

    private static func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        let w = Int(frameSize.width)
        let h = Int(frameSize.height)

        var pxbuf: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pxbuf) == kCVReturnSuccess,
              let buf = pxbuf else { return nil }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }

        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)

        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                        | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let ctx = CGContext(data: base, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo.rawValue) else { return nil }

        // 标准翻转：让 UIImage(上下正) 画进像素缓冲后也是上下正。
        // 若 PiP 里仍倒着，把 flipVertical 设为 true 即可去掉这次翻转。
        if !flipVertical {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        if let cg = image.cgImage {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    // MARK: - CVPixelBuffer -> CMSampleBuffer

    private static func sampleBuffer(from buf: CVPixelBuffer) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                      imageBuffer: buf,
                                                      formatDescriptionOut: &fmt)
        guard let fmtDesc = fmt else { return nil }

        var sbuf: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: buf,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: fmtDesc,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sbuf)
        return sbuf
    }
}
