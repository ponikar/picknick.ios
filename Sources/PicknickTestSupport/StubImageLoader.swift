import CoreGraphics
import Foundation
import PicknickCore

/// Returns a solid-colour bitmap for any asset, or fails on demand.
public actor StubImageLoader: ImageLoader {
    public private(set) var requests: [ImageRequest] = []
    private var failures: [AssetID: PicknickError] = [:]

    public init() {}

    public func failAll(for id: AssetID, with error: PicknickError) {
        failures[id] = error
    }

    public func loadImage(_ request: ImageRequest) async throws -> CGImage {
        requests.append(request)

        if let failure = failures[request.assetID] {
            throw failure
        }

        guard let image = Self.makeImage(side: max(1, request.maxPixelSize / 8)) else {
            throw PicknickError.imageDecodingFailed(request.assetID)
        }
        return image
    }

    private static func makeImage(side: Int) -> CGImage? {
        let context: CGContext? = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context?.makeImage()
    }
}
