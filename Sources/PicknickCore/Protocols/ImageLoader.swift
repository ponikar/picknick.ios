import CoreGraphics
import Foundation

public struct ImageRequest: Hashable, Sendable {
    public let assetID: AssetID
    public let maxPixelSize: Int

    /// Off by default, and off for every stage in v1. Turning this on lets the
    /// request pull an original down from iCloud, which is slow, metered, and
    /// not something an index pass may decide on the user's behalf.
    public let allowsNetworkAccess: Bool

    public init(assetID: AssetID, maxPixelSize: Int, allowsNetworkAccess: Bool = false) {
        self.assetID = assetID
        self.maxPixelSize = maxPixelSize
        self.allowsNetworkAccess = allowsNetworkAccess
    }
}

public protocol ImageLoader: Sendable {
    /// Throws `.assetUnavailableLocally` when only a cloud copy exists and the
    /// request forbids network access, so the caller can defer rather than
    /// record a permanent failure.
    func loadImage(_ request: ImageRequest) async throws -> CGImage
}
