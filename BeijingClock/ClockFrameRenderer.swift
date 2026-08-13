import AVFoundation
import CoreGraphics
import CoreVideo
import UIKit

/// 把一段文字（北京时间）画进 CVPixelBuffer，再包成 CMSampleBuffer，
/// 供 AVSampleBufferDisplayLayer 逐帧播放，最终由画中画(PiP)悬浮显示。
enum ClockFrameRenderer {

    /// 画中画帧尺寸（决定悬浮窗默认比例，用户可在 PiP 里缩放）。
    static let frameSize = CGSize(width: 480, height: 160)

    static func makeSampleBuffer(text: String) -> CMSampleBuffer? {
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

        // 32BGRA：little-endian + premultipliedFirst，这是往 CVPixelBuffer 画 CGContext 的通用组合
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                        | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let ctx = CGContext(data: base, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo.rawValue) else { return nil }

        // 背景：纯黑（圆角交给 PiP 窗口本身）
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 文字：等宽字体，白字，垂直水平居中
        let font = CTFontCreateWithName("Menlo" as CFString, 44, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let lineBounds = CTLineGetBoundsWithOptions(line, [])
        let x = (CGFloat(w) - lineBounds.width) / 2
        let y = (CGFloat(h) + lineBounds.height) / 2

        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)

        var timing = CMSampleTimingInfo(
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
            duration: .invalid,
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
