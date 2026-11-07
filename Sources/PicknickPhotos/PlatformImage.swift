import CoreGraphics

#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage

extension UIImage {
    var coreGraphicsImage: CGImage? { cgImage }
}
#elseif canImport(AppKit)
import AppKit

typealias PlatformImage = NSImage

extension NSImage {
    var coreGraphicsImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#endif
