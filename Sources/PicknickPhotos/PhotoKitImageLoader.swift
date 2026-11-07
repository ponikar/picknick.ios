import CoreGraphics
import Foundation
import PicknickCore
import Photos

/// Loads index-sized renditions from PhotoKit.
public struct PhotoKitImageLoader: ImageLoader {
    private let imageManager: PHImageManager

    public init(imageManager: PHImageManager = .default()) {
        self.imageManager = imageManager
    }

    public func loadImage(_ request: ImageRequest) async throws -> CGImage {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [request.assetID.rawValue],
            options: nil
        ).firstObject else {
            throw PicknickError.assetNotFound(request.assetID)
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = request.allowsNetworkAccess
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        // Guarantees the result handler runs exactly once, which is what makes
        // bridging to a continuation safe.
        options.isSynchronous = true

        let side = CGFloat(request.maxPixelSize)
        let targetSize = CGSize(width: side, height: side)

        let outcome: ImageOutcome = await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                continuation.resume(returning: ImageOutcome(image: image, info: info))
            }
        }

        if outcome.isCloudOnly, !request.allowsNetworkAccess {
            throw PicknickError.assetUnavailableLocally(request.assetID)
        }

        guard let cgImage = outcome.image?.coreGraphicsImage else {
            throw PicknickError.imageDecodingFailed(request.assetID)
        }

        return cgImage
    }
}

private struct ImageOutcome: @unchecked Sendable {
    let image: PlatformImage?
    let info: [AnyHashable: Any]?

    /// True when PhotoKit declined because the only copy lives in iCloud.
    var isCloudOnly: Bool {
        info?[PHImageResultIsInCloudKey] as? Bool == true
    }
}
