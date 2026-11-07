import CoreGraphics
import CoreText
import Foundation

enum ImageFixtures {
    static func context(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    /// Black text on white, drawn in the top half of the image.
    static func text(_ string: String, width: Int = 1600, height: Int = 800) -> CGImage {
        let context = context(width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 120, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        // Core Graphics has a bottom-left origin, so a high y lands near the top.
        context.textPosition = CGPoint(x: 80, y: Double(height) * 0.7)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    static func scene(width: Int = 512, height: Int = 512) -> CGImage {
        let context = context(width: width, height: height)
        context.setFillColor(CGColor(red: 0.4, green: 0.7, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: width * 3 / 4 - 40, y: height * 3 / 4 - 40, width: 80, height: 80))
        return context.makeImage()!
    }
}
