import Foundation
import PicknickCore
import Photos

/// `PhotoLibrary` backed by PhotoKit.
public struct PhotoKitLibrary: PhotoLibrary {
    private let includesHiddenAssets: Bool

    /// Hidden assets stay out of the index unless the host app deliberately
    /// opts in; surfacing them in search would defeat the point of hiding them.
    public init(includesHiddenAssets: Bool = false) {
        self.includesHiddenAssets = includesHiddenAssets
    }

    public var authorization: LibraryAuthorization {
        get async {
            LibraryAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }
    }

    @discardableResult
    public func requestAuthorization() async -> LibraryAuthorization {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: LibraryAuthorization(status))
            }
        }
    }

    public func fingerprints() async throws -> [AssetID: AssetFingerprint] {
        let options = fetchOptions()
        // Only the two properties the diff needs are touched, so PhotoKit never
        // has to fault in the rest of each asset.
        options.wantsIncrementalChangeDetails = false

        let result = PHAsset.fetchAssets(with: options)
        var fingerprints: [AssetID: AssetFingerprint] = [:]
        fingerprints.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            fingerprints[AssetID(asset.localIdentifier)] =
                AssetFingerprint(modifiedAt: asset.modificationDate)
        }

        return fingerprints
    }

    public func metadata(for ids: [AssetID]) async throws -> [AssetMetadata] {
        guard !ids.isEmpty else { return [] }

        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: ids.map(\.rawValue),
            options: fetchOptions()
        )

        var metadata: [AssetMetadata] = []
        metadata.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            metadata.append(AssetMetadata(asset))
        }

        return metadata
    }

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = LibraryChangeObserver { continuation.yield(()) }
            PHPhotoLibrary.shared().register(observer)
            continuation.onTermination = { _ in
                PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            }
        }
    }

    private func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = includesHiddenAssets
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        return options
    }
}

/// PhotoKit requires an object conforming to its observer protocol; the change
/// details are ignored because the coordinator responds by rescanning.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
