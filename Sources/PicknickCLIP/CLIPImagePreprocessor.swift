import CoreGraphics
import CoreVideo
import Foundation

/// Turns an arbitrary image into the square pixel buffer the encoder takes.
///
/// Matches CLIP's training transform: scale the short side to the target, then
/// center-crop. Pixel values stay in 0...255; the MobileCLIP Core ML export
/// applies its own 1/255 scale.
public enum CLIPImagePreprocessor {
    public static func pixelBuffer(
        from image: CGImage,
        spec: CLIPImageInputSpec
    ) throws -> CVPixelBuffer {
        guard spec.width > 0, spec.height > 0, image.width > 0, image.height > 0 else {
            throw CLIPError.predictionFailed("empty image or input size")
        }
        let bitmapInfo: UInt32
        switch spec.pixelFormat {
        case kCVPixelFormatType_32BGRA:
            bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        case kCVPixelFormatType_32ARGB:
            bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        default:
            throw CLIPError.unsupportedModelInterface("pixel format \(spec.pixelFormat)")
        }

        var created: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, spec.width, spec.height, spec.pixelFormat, attributes, &created
        )
        guard status == kCVReturnSuccess, let buffer = created else {
            throw CLIPError.predictionFailed("CVPixelBufferCreate returned \(status)")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: spec.width,
            height: spec.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo
        ) else {
            throw CLIPError.predictionFailed("could not create a bitmap context")
        }

        context.interpolationQuality = .high
        context.draw(image, in: aspectFillRect(
            source: CGSize(width: image.width, height: image.height),
            target: CGSize(width: spec.width, height: spec.height)
        ))
        return buffer
    }

    static func aspectFillRect(source: CGSize, target: CGSize) -> CGRect {
        let scale = max(target.width / source.width, target.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (target.width - size.width) / 2,
            y: (target.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
